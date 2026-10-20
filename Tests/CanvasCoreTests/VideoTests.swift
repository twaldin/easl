import Darwin
import Foundation
import Testing
import CanvasCore

extension ApiRouterTests {
    @Test func videoPropsPersistAndRejectInvalidUpdates() async throws {
        let client = try connect()
        let props: JSONValue = .object(["path": "clip.mp4", "poster": "poster.png", "loop": .bool(true), "muted": .bool(false), "autoplay": .bool(false), "startTime": .number(1.25), "title": "Demo", "key": "demo"])
        let created = try await call(client, "object.create", ["board": .string(board.id), "type": "video", "props": props])
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        let patches: [JSONValue] = [
            .object(["startTime": .number(-1)]), .object(["startTime": "2"]), .object(["startTime": .bool(true)]),
            .object(["loop": "true"]), .object(["muted": .number(1)]), .object(["autoplay": "false"]),
            .object(["poster": .number(2)]), .object(["title": .bool(false)]), .object(["path": .null])
        ]
        for patch in patches {
            let reply = try await call(client, "object.update", ["id": .string(id), "props": patch])
            #expect(reply["error"]?["code"] == "invalid_params")
        }
        _ = try await call(client, "object.update", ["id": .string(id), "props": .object(["startTime": .number(2.5), "title": "Edited"])])
        let store = BoardStore(directory: dir.appendingPathComponent("video-store"))
        try store.saveChecked(board)
        let restored = try await store.load(root: board.root)
        let object = try restored.object(id)
        #expect(object.type == .video)
        #expect(object.props == .object(["path": "clip.mp4", "poster": "poster.png", "loop": .bool(true), "muted": .bool(false), "autoplay": .bool(false), "startTime": .number(2.5), "title": "Edited", "key": "demo"]))
    }

    @Test func worktreeVideoCreateAndReaimReadOriginalFileURIs() async throws {
        _ = try await TempRepo.run(["init", "-q", "-b", "main"], in: board.root)
        _ = try await TempRepo.run(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "seed"], in: board.root)
        let checkout = dir.appendingPathComponent("feature")
        _ = try await TempRepo.run(["worktree", "add", "-q", "-b", "video-feature", checkout.path], in: board.root)
        let caller = board.create(type: .terminal, props: .object(["cwd": .string(checkout.path)])).id
        let client = try connect()
        let movie = board.root.appendingPathComponent("clip space.mp4")
        let poster = board.root.appendingPathComponent("poster space.png")
        try VideoHeader.movie(width: 640, height: 360).write(to: movie)
        let posterBytes = Data("original poster".utf8)
        try posterBytes.write(to: poster)
        func shadow(_ path: String, bytes: Data) throws {
            let file = checkout.appendingPathComponent(path).standardizedFileURL
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        try shadow(movie.absoluteString, bytes: VideoHeader.movie(width: 90, height: 160))
        try shadow(poster.absoluteString, bytes: Data("shadow poster".utf8))
        try VideoHeader.movie(width: 800, height: 600).write(to: checkout.appendingPathComponent("relative.mp4"))
        try Data("checkout poster".utf8).write(to: checkout.appendingPathComponent("relative.png"))
        let cases: [(String, String, CGSize, Data, String)] = [
            (movie.absoluteString, poster.absoluteString, CGSize(width: 640, height: 360), posterBytes, board.root.path),
            ("FILE:" + movie.absoluteString.dropFirst(5), "FILE:" + poster.absoluteString.dropFirst(5), CGSize(width: 640, height: 360), posterBytes, board.root.path),
            ("relative.mp4", "relative.png", CGSize(width: 800, height: 600), Data("checkout poster".utf8), checkout.path),
            (checkout.appendingPathComponent("relative.mp4").absoluteString, checkout.appendingPathComponent("relative.png").absoluteString,
             CGSize(width: 800, height: 600), Data("checkout poster".utf8), checkout.path)
        ]
        for (path, image, dimensions, expectedPoster, expectedCheckout) in cases {
            let props: JSONValue = .object(["path": .string(path), "poster": .string(image)])
            let created = try await call(client, "object.create", ["board": .string(board.id), "caller": .string(caller), "type": "video", "props": props])
            let id = try #require(created["result"]?["object"]?["id"]?.string)
            let other = try await call(client, "object.create", ["board": .string(board.id), "type": "video", "props": .object(["path": "before.mp4"])])
            let updatedID = try #require(other["result"]?["object"]?["id"]?.string)
            _ = try await call(client, "object.update", ["id": .string(updatedID), "caller": .string(caller), "props": props])
            for tile in [id, updatedID] {
                let stored = try board.object(tile).props
                let storedPath = try #require(stored["path"]?.string)
                let storedPoster = try #require(stored["poster"]?.string)
                #expect(try await LocalVideo.naturalSize(path: storedPath, root: board.root) == dimensions)
                let read = try await HostFiles.readLocal(HostFileRequest(source: .directory(board.root.path), policy: .boardAsset(storedPoster)))
                #expect(read.data == expectedPoster)
                #expect(PromptTarget.checkout(of: .object(tile), on: board)?.toplevel == expectedCheckout)
            }
        }
        let outside = dir.appendingPathComponent("outside.mp4")
        try VideoHeader.movie(width: 640, height: 360).write(to: outside)
        for refused in [outside.absoluteString, "file://remote.example\(movie.path)", "FILE://remote.example\(movie.path)", "file://%zz\(movie.path)"] {
            try shadow(refused, bytes: VideoHeader.movie(width: 90, height: 160))
            for key in ["path", "poster"] {
                var fields: [String: JSONValue] = ["path": .string(movie.absoluteString), "poster": .string(poster.absoluteString)]
                fields[key] = .string(refused)
                let props = JSONValue.object(fields)
                let created = try await call(client, "object.create", ["board": .string(board.id), "caller": .string(caller), "type": "video", "props": props])
                let id = try #require(created["result"]?["object"]?["id"]?.string)
                let other = try await call(client, "object.create", ["board": .string(board.id), "type": "video", "props": .object(["path": .string(movie.absoluteString)])])
                let reaimed = try #require(other["result"]?["object"]?["id"]?.string)
                _ = try await call(client, "object.update", ["id": .string(reaimed), "caller": .string(caller), "props": props])
                for tile in [id, reaimed] {
                    let stored = try board.object(tile).props
                    let original = try #require(stored[key]?.string)
                    #expect(original == refused)
                    await #expect(throws: HostFileError.refused) {
                        try await HostFiles.readLocal(HostFileRequest(source: .directory(board.root.path), policy: .boardAsset(original)))
                    }
                }
            }
        }
    }
}

@MainActor
struct VideoMetadataTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("video-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func containerHeadersMeasureExactDisplayDimensions() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [(String, Data, CGSize)] = [
            ("landscape.mp4", VideoHeader.movie(width: 640, height: 360), CGSize(width: 640, height: 360)),
            ("portrait.mov", VideoHeader.movie(width: 1920, height: 1080, version: 1, matrix: [0, 1, -1, 0]), CGSize(width: 1080, height: 1920)),
            ("scaled.mov", VideoHeader.movie(width: 320, height: 180, matrix: [2, 0, 0, 0.5]), CGSize(width: 640, height: 90)),
            ("rotated-scaled.mp4", VideoHeader.movie(width: 320, height: 180, matrix: [0, -2, 0.5, 0]), CGSize(width: 90, height: 640)),
            ("fractional.mp4", VideoHeader.movie(width: 321.5, height: 180.25), CGSize(width: 321.5, height: 180.25)),
            ("audio-first.mp4", VideoHeader.box("moov", VideoHeader.track(width: 999, height: 777, handler: "soun") + VideoHeader.track(width: 480, height: 270)), CGSize(width: 480, height: 270)),
            ("handler-first.mov", VideoHeader.box("moov", VideoHeader.track(width: 720, height: 480, handlerFirst: true)), CGSize(width: 720, height: 480))
        ]
        for (name, bytes, expected) in fixtures {
            try bytes.write(to: root.appendingPathComponent(name))
            #expect(try await LocalVideo.naturalSize(path: name, root: root) == expected)
        }
        let file = root.appendingPathComponent("landscape.mp4")
        #expect(try await LocalVideo.naturalSize(path: file.absoluteString, root: root) == CGSize(width: 640, height: 360))
        let measured = try await ObjectMeasure.size(type: .video, props: .object(["path": "landscape.mp4"]), width: 320, root: root)
        #expect(measured == CGSize(width: 320, height: 180 + RenderMath.tileTitleHeight))
    }

    @Test func validMetadataIgnoresExcessiveOrTruncatedTail() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = VideoHeader.movie(width: 854, height: 480)
        var excessive = movie
        for _ in 0..<9000 { excessive += VideoHeader.box("free", Data()) }
        try excessive.write(to: root.appendingPathComponent("fragments.mp4"))
        var truncated = movie
        truncated += VideoHeader.word(UInt32.max) + Data("mdat".utf8)
        try truncated.write(to: root.appendingPathComponent("truncated.mp4"))
        let sparse = root.appendingPathComponent("sparse.mov")
        try movie.write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 8 * 1024 * 1024 * 1024)
        try handle.close()
        for name in ["fragments.mp4", "truncated.mp4", "sparse.mov"] {
            #expect(try await LocalVideo.naturalSize(path: name, root: root) == CGSize(width: 854, height: 480))
        }
    }

    @Test func skipsHugeMediaPayloadAndReadsExtendedBoxes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("late-moov.mov")
        let mediaSize: UInt64 = 8 * 1024 * 1024 * 1024
        try (VideoHeader.word(1) + Data("mdat".utf8) + VideoHeader.word(UInt32(mediaSize >> 32)) + VideoHeader.word(UInt32(truncatingIfNeeded: mediaSize))).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: mediaSize)
        try handle.write(contentsOf: VideoHeader.movie(width: 1024, height: 576))
        try handle.close()
        #expect(try await LocalVideo.naturalSize(path: file.path, root: root) == CGSize(width: 1024, height: 576))
    }

    @Test func missingMalformedAndAudioOnlyMetadataAreErrors() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var excessive = Data()
        for _ in 0..<8192 { excessive += VideoHeader.box("free", Data()) }
        excessive += VideoHeader.movie(width: 640, height: 360)
        let fixtures = [
            Data("not a video".utf8),
            VideoHeader.box("moov", VideoHeader.track(width: 640, height: 360, handler: "soun")),
            VideoHeader.movie(width: 0, height: 360),
            VideoHeader.movie(width: 640, height: 360, matrix: [0, 0, 0, 0]),
            VideoHeader.movie(width: 640, height: 360, version: 2),
            VideoHeader.word(100) + Data("moov".utf8),
            VideoHeader.box("moov", VideoHeader.box("trak", VideoHeader.box("tkhd", Data(repeating: 0, count: 12)))),
            excessive
        ]
        for (index, data) in fixtures.enumerated() {
            let name = "invalid-\(index).mp4"
            try data.write(to: root.appendingPathComponent(name))
            await #expect(throws: ObjectMeasure.Failure.unavailable("video dimensions unavailable: a readable MP4 or MOV video track is required")) {
                try await LocalVideo.naturalSize(path: name, root: root)
            }
        }
        await #expect(throws: ObjectMeasure.Failure.notFound("no readable video at missing.mp4")) {
            try await LocalVideo.naturalSize(path: "missing.mp4", root: root)
        }
    }

    @Test(.timeLimit(.minutes(1))) func refusesOutsideSymlinkAndNonregularFiles() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("board")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside.mp4")
        try VideoHeader.movie(width: 640, height: 360).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.mp4"), withDestinationURL: outside)
        for path in [outside.path, "../outside.mp4", "escape.mp4", "https://example.com/video.mp4"] {
            await #expect(throws: ObjectMeasure.Failure.invalidParams("video path refused")) {
                try await LocalVideo.naturalSize(path: path, root: root)
            }
        }
        try VideoHeader.movie(width: 320, height: 240).write(to: root.appendingPathComponent("inside.mp4"))
        #expect(try await LocalVideo.naturalSize(path: "inside.mp4", root: root) == CGSize(width: 320, height: 240))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.mp4"), withIntermediateDirectories: true)
        #expect(mkfifo(root.appendingPathComponent("pipe.mp4").path, 0o600) == 0)
        for name in ["directory.mp4", "pipe.mp4"] {
            await #expect(throws: ObjectMeasure.Failure.unavailable("video is not a regular file")) {
                try await LocalVideo.naturalSize(path: name, root: root)
            }
        }
    }

    @Test func registeredWorktreesOnlyAllowMatchingBoardSubdirectory() async throws {
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("pkg/tracked", "seed")
        try await repo.commit("seed")
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = directory.appendingPathComponent("feature")
        try await repo.git("worktree", "add", "-q", "-b", "video-feature", worktree.path)
        let allowed = worktree.appendingPathComponent("pkg/clip.mp4")
        let refused = worktree.appendingPathComponent("outside.mp4")
        try VideoHeader.movie(width: 800, height: 450).write(to: allowed)
        try VideoHeader.movie(width: 123, height: 456).write(to: refused)
        #expect(try await LocalVideo.naturalSize(path: allowed.path, root: repo.url("pkg")) == CGSize(width: 800, height: 450))
        await #expect(throws: ObjectMeasure.Failure.invalidParams("video path refused")) {
            try await LocalVideo.naturalSize(path: refused.path, root: repo.url("pkg"))
        }
    }
}

enum VideoHeader {
    static func word(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    static func box(_ kind: String, _ body: Data) -> Data {
        word(UInt32(body.count + 8)) + Data(kind.utf8) + body
    }

    static func track(width: Double, height: Double, version: UInt8 = 0, matrix: [Double] = [1, 0, 0, 1], handler: String = "vide", handlerFirst: Bool = false) -> Data {
        var header = Data(repeating: 0, count: version == 1 ? 96 : 84)
        header[0] = version
        let matrixOffset = version == 1 ? 52 : 40
        let dimensions = version == 1 ? 88 : 76
        for (index, value) in zip([0, 4, 12, 16], matrix) {
            header.replaceSubrange((matrixOffset + index)..<(matrixOffset + index + 4), with: word(UInt32(bitPattern: Int32(value * 65536))))
        }
        header.replaceSubrange((matrixOffset + 32)..<(matrixOffset + 36), with: word(1 << 30))
        header.replaceSubrange(dimensions..<(dimensions + 4), with: word(UInt32(width * 65536)))
        header.replaceSubrange((dimensions + 4)..<(dimensions + 8), with: word(UInt32(height * 65536)))
        let tkhd = box("tkhd", header)
        let mdia = box("mdia", box("hdlr", Data(repeating: 0, count: 8) + Data(handler.utf8)))
        return box("trak", handlerFirst ? mdia + tkhd : tkhd + mdia)
    }

    static func movie(width: Double, height: Double, version: UInt8 = 0, matrix: [Double] = [1, 0, 0, 1]) -> Data {
        box("ftyp", Data("qt  ".utf8) + word(0) + Data("qt  ".utf8)) +
            box("moov", track(width: width, height: height, version: version, matrix: matrix))
    }
}
