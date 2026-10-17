import AppKit
import Foundation
import Testing
@testable import CanvasCore

struct HostNotesTests {
    private func request(_ markdown: String, root: URL, source: HostFileRequest.Source? = nil, images: [String] = []) -> HostNoteRequest {
        HostNoteRequest(boardRoot: root.path, source: source ?? .directory(root.path), imagesSource: .directory(root.path),
                        fences: NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(markdown)), images: images)
    }

    @Test func hostTextRelocatesAndRetainsCapturedTextWhenLost() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let request = self.request("```swift path=host.swift lines=2-3\n```", root: fixture.root)
        let key = try #require(request.fences.first?.key)
        try fixture.write("host.swift", Data("before\nfirst\nlast\nafter\n".utf8))
        let first = try await files.note(request)
        #expect(first.excerpts[key]?.lines == ["first", "last"])
        #expect(first.excerpts[key]?.path == "host.swift")
        let captured = [key: ["first", "last"]]
        try fixture.write("host.swift", Data("new\nbefore\nfirst\nlast\nafter\n".utf8))
        let moved = try await files.note(request, captured: captured)
        #expect(moved.excerpts[key]?.range == LineRange(start: 3, end: 4))
        #expect(moved.excerpts[key]?.state == .relocated)
        try fixture.write("host.swift", Data("unrelated\n".utf8))
        let stale = try await files.note(request, captured: captured)
        #expect(stale.excerpts[key]?.state == .stale)
        #expect(stale.excerpts[key]?.lines == ["first", "last"])
        let probe = try await files.note(request, bytes: false)
        #expect(probe.images.isEmpty && probe.excerpts.isEmpty)
        #expect(probe.observation == stale.observation)
    }

    @Test func fenceCommitAlwaysReadsObjectsAndWinsOverNoteRef() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("file.swift", "committed\n")
        try await repo.commit("base")
        try await repo.git("branch", "feature")
        try await repo.write("file.swift", "uncommitted\n")
        let request = self.request("```swift path=file.swift commit=main\n```\n```swift path=file.swift\n```", root: repo.root,
                                  source: .ref("feature", lastKnownSha: nil, boardRoot: repo.root.path))
        let read = try await files.note(request)
        #expect(read.excerpts[request.fences[0].key]?.lines == ["committed"])
        #expect(read.excerpts[request.fences[1].key]?.lines == ["committed"])
        let live = self.request("```swift path=file.swift\n```", root: repo.root,
                           source: .ref("main", lastKnownSha: nil, boardRoot: repo.root.path))
        #expect(try await files.note(live).excerpts[live.fences[0].key]?.lines == ["uncommitted"])
        var unknown = request
        unknown.source = .ref("unknown", lastKnownSha: nil, boardRoot: repo.root.path)
        let failedRef = try await files.note(unknown)
        #expect(failedRef.excerpts[request.fences[0].key]?.lines == ["committed"])
        #expect(failedRef.excerpts[request.fences[1].key]?.isStale == true)
    }

    @Test func pinnedFilesIgnoreLiveSymlinksButRefuseHistoricalSymlinkEntries() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("file.swift", "committed source\n")
        try FileManager.default.createSymbolicLink(at: repo.url("escape.swift"), withDestinationURL: fixture.temp.appendingPathComponent("secret.swift"))
        try await repo.commit("base")
        try FileManager.default.removeItem(at: repo.url("file.swift"))
        try FileManager.default.createSymbolicLink(at: repo.url("file.swift"), withDestinationURL: fixture.temp.appendingPathComponent("secret.swift"))
        try Data("outside source\n".utf8).write(to: fixture.temp.appendingPathComponent("secret.swift"))
        let request = self.request("```swift path=file.swift commit=main\n```\n```swift path=escape.swift commit=main\n```\n```swift path=file.swift commit=absent-ref\n```", root: repo.root)
        let read = try await files.note(request)
        #expect(read.excerpts[request.fences[0].key]?.lines == ["committed source"])
        #expect(read.observation.fences[1] == [.failure(.refused)])
        #expect(read.excerpts[request.fences[2].key]?.state == .missing)
    }

    @Test(arguments: [true, false])
    func pinnedSymbolDiscoveryIgnoresLiveDeclarations(ownCommit: Bool) async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let declaration = ["func hello() {", "    print(1)", "}"]
        try await repo.write("nested/file.swift", declaration.joined(separator: "\n") + "\n")
        try await repo.commit("source")
        try await repo.git("branch", "snapshot")
        let root = repo.url("nested")
        let request = self.request("```swift symbol=hello\(ownCommit ? " commit=snapshot" : "")\n```", root: root,
                                  source: ownCommit ? .directory(root.path) : .ref("snapshot", lastKnownSha: nil, boardRoot: root.path))
        let key = request.fences[0].key
        let before = try await files.note(request)
        #expect(before.excerpts[key]?.path == "file.swift")
        #expect(before.excerpts[key]?.lines == declaration)
        try await repo.write("nested/file.swift", "let removed = true\n")
        try await repo.write("nested/other.swift", "func hello() {\n    print(2)\n}\n")
        let after = try await files.note(request)
        #expect(after.excerpts[key]?.path == "file.swift")
        #expect(after.excerpts[key]?.lines == declaration)
        #expect(after.observation == before.observation)
        #expect(try await files.note(request, bytes: false).observation == before.observation)
    }

    @Test func symbolDiscoveryTracksMissingAddedMovedAndEditedDeclarations() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("nested/first.swift", "let absent = 1\n")
        try await repo.write("nested/second.swift", "let other = 2\n")
        try await repo.commit("base")
        let request = self.request("```swift symbol=hello\n```", root: repo.root)
        let key = request.fences[0].key
        let missing = try await files.note(request)
        #expect(missing.excerpts[key]?.range == nil)
        try await repo.write("nested/first.swift", "func hello() {\n    print(1)\n}\n")
        let added = try await files.note(request)
        #expect(added.excerpts[key]?.lines == ["func hello() {", "    print(1)", "}"])
        #expect(added.observation != missing.observation)
        try await repo.write("nested/first.swift", "let absent = 1\n")
        try await repo.write("nested/second.swift", "func hello() {\n    print(2)\n}\n")
        let moved = try await files.note(request)
        #expect(moved.excerpts[key]?.path == "nested/second.swift")
        #expect(moved.excerpts[key]?.lines == ["func hello() {", "    print(2)", "}"])
        #expect(moved.observation != added.observation)
        #expect(try await files.note(request, bytes: false).observation == moved.observation)
    }

    @Test func outsideMissingAndSymlinkPathsAreRefusedAndFailuresRecover() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let outside = fixture.directory.appendingPathComponent("absent.swift").path
        let request = self.request("```swift path=\(outside)\n```\n```swift path=escape/missing.swift\n```\n```swift path=missing.swift\n```", root: fixture.root)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("escape"), withDestinationURL: fixture.temp)
        let read = try await files.note(request)
        #expect(read.observation.fences == [[.failure(.refused)], [.failure(.refused)], [.failure(.notFound(commit: nil))]])
        #expect(read.excerpts[request.fences[2].key]?.state == .missing)
        #expect(try await files.note(request, bytes: false).observation == read.observation)
        try fixture.write("missing.swift", Data("recovered\n".utf8))
        let recovered = try await files.note(request)
        #expect(recovered.excerpts[request.fences[2].key]?.lines == ["recovered"])
        #expect(recovered.observation != read.observation)
    }

    @Test func noteRootsCannotAuthorizeOutsideDirectoriesOrSymlinkTargets() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try Data("outside source\n".utf8).write(to: fixture.temp.appendingPathComponent("secret.swift"))
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.temp)
        for source in [HostFileRequest.Source.directory(fixture.temp.path), .directory(alias.path)] {
            let request = self.request("```swift path=secret.swift\n```", root: fixture.root, source: source)
            let result = try await files.note(request)
            #expect(result.observation.fences == [[.failure(.refused)]])
            #expect(result.excerpts[request.fences[0].key]?.lines == [])
        }
    }

    @Test func proposalUsesTheSameInterpreterAndInvalidCommitsStayErrors() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try fixture.write("file.swift", Data("new\n".utf8))
        let request = self.request("```swift path=file.swift lines=1 propose\nnew\n```\n```swift path=file.swift commit=--help\n```", root: fixture.root)
        let result = try await files.note(request)
        #expect(result.excerpts[request.fences[0].key]?.state == .applied)
        #expect(result.excerpts[request.fences[1].key]?.isStale == true)
        #expect(result.excerpts[request.fences[1].key]?.lines == [])
        #expect(try await files.note(request, bytes: false).observation == result.observation)
    }

    @Test func authoredCaptionsAndHostObservationsPreserveSymlinkSpellings() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try fixture.write("nested/file.swift", Data("source\n".utf8))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias.swift").path,
                                                 withDestinationPath: "nested/file.swift")
        let root = fixture.directory.appendingPathComponent("board-alias")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: fixture.root)
        let request = self.request("```swift path=./alias.swift\n```", root: root)
        let read = try await files.note(request)
        #expect(read.excerpts[request.fences[0].key]?.path == "./alias.swift")
        #expect(read.excerpts[request.fences[0].key]?.lines == ["source"])
        guard case .version(let version) = read.observation.fences[0][0] else {
            Issue.record("expected an authorized host file")
            return
        }
        #expect(version.path == root.appendingPathComponent("alias.swift").path)
        #expect(try await files.note(request, bytes: false).observation == read.observation)
    }

    @Test func encodedImageDestinationsLoadAndDecodedUnsafePathsAreRefused() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let data = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"42\" height=\"24\"/>".utf8)
        try fixture.write("image space.svg", data)
        try fixture.write("not-image.txt", data)
        try fixture.write("oversized.svg", Data(repeating: 0, count: (4 << 20) + 1))
        let url = fixture.root.appendingPathComponent("image space.svg").absoluteString
        var qualified = try #require(URLComponents(string: url))
        qualified.host = "fixture"
        let hostURL = try #require(qualified.string)
        let outside = fixture.directory.appendingPathComponent("outside.svg")
        try data.write(to: outside)
        let sources = ["image%20space.svg", url, hostURL, "image%00space.svg", "%2e%2e/outside.svg", "not-image.txt", "oversized.svg"]
        let request = self.request("", root: fixture.root, images: sources)
        let read = try await files.note(request)
        #expect(read.images == ["image%20space.svg": data, url: data, hostURL: data])
        #expect(Array(read.observation.images.suffix(4)) == [.failure(.refused), .failure(.refused), .failure(.refused), .failure(.tooLarge(limit: 4 << 20))])
        #expect(try await files.note(request, bytes: false).observation == read.observation)
        try fixture.write("oversized.svg", data)
        let recovered = try await files.note(request)
        #expect(recovered.images["oversized.svg"] == data)
        #expect(recovered.observation != read.observation)
        #expect(try await files.note(request, bytes: false).observation == recovered.observation)
    }

    @Test(arguments: [false, true])
    func aggregateBodyBudgetHasStableProbesAndRecoversForLiveAndPinnedSymbols(pinned: Bool) async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let padding = "padding\n" + String(repeating: " ", count: (4 << 20) - 8)
        for index in 0..<8 { try await repo.write("file\(index).swift", padding) }
        try await repo.write("symbol.swift", "func hello() {\n    print(1)\n}\n")
        try await repo.commit("base")
        let commit = pinned ? " commit=main" : ""
        let markdown = (0..<8).map { "```swift path=file\($0).swift lines=1\(commit)\n```" }.joined(separator: "\n")
            + "\n```swift symbol=hello\(commit)\n```"
        let request = self.request(markdown, root: repo.root)
        let symbolKey = request.fences[8].key
        let capture = [symbolKey: ["captured symbol"]]
        let full = try await files.note(request, captured: capture)
        #expect(full.excerpts[request.fences[0].key]?.lines == ["padding"])
        #expect(full.excerpts[symbolKey]?.lines == ["captured symbol"])
        #expect(full.excerpts[symbolKey]?.isStale == true)
        #expect(full.observation.fences[8] == [.failure(.tooLarge(limit: 0))])
        #expect(try await files.note(request, bytes: false).observation == full.observation)
        try await repo.write("file0.swift", "padding\n")
        if pinned { try await repo.commit("shrink") }
        let recovered = try await files.note(request)
        #expect(recovered.excerpts[symbolKey]?.path == "symbol.swift")
        #expect(recovered.excerpts[symbolKey]?.lines == ["func hello() {", "    print(1)", "}"])
        #expect(recovered.observation != full.observation)
        #expect(try await files.note(request, bytes: false).observation == recovered.observation)
    }

    @MainActor
    @Test func imagesLoadAndReplaceFromHostBytesWithoutLocalFiles() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"42\" height=\"24\"></svg>"
        try fixture.write("chart.svg", Data(svg.utf8))
        let request = self.request("", root: fixture.root, images: ["chart.svg", fixture.temp.appendingPathComponent("temp.svg").path])
        try Data(svg.utf8).write(to: fixture.temp.appendingPathComponent("temp.svg"))
        let first = try await files.note(request)
        #expect(first.images["chart.svg"] == Data(svg.utf8))
        #expect(first.images[fixture.temp.appendingPathComponent("temp.svg").path] == Data(svg.utf8))
        #expect(await NoteImages.decode(first.images)["chart.svg"]?.size == CGSize(width: 42, height: 24))
        try fixture.write("chart.svg", Data(svg.replacingOccurrences(of: "42", with: "84").utf8))
        let replacement = try await files.note(request)
        #expect(await NoteImages.decode(replacement.images)["chart.svg"]?.size == CGSize(width: 84, height: 24))
        #expect(first.observation != replacement.observation)
        #expect(try await files.note(request, bytes: false).observation == replacement.observation)
    }

    @Test func refTransitionsRemainObservedAfterWorktreeRemovalAndBranchDeletion() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("file.swift", "base\n")
        try await repo.commit("base")
        let worktree = fixture.directory.appendingPathComponent("feature")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try "feature\n".write(to: worktree.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)
        try await TempRepo.run(["commit", "-a", "-q", "-m", "feature"], in: worktree)
        let sha = try await TempRepo.run(["rev-parse", "HEAD"], in: worktree)
        try "dirty\n".write(to: worktree.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)
        let request = self.request("```swift path=file.swift\n```", root: repo.root,
                                  source: .ref("feature", lastKnownSha: sha, boardRoot: repo.root.path))
        let key = request.fences[0].key
        let live = try await files.note(request)
        #expect(live.excerpts[key]?.lines == ["dirty"])
        let absolute = self.request("```swift path=\(repo.url("file.swift").path)\n```", root: repo.root,
                                    source: request.source)
        #expect(try await files.note(absolute).excerpts[absolute.fences[0].key]?.lines == ["dirty"])
        try await repo.git("worktree", "remove", "--force", worktree.path)
        let objects = try await files.note(request)
        #expect(objects.excerpts[key]?.lines == ["feature"])
        #expect(objects.observation != live.observation)
        try await repo.git("branch", "-D", "feature")
        let fallback = try await files.note(request)
        #expect(fallback.excerpts[key]?.lines == ["feature"])
        try await repo.write("file.swift", "different\n")
        try await repo.commit("different")
        #expect(try await files.note(request, bytes: false).observation == fallback.observation)
    }

    @MainActor
    @Test func watchUsesReadBaselineAndRecoversFromOversizeWithoutASecondEdit() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try fixture.write("large.swift", Data())
        let handle = try FileHandle(forWritingTo: fixture.root.appendingPathComponent("large.swift"))
        try handle.truncate(atOffset: UInt64(SourceExcerpt.maxFileBytes + 1))
        try handle.close()
        let request = self.request("```swift path=large.swift\n```", root: fixture.root)
        let first = try await files.note(request)
        #expect(first.observation.fences == [[.failure(.tooLarge(limit: SourceExcerpt.maxFileBytes))]])
        #expect(try await files.note(request, bytes: false).observation == first.observation)
        try fixture.write("large.swift", Data("recovered\n".utf8))
        var changes: [HostNoteObservation] = []
        let watch = HostFileWatch(baseline: first.observation, interval: .milliseconds(20), probe: {
            await files.loadNote(request, bytes: false).observation
        }, changed: { changes.append($0) })
        defer { watch.cancel() }
        let deadline = ContinuousClock.now + .seconds(20)
        while changes.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let recovered = try await files.note(request)
        #expect(recovered.excerpts[request.fences[0].key]?.lines == ["recovered"])
        #expect(changes == [recovered.observation])
        watch.cancel()
        try fixture.write("large.swift", Data("after cancel\n".utf8))
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes == [recovered.observation])
    }
}
