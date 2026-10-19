import Darwin
import Foundation
import Testing
@testable import CanvasCore

struct HostFileRangeTests {
    private let sparseSize: Int64 = 200 * 1024 * 1024

    private func sparseAsset(_ fixture: HostFileFixture, path: String = "movie.mp4") throws {
        try fixture.write(path, Data())
        let file = try FileHandle(forWritingTo: fixture.root.appendingPathComponent(path))
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(sparseSize))
        for (offset, text) in [(Int64(0), "beginning"), (Int64(100 * 1024 * 1024 + 17), "middle"), (sparseSize - 7, "ending!")] {
            try file.seek(toOffset: UInt64(offset))
            try file.write(contentsOf: Data(text.utf8))
        }
    }

    private func read(_ request: HostFileRequest, files: HostFiles, local: Bool) async throws -> HostFile {
        if local { return try await HostFiles.readLocal(request) }
        return try await files.read(request)
    }

    @Test(arguments: [false, true])
    func sparseVideoRangesReadOnlyTheSelectedBytes(local: Bool) async throws {
        let fixture = try HostFileFixture()
        try sparseAsset(fixture)
        let files = try fixture.reader()
        let source = HostFileRequest.Source.directory(fixture.root.path)
        let metadata = try await read(HostFileRequest(source: source, policy: .boardAsset("movie.mp4"), bytes: false), files: files, local: local)
        #expect(metadata.size == 209_715_200)
        #expect(metadata.offset == 0)
        #expect(metadata.data == Data())
        #expect(metadata.commit == nil)
        let stamp = try #require(metadata.stamp)
        for (offset, length, expected) in [(Int64(0), 9, "beginning"), (Int64(104_857_617), 6, "middle"), (sparseSize - 7, 7, "ending!"), (sparseSize - 3, 512, "ng!"), (sparseSize, 32, "")] {
            let request = HostFileRequest(source: source, policy: .boardAsset("movie.mp4"), range: HostFileRange(offset: offset, length: length))
            let result = try await read(request, files: files, local: local)
            #expect(result.data == Data(expected.utf8))
            #expect(result.size == 209_715_200)
            #expect(result.offset == offset)
            #expect(result.stamp == stamp)
            #expect(result.path == metadata.path)
        }
        let zeros = try await read(HostFileRequest(source: source, policy: .boardAsset("movie.mp4"), range: HostFileRange(offset: 1024, length: 1_048_576)), files: files, local: local)
        #expect(zeros.data == Data(repeating: 0, count: 1_048_576))
        #expect(zeros.size == 209_715_200)
        #expect(zeros.offset == 1024)
        let probe = try await read(HostFileRequest(source: source, policy: .boardAsset("movie.mp4"), bytes: false, range: HostFileRange(offset: 104_857_617, length: 6)), files: files, local: local)
        #expect(probe.data == Data())
        #expect(probe.offset == 104_857_617)
        #expect(probe.size == 209_715_200)
        #expect(probe.stamp == stamp)
        await #expect(throws: HostFileError.tooLarge(limit: 4 * 1024 * 1024)) {
            try await read(HostFileRequest(source: source, policy: .boardAsset("movie.mp4")), files: files, local: local)
        }
    }

    @Test(arguments: [false, true])
    func invalidAndOversizedRangesAreRefused(local: Bool) async throws {
        let fixture = try HostFileFixture()
        try fixture.write("movie.mp4", Data("0123456789".utf8))
        let files = try fixture.reader()
        for range in [HostFileRange(offset: -1, length: 1), HostFileRange(offset: 0, length: 0), HostFileRange(offset: 0, length: -1), HostFileRange(offset: 0, length: 1_048_577), HostFileRange(offset: Int64.max, length: 1), HostFileRange(offset: 11, length: 1)] {
            for bytes in [true, false] {
                let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset("movie.mp4"), bytes: bytes, range: range)
                await #expect(throws: HostFileError.refused) { try await read(request, files: files, local: local) }
            }
        }
    }

    @Test func hostRefusesRangeValidationBypassesOnTheWire() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("movie.mp4", Data("0123456789".utf8))
        let spans: [JSONValue] = [
            .object(["offset": -1, "length": 1]),
            .object(["offset": 0, "length": 0]),
            .object(["offset": 0, "length": -1]),
            .object(["offset": 0, "length": 1_048_577]),
            .object(["offset": .number(0.5), "length": 1]),
            .object(["offset": 0, "length": .number(1.5)]),
            .object(["offset": "0", "length": 1]),
            .object(["offset": .bool(false), "length": 1]),
            .object(["offset": .number(9_007_199_254_740_992), "length": 1]),
            .object(["offset": 11, "length": 1]),
            .object(["length": 1]), .array([]), .string("0-1")
        ]
        for span in spans {
            for bytes in [true, false] {
                let wire: JSONValue = .object([
                    "source": .object(["kind": "directory", "root": .string(fixture.root.path)]),
                    "policy": .object(["kind": "boardAsset", "path": "movie.mp4"]),
                    "bytes": .bool(bytes), "range": span
                ])
                let files = try fixture.reader(request: wire)
                await #expect(throws: HostFileError.refused) { try await files.read(fixture.request("movie.mp4")) }
            }
        }
    }

    @Test(arguments: [false, true])
    func assetsRequireBothLexicalAndCanonicalBoardContainment(local: Bool) async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try fixture.write("asset space.css", Data("body {}".utf8))
        let inside = fixture.root.appendingPathComponent("asset space.css")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias.css").path, withDestinationPath: "asset space.css")
        for source in [HostFileRequest.Source.directory(fixture.root.path), .liveRoot(ref: "main", boardRoot: fixture.root.path)] {
            for path in ["asset space.css", inside.path, inside.absoluteString, "alias.css"] {
                let result = try await read(HostFileRequest(source: source, policy: .boardAsset(path)), files: files, local: local)
                #expect(result.data == Data("body {}".utf8))
                #expect(result.size == 7 && result.offset == 0)
            }
        }
        let outside = fixture.temp.appendingPathComponent("outside.css")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("escape.css"), withDestinationURL: outside)
        let outsideAlias = fixture.directory.appendingPathComponent("outside-alias.css")
        try FileManager.default.createSymbolicLink(at: outsideAlias, withDestinationURL: inside)
        let sibling = fixture.directory.appendingPathComponent("root-evil.css")
        try Data("sibling".utf8).write(to: sibling)
        for path in [outside.path, outside.absoluteString, outsideAlias.path, sibling.path, "../host-temp/outside.css", "escape.css", "~/asset.css", "https://example.com/asset.css", "file://remote.example/asset.css", "asset\0.css"] {
            for bytes in [true, false] {
                let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset(path), bytes: bytes, range: HostFileRange(offset: 0, length: 4))
                await #expect(throws: HostFileError.refused) { try await read(request, files: files, local: local) }
            }
        }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("directory.mp4"), withIntermediateDirectories: true)
        await #expect(throws: HostFileError.notFound(commit: nil)) {
            try await read(HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset("directory.mp4")), files: files, local: local)
        }
        let fifo = fixture.root.appendingPathComponent("pipe.mp4")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: HostFileError.notFound(commit: nil)) {
            try await read(HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset("pipe.mp4")), files: files, local: local)
        }
    }

    @Test func hostAssetRangesRefuseDirectorySwapsAfterCanonicalization() async throws {
        for bytes in [true, false] {
            let fixture = try HostFileFixture()
            try fixture.write("pkg/movie.mp4", Data("allowed".utf8))
            let files = try fixture.readerSwappingDirectory(containing: "pkg/movie.mp4", afterCanonicalization: 2)
            let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset("pkg/movie.mp4"), bytes: bytes, range: HostFileRange(offset: 0, length: 4))
            await #expect(throws: HostFileError.refused) { try await files.read(request) }
            #expect(try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("pkg").path)[.type] as? FileAttributeType == .typeSymbolicLink)
        }
    }

    @Test func localAssetDescriptorsRefuseDirectoryAndFinalSymlinkSwaps() async throws {
        for swapDirectory in [true, false] {
            for bytes in [true, false] {
                let fixture = try HostFileFixture()
                try fixture.write("pkg/movie.mp4", Data("allowed".utf8))
                let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset("pkg/movie.mp4"), bytes: bytes, range: HostFileRange(offset: 0, length: 4))
                let authorized = try HostLocalFile(request)
                let outside = fixture.temp.appendingPathComponent("movie.mp4")
                try Data("outside".utf8).write(to: outside)
                let swapped = swapDirectory ? fixture.root.appendingPathComponent("pkg") : fixture.root.appendingPathComponent("pkg/movie.mp4")
                try FileManager.default.moveItem(at: swapped, to: fixture.directory.appendingPathComponent("parked"))
                try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: swapDirectory ? fixture.temp : outside)
                #expect(throws: HostFileError.refused) { try authorized.read() }
            }
        }
    }

    @Test func hostRefusesBytesModifiedWhileTheirDescriptorIsBeingRead() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("movie.mp4", Data("allowed".utf8))
        let files = try fixture.reader(running: """
        (() => {
          const cp = require('node:child_process');
          const spawn = cp.spawnSync;
          cp.spawnSync = (executable, args, options) => {
            if (executable === 'python3') args = args.map(arg => arg.replace('data = stream.read(count)', "data = stream.read(count); os.utime(request['path'], ns=(0, 0))"));
            return spawn(executable, args, options);
          };
        })();
        """)
        let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset("movie.mp4"), range: HostFileRange(offset: 0, length: 4))
        await #expect(throws: HostFileError.unreadable) { try await files.read(request) }
    }

    @Test func localLegacyPageImagesRetainResolvedExtensionsAndTempRoots() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("chart.PNG", Data("board image".utf8))
        try fixture.write("text.txt", Data("not an image".utf8))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias").path, withDestinationPath: "chart.PNG")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("hidden.png").path, withDestinationPath: "text.txt")
        let temp = fixture.temp.appendingPathComponent("chart.svg")
        try Data("<svg/>".utf8).write(to: temp)
        let source = HostFileRequest.Source.directory(fixture.root.path)
        for (relative, absolute, expected) in [("chart.PNG", nil, "board image"), ("alias", nil, "board image"), (nil, temp.path, "<svg/>")] as [(String?, String?, String)] {
            let request = HostFileRequest(source: source, policy: .pageImage(relative: relative, absolute: absolute, temps: [fixture.temp.path]))
            #expect(try await HostFiles.readLocal(request).data == Data(expected.utf8))
        }
        for path in ["text.txt", "hidden.png"] {
            let request = HostFileRequest(source: source, policy: .pageImage(relative: path, absolute: fixture.root.appendingPathComponent(path).path, temps: [fixture.temp.path]))
            await #expect(throws: HostFileError.refused) { try await HostFiles.readLocal(request) }
        }
        await #expect(throws: HostFileError.refused) {
            try await HostFiles.readLocal(HostFileRequest(source: source, policy: .pageImage(relative: nil, absolute: temp.path, temps: [])))
        }
        let missing = fixture.root.appendingPathComponent("missing.mp4")
        await #expect(throws: HostFileError.notFound(commit: nil)) {
            try await HostFiles.readLocal(HostFileRequest(source: source, policy: .boardAsset(missing.path)))
        }
    }

    @Test func hostAssetDescriptorsRefuseFinalSymlinkSwaps() async throws {
        for bytes in [true, false] {
            let fixture = try HostFileFixture()
            try fixture.write("movie.mp4", Data("allowed".utf8))
            let outside = fixture.temp.appendingPathComponent("movie.mp4")
            try Data("outside".utf8).write(to: outside)
            let paths = String(decoding: try JSONEncoder().encode([
                fixture.root.appendingPathComponent("movie.mp4").path, outside.path,
                fixture.directory.appendingPathComponent("parked").path
            ]), as: UTF8.self)
            let files = try fixture.reader(running: """
            (() => {
              const fs = require('node:fs');
              const [file, outside, parked] = \(paths);
              const target = fs.realpathSync(file);
              const canonicalize = fs.realpathSync;
              let calls = 0;
              fs.realpathSync = (...args) => {
                const canonical = canonicalize(...args);
                if (canonical === target && ++calls === 2) {
                  fs.renameSync(file, parked);
                  fs.symlinkSync(outside, file);
                }
                return canonical;
              };
            })();
            """)
            let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset("movie.mp4"), bytes: bytes,
                                          range: HostFileRange(offset: 0, length: 4))
            await #expect(throws: HostFileError.refused) { try await files.read(request) }
        }
    }

    @Test(arguments: [false, true])
    func assetLiveRootsSelectTheBranchWorktree(local: Bool) async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("pkg/asset.js", "board root")
        try await repo.commit("asset")
        let worktree = fixture.directory.appendingPathComponent("feature")
        try await repo.git("worktree", "add", "-q", "-b", "asset-feature", worktree.path)
        try Data("feature root".utf8).write(to: worktree.appendingPathComponent("pkg/asset.js"))
        let request = HostFileRequest(source: .liveRoot(ref: "asset-feature", boardRoot: repo.url("pkg").path),
                                      policy: .boardAsset("asset.js"), range: HostFileRange(offset: 0, length: 7))
        let file = try await read(request, files: files, local: local)
        #expect(file.data == Data("feature".utf8))
        #expect(file.size == 12 && file.offset == 0)
        #expect(URL(fileURLWithPath: file.root).resolvingSymlinksInPath() == worktree.appendingPathComponent("pkg").resolvingSymlinksInPath())
    }

    @Test(arguments: [false, true])
    func absoluteAssetsUseRegisteredCounterpartAreas(local: Bool) async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("pkg/movie.mp4", "original")
        try await repo.commit("media")
        let worktree = fixture.directory.appendingPathComponent("feature")
        try await repo.git("worktree", "add", "-q", "-b", "media-area", worktree.path)
        let counterpart = worktree.appendingPathComponent("pkg")
        let movie = counterpart.appendingPathComponent("movie.mp4")
        try Data("feature movie".utf8).write(to: movie)
        let source = HostFileRequest.Source.directory(repo.url("pkg").path)
        let result = try await read(HostFileRequest(source: source, policy: .boardAsset(movie.path), range: HostFileRange(offset: 0, length: 7)), files: files, local: local)
        #expect(result.data == Data("feature".utf8))
        #expect(result.size == 13)
        let outside = worktree.appendingPathComponent("outside.mp4")
        try Data("outside".utf8).write(to: outside)
        let escape = counterpart.appendingPathComponent("escape.mp4")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        for path in [outside.path, escape.path] {
            await #expect(throws: HostFileError.refused) {
                try await read(HostFileRequest(source: source, policy: .boardAsset(path), range: HostFileRange(offset: 0, length: 4)), files: files, local: local)
            }
        }
    }

    @Test func localPageImagesKeepTheirUnboundedLegacyReadWhileBoardImagesStayBounded() async throws {
        let fixture = try HostFileFixture()
        let data = Data(repeating: 65, count: 4 * 1024 * 1024 + 1)
        try fixture.write("large.png", data)
        let source = HostFileRequest.Source.directory(fixture.root.path)
        let page = try await HostFiles.readLocal(HostFileRequest(source: source, policy: .pageImage(relative: "large.png", absolute: nil, temps: [])))
        #expect(page.data == data)
        #expect(page.size == 4_194_305 && page.offset == 0)
        for bytes in [true, false] {
            await #expect(throws: HostFileError.tooLarge(limit: 4 * 1024 * 1024)) {
                try await HostFiles.readLocal(HostFileRequest(source: source, policy: .boardImage("large.png"), bytes: bytes))
            }
        }
    }

    @Test(arguments: [false, true])
    func batchedObservationsKeepFailuresAndDetectOnlyChangedFiles(local: Bool) async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try fixture.write("a.js", Data("first".utf8))
        try fixture.write("b.json", Data("{}".utf8))
        try sparseAsset(fixture)
        let outside = fixture.temp.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let source = HostFileRequest.Source.directory(fixture.root.path)
        let requests = ["a.js", "b.json", "movie.mp4", "missing.css", outside.path].map {
            HostFileRequest(source: source, policy: .boardAsset($0))
        }
        func observe() async throws -> [HostFileObservation] {
            if local { return try await HostFiles.observeLocal(requests) }
            return try await files.observe(requests)
        }
        let first = try await observe()
        try #require(first.count == 5)
        #expect(first[3] == .failure(.notFound(commit: nil)))
        #expect(first[4] == .failure(.refused))
        try fixture.write("a.js", Data("second".utf8))
        let second = try await observe()
        try #require(second.count == 5)
        #expect(second[0] != first[0])
        #expect(Array(second.dropFirst()) == Array(first.dropFirst()))
        let content = try await read(requests[0], files: files, local: local)
        #expect(content.data == Data("second".utf8))
    }
}
