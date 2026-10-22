import AppKit
import Foundation
import ImageIO
import Testing
@testable import CanvasCore

private enum PreviewRaster {
    static func image(width: Int, height: Int) throws -> CGImage {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied, bytesPerRow: width * 4, bitsPerPixel: 32))
        let pixels = try #require(rep.bitmapData)
        var state: UInt32 = 42
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rep.bytesPerRow + x * 4
                for channel in 0..<3 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    pixels[offset + channel] = UInt8(truncatingIfNeeded: state >> 24)
                }
                pixels[offset + 3] = x < width / 4 ? 0 : 255
            }
        }
        return try #require(rep.cgImage)
    }

    static func data(width: Int, height: Int, type: String = "public.png", orientation: Int = 1,
                     frames: Int = 1, quality: Double = 1) async throws -> Data {
        try await offPool {
            Result {
                let image = try image(width: width, height: height)
                let data = NSMutableData()
                let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, frames, nil))
                for _ in 0..<frames {
                    CGImageDestinationAddImage(destination, image, [
                        kCGImagePropertyOrientation: orientation,
                        kCGImageDestinationLossyCompressionQuality: quality,
                        kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1],
                    ] as CFDictionary)
                }
                try #require(CGImageDestinationFinalize(destination))
                return data as Data
            }
        }.get()
    }

    static func reply() async throws -> JSONValue {
        HostImagePreview(data: try await data(width: 64, height: 32), image: try image(width: 64, height: 32), naturalWidth: 640, naturalHeight: 320,
            width: 64, height: 32, version: HostFileVersion(root: "/board", path: "/board/chart.png", stamp: "1:2:100000:4:5")).json
    }
}

extension ApiRouterTests {
    @Test func imagePreviewDownsamplesAspectRatioAndPreservesTransparencyAndVersion() async throws {
        let path = board.root.appendingPathComponent("preview.png")
        let original = try await PreviewRaster.data(width: 640, height: 321)
        try original.write(to: path)
        let tile = board.create(type: .image, props: .object(["path": "preview.png"]))
        let response = try await call(connect(), "image.preview", ["id": .string(tile.id), "maxPixels": 64])
        #expect(response["ok"] == .bool(true))
        let result = try #require(response["result"])
        #expect(result["naturalWidth"] == 640)
        #expect(result["naturalHeight"] == 321)
        #expect(result["width"] == 64)
        #expect(result["height"] == 32)
        let decoded = try HostImagePreview.decode(result, maxPixels: 64)
        let preview = try #require(decoded)
        #expect(preview.data.count < original.count)
        let metadata = try await HostFiles.readLocal(HostFileRequest(source: .directory(board.root.path), policy: .boardImage("preview.png"), bytes: false))
        #expect(preview.version == metadata.version)
        let source = try #require(CGImageSourceCreateWithData(preview.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixels[(16 * 64 + 2) * 4 + 3] == 0)
        #expect(pixels[(16 * 64 + 60) * 4 + 3] == 255)
    }

    @Test func imagePreviewPortraitRoundsItsShortEdgeAndNeverUpscales() async throws {
        try await PreviewRaster.data(width: 201, height: 640).write(to: board.root.appendingPathComponent("portrait.png"))
        let tile = board.create(type: .image, props: .object(["path": "portrait.png"]))
        let client = try connect()
        let preview = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": 64])
        #expect(preview["result"]?["width"] == 20)
        #expect(preview["result"]?["height"] == 64)
        let original = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": 640])
        #expect(original["result"] == .object(["kind": "original"]))
    }

    @Test func imagePreviewEncodesJPEGThumbnailsAsPNG() async throws {
        try await PreviewRaster.data(width: 640, height: 320, type: "public.jpeg").write(to: board.root.appendingPathComponent("photo.jpg"))
        let tile = board.create(type: .image, props: .object(["path": "photo.jpg"]))
        let response = try await call(connect(), "image.preview", ["id": .string(tile.id), "maxPixels": 64])
        let result = try #require(response["result"])
        let decoded = try HostImagePreview.decode(result, maxPixels: 64)
        let preview = try #require(decoded)
        #expect(preview.width == 64)
        #expect(preview.height == 32)
        #expect(preview.data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
    }

    @Test func imagePreviewVersionChangesWithTheSource() async throws {
        let path = board.root.appendingPathComponent("changing.png")
        try await PreviewRaster.data(width: 640, height: 320).write(to: path)
        let tile = board.create(type: .image, props: .object(["path": "changing.png"]))
        let client = try connect()
        let first = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": 64])
        try await PreviewRaster.data(width: 800, height: 400).write(to: path, options: .atomic)
        let second = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": 64])
        #expect(first["result"]?["kind"] == "preview")
        #expect(second["result"]?["kind"] == "preview")
        #expect(first["result"]?["version"]?["stamp"] != second["result"]?["version"]?["stamp"])
        #expect(second["result"]?["naturalWidth"] == 800)
        let metadata = try await HostFiles.readLocal(HostFileRequest(source: .directory(board.root.path), policy: .boardImage("changing.png"), bytes: false))
        #expect(second["result"]?["version"]?["stamp"]?.string == metadata.stamp)
    }

    @Test func imagePreviewKeepsAnimationOrientationAndUnsupportedFormatsOnOriginalTransport() async throws {
        let fixtures: [(String, Data)] = [
            ("animated.png", try await PreviewRaster.data(width: 640, height: 320, frames: 2)),
            ("rotated.jpg", try await PreviewRaster.data(width: 640, height: 320, type: "public.jpeg", orientation: 6)),
            ("small.png", try await PreviewRaster.data(width: 32, height: 16)),
            ("vector.svg", Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="640" height="320"/>"#.utf8)),
            ("compressed.jpg", try await PreviewRaster.data(width: 640, height: 320, type: "public.jpeg", quality: 0.01)),
        ]
        let client = try connect()
        for (name, bytes) in fixtures {
            try bytes.write(to: board.root.appendingPathComponent(name))
            let tile = board.create(type: .image, props: .object(["path": .string(name)]))
            let response = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": 256])
            #expect(response["result"] == .object(["kind": "original"]), "\(name): \(response)")
        }
    }

    @Test func imagePreviewRejectsInvalidParamsBeforeReadingAndRejectsNonImages() async throws {
        let tile = board.create(type: .image, props: .object(["path": "missing.png"]))
        let client = try connect()
        for value: JSONValue in [.number(63), .number(2049), .number(64.5), "64", .bool(true), .null] {
            let response = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": value])
            #expect(response["error"]?["code"] == "invalid_params")
        }
        let missing = try await call(client, "image.preview", ["id": .string(tile.id)])
        #expect(missing["error"]?["code"] == "invalid_params")
        let other = board.create(type: .note, props: .object(["markdown": "text"]))
        let wrongType = try await call(client, "image.preview", ["id": .string(other.id), "maxPixels": 64])
        #expect(wrongType["error"]?["code"] == "invalid_params")
        let absent = try await call(client, "image.preview", ["id": "obj_missing", "maxPixels": 64])
        #expect(absent["error"]?["code"] == "not_found")
        let notFound = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": 64])
        #expect(notFound["error"]?["code"] == "not_found")
    }

    @Test func imagePreviewUsesBoardImageAuthorizationAndByteLimit() async throws {
        let outside = dir.appendingPathComponent("outside.png")
        try await PreviewRaster.data(width: 640, height: 320).write(to: outside)
        try FileManager.default.createSymbolicLink(at: board.root.appendingPathComponent("escape.png"), withDestinationURL: outside)
        let client = try connect()
        for path in [outside.path, "../outside.png", "escape.png", "https://example.com/image.png"] {
            let tile = board.create(type: .image, props: .object(["path": .string(path)]))
            let response = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": 64])
            #expect(response["error"]?["code"] == "refused")
        }
        for (name, bytes, code) in [
            ("invalid.png", Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "unreadable"),
            ("large.png", Data(repeating: 0, count: SourceExcerpt.maxFileBytes + 1), "too_large"),
        ] {
            try bytes.write(to: board.root.appendingPathComponent(name))
            let tile = board.create(type: .image, props: .object(["path": .string(name)]))
            let response = try await call(client, "image.preview", ["id": .string(tile.id), "maxPixels": 64])
            #expect(response["error"]?["code"]?.string == code)
        }
    }
}

private final class ImagePreviewPeer: Sendable {
    let directory: URL
    let server: SocketServer
    let reply: Locked<Result<JSONValue, EaslConnection.Failure>>
    let calls = Locked<[JSONValue]>([])
    var path: String { directory.appendingPathComponent("s").path }

    init(reply: JSONValue) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preview-peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let answer = Locked<Result<JSONValue, EaslConnection.Failure>>(.success(reply))
        self.reply = answer
        let calls = calls
        server = SocketServer(path: directory.appendingPathComponent("s").path) { request, _ in
            let id = request["id"] ?? .null
            if request["method"]?.string == "system.ping" { return .object(["id": id, "ok": .bool(true), "result": .object([:])]) }
            calls.withLock { $0.append(request) }
            switch answer.withLock({ $0 }) {
            case .success(let result): return .object(["id": id, "ok": .bool(true), "result": result])
            case .failure(let error): return .object(["id": id, "ok": .bool(false), "error": .object(["code": .string(error.code), "message": .string(error.message)])])
            }
        }
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func files() -> HostFiles {
        let path = path
        return HostFiles(hostName: "preview", route: HostRoute(target: "unused", controlPath: "/unused"), temps: [],
                         imagePreviews: HostImagePreviews { .unixSocket(path) })
    }
}

@MainActor
struct HostImagePreviewTests {
    @Test func dedicatedConnectionIsLazySharedByPrioritiesAndClosedWithItsOwner() async throws {
        let peer = try await ImagePreviewPeer(reply: PreviewRaster.reply())
        let made = Locked(0)
        let retained = Locked<EaslConnection?>(nil)
        let path = peer.path
        var files: HostFiles? = HostFiles(hostName: "preview", route: HostRoute(target: "unused", controlPath: "/unused"), temps: [], imagePreviews: HostImagePreviews {
            made.withLock { $0 += 1 }
            let connection = EaslConnection.unixSocket(path)
            retained.withLock { $0 = connection }
            return connection
        })
        var prioritized = files?.prioritized(.interactive)
        #expect(made.withLock { $0 } == 0)
        await #expect(throws: EaslConnection.Failure("invalid_params", "image.preview requires an id and maxPixels from 64 through 2048")) {
            try await files?.imagePreview(object: "obj_invalid", maxPixels: 63)
        }
        #expect(made.withLock { $0 } == 0)
        _ = try await files?.imagePreview(object: "obj_first", maxPixels: 64)
        _ = try await prioritized?.imagePreview(object: "obj_second", maxPixels: 64)
        #expect(made.withLock { $0 } == 1)
        files = nil
        let connection = try #require(retained.withLock { $0 })
        #expect(connection.state == .online)
        prioritized = nil
        let deadline = ContinuousClock.now + .seconds(5)
        while connection.problem != "closed", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.state == .offline)
        #expect(connection.problem == "closed")
    }

    @Test func explicitOriginalIsTheOnlyNilAndMalformedResponsesNeverFallBack() async throws {
        let valid = try await PreviewRaster.reply()
        let peer = try ImagePreviewPeer(reply: valid)
        let files = peer.files()
        #expect(try await files.imagePreview(object: "obj_valid", maxPixels: 64)?.height == 32)
        var malformed: [JSONValue] = [
            .null, .object([:]), .object(["kind": "unknown"]), .object(["kind": "original", "data": "unexpected"]),
        ]
        for patch: JSONValue in [
            .object(["naturalWidth": .number(640.5)]), .object(["naturalHeight": 0]), .object(["naturalWidth": 16_000_001]),
            .object(["width": 63]), .object(["height": 33]), .object(["data": "not base64"]),
            .object(["data": .string(Data("not PNG".utf8).base64EncodedString())]),
            .object(["data": .string(try await PreviewRaster.data(width: 32, height: 16).base64EncodedString())]),
            .object(["version": .object(["root": "relative", "path": "/board/chart.png", "stamp": "1:2:3:4:5"]) ]),
            .object(["version": .object(["root": "/board", "path": "/board/../chart.png", "stamp": "1:2:3:4:5"]) ]),
            .object(["version": .object(["root": "/board", "path": "/board/chart.png", "stamp": "stale"]) ]),
            .object(["version": .object(["root": "/board", "path": "/board/chart.png"]) ]),
        ] { malformed.append(valid.merging(patch)) }
        for reply in malformed {
            peer.reply.withLock { $0 = .success(reply) }
            await #expect(throws: HostFileError.self) { try await files.imagePreview(object: "obj_invalid", maxPixels: 64) }
        }
        peer.reply.withLock { $0 = .success(.object(["kind": "original"])) }
        #expect(try await files.imagePreview(object: "obj_original", maxPixels: 64) == nil)
    }

    @Test func serverAndTransportErrorsAreNotOriginalResponses() async throws {
        let peer = try await ImagePreviewPeer(reply: PreviewRaster.reply())
        let files = peer.files()
        for (code, expected) in [("refused", HostFileError.refused), ("not_found", .notFound(commit: nil)),
                                 ("too_large", .tooLarge(limit: SourceExcerpt.maxFileBytes)), ("unreadable", .unreadable),
                                 ("unknown_method", .unavailable("failed"))] {
            peer.reply.withLock { $0 = .failure(EaslConnection.Failure(code, "failed")) }
            await #expect(throws: expected) { try await files.imagePreview(object: "obj_error", maxPixels: 64) }
        }
        peer.reply.withLock { $0 = .failure(EaslConnection.Failure("unavailable", "file changed during preview")) }
        do {
            _ = try await files.imagePreview(object: "obj_changed", maxPixels: 64)
            Issue.record("a host preview error selected original bytes")
        } catch let failure as EaslConnection.Failure {
            #expect(failure.code == "unavailable")
            #expect(failure.message == "file changed during preview")
            #expect(failure.isHostResponse)
        }
        peer.server.stop()
        do {
            _ = try await files.imagePreview(object: "obj_disconnected", maxPixels: 64)
            Issue.record("a disconnected preview selected original bytes")
        } catch let failure as EaslConnection.Failure {
            #expect(failure.code == "unavailable")
            #expect(!failure.isHostResponse)
        }
        let noEndpoint = HostFiles(hostName: "custom", route: HostRoute(target: "unused", controlPath: "/unused"), temps: [])
        await #expect(throws: HostFileError.self) { try await noEndpoint.imagePreview(object: "obj_custom", maxPixels: 64) }
    }
}
