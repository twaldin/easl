import Darwin
import Foundation
import Testing
@testable import CanvasCore

@Suite(.serialized)
struct HostReferencesTests {
    private func canonical(_ url: URL) throws -> String {
        let path = try #require(realpath(url.path, nil))
        defer { free(path) }
        return String(cString: path)
    }

    private func host(_ fixture: HostFileFixture, listing: String = "") throws -> RemoteHost {
        let zmx = fixture.directory.appendingPathComponent("zmx")
        try "#!/bin/sh\nprintf '%s' \(RemoteHost.quote(listing))\n".write(to: zmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)
        return RemoteHost(name: "fixture", sshTarget: "fixture", socketPath: fixture.directory.appendingPathComponent("api.sock").path,
                          tmpdir: fixture.temp.path, easlBin: "easl", zmxBin: zmx.path)
    }

    private func candidates(_ paths: [String], pytest: [String]? = nil) -> [TerminalReferences.Candidate] {
        paths.map { .init(reference: .init(range: NSRange(location: 0, length: $0.utf16.count), path: $0,
                                           lines: LineRange(start: 3, end: 3), test: pytest), runs: []) }
    }

    private func request(_ fixture: HostFileFixture, _ paths: [String], cwd: String? = nil) -> HostReferenceRequest {
        .init(boardRoot: fixture.root.path, board: "board", tile: "tile", cwd: cwd, candidates: candidates(paths))
    }

    @Test func directRelativeAbsoluteAndDiffReferencesOpenHostPathsWithoutBytes() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("src/lib.rs", Data("host source".utf8))
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        let expected = fixture.root.appendingPathComponent("src/lib.rs").path
        for path in ["src/lib.rs", "a/src/lib.rs", "b/src/lib.rs", fixture.root.appendingPathComponent("src/lib.rs").path] {
            #expect(try await references.resolve(request(fixture, [path])) == .resolved(.init(candidate: 0, path: expected, pytestBytes: nil)))
        }
        #expect(try await references.resolve(request(fixture, ["missing.rs"])) == .failure(.missing))
    }

    @Test func explicitOutsideAndEscapingSymlinksRefuseEvenWhenMissing() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("src/lib.rs", Data("inside".utf8))
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("lib.rs"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("escape"), withDestinationURL: outside)
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        for path in [outside.appendingPathComponent("lib.rs").path, outside.appendingPathComponent("missing.rs").path,
                     "../outside/lib.rs", "../outside/missing.rs", "escape/lib.rs", "escape/missing.rs"] {
            #expect(try await references.resolve(request(fixture, [path, "src/lib.rs"])) == .failure(.refused))
        }
    }

    @Test func hostSessionCwdAndOSC7PrecedenceSelectTheNearestIndexedFile() async throws {
        let fixture = try HostFileFixture()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("one/src/lib.rs", "one")
        try await repo.write("two/src/lib.rs", "two")
        try await repo.commit("files")
        let home = HostedTerminal.homeLabel(fixture.directory.path)
        let listing = "name=canvas-tile\tcanvas.tile=tile\tcanvas.home=\(home)\tcanvas.board=old\tcwd=file://fixture\(repo.url("two").path)\n"
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture, listing: listing))
        var req = HostReferenceRequest(boardRoot: repo.root.path, board: "board", tile: "tile", merged: ["old"],
                                       cwd: repo.url("one").path, candidates: candidates(["lib.rs"]))
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: repo.url("two/src/lib.rs").path, pytestBytes: nil)))
        req.reportedCwd = repo.url("one").path
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: repo.url("one/src/lib.rs").path, pytestBytes: nil)))
        req.reportedCwd = fixture.directory.path
        #expect(try await references.resolve(req) == .failure(.refused))
        req.reportedCwd = repo.url("missing").path
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: repo.url("two/src/lib.rs").path, pytestBytes: nil)))
        req.merged = []
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: repo.url("one/src/lib.rs").path, pytestBytes: nil)))
        req.board = "old"
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: repo.url("two/src/lib.rs").path, pytestBytes: nil)))
        req.hosted = true
        #expect(try await references.resolve(req) == .failure(.ambiguous))
    }

    @Test func invalidSessionCwdDoesNotUseStaleStartDirectory() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("startup/lib.rs", Data("startup".utf8))
        try fixture.write("current/lib.rs", Data("current".utf8))
        try fixture.write("lib.rs", Data("root".utf8))
        let home = HostedTerminal.homeLabel(fixture.directory.path)
        for cwd in ["", "relative", fixture.root.appendingPathComponent("missing").path] {
            let listing = "name=canvas-tile\tcanvas.tile=tile\tcanvas.home=\(home)\tcanvas.board=board\tcwd=\(cwd)\tstart_dir=\(fixture.root.appendingPathComponent("startup").path)\n"
            let references = HostReferences(files: try fixture.reader(), host: try host(fixture, listing: listing))
            var req = request(fixture, ["lib.rs"], cwd: fixture.root.appendingPathComponent("current").path)
            req.reportedCwd = "not/absolute"
            #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: fixture.root.appendingPathComponent("current/lib.rs").path, pytestBytes: nil)))
            req.cwd = nil
            #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: fixture.root.appendingPathComponent("lib.rs").path, pytestBytes: nil)))
        }
    }

    @Test func outsidePropsAndSessionDirectoriesRefuseRelativeNames() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("lib.rs", Data("board".utf8))
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("lib.rs"))
        let home = HostedTerminal.homeLabel(fixture.directory.path)
        let listing = "name=canvas-tile\tcanvas.tile=tile\tcanvas.home=\(home)\tcanvas.board=board\tcwd=\(outside.path)\n"
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        #expect(try await references.resolve(request(fixture, ["lib.rs"], cwd: outside.path)) == .failure(.refused))
        let sessionReferences = HostReferences(files: try fixture.reader(), host: try host(fixture, listing: listing))
        #expect(try await sessionReferences.resolve(request(fixture, ["lib.rs"])) == .failure(.refused))
        #expect(try await sessionReferences.resolve(request(fixture, [fixture.root.appendingPathComponent("lib.rs").path])) ==
            .resolved(.init(candidate: 0, path: fixture.root.appendingPathComponent("lib.rs").path, pytestBytes: nil)))
    }

    @Test func tmpBoardAliasKeepsOneWrittenIdentityForDirectAbsoluteAndIndexedReferences() async throws {
        let fixture = try HostFileFixture()
        let repo = try await TempRepo()
        let alias = "/tmp/easl-reference-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: alias)
            try? FileManager.default.removeItem(at: repo.root)
        }
        try await repo.write("src/lib.rs", "source\n")
        try await repo.commit("source")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: repo.root.path)
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        let absolute = try canonical(repo.url("src/lib.rs"))
        for path in ["src/lib.rs", "lib.rs", alias + "/src/lib.rs", absolute] {
            let req = HostReferenceRequest(boardRoot: alias, board: "board", tile: "tile", candidates: candidates([path]))
            #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: alias + "/src/lib.rs", pytestBytes: nil)))
        }
    }

    @Test func inBoardSymlinkKeepsItsAuthoredPathIncludingIndexedMatches() async throws {
        let fixture = try HostFileFixture()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("src/lib.rs", "source\n")
        try FileManager.default.createSymbolicLink(atPath: repo.url("src/alias.rs").path, withDestinationPath: "lib.rs")
        try await repo.commit("alias")
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        for path in ["src/alias.rs", "alias.rs", repo.url("src/alias.rs").path] {
            let req = HostReferenceRequest(boardRoot: repo.root.path, board: "board", tile: "tile", candidates: candidates([path]))
            #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: repo.url("src/alias.rs").path, pytestBytes: nil)))
        }
    }

    @Test func refusedIndexedSymlinkDoesNotHideSafeMatchOrLaterReading() async throws {
        let fixture = try HostFileFixture()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("safe/lib.rs", "safe\n")
        try await repo.write("unsafe/keep.rs", "keep\n")
        try await repo.write("chosen.rs", "chosen\n")
        try FileManager.default.createSymbolicLink(atPath: repo.url("unsafe/lib.rs").path,
                                                 withDestinationPath: fixture.directory.appendingPathComponent("outside.rs").path)
        try await repo.commit("files")
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        var req = HostReferenceRequest(boardRoot: repo.root.path, board: "board", tile: "tile", candidates: candidates(["lib.rs"]))
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: repo.url("safe/lib.rs").path, pytestBytes: nil)))
        try FileManager.default.removeItem(at: repo.url("safe/lib.rs"))
        #expect(try await references.resolve(req) == .failure(.refused))
        req.candidates = candidates(["lib.rs", "chosen.rs"])
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 1, path: repo.url("chosen.rs").path, pytestBytes: nil)))
        req.candidates = candidates(["unsafe/lib.rs", "chosen.rs"])
        #expect(try await references.resolve(req) == .failure(.refused))
    }

    @Test func safeInBoardResolutionMatchesTheLocalConsumer() async throws {
        let fixture = try HostFileFixture()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("pkg/src/lib.rs", "nearest\n")
        try await repo.write("other/lib.rs", "farther\n")
        try await repo.commit("files")
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        let cwd = repo.url("pkg").path
        let expected = repo.url("pkg/src/lib.rs").path
        let listed = FileIndex(paths: ["pkg/src/lib.rs", "other/lib.rs"])
        for path in ["src/lib.rs", "a/src/lib.rs", "b/src/lib.rs", "lib.rs", "pkg/src/lib.rs", expected] {
            let local = TerminalReferences.resolve(path, directories: [cwd, repo.root.path], home: "/unused",
                                                   isFile: TerminalReferences.isFile, listed: (repo.root.path, listed), near: cwd)
            #expect(local == expected)
            let req = HostReferenceRequest(boardRoot: repo.root.path, board: "board", tile: "tile", cwd: cwd, candidates: candidates([path]))
            #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: expected, pytestBytes: nil)))
        }
    }

    @Test func ambiguousAndMissingReadingsFallThroughInOneHostInvocation() async throws {
        let fixture = try HostFileFixture()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("one/lib.rs", "one")
        try await repo.write("two/lib.rs", "two")
        try await repo.write("chosen.rs", "chosen")
        try await repo.commit("files")
        let runs = fixture.directory.appendingPathComponent("runs")
        let files = try fixture.reader(body: "echo run >> \(RemoteHost.quote(runs.path))\nexec /bin/sh -c \"$command\"")
        let references = HostReferences(files: files, host: try host(fixture))
        let req = HostReferenceRequest(boardRoot: repo.root.path, board: "board", tile: "tile",
                                       candidates: candidates(["missing.rs", "lib.rs", "chosen.rs"]))
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 2, path: repo.url("chosen.rs").path, pytestBytes: nil)))
        #expect(try String(contentsOf: runs, encoding: .utf8) == "run\n")
    }

    @Test func viewportCapturesWrappedAlternativesBeforeHostResolution() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("src/lib.rs", Data("source".utf8))
        let rows = ["wrong/", "src/lib.rs:3"]
        let readings = TerminalReferences.candidates(row: 1, column: 3, columns: 40, read: { rows.indices.contains($0) ? rows[$0] : nil })
        #expect(readings.map { $0.reference.path } == ["wrong/src/lib.rs", "src/lib.rs"])
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        let req = HostReferenceRequest(boardRoot: fixture.root.path, board: "board", tile: "tile", candidates: readings)
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 1, path: fixture.root.appendingPathComponent("src/lib.rs").path, pytestBytes: nil)))
        let hit = TerminalReferences.hit(row: 1, column: 3, columns: 40, read: { rows.indices.contains($0) ? rows[$0] : nil },
                                         resolve: { $0 == "src/lib.rs" ? "/local/src/lib.rs" : nil })
        #expect(hit?.file == "/local/src/lib.rs")
        #expect(hit?.lines == LineRange(start: 3, end: 3))
    }

    @Test func pytestBytesArriveInTheResolutionAndLocateTheExistingDefinition() async throws {
        let fixture = try HostFileFixture()
        let source = "class TestA:\n    def test_b(self):\n        pass\n"
        try fixture.write("test_x.py", Data(source.utf8))
        let references = HostReferences(files: try fixture.reader(), host: try host(fixture))
        var req = request(fixture, ["test_x.py"])
        req.candidates = candidates(["test_x.py"], pytest: ["TestA", "test_b"])
        let result = try await references.resolve(req)
        #expect(result == .resolved(.init(candidate: 0, path: fixture.root.appendingPathComponent("test_x.py").path, pytestBytes: Data(source.utf8))))
        guard case .resolved(let resolved) = result else { return }
        let bytes = try #require(resolved.pytestBytes)
        #expect(PytestNode.line(of: ["TestA", "test_b"], in: String(decoding: bytes, as: UTF8.self)) == 2)
        try fixture.write("test_x.py", Data(repeating: 65, count: SourceExcerpt.maxFileBytes + 1))
        #expect(try await references.resolve(req) == .failure(.tooLarge))
        req.candidates = candidates(["test_x.py"])
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: fixture.root.appendingPathComponent("test_x.py").path, pytestBytes: nil)))
    }

    @MainActor
    @Test func worktreeCounterpartsAreAcceptedButEscapingCounterpartDirectoriesAreNot() async throws {
        let fixture = try HostFileFixture()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("sub/lib.rs", "base")
        try await repo.commit("base")
        let worktree = fixture.directory.appendingPathComponent("worktree")
        try await repo.git("worktree", "add", "-b", "other", worktree.path)
        let files = try fixture.reader()
        let references = HostReferences(files: files, host: try host(fixture))
        let git = HostGit(files: files)
        let file = worktree.appendingPathComponent("sub/lib.rs")
        let req = HostReferenceRequest(boardRoot: repo.url("sub").path, board: "board", tile: "tile", candidates: candidates([file.path]))
        let expected = try canonical(worktree.appendingPathComponent("sub")) + "/lib.rs"
        #expect(try await references.resolve(req) == .resolved(.init(candidate: 0, path: expected, pytestBytes: nil)))
        let code = try await git.code(HostCodeRead(boardRoot: req.boardRoot, path: expected, base: .head, pinned: nil, ref: nil, refSha: nil))
        #expect(code.document.diff.state == .unchanged)
        #expect(code.document.diff.new.text == "base")
        let alias = worktree.appendingPathComponent("sub/alias.rs")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "lib.rs")
        var aliasReq = req
        aliasReq.candidates = candidates([alias.path])
        let expectedAlias = try canonical(worktree.appendingPathComponent("sub")) + "/alias.rs"
        #expect(try await references.resolve(aliasReq) == .resolved(.init(candidate: 0, path: expectedAlias, pytestBytes: nil)))
        let aliasCode = try await git.code(HostCodeRead(boardRoot: req.boardRoot, path: expectedAlias, base: .head, pinned: nil, ref: nil, refSha: nil))
        #expect(aliasCode.document.diff.new.text == "base")
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: worktree.appendingPathComponent("sub"), withDestinationURL: repo.url("sub"))
        #expect(try await references.resolve(req) == .failure(.refused))
        let refusedCode = try await git.code(HostCodeRead(boardRoot: req.boardRoot, path: file.path, base: .head, pinned: nil, ref: nil, refSha: nil))
        #expect(refusedCode.document.diff.state == .unreadable)
        #expect(refusedCode.document.diff.new.text == "")
    }
}
