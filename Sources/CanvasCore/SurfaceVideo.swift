import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox

private enum SurfaceVideoError: Error {
    case invalidDimensions, invalidPacket, missingKeyframe, missingOutput, timeout
    case status(OSStatus)
}

// Process-local logical sessions, not hardware slots. Process exit releases sessions without invalidation events.
private final class VideoSessionDiagnostics: @unchecked Sendable {
    static let shared = VideoSessionDiagnostics()

    enum Kind: String { case encoder, decoder }
    enum Phase: String { case active, queued, executing }
    private struct Session {
        let kind: Kind
        let dimensions: String
        let profile: String
        let created: UInt64
        var phase: Phase = .active
    }
    private struct Counts {
        var created = 0
        var enqueued = 0
        var entered = 0
        var invalidated = 0
        var live = 0
        var queued = 0
        var executing = 0
        var peakLive = 0
        var peakQueued = 0
        var peakExecuting = 0

        mutating func updatePeaks() -> Bool {
            let increased = live > peakLive || queued > peakQueued || executing > peakExecuting
            peakLive = max(peakLive, live)
            peakQueued = max(peakQueued, queued)
            peakExecuting = max(peakExecuting, executing)
            return increased
        }

        var fields: String {
            "created=\(created),enqueued=\(enqueued),entered=\(entered),invalidated=\(invalidated)"
                + ",live=\(live),queued=\(queued),executing=\(executing)"
                + ",peakLive=\(peakLive),peakQueued=\(peakQueued),peakExecuting=\(peakExecuting)"
        }
    }

    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var encoders = Counts()
    private var decoders = Counts()
    private var recent: [String] = []
    private var event: UInt64 = 0

    func created(_ id: ObjectIdentifier, kind: Kind, width: Int, height: Int, profile: String) {
        lock.lock()
        sessions[id] = Session(kind: kind, dimensions: "\(width)x\(height)", profile: profile,
                               created: DispatchTime.now().uptimeNanoseconds)
        var counts = kind == .encoder ? encoders : decoders
        counts.created += 1
        counts.live += 1
        let peak = record("created", id: id, counts: &counts)
        if kind == .encoder { encoders = counts } else { decoders = counts }
        lock.unlock()
        if let peak { emit(peak) }
    }

    func transition(_ id: ObjectIdentifier, to phase: Phase?, synchronous: Bool = false) {
        lock.lock()
        guard var session = sessions[id] else { lock.unlock(); return }
        var counts = session.kind == .encoder ? encoders : decoders
        let name: String
        switch phase {
        case .queued:
            counts.enqueued += 1
            counts.queued += 1
            name = "retirement-enqueued"
        case .executing:
            if synchronous { counts.enqueued += 1 } else { counts.queued -= 1 }
            counts.entered += 1
            counts.executing += 1
            name = synchronous ? "retirement-enqueued+entered-sync" : "retirement-entered"
        case nil:
            counts.executing -= 1
            counts.live -= 1
            counts.invalidated += 1
            name = "invalidated"
        case .active:
            lock.unlock()
            return
        }
        if let phase {
            session.phase = phase
            sessions[id] = session
        }
        let peak = record(name, id: id, counts: &counts)
        if session.kind == .encoder { encoders = counts } else { decoders = counts }
        if phase == nil { sessions.removeValue(forKey: id) }
        lock.unlock()
        if let peak { emit(peak) }
    }

    // Only lifecycle events allocate history; the last 32 are retained, never frame successes.
    private func record(_ name: String, id: ObjectIdentifier, counts: inout Counts) -> String? {
        event += 1
        let now = DispatchTime.now().uptimeNanoseconds
        let session = sessions[id]!
        if recent.count == 32 { recent.removeFirst() }
        recent.append("event=\(event),ns=\(now),action=\(name),id=\(id)"
            + ",kind=\(session.kind.rawValue),dimensions=\(session.dimensions),profile=\(session.profile)"
            + ",age_ns=\(now - session.created)")
        if counts.updatePeaks() {
            // Peaks are sparse and expose backlog even when no codec failure occurs.
            return "type=peak pid=\(ProcessInfo.processInfo.processIdentifier) ns=\(now)"
                + " event=\(event) action=\(name) id=\(id) kind=\(session.kind.rawValue)"
                + " dimensions=\(session.dimensions) profile=\(session.profile) \(counts.fields)"
        }
        return nil
    }

    func failure(_ error: String, operation: String, id: ObjectIdentifier? = nil,
                 detail: String = "", file: StaticString = #fileID, line: UInt = #line) {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let context = id.flatMap { id in
            sessions[id].map {
                "id=\(id),kind=\($0.kind.rawValue),dimensions=\($0.dimensions),profile=\($0.profile),phase=\($0.phase.rawValue)"
            }
        } ?? "id=\(String(describing: id))"
        let message = "type=failure pid=\(ProcessInfo.processInfo.processIdentifier) ns=\(now)"
            + " operation=\(operation) site=\(file):\(line) error=\(error) detail=\(detail) \(context)"
            + " encoder={\(encoders.fields)} decoder={\(decoders.fields)}"
            + " recent=[\(recent.joined(separator: ";"))]"
        lock.unlock()
        emit(message)
    }

    private func emit(_ message: String) {
        FileHandle.standardError.write(Data(("SurfaceVideoDiagnostics \(message)\n").utf8))
    }
}

private func videoCheck(_ status: OSStatus, operation: String = #function,
                        id: ObjectIdentifier? = nil, detail: @autoclosure () -> String = "",
                        file: StaticString = #fileID, line: UInt = #line) throws {
    guard status == noErr else {
        VideoSessionDiagnostics.shared.failure("status(\(status))", operation: operation, id: id,
                                               detail: detail(), file: file, line: line)
        throw SurfaceVideoError.status(status)
    }
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
    private let sessionID: ObjectIdentifier

    init(sessionID: ObjectIdentifier) { self.sessionID = sessionID }

    func finish(status: OSStatus, dropped: Bool, value: Value?,
                file: StaticString = #fileID, line: UInt = #line) {
        lock.lock()
        if status != noErr { result = .failure(SurfaceVideoError.status(status)) }
        else if dropped { result = .success(nil) }
        else if let value { result = .success(value) }
        else { result = .failure(SurfaceVideoError.missingOutput) }
        lock.unlock()
        if status != noErr || (!dropped && value == nil) {
            VideoSessionDiagnostics.shared.failure(status != noErr ? "status(\(status))" : "missingOutput",
                operation: "callback", id: sessionID, file: file, line: line)
        }
        ready.signal()
    }

    func wait(file: StaticString = #fileID, line: UInt = #line) throws -> Value? {
        guard ready.wait(timeout: .now() + 2) == .success else {
            VideoSessionDiagnostics.shared.failure("timeout", operation: "output-wait", id: sessionID,
                                                   file: file, line: line)
            throw SurfaceVideoError.timeout
        }
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

enum SurfaceVideoCompressionSessions {
    static let retirementQueue = DispatchQueue(label: "easl.surface.video-retirement", qos: .utility)
    private static let counters = Locked((live: 0, retiring: 0))

    static var counts: (live: Int, retiring: Int) { counters.withLock { $0 } }

    static func waitForRetirements() {
        guard counters.withLock({ $0.retiring > 0 }) else { return }
        retirementQueue.sync {}
    }

    fileprivate static func didCreate() {
        counters.withLock { $0.live += 1 }
    }

    fileprivate static func retire(_ work: @escaping @Sendable () -> Void) {
        counters.withLock {
            $0.retiring += 1
            retirementQueue.async(execute: work)
        }
    }

    fileprivate static func didRetire() {
        counters.withLock {
            $0.live -= 1
            $0.retiring -= 1
        }
    }
}

private struct RetiredVideoCompressionSession: @unchecked Sendable {
    let session: VTCompressionSession

    func invalidate() {
        VideoSessionDiagnostics.shared.transition(ObjectIdentifier(session), to: .queued)
        SurfaceVideoCompressionSessions.retire { [self] in
            VideoSessionDiagnostics.shared.transition(ObjectIdentifier(session), to: .executing)
            // Drain callbacks before invalidation, without retaining the encoder or blocking its caller.
            let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            if status != noErr {
                VideoSessionDiagnostics.shared.failure("status(\(status))", operation: "retirement-complete-frames",
                                                       id: ObjectIdentifier(session))
            }
            VTCompressionSessionInvalidate(session)
            VideoSessionDiagnostics.shared.transition(ObjectIdentifier(session), to: nil)
            SurfaceVideoCompressionSessions.didRetire()
        }
    }
}

public final class SurfaceVideoEncoder: @unchecked Sendable {
    private enum Profile {
        case motion, sharp
    }

    private struct MotionSession {
        let session: VTCompressionSession
        let pool: CVPixelBufferPool
        let width: Int
        let height: Int
        let requestedWidth: Int
        let requestedHeight: Int
        let epoch: TimeInterval
        let minimumQP: Int
    }

    private let maximumMotionBytes = 48 * 1024
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var profile: Profile = .motion
    private var motionSession: MotionSession?
    private var width = 0
    private var height = 0
    private var requestedWidth = 0
    private var requestedHeight = 0
    private var sequence: Int64 = 0
    private var epoch: TimeInterval = 0
    private var minimumMotionQP = 35

    public init() {}
    deinit { clear() }

    public static func fittedVideoPixels(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = Double(max(1, width))
        let h = Double(max(1, height))
        let scale = min(1, 4096 / w, 4096 / h, sqrt(4_000_000 / w / h))
        return (max(16, Int(w * scale) / 2 * 2), max(16, Int(h * scale) / 2 * 2))
    }

    private func clearActive() {
        if let session { RetiredVideoCompressionSession(session: session).invalidate() }
        session = nil
        pool = nil
        sequence = 0
        profile = .motion
        minimumMotionQP = 35
    }

    private func clear() {
        clearActive()
        if let motionSession { RetiredVideoCompressionSession(session: motionSession.session).invalidate() }
        motionSession = nil
    }

    private func cacheMotion() {
        guard let session, let pool else { return }
        if let motionSession { RetiredVideoCompressionSession(session: motionSession.session).invalidate() }
        motionSession = MotionSession(session: session, pool: pool, width: width, height: height,
                                      requestedWidth: requestedWidth, requestedHeight: requestedHeight, epoch: epoch,
                                      minimumQP: minimumMotionQP)
        self.session = nil
        self.pool = nil
        sequence = 0
    }

    private func restoreMotion(width: Int, height: Int) throws {
        guard let motionSession, motionSession.requestedWidth == width,
              motionSession.requestedHeight == height else { return }
        clearActive()
        session = motionSession.session
        pool = motionSession.pool
        self.width = motionSession.width
        self.height = motionSession.height
        requestedWidth = width
        requestedHeight = height
        epoch = motionSession.epoch
        self.motionSession = nil
        minimumMotionQP = motionSession.minimumQP
        if minimumMotionQP != 42 {
            try videoCheck(VTSessionSetProperty(motionSession.session, key: kVTCompressionPropertyKey_MinAllowedFrameQP,
                                                value: NSNumber(value: 42)))
            minimumMotionQP = 42
        }
    }

    /// Refresh starts a native-pixel reference chain. Unpublished references reset the stream.
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
            var nextProfile: Profile = refresh ? .sharp : motion ? .motion : profile
            if nextProfile == .motion, profile == .sharp { try restoreMotion(width: width, height: height) }
            if nextProfile == .sharp, profile == .motion { cacheMotion() }
            var target = nextProfile == .sharp ?
                (width: max(16, (width + 1) / 2 * 2), height: max(16, (height + 1) / 2 * 2)) :
                Self.fittedVideoPixels(width: width, height: height)
            guard target.width <= 4_000_000 / target.height else { clear(); return nil }
            if nextProfile == .motion, session != nil, requestedWidth == width, requestedHeight == height {
                target = (self.width, self.height)
            }
            for attempt in 0..<6 {
                if session == nil || self.width != target.width || self.height != target.height || profile != nextProfile {
                    clearActive()
                    try start(width: target.width, height: target.height, profile: nextProfile)
                    requestedWidth = width
                    requestedHeight = height
                }
                guard !isCancelled() else { clear(); return nil }
                let independent = refresh || sequence == 0
                guard let sample = try encodeSample(image, forceKeyframe: independent, isCancelled: isCancelled) else {
                    clear()
                    return nil
                }
                guard !isCancelled() else { clear(); return nil }
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                let reference = nextProfile == .sharp && keyframe
                let maximumBytes = reference ? SurfaceImageEncoder.refinementBytes : maximumMotionBytes
                if let packet = try packetFromSample(sample, maximumBytes: maximumBytes, keyframe: keyframe) {
                    guard !independent || keyframe else { throw SurfaceVideoError.missingKeyframe }
                    guard !isCancelled() else { clear(); return nil }
                    sequence += 1
                    return SurfaceVideoFrame(data: packet, width: self.width, height: self.height, refresh: reference)
                }
                // Neither an oversized refresh nor its predicted successors can be published.
                clear()
                if refresh || reference { return nil }
                if nextProfile == .sharp {
                    nextProfile = .motion
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

    private func encodeSample(_ image: CGImage, forceKeyframe: Bool, isCancelled: () -> Bool) throws -> CMSampleBuffer? {
        guard let session, let pool else { throw SurfaceVideoError.missingOutput }
        if profile == .motion, sequence > 0, minimumMotionQP != 35 {
            try videoCheck(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MinAllowedFrameQP,
                                                value: NSNumber(value: 35)))
            minimumMotionQP = 35
        }
        var buffer: CVPixelBuffer?
        try videoCheck(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer))
        guard let buffer else { throw SurfaceVideoError.missingOutput }
        try videoCheck(CVPixelBufferLockBaseAddress(buffer, []))
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: videoColorSpace,
                bitmapInfo: videoBitmapInfo) else { throw SurfaceVideoError.missingOutput }
            context.setBlendMode(.copy)
            if profile == .sharp {
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
        let output = VideoOutput<CMSampleBuffer>(sessionID: ObjectIdentifier(session))
        try videoCheck(VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
            presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime - epoch, preferredTimescale: 1_000_000),
            duration: .invalid,
            frameProperties: forceKeyframe ?
                [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            infoFlagsOut: nil, outputHandler: { status, flags, sample in
                output.finish(status: status, dropped: flags.contains(.frameDropped), value: sample)
            }), operation: "encoder-encode", id: ObjectIdentifier(session))
        return try output.wait()
    }

    private func start(width: Int, height: Int, profile: Profile) throws {
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: profile == .motion]
        if profile == .sharp { specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true }
        SurfaceVideoCompressionSessions.waitForRetirements()
        try videoCheck(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session),
            operation: "encoder-create", detail: "dimensions=\(width)x\(height),profile=\(profile)")
        guard let session else { throw SurfaceVideoError.missingOutput }
        SurfaceVideoCompressionSessions.didCreate()
        VideoSessionDiagnostics.shared.created(ObjectIdentifier(session), kind: .encoder,
                                               width: width, height: height, profile: "\(profile)")
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
        for (key, value) in settings {
            try videoCheck(VTSessionSetProperty(session, key: key, value: value),
                           operation: "encoder-set-property", id: ObjectIdentifier(session), detail: "\(key)")
        }
        // Zero lets the encoder choose keyframes; remove periodic scheduling without trusting that default.
        try videoCheck(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                            value: NSNumber(value: Int32.max)))
        try videoCheck(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                            value: NSNumber(value: 0)))
        try videoCheck(VTCompressionSessionPrepareToEncodeFrames(session),
                       operation: "encoder-prepare", id: ObjectIdentifier(session))
        try videoCheck(CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary,
                                             attributes as CFDictionary, &pool))
        self.width = width
        self.height = height
        self.profile = profile
        epoch = ProcessInfo.processInfo.systemUptime
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
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps = Data()
    private var pps = Data()

    public init() {}
    deinit { clear() }

    private func clear() {
        if let session {
            VideoSessionDiagnostics.shared.transition(ObjectIdentifier(session), to: .executing, synchronous: true)
            VTDecompressionSessionInvalidate(session)
            VideoSessionDiagnostics.shared.transition(ObjectIdentifier(session), to: nil)
        }
        session = nil
        format = nil
        sps = Data()
        pps = Data()
    }

    public func decode(_ data: Data, width: Int, height: Int) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        do {
            try videoDimensions(width, height)
            let packet = try VideoPacket(data)
            let changed = packet.sps != sps || packet.pps != pps
            guard packet.keyframe || (session != nil && !changed) else { throw SurfaceVideoError.missingKeyframe }
            if changed || session == nil || packet.keyframe {
                let nextFormat = try packet.format(width: width, height: height)
                clear()
                SurfaceVideoCompressionSessions.waitForRetirements()
                try videoCheck(VTDecompressionSessionCreate(allocator: nil, formatDescription: nextFormat,
                    decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                    imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                    outputCallback: nil, decompressionSessionOut: &session),
                    operation: "decoder-create", detail: "dimensions=\(width)x\(height),profile=H264")
                if let session {
                    VideoSessionDiagnostics.shared.created(ObjectIdentifier(session), kind: .decoder,
                                                           width: width, height: height, profile: "H264")
                }
                format = nextFormat
                sps = packet.sps
                pps = packet.pps
            }
            guard let session, let format else { throw SurfaceVideoError.missingOutput }
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
            let output = VideoOutput<CVImageBuffer>(sessionID: ObjectIdentifier(session))
            try videoCheck(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil,
                outputHandler: { status, flags, image, _, _ in
                    output.finish(status: status, dropped: flags.contains(.frameDropped), value: image)
                }), operation: "decoder-decode", id: ObjectIdentifier(session))
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
