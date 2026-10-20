import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox

private enum SurfaceVideoError: Error {
    case invalidDimensions, invalidPacket, missingKeyframe, missingOutput, timeout
    case status(OSStatus)
}

private func videoCheck(_ status: OSStatus) throws {
    guard status == noErr else { throw SurfaceVideoError.status(status) }
}

private func videoDimensions(_ width: Int, _ height: Int) throws {
    guard width > 0, height > 0, width <= 4_000_000 / height else {
        throw SurfaceVideoError.invalidDimensions
    }
}

private let videoMaxBytes = 8 * 1024 * 1024
private let videoColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
private let videoBitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

private final class VideoOutput<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<Value?, Error>?

    func finish(status: OSStatus, dropped: Bool, value: Value?) {
        lock.lock()
        if status != noErr { result = .failure(SurfaceVideoError.status(status)) }
        else if dropped { result = .success(nil) }
        else if let value { result = .success(value) }
        else { result = .failure(SurfaceVideoError.missingOutput) }
        lock.unlock()
        ready.signal()
    }

    func wait() throws -> Value? {
        guard ready.wait(timeout: .now() + 2) == .success else { throw SurfaceVideoError.timeout }
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw SurfaceVideoError.missingOutput }
        return try result.get()
    }
}

private struct VideoPacket {
    let sps: Data
    let pps: Data
    let sample: Data
    let keyframe: Bool

    init(_ data: Data) throws {
        guard data.count <= videoMaxBytes, data.count >= 10 else { throw SurfaceVideoError.invalidPacket }
        let parsed: (Data, Data, Data, Bool) = try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes[0] == 69, bytes[1] == 83, bytes[2] == 86, bytes[3] == 49,
                  bytes[4] <= 1, bytes[5] == 4 else { throw SurfaceVideoError.invalidPacket }
            let spsSize = Int(bytes[6]) << 8 | Int(bytes[7])
            let ppsSize = Int(bytes[8]) << 8 | Int(bytes[9])
            let sampleStart = 10 + spsSize + ppsSize
            guard spsSize >= 4, ppsSize >= 2, sampleStart < bytes.count,
                  bytes[10] & 0x9f == 7, bytes[10 + spsSize] & 0x9f == 8 else {
                throw SurfaceVideoError.invalidPacket
            }
            var offset = sampleStart
            var idr = false
            var predicted = false
            while offset < bytes.count {
                guard bytes.count - offset >= 4 else { throw SurfaceVideoError.invalidPacket }
                let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
                guard size > 0, size <= bytes.count - offset, bytes[offset] & 0x80 == 0 else {
                    throw SurfaceVideoError.invalidPacket
                }
                switch bytes[offset] & 0x1f {
                case 1: predicted = true
                case 5: idr = true
                case 6, 9, 12: break
                default: throw SurfaceVideoError.invalidPacket
                }
                offset += size
            }
            guard idr != predicted, idr == (bytes[4] == 1) else { throw SurfaceVideoError.invalidPacket }
            return (Data(bytes[10..<(10 + spsSize)]), Data(bytes[(10 + spsSize)..<sampleStart]),
                    Data(bytes[sampleStart..<bytes.count]), idr)
        }
        (sps, pps, sample, keyframe) = parsed
    }

    func format(width: Int, height: Int) throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        try sps.withUnsafeBytes { spsBytes in
            try pps.withUnsafeBytes { ppsBytes in
                var pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [sps.count, pps.count]
                try videoCheck(CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format))
            }
        }
        guard let format else { throw SurfaceVideoError.invalidPacket }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        try videoDimensions(Int(dimensions.width), Int(dimensions.height))
        guard Int(dimensions.width) == width, Int(dimensions.height) == height else {
            throw SurfaceVideoError.invalidDimensions
        }
        return format
    }
}

public struct SurfaceVideoFrame: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    let refresh: Bool
}

private struct RetiredVideoCompressionSession: @unchecked Sendable {
    let session: VTCompressionSession

    func invalidate() {
        DispatchQueue.global(qos: .utility).async { [self] in
            // Drain callbacks before invalidation, without retaining the encoder or blocking its caller.
            _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
}

/// Callers publish every returned frame in order and discard the encoder after dropping one.
/// Retained refinement requires a consumer that caches the previous configuration's references.
public final class SurfaceVideoEncoder: @unchecked Sendable {
    private enum Profile {
        case motion, sharp
    }

    private struct Session {
        let session: VTCompressionSession
        let pool: CVPixelBufferPool
        let profile: Profile
        let width: Int
        let height: Int
        let requestedWidth: Int
        let requestedHeight: Int
        let epoch: TimeInterval
        var sequence: Int64 = 0
        var minimumQP = 35

        func serves(_ profile: Profile, width: Int, height: Int) -> Bool {
            self.profile == profile && requestedWidth == width && requestedHeight == height
        }
    }

    private let maximumMotionBytes = 48 * 1024
    private let refinement: SurfaceRefinement
    private let lock = NSLock()
    private var active: Session?
    private var cached: Session?

    public init(refinement: SurfaceRefinement = .retained) { self.refinement = refinement }
    deinit { clear() }

    public static func fittedVideoPixels(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = Double(max(1, width))
        let h = Double(max(1, height))
        let scale = min(1, 4096 / w, 4096 / h, sqrt(4_000_000 / w / h))
        return (max(16, Int(w * scale) / 2 * 2), max(16, Int(h * scale) / 2 * 2))
    }

    private func clear() {
        if let active { RetiredVideoCompressionSession(session: active.session).invalidate() }
        if let cached { RetiredVideoCompressionSession(session: cached.session).invalidate() }
        active = nil
        cached = nil
    }

    /// Restored configurations restart unless retained sharp prediction was negotiated.
    private func restore(_ profile: Profile, width: Int, height: Int) throws {
        guard active?.serves(profile, width: width, height: height) != true,
              let restored = cached, restored.serves(profile, width: width, height: height) else { return }
        cached = active
        active = restored
        guard profile == .motion || refinement == .independent else { return }
        active?.sequence = 0
        guard profile == .motion else { return }
        if restored.minimumQP != 42 {
            try videoCheck(VTSessionSetProperty(restored.session, key: kVTCompressionPropertyKey_MinAllowedFrameQP,
                                                value: NSNumber(value: 42)))
            active?.minimumQP = 42
        }
    }

    /// Refresh requests native-pixel refinement, independently decodable when required by the consumer.
    public func encode(_ image: CGImage, width: Int, height: Int, refresh: Bool = false, motion: Bool = false,
                       isCancelled: () -> Bool = { false }) throws -> SurfaceVideoFrame? {
        guard !isCancelled() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        do {
            guard !isCancelled() else { return nil }
            try videoDimensions(width, height)
            if refresh, image.width != width || image.height != height {
                throw SurfaceVideoError.invalidDimensions
            }
            var profile: Profile = refresh ? .sharp : motion ? .motion : active?.profile ?? .motion
            try restore(profile, width: width, height: height)
            var target = profile == .sharp ?
                (width: max(16, (width + 1) / 2 * 2), height: max(16, (height + 1) / 2 * 2)) :
                Self.fittedVideoPixels(width: width, height: height)
            guard target.width <= 4_000_000 / target.height else { clear(); return nil }
            if profile == .motion, let active, active.requestedWidth == width, active.requestedHeight == height {
                target = (active.width, active.height)
            }
            for attempt in 0..<6 {
                if active.map({ $0.width != target.width || $0.height != target.height || $0.profile != profile }) ?? true {
                    try start(width: target.width, height: target.height, requestedWidth: width,
                              requestedHeight: height, profile: profile)
                }
                guard let current = active else { throw SurfaceVideoError.missingOutput }
                guard !isCancelled() else { clear(); return nil }
                let independent = current.sequence == 0 || (refresh && self.refinement == .independent)
                guard let sample = try encodeSample(image, on: current, independent: independent,
                                                    isCancelled: isCancelled) else {
                    clear()
                    return nil
                }
                guard !isCancelled() else { clear(); return nil }
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                let refinement = refresh || (profile == .sharp && keyframe)
                let maximumBytes = refinement ? SurfaceImageEncoder.refinementBytes : maximumMotionBytes
                if let packet = try packetFromSample(sample, maximumBytes: maximumBytes, keyframe: keyframe) {
                    guard !independent || keyframe else { throw SurfaceVideoError.missingKeyframe }
                    guard !isCancelled() else { clear(); return nil }
                    active?.sequence += 1
                    return SurfaceVideoFrame(data: packet, width: current.width, height: current.height, refresh: refinement)
                }
                // Neither an oversized refinement nor its predicted successors can be published.
                if refinement || current.sequence > 0 {
                    clear()
                } else {
                    // The decoder never saw this first frame, so its active configuration is still the cached session.
                    RetiredVideoCompressionSession(session: current.session).invalidate()
                    active = nil
                }
                if refinement { return nil }
                if profile == .sharp {
                    profile = .motion
                    target = Self.fittedVideoPixels(width: width, height: height)
                    continue
                }
                guard target.width > 16 || target.height > 16 else {
                    throw SurfaceVideoError.invalidPacket
                }
                let size = CMSampleBufferGetTotalSampleSize(sample)
                let scale = min(0.75, max(0.25, sqrt(Double(maximumMotionBytes) / Double(size)) * 0.85))
                target = attempt == 4 ? (16, 16) :
                    (max(16, Int(Double(target.width) * scale) / 2 * 2),
                     max(16, Int(Double(target.height) * scale) / 2 * 2))
            }
            throw SurfaceVideoError.invalidPacket
        } catch {
            clear()
            throw error
        }
    }

    private func encodeSample(_ image: CGImage, on current: Session, independent: Bool,
                              isCancelled: () -> Bool) throws -> CMSampleBuffer? {
        let session = current.session, width = current.width, height = current.height
        if current.profile == .motion, current.sequence > 0, current.minimumQP != 35 {
            try videoCheck(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP,
                                                value: NSNumber(value: 35)))
            active?.minimumQP = 35
        }
        var buffer: CVPixelBuffer?
        try videoCheck(CVPixelBufferPoolCreatePixelBuffer(nil, current.pool, &buffer))
        guard let buffer else { throw SurfaceVideoError.missingOutput }
        try videoCheck(CVPixelBufferLockBaseAddress(buffer, []))
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: videoColorSpace,
                bitmapInfo: videoBitmapInfo) else { throw SurfaceVideoError.missingOutput }
            context.setBlendMode(.copy)
            if current.profile == .sharp {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: height - image.height,
                                              width: image.width, height: image.height))
            } else {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        guard !isCancelled() else { return nil }
        let output = VideoOutput<CMSampleBuffer>()
        try videoCheck(VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
            presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime - current.epoch, preferredTimescale: 1_000_000),
            duration: .invalid,
            frameProperties: independent ?
                [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            infoFlagsOut: nil, outputHandler: { status, flags, sample in
                output.finish(status: status, dropped: flags.contains(.frameDropped), value: sample)
            }))
        return try output.wait()
    }

    /// The active session, which sent the decoder's active configuration, becomes cached as the new IDR replaces it.
    private func start(width: Int, height: Int, requestedWidth: Int, requestedHeight: Int, profile: Profile) throws {
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var pool: CVPixelBufferPool?
        try videoCheck(CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary,
                                             attributes as CFDictionary, &pool))
        guard let pool else { throw SurfaceVideoError.missingOutput }
        var specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: profile == .motion]
        if profile == .sharp { specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true }
        var created: VTCompressionSession?
        try videoCheck(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created))
        guard let session = created else { throw SurfaceVideoError.missingOutput }
        if let active {
            if let cached { RetiredVideoCompressionSession(session: cached.session).invalidate() }
            cached = active
        }
        active = Session(session: session, pool: pool, profile: profile, width: width, height: height,
                         requestedWidth: requestedWidth, requestedHeight: requestedHeight,
                         epoch: ProcessInfo.processInfo.systemUptime)
        let settings: [(CFString, CFTypeRef)] = profile == .sharp ? [
            (kVTCompressionPropertyKey_ProfileLevel, "H264_High444Predictive_AutoLevel" as CFString),
            (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 15)),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse),
            (kVTCompressionPropertyKey_Quality, NSNumber(value: 1))] : [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 15)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 2_000_000)),
            (kVTCompressionPropertyKey_MinAllowedFrameQP, NSNumber(value: 35)),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)]
        for (key, value) in settings { try videoCheck(VTSessionSetProperty(session, key: key, value: value)) }
        // Zero lets the encoder choose keyframes; remove periodic scheduling without trusting that default.
        try videoCheck(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                            value: NSNumber(value: Int32.max)))
        try videoCheck(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                            value: NSNumber(value: 0)))
        try videoCheck(VTCompressionSessionPrepareToEncodeFrames(session))
    }

    private func packetFromSample(_ sample: CMSampleBuffer, maximumBytes: Int, keyframe: Bool) throws -> Data? {
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
              let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else {
            throw SurfaceVideoError.missingOutput
        }
        var parameters: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var count = 0
            var header: Int32 = 0
            try videoCheck(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &header))
            guard let pointer, size > 0, size <= Int(UInt16.max), header == 4, count == 2 else {
                throw SurfaceVideoError.invalidPacket
            }
            parameters.append(Data(bytes: pointer, count: size))
        }
        let size = CMBlockBufferGetDataLength(block)
        let total = 10 + parameters[0].count + parameters[1].count + size
        guard size > 0 else { throw SurfaceVideoError.invalidPacket }
        guard total <= maximumBytes else { return nil }
        var packet = Data(capacity: total)
        packet.append(contentsOf: [69, 83, 86, 49, keyframe ? 1 : 0, 4])
        for parameter in parameters {
            packet.append(UInt8(parameter.count >> 8))
            packet.append(UInt8(parameter.count & 255))
        }
        for parameter in parameters { packet.append(parameter) }
        let offset = packet.count
        packet.count = total
        try packet.withUnsafeMutableBytes { bytes in
            try videoCheck(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size,
                                                       destination: bytes.baseAddress!.advanced(by: offset)))
        }
        return packet
    }
}

public final class SurfaceVideoDecoder: @unchecked Sendable {
    private struct Configuration {
        let session: VTDecompressionSession
        let format: CMVideoFormatDescription
        let sps: Data
        let pps: Data

        func matches(_ packet: VideoPacket) -> Bool {
            sps == packet.sps && pps == packet.pps
        }
    }

    private let lock = NSLock()
    private var configuration: Configuration?
    private var cached: Configuration?

    public init() {}
    deinit { clear() }

    private func clear() {
        if let configuration { VTDecompressionSessionInvalidate(configuration.session) }
        if let cached { VTDecompressionSessionInvalidate(cached.session) }
        configuration = nil
        cached = nil
    }

    public func decode(_ data: Data, width: Int, height: Int) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        do {
            try videoDimensions(width, height)
            let packet = try VideoPacket(data)
            if configuration?.matches(packet) != true {
                // Only the exact cached configuration still holds a predicted packet's references.
                if cached?.matches(packet) == true {
                    swap(&configuration, &cached)
                } else {
                    guard packet.keyframe else { throw SurfaceVideoError.missingKeyframe }
                    let nextFormat = try packet.format(width: width, height: height)
                    var nextSession: VTDecompressionSession?
                    try videoCheck(VTDecompressionSessionCreate(allocator: nil, formatDescription: nextFormat,
                        decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                        imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                        outputCallback: nil, decompressionSessionOut: &nextSession))
                    guard let nextSession else { throw SurfaceVideoError.missingOutput }
                    if let cached { VTDecompressionSessionInvalidate(cached.session) }
                    cached = configuration
                    configuration = Configuration(session: nextSession, format: nextFormat, sps: packet.sps, pps: packet.pps)
                }
            }
            guard let configuration else { throw SurfaceVideoError.missingOutput }
            let session = configuration.session, format = configuration.format
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard Int(dimensions.width) == width, Int(dimensions.height) == height else {
                throw SurfaceVideoError.invalidDimensions
            }
            var block: CMBlockBuffer?
            try videoCheck(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                blockLength: packet.sample.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: packet.sample.count, flags: 0, blockBufferOut: &block))
            guard let block else { throw SurfaceVideoError.missingOutput }
            try packet.sample.withUnsafeBytes { bytes in
                try videoCheck(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: bytes.count))
            }
            var sample: CMSampleBuffer?
            var size = packet.sample.count
            try videoCheck(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &sample))
            guard let sample else { throw SurfaceVideoError.missingOutput }
            let output = VideoOutput<CVImageBuffer>()
            try videoCheck(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil,
                outputHandler: { status, flags, image, _, _ in
                    output.finish(status: status, dropped: flags.contains(.frameDropped), value: image)
                }))
            guard let pixel = try output.wait() else { throw SurfaceVideoError.missingOutput }
            guard CVPixelBufferGetWidth(pixel) == width, CVPixelBufferGetHeight(pixel) == height,
                  CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else {
                throw SurfaceVideoError.invalidDimensions
            }
            try videoCheck(CVPixelBufferLockBaseAddress(pixel, .readOnly))
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw SurfaceVideoError.missingOutput }
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            let pixels = Data(bytes: base, count: stride * height)
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: stride, space: videoColorSpace, bitmapInfo: CGBitmapInfo(rawValue: videoBitmapInfo),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw SurfaceVideoError.missingOutput
            }
            return image
        } catch {
            clear()
            throw error
        }
    }
}
