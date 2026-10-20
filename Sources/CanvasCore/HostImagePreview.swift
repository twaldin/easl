import CoreGraphics
import Foundation
import ImageIO

public struct HostImagePreview: Sendable {
    public var data: Data
    public var image: CGImage
    public var naturalWidth: Int
    public var naturalHeight: Int
    public var width: Int
    public var height: Int
    public var version: HostFileVersion

    public init(data: Data, image: CGImage, naturalWidth: Int, naturalHeight: Int, width: Int, height: Int, version: HostFileVersion) {
        self.data = data
        self.image = image
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
        self.width = width
        self.height = height
        self.version = version
    }

    static let maxNaturalPixels = 16_000_000
    static let pixelRange = 64...2048

    static func dimensions(width: Int, height: Int, maxPixels: Int) -> (width: Int, height: Int) {
        if width >= height {
            return (maxPixels, max(1, Int((Double(height) * Double(maxPixels) / Double(width)).rounded())))
        }
        return (max(1, Int((Double(width) * Double(maxPixels) / Double(height)).rounded())), maxPixels)
    }

    var json: JSONValue {
        .object([
            "kind": .string("preview"), "data": .string(data.base64EncodedString()),
            "naturalWidth": .number(Double(naturalWidth)), "naturalHeight": .number(Double(naturalHeight)),
            "width": .number(Double(width)), "height": .number(Double(height)),
            "version": .object(["root": .string(version.root), "path": .string(version.path!), "stamp": .string(version.stamp!)]),
        ])
    }

    static func decode(_ reply: JSONValue, maxPixels: Int) throws -> HostImagePreview? {
        let invalid = HostFileError.unavailable("invalid host image preview reply")
        guard let object = reply.object else { throw invalid }
        if reply["kind"]?.string == "original" {
            guard object.count == 1 else { throw invalid }
            return nil
        }
        guard reply["kind"]?.string == "preview",
              let naturalWidth = integer(reply["naturalWidth"]), let naturalHeight = integer(reply["naturalHeight"]),
              let width = integer(reply["width"]), let height = integer(reply["height"]),
              naturalWidth > 0, naturalHeight > 0, naturalWidth <= maxNaturalPixels / naturalHeight,
              max(naturalWidth, naturalHeight) > maxPixels,
              let encoded = reply["data"]?.string, encoded.utf8.count <= ((SourceExcerpt.maxFileBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded), !data.isEmpty, data.count < SourceExcerpt.maxFileBytes,
              let version = reply["version"],
              let root = version["root"]?.string, let path = version["path"]?.string, let stamp = version["stamp"]?.string,
              canonical(root), canonical(path), path != root, validStamp(stamp),
              version["commit"] == nil || version["commit"] == .null else { throw invalid }
        let expected = dimensions(width: naturalWidth, height: naturalHeight, maxPixels: maxPixels)
        guard width == expected.width, height == expected.height,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              (CGImageSourceGetType(source) as String?) == "public.png", CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == height,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              (try? LocalImagePreview.animatedPNG(data)) == false,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw invalid }
        return HostImagePreview(data: data, image: image, naturalWidth: naturalWidth, naturalHeight: naturalHeight,
                                width: width, height: height, version: HostFileVersion(root: root, path: path, stamp: stamp))
    }

    static func integer(_ value: JSONValue?) -> Int? {
        guard let number = value?.number, number.isFinite else { return nil }
        return Int(exactly: number)
    }

    private static func canonical(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && Board.hostPath(path, under: "/") == path
    }

    private static func validStamp(_ stamp: String) -> Bool {
        let fields = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 5 else { return false }
        return Int64(fields[0]) != nil && UInt64(fields[1]) != nil && UInt64(fields[2]) != nil &&
            Int64(fields[3]) != nil && Int64(fields[4]) != nil
    }
}

actor HostImagePreviews {
    private struct Waiter {
        let id: UUID
        let priority: HostReadPriority
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }

    private let makeConnection: @Sendable () -> EaslConnection
    private var connection: EaslConnection?
    private var active = false
    private var waiting: [Waiter] = []
    private static let traceReads = ProcessInfo.processInfo.environment["EASL_DEV_HOST_READ_TRACE"] == "1"

    init(connection: @escaping @Sendable () -> EaslConnection) {
        makeConnection = connection
    }

    deinit { connection?.close() }

    func read(object: String, maxPixels: Int, priority: HostReadPriority,
              deadline: ContinuousClock.Instant = .now + .seconds(30)) async throws -> HostImagePreview? {
        let started = Metrics.now()
        try await acquire(priority: priority, deadline: deadline)
        let admitted = Metrics.now()
        var preview: HostImagePreview?
        defer {
            release()
            if Self.traceReads {
                NSLog("easl: host-image-preview object=%@ priority=%ld requestedPixels=%ld outputWidth=%ld outputHeight=%ld pngPayloadBytes=%ld queueMs=%.3f durationMs=%.3f",
                      object, priority.rawValue, maxPixels, preview?.width ?? 0, preview?.height ?? 0, preview?.data.count ?? 0,
                      (admitted - started) * 1000, (Metrics.now() - started) * 1000)
            }
        }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw EaslConnection.Failure("timeout", "host image preview timed out") }
        let link: EaslConnection
        if let connection {
            link = connection
        } else {
            link = makeConnection()
            connection = link
        }
        let reply: JSONValue
        do {
            reply = try await link.request("image.preview", .object(["id": .string(object), "maxPixels": .number(Double(maxPixels))]), timeout: remaining)
        } catch is CancellationError {
            link.close()
            connection = nil
            throw CancellationError()
        } catch let failure as EaslConnection.Failure {
            if !failure.isHostResponse, failure.code == "timeout" {
                link.close()
                connection = nil
            }
            if !failure.isHostResponse || failure.code == "invalid_params" || failure.code == "unavailable" || failure.code == "timeout" { throw failure }
            throw HostFileError(code: failure.code, message: failure.message, limit: HostImagePreview.integer(failure.data?["limit"]))
        }
        preview = try await offPool { Result { try HostImagePreview.decode(reply, maxPixels: maxPixels) } }.get()
        try Task.checkCancellation()
        return preview
    }

    private func acquire(priority: HostReadPriority, deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        if !active {
            active = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let timeout = Task { [weak self] in
                        do { try await Task.sleep(until: deadline, clock: .continuous) }
                        catch { return }
                        await self?.fail(id, error: EaslConnection.Failure("timeout", "host image preview timed out"))
                    }
                    let waiter = Waiter(id: id, priority: priority, continuation: continuation, timeout: timeout)
                    let index = waiting.firstIndex { $0.priority.rawValue < priority.rawValue } ?? waiting.endIndex
                    waiting.insert(waiter, at: index)
                }
            }
        } onCancel: {
            Task { await self.fail(id, error: CancellationError()) }
        }
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    private func release() {
        if waiting.isEmpty {
            active = false
        } else {
            let waiter = waiting.removeFirst()
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    private func fail(_ id: UUID, error: Error) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiting.remove(at: index)
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }
}
