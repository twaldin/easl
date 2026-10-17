import Darwin
import Foundation
import Testing
@testable import CanvasCore

final class HostFileFixture: @unchecked Sendable {
    let directory: URL
    let root: URL
    let temp: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-files-\(UUID().uuidString)")
        root = directory.appendingPathComponent("root")
        temp = directory.appendingPathComponent("host-temp")
        for url in [root, temp] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func write(_ path: String, _ data: Data) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func reader(body: String? = nil, request: JSONValue? = nil) throws -> HostFiles {
        let executable = directory.appendingPathComponent("ssh-\(UUID().uuidString)")
        let execution: String
        if let request {
            let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            execution = """
            { head -n 1; printf '%s' \(RemoteHost.quote(json)); } | /bin/sh -c "$command"
            """
        } else {
            execution = body ?? "exec /bin/sh -c \"$command\""
        }
        try """
        #!/bin/sh
        for command; do :; done
        \(execution)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return HostFiles(hostName: "fixture", route: HostRoute(target: "fixture", controlPath: directory.appendingPathComponent("control").path, executable: executable.path), temps: [temp.path])
    }

    func reader(running injection: String) throws -> HostFiles {
        let escaped = String(decoding: try JSONEncoder().encode(injection + "\n"), as: UTF8.self).dropFirst().dropLast()
        return try reader(body: """
        { dd bs=1 count=1 of=/dev/null 2>/dev/null; printf '"%s' \(RemoteHost.quote(String(escaped))); cat; } | /bin/sh -c "$command"
        """)
    }

    func readerSwappingDirectory(containing relative: String, afterCanonicalization: Int) throws -> HostFiles {
        let file = root.appendingPathComponent(relative)
        let outside = directory.appendingPathComponent("outside")
        let parked = directory.appendingPathComponent("parked")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside bytes\n".utf8).write(to: outside.appendingPathComponent(file.lastPathComponent))
        let paths = String(decoding: try JSONEncoder().encode([file.path, outside.path, parked.path]), as: UTF8.self)
        let injection = """
        (() => {
          const fs = require('node:fs');
          const path = require('node:path');
          const [file, outside, parked] = \(paths);
          const target = fs.realpathSync(file);
          const parent = path.dirname(target);
          const destination = fs.realpathSync(outside);
          const realpath = fs.realpathSync;
          let canonicalizations = 0;
          fs.realpathSync = (...args) => {
            const canonical = realpath(...args);
            if (canonical === target && ++canonicalizations === \(afterCanonicalization)) {
              fs.renameSync(parent, parked);
              fs.symlinkSync(destination, parent, 'dir');
            }
            return canonical;
          };
        })();
        """
        return try reader(running: injection)
    }

    func request(_ path: String, source: HostFileRequest.Source? = nil, bytes: Bool = true) -> HostFileRequest {
        HostFileRequest(source: source ?? .directory(root.path), policy: .boardFile(path), bytes: bytes)
    }

    func wireRequest(_ path: String, root: URL? = nil) -> JSONValue {
        .object(["source": .object(["kind": "directory", "root": .string((root ?? self.root).path)]),
                 "policy": .object(["kind": "board", "relative": .string(path)]), "bytes": .bool(true)])
    }
}

struct HostFilesTests {
    @Test func bytesAndQuotedFilenamesComeFromTheHost() async throws {
        let fixture = try HostFileFixture()
        let name = "quoted ' file\nname.swift"
        let bytes = Data([0, 10, 255, 34, 39, 128])
        try fixture.write(name, bytes)
        let files = try fixture.reader()
        let result = try await files.read(fixture.request(name))
        #expect(result.data == bytes)
        let path = try #require(result.path)
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == fixture.root.appendingPathComponent(name).resolvingSymlinksInPath())
        #expect(result.commit == nil)
        let checked = try await files.read(fixture.request(name, bytes: false))
        #expect(checked.path == result.path && checked.data.isEmpty)
        #expect(checked.version == result.version)
    }

    @Test func descriptorVersionsPreserveExactNanosecondsAndDetectSameSizeChanges() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let path = fixture.root.appendingPathComponent("chart.png")
        try fixture.write("chart.png", Data("first".utf8))
        let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("chart.png"))
        let first = try await files.read(request)
        var metadata = stat()
        #expect(lstat(path.path, &metadata) == 0)
        let mtime = Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_mtimespec.tv_nsec)
        let ctime = Int64(metadata.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_ctimespec.tv_nsec)
        #expect(first.stamp == "\(metadata.st_dev):\(metadata.st_ino):5:\(mtime):\(ctime)")
        var check = request
        check.bytes = false
        let unchanged = try await files.read(check)
        #expect(unchanged.version == first.version)
        #expect(unchanged.data == Data())

        try fixture.write("chart.png", Data("other".utf8))
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        let edited = try await files.read(check)
        #expect(edited.version != first.version)
        #expect(edited.version == (try await files.read(request)).version)
        #expect(try await files.read(request).data == Data("other".utf8))

        try Data("third".utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        let replacement = try await files.read(check)
        #expect(replacement.version != edited.version)
        #expect(replacement.version == (try await files.read(request)).version)
        #expect(try await files.read(request).data == Data("third".utf8))
    }

    @Test func imageTilesReadOnlyInsideTheBoardIncludingAbsoluteAndFileURLs() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let bytes = Data("board image".utf8)
        try fixture.write("image space.png", bytes)
        let image = fixture.root.appendingPathComponent("image space.png")
        for path in ["image space.png", image.path, image.absoluteString] {
            let result = try await files.read(HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage(path)))
            #expect(result.data == bytes)
        }
        try fixture.write("shot-06:15.png", Data("colon filename".utf8))
        for bytes in [true, false] {
            let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("shot-06:15.png"), bytes: bytes)
            let result = try await files.read(request)
            #expect(result.data == (bytes ? Data("colon filename".utf8) : Data()))
        }
        let outside = fixture.temp.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        let sibling = fixture.directory.appendingPathComponent("root-evil.png")
        try Data("sibling".utf8).write(to: sibling)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("escape.png"), withDestinationURL: outside)
        for path in [outside.path, outside.absoluteString, "../host-temp/outside.png", sibling.path, "escape.png", "https://example.com/image.png", "~/image.png", "image\0.png"] {
            for bytes in [true, false] {
                let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage(path), bytes: bytes)
                await #expect(throws: HostFileError.refused) { try await files.read(request) }
            }
        }
        let page = HostFileRequest(source: .directory(fixture.root.path), policy: .pageImage(relative: nil, absolute: outside.path, temps: [fixture.temp.path]))
        #expect(try await files.read(page).data == Data("outside".utf8))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias.png").path, withDestinationPath: image.lastPathComponent)
        #expect(try await files.read(HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("alias.png"))).data == bytes)
    }

    @Test func committedImagesKeepTheirRequestedPathDespiteLiveSymlinks() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("pkg/chart.png", "committed chart")
        try await repo.write("pkg/other.png", "committed other")
        let commit = try await repo.commit("images")
        try await repo.git("branch", "snapshot")
        let root = repo.url("pkg")
        let chart = root.appendingPathComponent("chart.png")
        let source = HostFileRequest.Source.ref("snapshot", lastKnownSha: nil, boardRoot: root.path)
        let outsideTarget = fixture.temp.appendingPathComponent("outside.png")
        try Data("outside live image".utf8).write(to: outsideTarget)
        for destination in ["other.png", outsideTarget.path, fixture.temp.appendingPathComponent("missing.png").path] {
            try FileManager.default.removeItem(at: chart)
            try FileManager.default.createSymbolicLink(atPath: chart.path, withDestinationPath: destination)
            for path in ["chart.png", chart.path, chart.absoluteString] {
                for bytes in [true, false] {
                    let result = try await files.read(HostFileRequest(source: source, policy: .boardImage(path), bytes: bytes))
                    #expect(result.data == (bytes ? Data("committed chart".utf8) : Data()))
                    #expect(result.version == HostFileVersion(root: root.path, path: "chart.png", commit: commit))
                }
            }
        }
        try FileManager.default.removeItem(at: chart)
        try FileManager.default.createSymbolicLink(atPath: chart.path, withDestinationPath: "other.png")
        let outside = fixture.temp.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: chart)
        for source in [source, .directory(root.path)] {
            for bytes in [true, false] {
                await #expect(throws: HostFileError.refused) {
                    try await files.read(HostFileRequest(source: source, policy: .boardImage(outside.path), bytes: bytes))
                }
            }
        }
    }

    @Test func imageTileMetadataRetainsSizeRefusalsAndRecoversMissingFiles() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("chart.png"))
        var metadata = request
        metadata.bytes = false
        for read in [request, metadata] {
            await #expect(throws: HostFileError.notFound(commit: nil)) { try await files.read(read) }
        }
        try fixture.write("chart.png", Data("created".utf8))
        let created = try await files.read(request)
        #expect(created.data == Data("created".utf8))
        #expect(try await files.read(metadata).version == created.version)
        try fixture.write("chart.png", Data(repeating: 65, count: SourceExcerpt.maxFileBytes + 1))
        for read in [request, metadata] {
            await #expect(throws: HostFileError.tooLarge(limit: 4 * 1024 * 1024)) { try await files.read(read) }
        }
    }

    @Test func imageTileReadsAndMetadataRefuseIntermediateDirectorySwaps() async throws {
        for bytes in [true, false] {
            let fixture = try HostFileFixture()
            try fixture.write("pkg/chart.png", Data("allowed".utf8))
            let files = try fixture.readerSwappingDirectory(containing: "pkg/chart.png", afterCanonicalization: 2)
            let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("pkg/chart.png"), bytes: bytes)
            await #expect(throws: HostFileError.refused) { try await files.read(request) }
            #expect(try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("pkg").path)[.type] as? FileAttributeType == .typeSymbolicLink)
        }
    }

    @Test func sandboxRefusesUnsafeRequestsOnTheHostItself() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("safe.txt", Data("safe\n".utf8))
        let outside = fixture.directory.appendingPathComponent("outside.txt")
        try Data("outside\n".utf8).write(to: outside)
        for path in ["../outside.txt", outside.path, "~/outside.txt", "safe\0.txt", "a/../safe.txt"] {
            let files = try fixture.reader(request: fixture.wireRequest(path))
            await #expect(throws: HostFileError.refused) { try await files.read(fixture.request("safe.txt")) }
        }
        let files = try fixture.reader()
        let safe = try await files.read(fixture.request("safe.txt"))
        #expect(String(decoding: safe.data, as: UTF8.self) == "safe\n")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        await #expect(throws: HostFileError.refused) { try await files.read(fixture.request("escape.txt")) }
        let sibling = fixture.directory.appendingPathComponent("root-evil")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("sibling".utf8).write(to: sibling.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("sibling"), withDestinationURL: sibling)
        await #expect(throws: HostFileError.refused) { try await files.read(fixture.request("sibling/file.txt")) }
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("inside.txt").path, withDestinationPath: "safe.txt")
        #expect(try await files.read(fixture.request("inside.txt")).data == Data("safe\n".utf8))
    }

    @Test func excerptBytesRefuseAnIntermediateDirectorySwap() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("pkg/file.txt", Data("allowed excerpt\n".utf8))
        let files = try fixture.readerSwappingDirectory(containing: "pkg/file.txt", afterCanonicalization: 2)
        await #expect(throws: HostFileError.refused) {
            try await files.read(fixture.request("pkg/file.txt"))
        }
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("pkg").path)[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func imageBytesRefuseAnIntermediateDirectorySwap() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("pkg/chart.png", Data("allowed image\n".utf8))
        let files = try fixture.readerSwappingDirectory(containing: "pkg/chart.png", afterCanonicalization: 1)
        let request = try #require(LocalImage.hostPageFile(requestPath: "/pkg/chart.png", source: .directory(fixture.root.path), temps: files.temps))
        await #expect(throws: HostFileError.refused) {
            try await files.read(request)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("pkg").path)[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func codeOpenMetadataRefusesAnIntermediateDirectorySwap() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("pkg/file.swift", Data("func allowed() {}\n".utf8))
        let files = try fixture.readerSwappingDirectory(containing: "pkg/file.swift", afterCanonicalization: 2)
        await #expect(throws: HostFileError.refused) {
            try await files.read(fixture.request("pkg/file.swift", bytes: false))
        }
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("pkg").path)[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func filesystemRootAllowsDescendantExcerptBytes() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("file.txt", Data("root excerpt\n".utf8))
        let file = fixture.root.appendingPathComponent("file.txt").resolvingSymlinksInPath()
        let files = try fixture.reader()
        let result = try await files.read(fixture.request(String(file.path.dropFirst()), source: .directory("/")))
        #expect(result.data == Data("root excerpt\n".utf8))
    }

    @Test func imagesUseHostTempDirectoriesAndResolvedExtensions() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try fixture.write("chart.PNG", Data("image bytes".utf8))
        try fixture.write("text.txt", Data("not an image".utf8))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("hidden.png").path, withDestinationPath: "text.txt")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias").path, withDestinationPath: "chart.PNG")
        let tempImage = fixture.temp.appendingPathComponent("temp image.svg")
        try Data("<svg/>".utf8).write(to: tempImage)
        for path in ["/chart.PNG", "/alias", tempImage.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!] {
            let request = try #require(LocalImage.hostPageFile(requestPath: path, source: .directory(fixture.root.path), temps: files.temps))
            let file = try await files.read(request)
            #expect(file.data == (path.contains("temp") ? Data("<svg/>".utf8) : Data("image bytes".utf8)))
            #expect(file.mimeType == (path.contains("temp") ? "image/svg+xml" : "image/png"))
        }
        for path in ["/hidden.png", "/text.txt"] {
            let request = try #require(LocalImage.hostPageFile(requestPath: path, source: .directory(fixture.root.path), temps: files.temps))
            await #expect(throws: HostFileError.self) { try await files.read(request) }
        }
        let denied = HostFileRequest(source: .directory(fixture.root.path), policy: .pageImage(relative: nil, absolute: tempImage.path, temps: []))
        await #expect(throws: HostFileError.refused) { try await files.read(denied) }
        let largeImage = Data(repeating: 65, count: SourceExcerpt.maxFileBytes + 1)
        try fixture.write("large.png", largeImage)
        let imageRequest = try #require(LocalImage.hostPageFile(requestPath: "/large.png", source: .directory(fixture.root.path), temps: files.temps))
        #expect(try await files.read(imageRequest).data == largeImage)
    }

    @Test func excerptsRetainMissingBinaryAndSizeErrors() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try fixture.write("binary.txt", Data([65, 0, 66]))
        let binary = try await files.read(fixture.request("binary.txt"))
        let excerpt = SourceExcerpt.from(binary, path: "binary.txt", lines: nil, symbol: nil)
        #expect(excerpt.stale && excerpt.reason == "binary.txt is a binary file")
        await #expect(throws: HostFileError.notFound(commit: nil)) { try await files.read(fixture.request("missing.txt")) }
        try fixture.write("large.txt", Data(repeating: 65, count: SourceExcerpt.maxFileBytes + 1))
        await #expect(throws: HostFileError.tooLarge(limit: 4 * 1024 * 1024)) { try await files.read(fixture.request("large.txt")) }
        let checked = try await files.read(fixture.request("large.txt", bytes: false))
        #expect(checked.path?.hasSuffix("large.txt") == true)
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("directory.txt"), withIntermediateDirectories: true)
        await #expect(throws: HostFileError.notFound(commit: nil)) { try await files.read(fixture.request("directory.txt")) }
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("dangling.txt").path, withDestinationPath: "missing.txt")
        await #expect(throws: HostFileError.notFound(commit: nil)) { try await files.read(fixture.request("dangling.txt")) }
    }

    @Test func malformedTransportIsUnavailable() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("file.txt", Data("host".utf8))
        let broken = try fixture.reader(body: "/bin/sh -c \"$command\"; printf 'truncated'")
        await #expect(throws: HostFileError.unavailable("invalid host file reply")) { try await broken.read(fixture.request("file.txt")) }
    }

    @Test func anSshThatTakesOnlyShortCommandsStillReadsFilesAndListsChanges() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader(body: """
        if [ "${#command}" -gt 4096 ]; then echo 'mux_client_request_session: send fds failed' >&2; exit 255; fi
        exec /bin/sh -c "$command"
        """)
        try fixture.write("file.txt", Data("host bytes\n".utf8))
        #expect(try await files.read(fixture.request("file.txt")).data == Data("host bytes\n".utf8))
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("a.txt", "base\n")
        try await repo.commit("base")
        try await repo.write("a.txt", "edited\n")
        let load = try await HostGit(files: files).changes(boardRoot: repo.root.path, spec: ChangesSpec(.object([:])), highlight: false)
        #expect(load.set.notice == nil && load.set.files.map(\.path) == ["a.txt"] && load.set.files.map { $0.new.text } == ["edited\n"])
    }

    @Test func cancellationReapsTheClient() async throws {
        let fixture = try HostFileFixture()
        let pidFile = fixture.directory.appendingPathComponent("client-pid")
        let files = try fixture.reader(body: "echo $$ > \(RemoteHost.quote(pidFile.path)); exec /bin/sleep 30")
        let task = Task { try await files.read(fixture.request("waiting.txt")) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(20)
        var started: Int32?
        while started == nil, ContinuousClock.now < deadline {
            started = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap {
                Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if started == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let pid = try #require(started, "the host-file client must start before cancellation is exercised")
        #expect(kill(pid, 0) == 0)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func refsReadLiveObjectsMergedAndMissingWithLocalParity() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("pkg/file.txt", "base\n")
        try await repo.write("pkg/other.txt", "other\n")
        try await repo.commit("base")
        let worktree = fixture.directory.appendingPathComponent("work tree ' live")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try "committed\n".write(to: worktree.appendingPathComponent("pkg/file.txt"), atomically: true, encoding: .utf8)
        try await TempRepo.run(["commit", "-q", "-a", "-m", "feature"], in: worktree)
        let tip = try await TempRepo.run(["rev-parse", "HEAD"], in: worktree)
        try "live\n".write(to: worktree.appendingPathComponent("pkg/file.txt"), atomically: true, encoding: .utf8)
        let boardRoot = repo.url("pkg")
        func compare(_ ref: String, sha: String?, expected: String) async throws {
            let local = try await RefSource.resolve(ref: ref, lastKnownSha: sha, boardRoot: boardRoot)
            let result = try await files.read(fixture.request("file.txt", source: .ref(ref, lastKnownSha: sha, boardRoot: boardRoot.path)))
            #expect(result.commit == local.commit)
            #expect(URL(fileURLWithPath: result.root).resolvingSymlinksInPath() == local.root.resolvingSymlinksInPath())
            #expect(String(decoding: result.data, as: UTF8.self) == expected)
            let metadata = try await files.read(fixture.request("file.txt", source: .ref(ref, lastKnownSha: sha, boardRoot: boardRoot.path), bytes: false))
            #expect(metadata.version == result.version)
            #expect(metadata.data == Data())
            if result.commit != nil {
                #expect(result.path == "file.txt")
                #expect(result.stamp == nil)
            }
            let imageRoot = try await files.read(fixture.request("file.txt", source: .liveRoot(ref: ref, boardRoot: boardRoot.path)))
            let expectedRoot = RefSource.liveRoot(ref: ref, boardRoot: boardRoot) ?? boardRoot
            #expect(URL(fileURLWithPath: imageRoot.root).resolvingSymlinksInPath() == expectedRoot.resolvingSymlinksInPath())
        }
        try await compare("feature", sha: nil, expected: "live\n")
        try await compare("refs/heads/feature", sha: nil, expected: "live\n")
        try await repo.git("worktree", "remove", "--force", worktree.path)
        try await compare("feature", sha: nil, expected: "committed\n")
        let objects = HostFileRequest.Source.ref("feature", lastKnownSha: nil, boardRoot: boardRoot.path)
        let immutable = try await files.read(fixture.request("file.txt", source: objects))
        let other = try await files.read(fixture.request("other.txt", source: objects))
        #expect(other.version == HostFileVersion(root: immutable.root, path: "other.txt", commit: tip))
        #expect(other.version != immutable.version)
        let imageRequest = HostFileRequest(source: objects, policy: .boardImage("file.txt"))
        var imageMetadata = imageRequest
        imageMetadata.bytes = false
        #expect(try await files.read(imageRequest).version == immutable.version)
        #expect(try await files.read(imageMetadata).version == immutable.version)
        await #expect(throws: HostFileError.notFound(commit: tip)) {
            try await files.read(fixture.request("missing.txt", source: objects))
        }
        let missingAtCommit = try await files.read(fixture.request("missing.txt", source: objects, bytes: false))
        #expect(missingAtCommit.commit == tip && missingAtCommit.data.isEmpty)
        try await repo.git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
        try await repo.write("pkg/file.txt", "later\n")
        try await repo.commit("later")
        try await repo.git("branch", "-d", "feature")
        try await compare("feature", sha: tip, expected: "committed\n")
        try await repo.git("checkout", "-q", "-b", "unmerged")
        try await repo.write("pkg/file.txt", "unmerged\n")
        let unmerged = try await repo.commit("unmerged")
        try await repo.git("checkout", "-q", "main")
        try await repo.git("branch", "-D", "unmerged")
        try await compare("unmerged", sha: unmerged, expected: "unmerged\n")
        await #expect(throws: HostFileError.ref("unknown ref unknown")) {
            try await files.read(fixture.request("file.txt", source: .ref("unknown", lastKnownSha: nil, boardRoot: boardRoot.path)))
        }
        await #expect(throws: HostFileError.ref("not in a git repository")) {
            try await files.read(fixture.request("file.txt", source: .ref("main", lastKnownSha: nil, boardRoot: fixture.root.path)))
        }
    }
}

@MainActor
private final class HtmlTestHost: BoardHost {
    var writes: [RemoteWrite] = []
    func send(_ write: RemoteWrite) { writes.append(write) }
}

@MainActor
struct RemoteHtmlChannelTests {
    @Test func excerptsAndNavigationUseHostFilesAndNormalBoardWrites() async throws {
        let fixture = try HostFileFixture()
        let viewer = fixture.directory.appendingPathComponent("viewer")
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        try "LOCAL\n".write(to: viewer.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)
        try fixture.write("file.swift", Data("func host() {\n    print(1)\n}\n".utf8))
        let files = try fixture.reader(request: fixture.wireRequest("file.swift"))
        let host = HtmlTestHost()
        let board = Board(remote: "brd_remote", root: viewer, host: host)
        let html = board.create(type: .html, props: .object(["html": "<canvas-code/> "]), frame: Frame(x: 0, y: 0, w: 500, h: 400))
        host.writes.removeAll()
        let excerpt = try await HtmlChannel.handle(.excerpt(path: "file.swift", lines: nil, symbol: "host"), tile: html.id, board: board, files: files)
        #expect(excerpt["lines"] == .array(["func host() {", "    print(1)", "}"]))
        #expect(excerpt["start"] == 1 && excerpt["stale"] == .bool(false))
        let opened = try await HtmlChannel.handle(.openCode(path: "file.swift", lines: nil, symbol: "host"), tile: html.id, board: board, files: files)
        let code = try board.object(try #require(opened["tile"]?.string))
        #expect(code.props["path"] == .string(fixture.root.appendingPathComponent("file.swift").path))
        #expect(code.props["range"] == .object(["start": 1, "end": 3]))
        #expect(host.writes == [.create(code)])
        _ = try await HtmlChannel.handle(.setState(key: "decision", value: .bool(true)), tile: html.id, board: board, files: files)
        #expect(board.objects[html.id]?.props["state"] == .object(["decision": .bool(true)]))
        #expect(host.writes.last == .update(html.id, seen: html.rev, frame: nil, z: nil, props: .object(["state": .object(["decision": .bool(true)])])))
        await #expect(throws: HtmlError.unavailable("host file reader is unavailable")) {
            try await HtmlChannel.handle(.excerpt(path: "file.swift", lines: nil, symbol: nil), tile: html.id, board: board)
        }
    }

    @Test func refPagesOpenAtTheRefEvenWhenAFileOrTheBranchIsGone() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("file.txt", "base\n")
        let base = try await repo.commit("base")
        try await repo.git("branch", "objects")
        let host = HtmlTestHost()
        let board = Board(remote: "brd_ref", root: repo.root, host: host)
        let html = board.create(type: .html, props: .object(["html": "<p>ref</p>", "ref": "objects"]))
        let missing = try await HtmlChannel.handle(.excerpt(path: "missing.txt", lines: nil, symbol: nil), tile: html.id, board: board, files: files)
        #expect(missing["stale"] == .bool(true))
        #expect(missing["reason"] == .string("missing.txt not found at \(base.prefix(7))"))
        let opened = try await HtmlChannel.handle(.openCode(path: "missing.txt", lines: LineRange(start: 2, end: 4), symbol: nil), tile: html.id, board: board, files: files)
        let code = try board.object(try #require(opened["tile"]?.string))
        #expect(code.props == .object(["path": "missing.txt", "ref": "objects", "range": .object(["start": 2, "end": 4])]))
        _ = try board.update(html.id, props: .object(["ref": "unknown"]))
        let unknown = try await HtmlChannel.handle(.excerpt(path: "file.txt", lines: nil, symbol: nil), tile: html.id, board: board, files: files)
        #expect(unknown["reason"] == "unknown ref unknown")
        let unknownOpen = try await HtmlChannel.handle(.openCode(path: "file.txt", lines: nil, symbol: nil), tile: html.id, board: board, files: files)
        let unknownCode = try board.object(try #require(unknownOpen["tile"]?.string))
        #expect(unknownCode.props == .object(["path": "file.txt", "ref": "unknown"]))
    }

    /// A page measured before its tile exists (`Board.measuring`) reads the host's files as its
    /// tile will, under its own root, and nothing it does reaches the board's host.
    @Test func aPageMeasuredBeforeItsTileExistsReadsUnderItsOwnRoot() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("file.swift", Data("func page() {\n    print(\"board root\")\n}\n".utf8))
        try fixture.write("pkg/file.swift", Data("func page() {\n    print(2)\n}\n".utf8))
        let files = try fixture.reader()
        let host = HtmlTestHost()
        let board = Board(remote: "brd_remote", root: fixture.root, host: host)
        let page = CanvasObject(id: "obj_page", type: .html, frame: Frame(x: 0, y: 0, w: 640, h: 27), z: 0, createdBy: .user, createdAt: Date(),
                                props: .object(["html": "<canvas-code/>", "root": "pkg"]))
        let scratch = Board.measuring(page, on: board)
        let excerpt = try await HtmlChannel.handle(.excerpt(path: "file.swift", lines: nil, symbol: "page"), tile: page.id, board: scratch, files: files)
        #expect(excerpt["lines"] == .array(["func page() {", "    print(2)", "}"]))
        _ = try await HtmlChannel.handle(.setState(key: "seen", value: .bool(true)), tile: page.id, board: scratch, files: files)
        #expect(host.writes.isEmpty)
        #expect(board.objects.isEmpty)
    }
}

@MainActor
struct RemoteImageMentionTests {
    @Test func aRemotePixelMentionDoesNotReadTheSameNamedViewerImage() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("chart.svg", Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="999" height="777"/>"#.utf8))
        let host = HtmlTestHost()
        let board = Board(remote: "brd_image_host", root: fixture.root, host: host)
        let image = board.create(type: .image, props: .object(["path": "chart.svg"]))
        let mention = try board.stage(.image(object: image.id, path: "chart.svg", x: 7, y: 9))
        let resolved = await MentionContext.resolve(mention, index: 1, on: board)
        #expect(resolved.summary == "[1] image chart.svg · pixel (7, 9), from its top-left · tile \(image.id)")
    }
}
