import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct SurfaceImageEncoding: @unchecked Sendable {
    public let format: SurfaceFormat
    public let data: Data
    public let width: Int
    public let height: Int
    public let canvas: CGSize
    public let refresh: Bool
}

private enum SurfaceImageEncodingError: Error {
    case invalidImage, missingOutput
}

private struct SurfaceImageIdentity {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let bitmap: UInt32
    private let space: CGColorSpace?
    private let pixels: CFData

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.decode == nil, image.bytesPerRow >= width * 4,
           image.bytesPerRow <= Int.max / height, let data = image.dataProvider?.data,
           CFDataGetLength(data) >= image.bytesPerRow * height {
            pixels = data
            bytesPerRow = image.bytesPerRow
            bitmap = image.bitmapInfo.rawValue
            space = image.colorSpace
        } else {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let normalized = context.makeImage(), let data = normalized.dataProvider?.data else { return nil }
            pixels = data
            bytesPerRow = normalized.bytesPerRow
            bitmap = Self.bitmapInfo
            space = Self.colorSpace
        }
    }

    enum Change {
        case none, small, large
    }

    func change(from previous: Self?) -> Change {
        guard let previous, width == previous.width, height == previous.height,
              bitmap == previous.bitmap, space == previous.space else { return .large }
        let left = CFDataGetBytePtr(pixels)!
        let right = CFDataGetBytePtr(previous.pixels)!
        let threshold = width * height / 100
        var changed = 0
        for row in 0..<height {
            let lhs = left + row * bytesPerRow
            let rhs = right + row * previous.bytesPerRow
            if memcmp(lhs, rhs, width * 4) == 0 { continue }
            for column in 0..<width {
                let offset = column * 4
                if memcmp(lhs + offset, rhs + offset, 4) != 0 {
                    changed += 1
                    if changed > threshold { return .large }
                }
            }
        }
        return changed == 0 ? .none : .small
    }
}

private final class SurfaceImageRefresh: @unchecked Sendable {
    struct Key: Equatable, Sendable {
        let epoch: UInt64
        let inputRevision: UInt64
    }

    private final class Job: @unchecked Sendable {
        let key: Key
        let image: CGImage
        let revision: SurfaceInputRevision
        let imageVersion: UInt64
        let identity: SurfaceImageIdentity
        let encoder: SurfaceVideoEncoder

        init(key: Key, image: CGImage, identity: SurfaceImageIdentity, revision: SurfaceInputRevision,
             imageVersion: UInt64, encoder: SurfaceVideoEncoder) {
            self.key = key
            self.image = image
            self.identity = identity
            self.revision = revision
            self.imageVersion = imageVersion
            self.encoder = encoder
        }
    }

    struct Frame {
        let video: SurfaceVideoFrame
        let imageVersion: UInt64
        let identity: SurfaceImageIdentity
    }

    private enum State {
        case idle
        case pending(Job)
        case ready(Job, Result<Frame, Error>)
        case delivered
        case refused(epoch: UInt64)
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var key: Key?
    private var state: State = .idle
    private var workerRunning = false

    init(queue: DispatchQueue) { self.queue = queue }

    @discardableResult
    func synchronize(_ key: Key?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.key != key else { return false }
        self.key = key
        let unpublished: Bool
        switch state {
        case .pending, .ready: unpublished = true
        case .idle, .delivered, .refused: unpublished = false
        }
        if case .refused(let epoch) = state, key == nil || key?.epoch == epoch { return unpublished }
        state = .idle
        return unpublished
    }

    private func isCurrent(_ job: Job) -> Bool {
        guard job.revision.value == job.key.inputRevision else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard key == job.key, case .pending(let pending) = state else { return false }
        return pending === job
    }

    func start(image: CGImage, identity: SurfaceImageIdentity, imageVersion: UInt64, key: Key,
               revision: SurfaceInputRevision, encoder: SurfaceVideoEncoder) -> Bool {
        lock.lock()
        guard self.key == key else { lock.unlock(); return false }
        guard case .idle = state else {
            let pending: Bool
            switch state {
            case .pending, .ready: pending = true
            case .idle, .delivered, .refused: pending = false
            }
            lock.unlock()
            return pending
        }
        let job = Job(key: key, image: image, identity: identity, revision: revision,
                      imageVersion: imageVersion, encoder: encoder)
        state = .pending(job)
        guard !workerRunning else { lock.unlock(); return true }
        workerRunning = true
        lock.unlock()
        queue.async { [self] in run() }
        return true
    }

    private func run() {
        while true {
            lock.lock()
            guard case .pending(let job) = state else {
                workerRunning = false
                lock.unlock()
                return
            }
            lock.unlock()
            guard isCurrent(job) else {
                lock.lock()
                if case .pending(let pending) = state, pending === job { state = .idle }
                lock.unlock()
                continue
            }
            let result: Result<Frame?, Error> = Result {
                guard let encoded = try job.encoder.encode(job.image, width: job.image.width, height: job.image.height,
                    refresh: true, isCancelled: { !self.isCurrent(job) }) else { return nil }
                return Frame(video: encoded, imageVersion: job.imageVersion, identity: job.identity)
            }
            lock.lock()
            if self.key == job.key, job.revision.value == job.key.inputRevision,
               case .pending(let pending) = state, pending === job {
                switch result {
                case .success(let frame?): state = .ready(job, .success(frame))
                case .success(nil): state = .refused(epoch: job.key.epoch)
                case .failure(let error): state = .ready(job, .failure(error))
                }
            }
            lock.unlock()
        }
    }

    func take(key: Key, revision: SurfaceInputRevision) throws -> Frame? {
        guard revision.value == key.inputRevision else { return nil }
        lock.lock()
        guard self.key == key, case .ready(let job, let result) = state,
              job.key == key else { lock.unlock(); return nil }
        switch result {
        case .success: state = .delivered
        case .failure: state = .idle
        }
        lock.unlock()
        return try result.get()
    }

    func markDelivered(key: Key) {
        lock.lock()
        self.key = key
        state = .delivered
        lock.unlock()
    }
}

/// Callers serialize captures, publish returned frames in order, and acknowledge each frame the viewer presents.
public final class SurfaceImageEncoder: @unchecked Sendable {
    public static let motionBytes = 16 << 20
    public static let refinementBytes = 576 * 1024
    public static let settle: TimeInterval = 1
    public private(set) var captureDelay: TimeInterval = 0.1

    private static let inputSettle: TimeInterval = 0.3
    private let refinement: SurfaceRefinement
    private var video: SurfaceVideoEncoder
    private let refresh: SurfaceImageRefresh
    /// Fences codec work through presentation, including jobs discarded before returning a frame.
    private var unacknowledgedRevision: UInt64?
    private var observed: SurfaceImageIdentity?
    private var sharp: SurfaceImageIdentity?
    private var refreshArmed = false
    private var refreshFromInput = false
    private var imageVersion: UInt64 = 0
    private var refreshEpoch: UInt64 = 0
    private var motionVersion: UInt64?
    private var changedAt: TimeInterval = 0
    private var lastJPEG: Data?
    private var lastJPEGCanvas: CGSize?

    public convenience init(refinement: SurfaceRefinement = .retained) {
        self.init(refreshQueue: DispatchQueue(label: "easl.surface.refresh", qos: .utility), refinement: refinement)
    }

    init(refreshQueue: DispatchQueue, refinement: SurfaceRefinement = .retained) {
        self.refinement = refinement
        video = SurfaceVideoEncoder(refinement: refinement)
        refresh = SurfaceImageRefresh(queue: refreshQueue)
    }

    /// The viewer presented the last returned frame, and so every frame published before it.
    public func acknowledgeFrame() {
        unacknowledgedRevision = nil
    }

    public func capture(_ image: CGImage, width: Int, height: Int, mode: SurfaceLinkMode,
                        inputActive: Bool, lastInput: TimeInterval, forceState: Bool,
                        revision: SurfaceInputRevision,
                        at now: TimeInterval) throws -> SurfaceImageEncoding? {
        captureDelay = inputActive ? 1.0 / 30 : 0.1
        guard let source = Self.sized(image, width: width, height: height) else { throw SurfaceImageEncodingError.invalidImage }
        let canvas = CGSize(width: width, height: height)
        if mode == .jpeg {
            if refresh.synchronize(nil) || unacknowledgedRevision != nil || lastJPEG == nil {
                video = SurfaceVideoEncoder(refinement: refinement)
                unacknowledgedRevision = nil
            }
            observed = nil
            sharp = nil
            refreshArmed = false
            motionVersion = nil
            guard let jpeg = Self.jpeg(source) else { throw SurfaceImageEncodingError.missingOutput }
            guard jpeg.data != lastJPEG || canvas != lastJPEGCanvas || forceState else {
                if !inputActive { captureDelay = 1 }
                return nil
            }
            lastJPEG = jpeg.data
            lastJPEGCanvas = canvas
            captureDelay = 1.0 / 30
            return SurfaceImageEncoding(format: .jpeg, data: jpeg.data, width: jpeg.width, height: jpeg.height,
                                        canvas: canvas, refresh: false)
        }
        guard let identity = SurfaceImageIdentity(source) else { throw SurfaceImageEncodingError.invalidImage }
        let inputRevision = revision.value
        if let unacknowledgedRevision, unacknowledgedRevision != inputRevision {
            refresh.synchronize(nil)
            video = SurfaceVideoEncoder(refinement: refinement)
            self.unacknowledgedRevision = nil
            motionVersion = nil
        }
        let change = identity.change(from: observed)
        observed = identity
        if inputActive { refreshFromInput = true }
        let resumeMotion: Bool
        if case .large = change { resumeMotion = inputActive }
        else { resumeMotion = false }
        switch change {
        case .large:
            imageVersion &+= 1
            refreshEpoch &+= 1
            changedAt = now
            refreshFromInput = inputActive
            refreshArmed = true
        case .small:
            imageVersion &+= 1
        case .none:
            break
        }
        if !refreshArmed, case .large = identity.change(from: sharp) {
            refreshEpoch &+= 1
            changedAt = now
            refreshFromInput = inputActive
            refreshArmed = true
        }
        let key = SurfaceImageRefresh.Key(epoch: refreshEpoch, inputRevision: inputRevision)
        if refresh.synchronize(inputActive || mode != .video ? nil : key) {
            // Detach an in-flight codec rather than waiting for its canceled callback on the input path.
            video = SurfaceVideoEncoder(refinement: refinement)
            unacknowledgedRevision = nil
            motionVersion = nil
        }
        let quietPeriod = refinement == .retained && refreshFromInput ? Self.inputSettle : Self.settle
        let due = max(changedAt, lastInput) + quietPeriod
        if mode == .video, !inputActive, now >= due {
            if let encoded = try refresh.take(key: key, revision: revision) {
                unacknowledgedRevision = inputRevision
                guard revision.value == inputRevision else { return nil }
                motionVersion = encoded.imageVersion == imageVersion ? imageVersion : nil
                sharp = encoded.identity
                refreshArmed = false
                captureDelay = 1.0 / 30
                return SurfaceImageEncoding(format: .h264, data: encoded.video.data,
                                            width: encoded.video.width, height: encoded.video.height,
                                            canvas: canvas, refresh: true)
            }
            let pending = refresh.start(image: source, identity: identity, imageVersion: imageVersion,
                                        key: key, revision: revision, encoder: video)
            captureDelay = pending ? 1.0 / 30 : 1
            if pending {
                unacknowledgedRevision = inputRevision
                return nil
            }
        }
        if motionVersion != imageVersion || forceState {
            guard let encoded = try video.encode(source, width: width, height: height, motion: resumeMotion) else { return nil }
            unacknowledgedRevision = inputRevision
            if encoded.refresh {
                refresh.markDelivered(key: key)
                sharp = identity
                refreshArmed = false
            }
            motionVersion = imageVersion
            lastJPEG = nil
            lastJPEGCanvas = nil
            captureDelay = 1.0 / 30
            return SurfaceImageEncoding(format: .h264, data: encoded.data, width: encoded.width, height: encoded.height,
                                        canvas: canvas, refresh: encoded.refresh)
        }
        if inputActive || now < due {
            captureDelay = min(captureDelay, max(1.0 / 30, due - now))
        }
        return nil
    }

    public static func sized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, width <= SurfaceEvent.Frame.maxPixels / height else { return nil }
        if image.width == width && image.height == height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func jpeg(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= motionBytes else { return nil }
        return (output as Data, image.width, image.height)
    }
}
