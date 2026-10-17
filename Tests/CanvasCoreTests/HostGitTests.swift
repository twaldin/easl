import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct HostGitTests {
    private func cachedHeaders(_ repo: TempRepo, _ path: String) async throws -> [String] {
        let output = try await TempRepo.run(["diff", "--no-color", "-U3", "--cached", "--", path], in: repo.root)
        return output.split(separator: "\n").filter { $0.hasPrefix("@@") }.map { $0.components(separatedBy: " @@")[0] + " @@" }
    }

    private func read(_ url: URL) async -> String? {
        await offPool { try? String(contentsOf: url, encoding: .utf8) }
    }

    private func reader(_ fixture: HostFileFixture, limit: String, of value: Int) throws -> HostFiles {
        try fixture.reader(body: "sed 's/\"\(limit)\":[0-9]*/\"\(limit)\":\(value)/' | /bin/sh -c \"$command\"")
    }

    private func reader(_ fixture: HostFileFixture, running injection: String) throws -> HostFiles {
        try fixture.reader(body: """
        eval "set -- $command"
        exec "$1" "$2" "$3" "$4" \(RemoteHost.quote(injection + "\n"))"$5" "$6"
        """)
    }

    @Test func aCodeTileReadsItsFileOnTheHostAsALocalTileDoes() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("src/app.swift", numbered(1...12))
        try await repo.commit("base")
        try await repo.write("src/app.swift", numbered(1...12).replacingOccurrences(of: "line 4\n", with: "line four\n") + "line 13\n")

        let load = try await git.code(HostCodeRead(boardRoot: repo.root.path, path: "src/app.swift", base: .head, pinned: nil, ref: nil, refSha: nil))
        let local = await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("src/app.swift"), base: .head)
        let diff = load.document.diff
        #expect(diff.state == .modified && local.state == .modified)
        #expect(diff.base == local.base && diff.baseLabel == local.baseLabel && diff.mappings == local.mappings)
        #expect(diff.old.text == local.old.text && diff.new.text == local.new.text)
        #expect(load.document.signs == CodeDocument(path: "src/app.swift", diff: local).signs)
        #expect(load.defaultBranch == "main")
        #expect(load.probe != nil && load.baseline != nil, "a live tile polls what it read")
    }

    @Test func aTwentyFileListingIsOneHostProcessAndListsWhatALocalTileLists() async throws {
        let fixture = try HostFileFixture()
        let runs = fixture.directory.appendingPathComponent("runs")
        let git = HostGit(files: try fixture.reader(body: "echo run >> \(RemoteHost.quote(runs.path))\nexec /bin/sh -c \"$command\""))
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        for index in 0..<20 { try await repo.write("src/f\(index).txt", numbered(1...10)) }
        try await repo.commit("base")
        for index in 0..<20 {
            try await repo.write("src/f\(index).txt", numbered(1...10).replacingOccurrences(of: "line \(index % 10 + 1)\n", with: "changed \(index)\n"))
        }
        try await repo.write("src/new.txt", "fresh\n")
        try await repo.git("add", "src/f3.txt")
        let spec = ChangesSpec(.object([:]))

        let load = try await git.changes(boardRoot: repo.root.path, spec: spec, highlight: false)
        #expect(await read(runs) == "run\n", "one host process for the whole listing")
        let local = await ChangeSet.load(root: repo.root, spec: spec, highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let set = load.set
        #expect(set.repository == nil && set.notice == nil && set.files.count == 21)
        #expect(set.base == local.base && set.baseLabel == local.baseLabel && set.head == local.head && set.branch == local.branch)
        #expect(set.files.map(\.path) == local.files.map(\.path))
        #expect(set.files.map(\.boardPath) == local.files.map(\.boardPath))
        #expect(set.files.map(\.status) == local.files.map(\.status))
        #expect(set.files.map(\.tracked) == local.files.map(\.tracked))
        #expect(set.files.map { $0.hunks.map(\.header) } == local.files.map { $0.hunks.map(\.header) })
        #expect(set.files.map { $0.hunks.map(\.status) } == local.files.map { $0.hunks.map(\.status) })
        #expect(set.files.map { $0.new.text } == local.files.map { $0.new.text })
        #expect(Set(load.sides.keys) == Set(local.files.map(\.path)), "every file can be staged from this listing")
        #expect(load.checkout != nil && load.probe != nil)
    }

    @Test func aLiveTilesPollSeesEditsNewFilesAndCommits() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("a.txt", "one\n")
        try await repo.commit("base")
        try await repo.write("a.txt", "two\n")
        let root = repo.root.path

        let code = try await git.code(HostCodeRead(boardRoot: root, path: "a.txt", base: .head, pinned: nil, ref: nil, refSha: nil))
        let listing = try await git.changes(boardRoot: root, spec: ChangesSpec(.object([:])), highlight: false)
        let codeProbe = try #require(code.probe), listProbe = try #require(listing.probe)
        #expect(await git.stamp(codeProbe) == code.baseline)
        #expect(await git.stamp(listProbe) == listing.baseline)

        try await repo.write("a.txt", "three, still modified\n")
        let edited = await git.stamp(listProbe)
        #expect(await git.stamp(codeProbe) != code.baseline)
        #expect(edited != listing.baseline, "a listed file's bytes changed though its git status did not")

        try await repo.write("b.txt", "new\n")
        let added = await git.stamp(listProbe)
        #expect(added != edited, "a new untracked file")

        let before = await git.stamp(codeProbe)
        try await repo.commit("all")
        #expect(await git.stamp(codeProbe) != before, "a commit moves HEAD")
        #expect(await git.stamp(listProbe) != added)
    }

    @Test func stageAndDiscardApplyOnTheHostOnlyWhileTheSidesAreUnchanged() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("app.txt", numbered(1...30))
        try await repo.write("other.txt", numbered(1...5))
        try await repo.commit("base")
        var lines = (1...30).map { "line \($0)" }
        lines[2] = "line 3 changed"
        lines.insert("inserted after 20", at: 20)
        try await repo.write("app.txt", lines.joined(separator: "\n") + "\n")
        try await repo.write("other.txt", numbered(1...6))
        let root = repo.root.path
        func listing() async throws -> HostChangesLoad { try await git.changes(boardRoot: root, spec: ChangesSpec(.object([:])), highlight: false) }

        let first = try await listing()
        let app = try #require(first.set.files.first { $0.path == "app.txt" })
        let sides = try #require(first.sides["app.txt"]), top = try #require(first.checkout)
        let stage = try await ReviewPatch.stage([app.hunks[1]], of: app, sides: sides, onHost: top)
        try await git.apply(stage, to: app, sides: sides, boardRoot: root)
        #expect(try await cachedHeaders(repo, "app.txt") == [app.hunks[1].header])

        let second = try await listing()
        let again = try #require(second.set.files.first { $0.path == "app.txt" })
        let againSides = try #require(second.sides["app.txt"])
        let stale = try await ReviewPatch.stage([again.hunks[0]], of: again, sides: againSides, onHost: top)
        try await repo.write("app.txt", lines.joined(separator: "\n") + "\nappended\n")
        await #expect(throws: ChangesFailure.self) {
            try await git.apply(stale, to: again, sides: againSides, boardRoot: root)
        }
        #expect(try await cachedHeaders(repo, "app.txt") == [app.hunks[1].header])
        #expect(await read(repo.url("app.txt")) == lines.joined(separator: "\n") + "\nappended\n")

        let third = try await listing()
        let other = try #require(third.set.files.first { $0.path == "other.txt" })
        let otherSides = try #require(third.sides["other.txt"])
        let discard = try await ReviewPatch.discardUncommitted(nil, of: other, sides: otherSides, onHost: top)
        try await git.apply(discard, to: other, sides: otherSides, boardRoot: root)
        #expect(await read(repo.url("other.txt")) == numbered(1...5))
    }

    @Test func theHostReadsNothingOutsideTheBoard() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("pkg/app.txt", "board\n")
        try await repo.write("outside.txt", "repository, not board\n")
        try await repo.commit("base")
        let secret = fixture.directory.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try "TOPSECRET\n".write(to: secret.appendingPathComponent("key"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: repo.url("pkg/escape.txt").path, withDestinationPath: secret.appendingPathComponent("key").path)
        let alias = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: repo.url("pkg").path)
        let root = repo.url("pkg").path

        for path in ["../outside.txt", repo.url("outside.txt").path, "escape.txt", alias.appendingPathComponent("app.txt").path, secret.appendingPathComponent("key").path] {
            let load = try await git.code(HostCodeRead(boardRoot: root, path: path, base: .head, pinned: nil, ref: nil, refSha: nil))
            #expect(load.document.diff.state == .unreadable, "\(path)")
            #expect(load.document.diff.old.text.isEmpty && load.document.diff.new.text.isEmpty)
        }
        let listing = try await git.changes(boardRoot: root, spec: ChangesSpec(.object([:])), highlight: false)
        let escape = try #require(listing.set.files.first { $0.path == "pkg/escape.txt" })
        #expect(escape.notice != nil && escape.hunks.isEmpty && escape.old.text.isEmpty && escape.new.text.isEmpty)
        #expect(listing.sides["pkg/escape.txt"] == nil)
        let otherRoot = try await git.changes(boardRoot: root, spec: ChangesSpec(.object(["root": .string(secret.path)])), highlight: false)
        #expect(otherRoot.set.notice != nil && otherRoot.set.files.isEmpty && otherRoot.checkout == nil && otherRoot.sides.isEmpty)
        let outsidePath = try await git.changes(boardRoot: root, spec: ChangesSpec(.object(["paths": ["../outside.txt"]])), highlight: false)
        #expect(outsidePath.set.notice != nil && outsidePath.set.files.isEmpty && outsidePath.checkout == nil && outsidePath.sides.isEmpty)
    }

    @Test func aRefReadsWhereItsBranchIsCheckedOutElseFromItsCommit() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("pkg/file.txt", "base\n")
        try await repo.commit("base")
        let worktree = fixture.directory.appendingPathComponent("feature")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try "committed\n".write(to: worktree.appendingPathComponent("pkg/file.txt"), atomically: true, encoding: .utf8)
        try await TempRepo.run(["commit", "-q", "-a", "-m", "feature"], in: worktree)
        let tip = try await TempRepo.run(["rev-parse", "HEAD"], in: worktree)
        try "live\n".write(to: worktree.appendingPathComponent("pkg/file.txt"), atomically: true, encoding: .utf8)
        let root = repo.url("pkg").path
        func code(_ ref: String) async throws -> HostCodeLoad {
            try await git.code(HostCodeRead(boardRoot: root, path: "file.txt", base: .mergeBase, pinned: nil, ref: ref, refSha: nil))
        }

        let live = try await code("feature")
        #expect(live.document.diff.new.text == "live\n" && live.refSha == tip && live.probe != nil)

        try await repo.git("worktree", "remove", "--force", worktree.path)
        let objects = try await code("feature")
        #expect(objects.document.diff.state == .pinned && objects.document.diff.new.text == "committed\n" && objects.refSha == tip)

        let unknown = try await code("nope")
        #expect(unknown.document.diff.state == .pinUnavailable && unknown.document.diff.new.text.isEmpty)

        let spec = ChangesSpec(.object(["ref": "feature"]))
        let changes = try await git.changes(boardRoot: root, spec: spec, highlight: false)
        let local = await ChangeSet.load(root: repo.url("pkg"), spec: spec, highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        #expect(changes.set.notice == nil && changes.set.commits == local.commits && changes.set.refSha == local.refSha)
        #expect(changes.set.files.map(\.path) == local.files.map(\.path) && changes.set.files.map { $0.hunks.map(\.header) } == local.files.map { $0.hunks.map(\.header) })
        #expect(changes.checkout == nil && changes.sides.isEmpty, "commits compared: nothing to stage")
    }

    @Test func aPinnedTileReadsThePathAsWrittenAtItsCommit() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("real.txt", "committed\n")
        let sha = try await repo.commit("base")
        try await repo.write("real.txt", "live\n")
        try FileManager.default.createSymbolicLink(atPath: repo.url("alias.txt").path, withDestinationPath: "real.txt")
        func pinned(_ path: String, _ revision: String) async throws -> HostCodeLoad {
            try await git.code(HostCodeRead(boardRoot: repo.root.path, path: path, base: .head, pinned: revision, ref: nil, refSha: nil))
        }

        let load = try await pinned("real.txt", sha)
        #expect(load.document.diff.state == .pinned && load.document.diff.new.text == "committed\n")
        #expect(load.probe == nil, "a pinned commit never changes")
        let alias = try await pinned("alias.txt", sha)
        #expect(alias.document.diff.state == .pinUnavailable && alias.document.diff.new.text.isEmpty)
        let invalid = try await pinned("real.txt", "--output=x")
        #expect(invalid.document.diff.state == .pinUnavailable && invalid.document.diff.new.text.isEmpty)
    }

    @Test func anUnreachableHostIsUnavailableNeverAnEmptyListing() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader(body: "echo 'ssh: connect to host fixture: Connection refused' >&2\nexit 255"))
        let refused = HostFileError.unavailable("ssh: connect to host fixture: Connection refused")
        await #expect(throws: refused) { try await git.changes(boardRoot: "/nowhere", spec: ChangesSpec(.object([:])), highlight: false) }
        await #expect(throws: refused) {
            try await git.code(HostCodeRead(boardRoot: "/nowhere", path: "a.txt", base: .head, pinned: nil, ref: nil, refSha: nil))
        }
        #expect(await git.stamp(HostGitProbe(boardRoot: "/nowhere", spec: .object(["dir": "/nowhere"]))) == .failure(refused))
    }

    @Test func aWorktreeWhoseBoardFolderLinksOutsideShowsNothingFromThere() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo(), outside = try await TempRepo()
        defer {
            try? FileManager.default.removeItem(at: repo.root)
            try? FileManager.default.removeItem(at: outside.root)
        }
        try await repo.write("pkg/file.txt", "board\n")
        try await repo.commit("base")
        try await outside.write("file.txt", "outside\n")
        let outsideSha = try await outside.commit("outside")
        try await outside.write("file.txt", "TOPSECRET\n")
        let worktree = fixture.directory.appendingPathComponent("feature")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        let link = worktree.appendingPathComponent("pkg")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.root.path)
        let root = repo.url("pkg").path, linked = link.appendingPathComponent("file.txt").path

        for read in [HostCodeRead(boardRoot: root, path: "file.txt", base: .head, pinned: nil, ref: "feature", refSha: nil),
                     HostCodeRead(boardRoot: root, path: linked, base: .head, pinned: nil, ref: nil, refSha: nil),
                     HostCodeRead(boardRoot: root, path: linked, base: .head, pinned: outsideSha, ref: nil, refSha: nil)] {
            let diff = try await git.code(read).document.diff
            #expect(diff.state == .unreadable, "\(read)")
            #expect(diff.old.text.isEmpty && diff.new.text.isEmpty, "\(read)")
        }
        let listing = try await git.changes(boardRoot: root, spec: ChangesSpec(.object(["ref": "feature"])), highlight: false)
        #expect(listing.set.notice != nil && listing.set.files.isEmpty && listing.checkout == nil && listing.sides.isEmpty)
        let board = try await git.code(HostCodeRead(boardRoot: root, path: "file.txt", base: .head, pinned: nil, ref: nil, refSha: nil))
        #expect(board.document.diff.new.text == "board\n")
    }

    @Test func aRefThatMovesWhileItsListingIsReadReloadsOnTheFirstPoll() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("a.txt", "base\n")
        let base = try await repo.commit("base")
        try await repo.write("a.txt", "first\n")
        let first = try await repo.commit("first")
        try await repo.write("b.txt", "second\n")
        let second = try await repo.commit("second")
        try await repo.git("branch", "feature", first)
        try await repo.git("reset", "-q", "--hard", base)
        let constants = String(decoding: try JSONEncoder().encode([repo.root.path, second]), as: UTF8.self)
        let racing = HostGit(files: try reader(fixture, running: """
        (() => {
          const cp = require('node:child_process');
          const [root, second] = \(constants);
          const execFileSync = cp.execFileSync;
          let moved = false;
          cp.execFileSync = (file, args, options) => {
            const out = execFileSync(file, args, options);
            if (!moved && args.at(-1) === 'feature^{commit}') {
              moved = true;
              execFileSync('git', ['-C', root, 'update-ref', 'refs/heads/feature', second]);
            }
            return out;
          };
        })();
        """))
        let spec = ChangesSpec(.object(["ref": "feature"]))

        let raced = try await racing.changes(boardRoot: repo.root.path, spec: spec, highlight: false)
        #expect(raced.set.refSha == first && raced.set.files.map(\.path) == ["a.txt"])
        let probe = try #require(raced.probe)
        #expect(await git.stamp(probe) != raced.baseline, "the first poll reloads a listing read before its ref moved")
        let reloaded = try await git.changes(boardRoot: repo.root.path, spec: spec, highlight: false)
        #expect(reloaded.set.refSha == second && reloaded.set.files.map(\.path) == ["a.txt", "b.txt"])
        let settled = try #require(reloaded.probe)
        #expect(await git.stamp(settled) == reloaded.baseline)
    }

    @Test func aListingTooLargeForOneReplyStillPollsAndLoadsOnceItShrinks() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try reader(fixture, limit: "reply", of: 4096))
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("big.txt", "small\n")
        try await repo.commit("base")
        try await repo.write("big.txt", String(repeating: "grown line\n", count: 400))
        let root = repo.root.path, spec = ChangesSpec(.object([:]))

        let oversized = try await git.changes(boardRoot: root, spec: spec, highlight: false)
        #expect(oversized.set.notice != nil && oversized.set.files.isEmpty)
        let probe = try #require(oversized.probe, "a listing too large to send still polls")
        #expect(await git.stamp(probe) == oversized.baseline)
        try await repo.write("big.txt", "small, edited\n")
        #expect(await git.stamp(probe) != oversized.baseline, "shrinking the change reloads the tile")
        let shrunk = try await git.changes(boardRoot: root, spec: spec, highlight: false)
        #expect(shrunk.set.notice == nil && shrunk.set.files.map { $0.new.text } == ["small, edited\n"])
    }

    @Test func aNewFileMadeExecutableSinceTheListingIsNotStaged() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("a.txt", "base\n")
        try await repo.commit("base")
        try await repo.write("script.sh", "echo hi\n")
        let root = repo.root.path
        func stage() async throws -> (ReviewPatch, ChangedFile, ReviewSides) {
            let listing = try await git.changes(boardRoot: root, spec: ChangesSpec(.object([:])), highlight: false)
            let file = try #require(listing.set.files.first { $0.path == "script.sh" })
            let sides = try #require(listing.sides["script.sh"]), top = try #require(listing.checkout)
            let patch = try await ReviewPatch.stage(nil, of: file, sides: sides, onHost: top)
            return (patch, file, sides)
        }

        let (stale, file, sides) = try await stage()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.url("script.sh").path)
        await #expect(throws: ChangesFailure.self) {
            try await git.apply(stale, to: file, sides: sides, boardRoot: root)
        }
        #expect(try await repo.git("ls-files", "--stage", "--", "script.sh") == "")

        let (fresh, freshFile, freshSides) = try await stage()
        try await git.apply(fresh, to: freshFile, sides: freshSides, boardRoot: root)
        #expect(try await repo.git("ls-files", "--stage", "--", "script.sh").hasPrefix("100755 "))
    }

    @Test func filesPastTheListingsByteBudgetAreTooLargeNotChanging() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try reader(fixture, limit: "total", of: 20))
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        for name in ["a.txt", "b.txt", "c.txt"] { try await repo.write(name, "one\n") }
        try await repo.commit("base")
        for name in ["a.txt", "b.txt", "c.txt"] { try await repo.write(name, "changed\n") }

        let load = try await git.changes(boardRoot: repo.root.path, spec: ChangesSpec(.object([:])), highlight: false)
        #expect(load.set.files.map(\.path) == ["a.txt", "b.txt", "c.txt"])
        #expect(load.set.files[0].notice == nil && load.set.files[1].notice == nil && load.set.files[2].notice != nil)
        #expect(load.set.files[2].hunks.isEmpty && load.sides["c.txt"] == nil)
        #expect(load.set.files.map { $0.new.text } == ["changed\n", "changed\n", ""])
    }

    @Test func anEditWhileTheListingIsReadShowsTheEditedFile() async throws {
        let fixture = try HostFileFixture()
        let git = HostGit(files: try fixture.reader())
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("a.txt", "base\n")
        try await repo.commit("base")
        try await repo.write("a.txt", "before\n")
        let constants = String(decoding: try JSONEncoder().encode([repo.url("a.txt").path]), as: UTF8.self)
        let editing = HostGit(files: try reader(fixture, running: """
        (() => {
          const cp = require('node:child_process');
          const fs = require('node:fs');
          const [file] = \(constants);
          const spawnSync = cp.spawnSync;
          let edited = false;
          cp.spawnSync = (command, args, options) => {
            const result = spawnSync(command, args, options);
            if (!edited && command === 'python3' && JSON.parse(options.input).budget != null) {
              edited = true;
              fs.writeFileSync(file, 'edited while listed\\n');
            }
            return result;
          };
        })();
        """))

        let load = try await editing.changes(boardRoot: repo.root.path, spec: ChangesSpec(.object([:])), highlight: false)
        #expect(load.set.files.map { $0.new.text } == ["edited while listed\n"])
        let probe = try #require(load.probe)
        #expect(await git.stamp(probe) == load.baseline)
    }
}
