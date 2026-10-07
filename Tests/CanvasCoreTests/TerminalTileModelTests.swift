import Foundation
import Testing
import CanvasCore

struct TerminalReferencesTests {
    func refs(_ text: String) -> [String] {
        TerminalReferences.find(in: text).map { reference in reference.lines.map { "\(reference.path) \($0.start)-\($0.end)" } ?? reference.path }
    }

    @Test func findsTheFormsAgentsAndToolsWrite() {
        #expect(refs("see `src/foo.ts:42` and src/bar.ts:42:7.") == ["src/foo.ts 42-42", "src/bar.ts 42-42"])
        #expect(refs("supervisor.ts:486, lib/x.py:10-20") == ["supervisor.ts 486-486", "lib/x.py 10-20"])
        #expect(refs("foo.rs#L10-20 and bar.rs#L3-L5 and baz.go#L7") == ["foo.rs 10-20", "bar.rs 3-5", "baz.go 7-7"])
        #expect(refs("/Users/me/app/main.swift:3 ~/x.py:9 ../up/a.c:1") == ["/Users/me/app/main.swift 3-3", "~/x.py 9-9", "../up/a.c 1-1"])
        #expect(refs("bin/easl:12") == ["bin/easl 12-12"], "a path with a slash needs no extension")
    }

    @Test func leavesUrlsTimesAndVersionsAlone() {
        #expect(refs("https://example.com:443/a.js:3 localhost:3000 at 12:30 v1.2:3 Makefile:4").isEmpty)
        #expect(refs("foo.ts:0 foo.ts:12abc").isEmpty)
    }

    @Test func aReversedRangeIsTheStartLine() {
        #expect(refs("a.ts:20-10") == ["a.ts 20-20"])
    }

    @Test func rangesWithAnEnOrEmDash() {
        #expect(refs("see main.go:223–231 and url.go:52—57, foo.rs#L3–L5") == ["main.go 223-231", "url.go 52-57", "foo.rs 3-5"])
    }

    @Test func findsPythonTracebackAndPdbFrames() {
        let traceback = """
        Traceback (most recent call last):
          File "/private/tmp/click/src/click/core.py", line 2651, in check_iter
            return _check_iter(value)
          File "src/my app/run.py", line 7, in <module>
          File "<frozen runpy>", line 88, in _run_code
        click.exceptions.BadParameter: Value must be an iterable.
        """
        #expect(refs(traceback) == ["/private/tmp/click/src/click/core.py 2651-2651", "src/my app/run.py 7-7", "<frozen runpy> 88-88"],
                "a quoted path may hold spaces; resolve turns away what names no file")
        let pdb = """
        (Pdb) where
          /opt/homebrew/lib/python3.13/bdb.py(606)run()
        -> exec(cmd, globals, locals)
          <string>(1)<module>()
        > /private/tmp/click/src/click/parser.py(106)_unpack_args()
        -> rv[spos] = tuple(args)
        """
        #expect(refs(pdb) == ["/opt/homebrew/lib/python3.13/bdb.py 606-606", "/private/tmp/click/src/click/parser.py 106-106"])
        #expect(refs("print(3) ls(1) f(x.py) tuple(args)") == ["x.py"], "a call or a man page section isn't a frame (a source file's name alone is)")
    }

    @Test func aWrappedTracebackOrPdbFrameIsOne() {
        let files: Set<String> = ["/private/tmp/click/src/click/core.py", "/private/tmp/click/src/click/parser.py"]
        let frame = ["  File \"/private/tmp/click/src/click/cor", "e.py\", line 2651, in check_iter"]
        #expect(hit(frame, columns: 40, row: 1, column: 3, files: files) == "/private/tmp/click/src/click/core.py 2651-2651 0:2+38 1:0+16")
        let stop = ["> /private/tmp/click/src/click", "/parser.py(106)_unpack_args()"]
        #expect(hit(stop, columns: 30, row: 0, column: 10, files: files) == "/private/tmp/click/src/click/parser.py 106-106 0:2+28 1:0+29")
    }

    /// A viewport `columns` wide showing `rows`; what ⌘-click at (`row`, `column`) opens among `files`.
    func hit(_ rows: [String], columns: Int, row: Int, column: Int, files: Set<String>) -> String? {
        guard let hit = TerminalReferences.hit(row: row, column: column, columns: columns, read: { rows.indices.contains($0) ? rows[$0] : nil },
                                               resolve: { files.contains($0) ? $0 : nil }) else { return nil }
        return "\(hit.file) \(hit.lines.map { "\($0.start)-\($0.end)" } ?? "(no line)") " + hit.runs.map { "\($0.row):\($0.column)+\($0.width)" }.joined(separator: " ")
    }

    @Test func aReferenceWrappedAtTheTerminalsEdgeIsOne() {
        // 20 columns: "error at src/walk.rs" fills the row, ":123:5" goes on below.
        let rows = ["error at src/walk.rs", ":123:5 here", "next"]
        let files: Set<String> = ["src/walk.rs"]
        #expect(hit(rows, columns: 20, row: 0, column: 12, files: files) == "src/walk.rs 123-123 0:9+11 1:0+6")
        #expect(hit(rows, columns: 20, row: 1, column: 2, files: files) == "src/walk.rs 123-123 0:9+11 1:0+6", "from either half")
        // A whole reference at the end of a shorter row is complete; a full row goes on.
        let split = ["error at src/walk.rs:12", "3 here"]
        #expect(hit(split, columns: 30, row: 0, column: 12, files: files) == "src/walk.rs 12-12 0:9+14")
        #expect(hit(split, columns: 23, row: 0, column: 12, files: files) == "src/walk.rs 123-123 0:9+14 1:0+1")
    }

    @Test func aReferenceATuiBrokeInsideItsMarginsIsJoinedWhenTheJoinResolves() {
        // opencode wraps its reply itself: padding on the left, a scrollbar in the last column.
        let rows = [
            "  depth() at src/dir_entry.     ▐",
            "  rs:16 keeps it; the walk at   ▐",
            "  src/walk.rs:661-              ▐",
            "  668 checks it.                ▐",
        ]
        let files: Set<String> = ["src/dir_entry.rs", "src/walk.rs"]
        #expect(hit(rows, columns: 33, row: 0, column: 16, files: files) == "src/dir_entry.rs 16-16 0:13+14 1:2+5")
        #expect(hit(rows, columns: 33, row: 1, column: 3, files: files) == "src/dir_entry.rs 16-16 0:13+14 1:2+5")
        #expect(hit(rows, columns: 33, row: 3, column: 3, files: files) == "src/walk.rs 661-668 2:2+16 3:2+3", "a range broken after its dash")
        // Joins are only guesses: a row alone wins when the joined text names no file.
        let grep = ["src/a.rs:3:  let x = foo.", "src/b.rs:7:  bar()"]
        #expect(hit(grep, columns: 40, row: 1, column: 2, files: ["src/a.rs", "src/b.rs"]) == "src/b.rs 7-7 1:0+10")
        #expect(hit(["see src/", "main.rs:4 now"], columns: 40, row: 1, column: 2, files: ["src/main.rs", "main.rs"]) == "src/main.rs 4-4 0:4+4 1:0+9")
        #expect(hit(["done: a.rs:1", "0 more"], columns: 40, row: 1, column: 0, files: ["a.rs"]) == nil, "a whole reference at a row's end isn't continued")
    }

    @Test func referenceAtAnOffset() {
        let text = "error in src/foo.ts:42 then lib/b.ts:3"
        #expect(TerminalReferences.reference(in: text, at: 12)?.path == "src/foo.ts")
        #expect(TerminalReferences.reference(in: text, at: 21)?.lines?.start == 42, "the line number is part of it")
        #expect(TerminalReferences.reference(in: text, at: 3) == nil)
    }

    @Test func resolvesAgainstDirectoriesInOrder() {
        let files: Set<String> = ["/cwd/src/a.ts", "/root/src/a.ts", "/root/only.ts", "/home/me/x.py", "/abs/b.swift", "/root/lib/c.rs"]
        func resolve(_ path: String) -> String? {
            TerminalReferences.resolve(path, directories: ["/cwd", "/props", "/root"], home: "/home/me", isFile: files.contains)
        }
        #expect(resolve("src/a.ts") == "/cwd/src/a.ts", "the reported cwd wins")
        #expect(resolve("only.ts") == "/root/only.ts", "then the board root")
        #expect(resolve("~/x.py") == "/home/me/x.py")
        #expect(resolve("/abs/b.swift") == "/abs/b.swift")
        #expect(resolve("b/lib/c.rs") == "/root/lib/c.rs", "a diff's b/ prefix")
        #expect(resolve("missing.ts") == nil)
        #expect(resolve("/abs/missing.swift") == nil)
    }

    /// Agents write `core.py:2535` for `src/click/core.py:2535` before they read the skill.
    @Test func resolvesFileNamesAmongTheRootsFilesNearestTheCwd() {
        let listed = [
            "src/click/core.py", "src/click/parser.py", "tests/test_core.py", "lib/helpers.py", "app/helpers.py",
            "pkg/a/util.py", "pkg/b/util.py", "docs/util.py", "src/click/README.md", "gone.py",
        ]
        let files = Set(listed.filter { $0 != "gone.py" }.map { "/root/" + $0 } + ["/cwd/parser.py"])
        func resolve(_ path: String, cwd: String = "/root") -> String? {
            TerminalReferences.resolve(path, directories: [cwd, "/root"], home: "/home/me", isFile: files.contains,
                                       listed: ("/root", FileIndex(paths: listed)), near: cwd)
        }
        #expect(resolve("core.py") == "/root/src/click/core.py", "a unique name")
        #expect(resolve("click/core.py") == "/root/src/click/core.py", "a trailing part of the path")
        #expect(resolve("./click/core.py") == "/root/src/click/core.py")
        #expect(resolve("lick/core.py") == nil, "whole path components only")
        #expect(resolve("parser.py", cwd: "/cwd") == "/cwd/parser.py", "a directory hit comes before the listing")
        #expect(resolve("gone.py") == nil, "listed but no longer on disk")
        #expect(resolve("helpers.py") == nil, "lib/ and app/ are equally near the root: ambiguous, no underline")
        #expect(resolve("util.py") == "/root/docs/util.py", "one directory down beats two")
        #expect(resolve("util.py", cwd: "/root/pkg/a") == "/root/pkg/a/util.py", "the one in the cwd")
        #expect(resolve("util.py", cwd: "/root/pkg/b/sub") == "/root/pkg/b/util.py", "the nearest one up")
        #expect(resolve("util.py", cwd: "/root/pkg") == nil, "pkg/a and pkg/b tie")
        #expect(resolve("a/util.py") == "/root/pkg/a/util.py", "a longer suffix narrows it")
        #expect(resolve("../core.py") == nil, "never climbs out")
        #expect(TerminalReferences.resolve("core.py", directories: ["/root"], home: "/home/me", isFile: files.contains) == nil, "no listing, no lookup")
    }

    /// A production stack trace names the deploy's paths: `file:///srv/app/server/routes/claims.ts:395:5`.
    @Test func deployPathsResolveByTheirLongestTrailingPartAmongTheRootsFiles() {
        #expect(refs("at async file:///srv/app/server/routes/claims.ts:395:5") == ["/srv/app/server/routes/claims.ts 395-395"], "the file:// URL's path")
        #expect(refs("(file:///srv/app/server/engine/db.ts:49:34)") == ["/srv/app/server/engine/db.ts 49-49"])
        let listed = ["server/routes/claims.ts", "server/engine/db.ts", "web/engine/db.ts", "lib/index.ts", "vendor/lib/index.ts"]
        let files = Set(listed.map { "/root/" + $0 })
        func resolve(_ path: String) -> String? {
            TerminalReferences.resolve(path, directories: ["/root"], home: "/home/me", isFile: files.contains,
                                       listed: ("/root", FileIndex(paths: listed)), near: "/root")
        }
        #expect(resolve("/srv/app/server/routes/claims.ts") == "/root/server/routes/claims.ts")
        #expect(resolve("/srv/app/server/engine/db.ts") == "/root/server/engine/db.ts", "the longest trailing part decides between two db.ts")
        #expect(resolve("/opt/x/engine/db.ts") == nil, "server/ and web/ tie: no guess")
        #expect(resolve("/srv/app/index.ts") == nil, "a name alone is too little to take an absolute path for a repo file")
        #expect(resolve("/rustc/ac68faa2/library/std/src/panicking.rs") == nil, "a toolchain's frame names nothing here, so it isn't a link")
        #expect(hit(["   at /rustc/ac68faa2/library/std/src/panicking.rs:689:5"], columns: 80, row: 0, column: 10,
                    files: []) == nil, "no underline for what can't open")
    }

    /// aider: `Applied edit to url.go`, `Editable: src/url.go`.
    @Test func aSourceFileNamedAloneIsAReferenceWithoutALine() {
        #expect(refs("Applied edit to url.go") == ["url.go"])
        #expect(refs("Editable: src/url.go. Next url.go:12") == ["src/url.go", "url.go 12-12"], "a full stop after it isn't part of it; a line wins")
        #expect(refs("see example.com, v1.2, archive.tar.gz and notes.txt").isEmpty, "only source files' extensions")
        let rows = ["Applied edit to url.go"]
        #expect(hit(rows, columns: 40, row: 0, column: 18, files: ["url.go"]) == "url.go (no line) 0:16+6")
        #expect(hit(rows, columns: 40, row: 0, column: 18, files: []) == nil, "a name no file has stays text")
    }
}

@MainActor
struct TerminalBoardTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    func makeBoard() -> Board {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: "brd_test", root: root)
    }

    @Test func openCodeReaimsTheTerminalsPreviewUntilTheUserKeepsIt() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object([:]))
        let path = root.appendingPathComponent("src/a.ts").path
        struct Opened: Equatable { var id: ObjectID, created: Bool }
        func open(_ start: Int, from tile: ObjectID = terminal.id, newTile: Bool = false) -> Opened {
            let opened = board.openCode(path: path, lines: LineRange(start: start, end: start), beside: tile, newTile: newTile)
            return Opened(id: opened.id, created: opened.created)
        }
        func line(_ id: ObjectID) -> Double? { board.objects[id]?.props["range"]?["start"]?.number }
        let preview = open(42)
        #expect(preview.created)
        #expect(board.objects[preview.id]?.props["path"]?.string == "src/a.ts", "stored board-relative")
        #expect(open(7) == Opened(id: preview.id, created: false), "the next ⌘-click re-aims the same tile")
        #expect(line(preview.id) == 7)
        #expect(open(7) == Opened(id: preview.id, created: false))

        // ⌥⌘-click opens a tile of its own; the preview stays the preview.
        let kept = open(9, newTile: true)
        #expect(kept.created && kept.id != preview.id)
        #expect(open(9) == Opened(id: kept.id, created: false), "a tile already showing that range is selected, not re-aimed")
        #expect(line(preview.id) == 7)
        #expect(open(12) == Opened(id: preview.id, created: false))

        // Another terminal has its own preview.
        let other = board.create(type: .terminal, props: .object([:]))
        let theirs = open(30, from: other.id)
        #expect(theirs.created && theirs.id != preview.id)

        // Scrolled or clicked in (the app's keepCode), or moved: the user keeps it.
        board.keepCode(preview.id)
        let second = open(50)
        #expect(second.created && second.id != preview.id)
        #expect(line(preview.id) == 12)
        let frame = board.objects[second.id]!.frame
        try board.update(second.id, frame: Frame(x: frame.x + 40, y: frame.y, w: frame.w, h: frame.h))
        let third = open(60)
        #expect(third.created && third.id != second.id, "a moved preview is kept")
        #expect(line(second.id) == 50)
        #expect(open(61) == Opened(id: third.id, created: false))
        try board.delete(third.id)
        #expect(open(62).created, "a closed preview is gone")
    }

    @Test func openCodeIgnoresFollowTiles() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object([:]))
        let range: JSONValue = .object(["start": .number(5), "end": .number(5)])
        let follow = board.create(type: .code, props: .object(["path": .string("a.ts"), "range": range, "followOf": .string(terminal.id)]))
        let opened = board.openCode(path: root.appendingPathComponent("a.ts").path, lines: LineRange(start: 5, end: 5), beside: terminal.id)
        #expect(opened.created && opened.id != follow.id, "the follow tile belongs to its agent")
    }

    @Test func terminalNoticesCoalesce() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object([:]))
        var events = 0
        board.onEvent = { if case .attentionChanged = $0 { events += 1 } }
        #expect(board.raiseTerminalNotice(terminal.id, message: "Bell", bell: true))
        #expect(!board.raiseTerminalNotice(terminal.id, message: "Bell", bell: true), "a second bell changes nothing")
        #expect(board.raiseTerminalNotice(terminal.id, message: "Claude: Needs permission", bell: false))
        #expect(!board.raiseTerminalNotice(terminal.id, message: "Bell", bell: true), "a bell never replaces a notification")
        #expect(!board.raiseTerminalNotice(terminal.id, message: "Claude: Needs permission", bell: false))
        #expect(events == 2)
        #expect(board.attention[terminal.id]?.message == "Claude: Needs permission")
        #expect(board.attention[terminal.id]?.raisedBy == nil)
        board.clearAttention(terminal.id)
        #expect(board.raiseTerminalNotice(terminal.id, message: "Bell", bell: true), "after the user looked, a bell raises again")
    }

    @Test func noticesOnlyForTerminals() {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]))
        #expect(!board.raiseTerminalNotice(note.id, message: "Bell", bell: true))
        #expect(!board.raiseTerminalNotice("obj_missing", message: "Bell", bell: true))
    }

    @Test func noticesFromAReportingAgentRaiseNothingUntilItExits() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["command": .array([])]))
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .done, message: nil, seq: 1, source: "canvas-omp")
        #expect(!board.raiseTerminalNotice(terminal.id, message: "omp: Complete", bell: false), "its badge already says done")
        #expect(board.attention[terminal.id] == nil)
        try board.releaseAgent(tile: terminal.id)
        #expect(board.raiseTerminalNotice(terminal.id, message: "Build: done", bell: false), "a plain shell again")
    }

    @Test func aNotificationFromAProgramIsItsAgentWaiting() throws {
        let board = makeBoard()
        let tile = board.create(type: .terminal, props: .object([:])).id
        func lifecycle() -> JSONValue? { board.objects[tile]?.props["lifecycle"] }
        #expect(board.terminalNotified(tile, message: "aider: waiting for you", bell: false, program: "aider --model x", watched: false) == .lifecycle)
        #expect(lifecycle()?["state"] == .string("done"), "it waits and the user hasn't looked")
        #expect(lifecycle()?["message"] == .string("aider: waiting for you"))
        #expect(board.objects[tile]?.props["agent"]?["kind"] == .string("aider"))
        #expect(board.attention[tile] == nil, "its dot says it, no marker too")
        #expect(NeedsYou.of(board.objects.values)?.level == .done)
        #expect(NeedsYouItem.all(board.objects, attention: board.attention).map(\.reason) == [.done])
        let terminal = try #require(board.objects[tile])
        #expect(PromptTarget.runsAgent(terminal) && !PromptTarget.drains(terminal), "an agent for the tray, but Hyper-V pastes to it")
        // Seen: idle, still reporting by notification.
        board.markSeen(tile)
        #expect(lifecycle()?["state"] == .string("idle"))
        #expect(lifecycle()?["via"] == .string(NotifyingAgent.via))
        // Return typed: it may work or not, so unknown; its next notification is unseen again.
        #expect(board.notifyingAgentSubmitted(tile))
        #expect(lifecycle()?["state"] == .string("unknown"))
        #expect(!board.notifyingAgentSubmitted(tile), "unknown already")
        board.terminalNotified(tile, message: "aider: waiting for you", bell: false, program: "aider", watched: false)
        #expect(lifecycle()?["state"] == .string("done"))
        // While the user looks at it: idle, seen.
        board.terminalNotified(tile, message: "aider: waiting for you", bell: false, program: "aider", watched: true)
        #expect(lifecycle()?["state"] == .string("idle"))
        // A program it runs (its editor) doesn't end it; the shell's prompt does.
        board.terminalProgram(tile, is: "vim")
        #expect(lifecycle() != nil)
        board.terminalProgram(tile, is: nil)
        #expect(lifecycle() == nil && board.objects[tile]?.props["agent"] == nil, "a plain shell again")
    }

    @Test func anIntegratedAgentSaidToBeBusyAtTheShellPromptHasExited() throws {
        let board = makeBoard()
        let omp = board.create(type: .terminal, props: .object([:])).id
        func lifecycle(_ tile: ObjectID) -> String? { board.objects[tile]?.props["lifecycle"]?["state"]?.string }
        try board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        board.terminalProgram(omp, is: "omp")
        #expect(lifecycle(omp) == "working", "the agent holds the terminal: its turn goes on")
        // Killed mid-turn (or it exited while easl was away, its release lost): the shell has the terminal.
        board.terminalProgram(omp, is: nil)
        #expect(board.objects[omp]?.props["lifecycle"] == nil && board.objects[omp]?.props["agent"] == nil, "no turn runs at a shell prompt")

        let codex = board.create(type: .terminal, props: .object([:])).id
        try board.reportLifecycle(tile: codex, kind: "codex", state: .blocked, message: "approve Bash?", seq: 1, source: "canvas-codex")
        board.terminalProgram(codex, is: nil)
        #expect(board.objects[codex]?.props["lifecycle"] == nil, "nor a dialog")

        // A finished agent's answer and dot stay: only a claim to be in a turn is false at the prompt.
        let done = board.create(type: .terminal, props: .object([:])).id
        try board.reportLifecycle(tile: done, kind: "codex", state: .working, message: nil, seq: 1, source: "canvas-codex")
        try board.reportLifecycle(tile: done, kind: "codex", state: .idle, message: nil, seq: 2, source: "canvas-codex", final: "Fixed.")
        board.terminalProgram(done, is: nil)
        #expect(lifecycle(done) == "done")
    }

    @Test func notificationsOnlyBecomeALifecycleForAProgramWithoutAnIntegration() throws {
        let board = makeBoard()
        let shell = board.create(type: .terminal, props: .object([:])).id
        #expect(board.terminalNotified(shell, message: "Bell after `make`", bell: true, program: nil, watched: false) == .marker, "the shell at its prompt")
        #expect(board.objects[shell]?.props["lifecycle"] == nil)
        let vim = board.create(type: .terminal, props: .object([:])).id
        #expect(board.terminalNotified(vim, message: "vim rang the bell", bell: true, program: "vim", watched: false, answersKey: true) == .marker, "a bell answering the key just typed")
        #expect(board.objects[vim]?.props["lifecycle"] == nil)
        #expect(board.terminalNotified(vim, message: "vim rang the bell", bell: true, program: "vim", watched: true, answersKey: true) == .none)
        let omp = board.create(type: .terminal, props: .object([:])).id
        try board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        #expect(board.terminalNotified(omp, message: "omp: Complete", bell: false, program: "omp", watched: false) == .none)
        #expect(board.objects[omp]?.props["lifecycle"]?["state"] == .string("working"), "an integration's lifecycle stays its own")
        // A kind a program had before (omp exited, its kind remembered) isn't the notifier's.
        let reused = board.create(type: .terminal, props: .object(["agent": .object(["kind": .string("omp"), "sessionId": .string("s")])])).id
        board.terminalNotified(reused, message: "crush: done", bell: false, program: "crush", watched: false)
        #expect(board.objects[reused]?.props["agent"] == .object(["kind": .string("crush")]))
    }

    @Test func anApprovalStaysBlockedUntilItsOwnCallFinishes() throws {
        let board = makeBoard()
        let tile = board.create(type: .terminal, props: .object([:])).id
        var seq = 0
        func report(_ state: LifecycleState, _ message: String? = nil, call: String? = nil) throws {
            seq += 1
            try board.reportLifecycle(tile: tile, kind: "codex", state: state, message: message, seq: seq, source: "canvas-codex", call: call)
        }
        func shown() -> (state: String?, message: String?) {
            let lifecycle = board.objects[tile]?.props["lifecycle"]
            return (lifecycle?["state"]?.string, lifecycle?["message"]?.string)
        }
        try report(.working)
        try report(.blocked, "run make check?", call: "a")
        try report(.blocked, "run pnpm --version?", call: "b")
        #expect(shown() == ("blocked", "run make check?"), "the approval on screen is the first one asked")
        try report(.working, call: "subagent-read")
        try report(.working, call: "sibling")
        #expect(shown() == ("blocked", "run make check?"), "other calls finishing don't answer it")
        try report(.working, call: "a")
        #expect(shown() == ("blocked", "run pnpm --version?"), "the queued approval comes up next")
        try report(.working, call: "b")
        #expect(shown().state == "working")

        // A call finishing reported late (async hooks) still ends its own wait.
        try report(.blocked, "edit a.ts?", call: "c")
        let late = seq
        try report(.blocked, "edit b.ts?", call: "d")
        try board.reportLifecycle(tile: tile, kind: "codex", state: .working, message: nil, seq: late, source: "canvas-codex", call: "c")
        try report(.working, call: "d")
        #expect(shown().state == "working", "c's late completion was not lost")

        // Stop, an interrupt, or a new prompt ends every wait.
        try report(.blocked, "edit c.ts?", call: "e")
        try report(.idle)
        try report(.working, call: "f")
        #expect(shown().state == "working")
        try report(.blocked, "edit d.ts?", call: "g")
        try report(.working)
        try report(.working, call: "h")
        #expect(shown().state == "working")
    }

    /// Codex asks one approval at a time: each request names what is on screen, even when the
    /// completion of the one approved before never matched its request.
    @Test func aSerialApprovalReplacesTheOneBefore() throws {
        let board = makeBoard()
        let tile = board.create(type: .terminal, props: .object([:])).id
        var seq = 0
        func report(_ state: LifecycleState, _ message: String? = nil, call: String? = nil) throws {
            seq += 1
            try board.reportLifecycle(tile: tile, kind: "codex", state: state, message: message, seq: seq, source: "canvas-codex", call: call, serial: state == .blocked)
        }
        func shown() -> (state: String?, message: String?) {
            let lifecycle = board.objects[tile]?.props["lifecycle"]
            return (lifecycle?["state"]?.string, lifecycle?["message"]?.string)
        }
        try report(.working)
        try report(.blocked, "May I read PR #1039's description?", call: "a")
        try report(.working, call: "a-as-completed")
        try report(.blocked, "May I fetch PR #1039 into pr-1039?", call: "b")
        #expect(shown() == ("blocked", "May I fetch PR #1039 into pr-1039?"))
        try report(.working, call: "b")
        #expect(shown().state == "working", "nothing left waiting on the first request")
    }

    @Test func anAgentThatExitedIsNotResumed() throws {
        let board = makeBoard()
        let tile = board.create(type: .terminal, props: .object([:])).id
        try board.reportSession(tile: tile, kind: "codex", sessionId: "thread-1", sessionPath: nil)
        try board.reportLifecycle(tile: tile, kind: "codex", state: .idle, message: nil, seq: 1, source: "canvas-codex")
        #expect(board.objects[tile]?.props["agent"]?["sessionId"] == .string("thread-1"), "a running agent is resumed after a reboot")
        try board.releaseAgent(tile: tile)
        #expect(board.objects[tile]?.props["agent"] == nil, "quit: the tile restores as a plain shell")
        #expect(board.objects[tile]?.props["lifecycle"] == nil)
    }

    @Test func noticeMessages() {
        #expect(Board.noticeMessage(title: "Claude", body: "Needs permission") == "Claude: Needs permission")
        #expect(Board.noticeMessage(title: "", body: "Build finished") == "Build finished")
        #expect(Board.noticeMessage(title: "Done", body: " ") == "Done")
    }
}

struct AgentResumeTests {
    /// Every case of Tests/Fixtures/agent-resume.json, which easld's `session.ResumeArgv` is
    /// checked against too. Each agent resumes its own way, with the tile's own options (PreScreen's
    /// capture: a restart of a resumed Codex tile ran plain `codex resume <id>` and dropped the
    /// tile's `-c` trust override, so Codex asked about the folder again); its session selectors
    /// and prompt don't come along, and nothing is doubled.
    @Test func eachAgentResumesItsOwnWayAsTheSharedFixtureSays() throws {
        struct Case: Decodable { var note: String?; var kind: String; var sessionId: String; var command: [String]; var argv: [String]? }
        struct Fixture: Decodable { var cases: [Case] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Fixtures/agent-resume.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(!fixture.cases.isEmpty)
        for c in fixture.cases {
            #expect(AgentResume.argv(kind: c.kind, sessionId: c.sessionId, command: c.command) == c.argv, "\(c.kind) \(c.command): \(c.note ?? "")")
        }
    }
}

struct TerminalNameTests {
    @Test func aProgramIsNamedByWhatItRunsNotItsInterpreterOrOptions() {
        // Gemini CLI is a node script behind `#!/usr/bin/env -S node --no-warnings=DEP0040`.
        #expect(TerminalName.program(argv: ["node", "--no-warnings=DEP0040", "/opt/homebrew/bin/gemini", "-m", "flash"]) == "gemini")
        #expect(TerminalName.program(argv: ["/Users/u/.opencode/bin/opencode", "-m", "zai/glm-4.7"]) == "opencode")
        #expect(TerminalName.program(argv: ["cargo", "test", "-j", "4"]) == "cargo test")
        #expect(TerminalName.program(argv: ["npm", "run", "dev", "extra"]) == "npm run dev")
        #expect(TerminalName.program(argv: ["vim", "src/main.rs"]) == "vim main.rs")
        #expect(TerminalName.program(argv: ["python3.12", "-u", "scripts/train.py", "--epochs", "3"]) == "train.py")
        // macOS's python.org build re-execs as its framework's `Python`.
        #expect(TerminalName.program(argv: ["/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python", "-m", "http.server", "8766"]) == "http.server 8766")
        #expect(TerminalName.program(argv: ["bun", "run", "dev"]) == "bun run dev")
        #expect(TerminalName.program(argv: []) == nil)
    }

    @Test func theHeaderSaysTheNameAndTheLiveTitleOnce() {
        #expect(TerminalName.label(name: "gemini", title: "◇ Ready (glow)") == "gemini · ◇ Ready (glow)")
        // A title that already says the name, in any case, isn't prefixed again.
        #expect(TerminalName.label(name: "claude", title: "✳ Claude Code") == "✳ Claude Code")
        #expect(TerminalName.label(name: "cargo test", title: nil) == "cargo test")
        #expect(TerminalName.label(name: nil, title: "~/dev/glow") == "~/dev/glow")
        #expect(TerminalName.label(name: " ", title: "") == nil)
        // The shell titles an unnamed terminal with the command line it runs: the program says it.
        let command = "aider --model gemini/gemini-2.5-pro --read /tmp/conventions.md"
        #expect(TerminalName.label(name: "aider", title: command, command: command) == "aider")
        #expect(TerminalName.label(name: "aider", title: "aider: editing url.go", command: command) == "aider: editing url.go", "a title the program set itself")
    }
}

struct LoginSessionTests {
    @Test func aTileStartsLikeAFreshLoginSessionNotWithTheAppsLauncherEnvironment() {
        // A dev instance launched from omp's bash tool: its non-interactive settings reached every
        // tile (git commit used GIT_EDITOR=true, Claude Code refused to start under CLAUDECODE).
        let inherited = [
            "HOME": "/Users/u", "USER": "u", "SHELL": "/bin/zsh", "TMPDIR": "/var/folders/x/T/", "LANG": "en_US.UTF-8",
            "SSH_AUTH_SOCK": "/private/tmp/agent", "XDG_CONFIG_HOME": "/tmp/xdg", "TERM": "dumb",
            "PATH": "/opt/homebrew/bin:/usr/bin", "EASL_SOCKET": "/old.sock",
            "CI": "true", "NO_COLOR": "1", "EDITOR": "true", "GIT_EDITOR": "true", "PAGER": "cat",
            "CLAUDECODE": "1", "HERDR_PANE_ID": "p2", "npm_config_yes": "true", "GEMINI_API_KEY": "k",
        ]
        let stripped = LoginSession.strippedForTile(inherited, keep: ["PATH", "EASL_SOCKET", "EASL_TILE_ID"])
        #expect(stripped == ["CI", "CLAUDECODE", "EDITOR", "GEMINI_API_KEY", "GIT_EDITOR", "HERDR_PANE_ID", "NO_COLOR", "PAGER", "npm_config_yes"])
    }

    @Test func aCanvasLaunchedFromATileTakesTheUsersStartupFilesNotThatTilesIntegration() {
        let app = "/tmp/cap/easl-next.app/Contents/Resources", old = "/tmp/cap/easl.app/Contents/Resources"
        let fresh = LoginSession.tileShellIntegration(resources: app, inherited: ["PATH": "/opt/homebrew/bin:/usr/bin", "ZDOTDIR": "/Users/u/.config/zsh"])
        #expect(fresh == [
            "PATH": "\(app)/bin:/opt/homebrew/bin:/usr/bin", "PYTHONPATH": "\(app)/clients/python", "ZDOTDIR": "\(app)/extensions/shell/zsh",
            "EASL_ZSH_ZDOTDIR": "/Users/u/.config/zsh", "PROMPT_COMMAND": ". '\(app)/extensions/shell/bash/easl.bash'",
            "BROWSER": "\(app)/bin/open",
        ], "launched from the Dock or a terminal")

        // Launched by an agent in a tile of another bundle (`dev.sh restart`, a non-interactive
        // shell): the tile's ZDOTDIR was its zsh integration, and new tiles sourced that instead
        // of ~/.zshrc (`_canvas_finish: command not found`).
        let tile = [
            "PATH": "\(old)/bin:/Users/u/.nvm/versions/node/v22/bin:\(old)/bin:/usr/bin", "PYTHONPATH": "\(old)/clients/python:/Users/u/py",
            "ZDOTDIR": "\(old)/extensions/shell/zsh", "PROMPT_COMMAND": ". '\(old)/extensions/shell/bash/easl.bash'; history -a",
        ]
        let nested = LoginSession.tileShellIntegration(resources: app, inherited: tile)
        #expect(nested["EASL_ZSH_ZDOTDIR"] == nil, "the user has none: their startup files are in HOME")
        #expect(nested["ZDOTDIR"] == "\(app)/extensions/shell/zsh")
        #expect(nested["PATH"] == "\(app)/bin:/Users/u/.nvm/versions/node/v22/bin:/usr/bin")
        #expect(nested["PYTHONPATH"] == "\(app)/clients/python:/Users/u/py")
        #expect(nested["PROMPT_COMMAND"] == ". '\(app)/extensions/shell/bash/easl.bash'; history -a")
        #expect(nested["BROWSER"] == "\(app)/bin/open", "the shim of this bundle, not the old tile's")

        // The user's own ZDOTDIR, kept aside by that tile, is theirs again; an interactive shell
        // had already restored it, and only PROMPT_COMMAND still names the old bundle.
        let kept = LoginSession.tileShellIntegration(resources: app, inherited: tile.merging(["EASL_ZSH_ZDOTDIR": "/Users/u/.config/zsh"]) { $1 })
        #expect(kept["EASL_ZSH_ZDOTDIR"] == "/Users/u/.config/zsh")
        let restored = LoginSession.tileShellIntegration(resources: app, inherited: ["PATH": "\(old)/bin:/usr/bin", "ZDOTDIR": "/Users/u/.config/zsh",
                                                                                    "PROMPT_COMMAND": tile["PROMPT_COMMAND"]!])
        #expect(restored["EASL_ZSH_ZDOTDIR"] == "/Users/u/.config/zsh")
        #expect(restored["PATH"] == "\(app)/bin:/usr/bin")

        // Relaunched from a tile of this same bundle: nothing doubles.
        #expect(LoginSession.tileShellIntegration(resources: app, inherited: fresh) == fresh)
    }
}

struct GhosttyConfigTests {
    typealias Entry = GhosttyConfig.Entry

    func load(_ files: [String: String], top: [String]) -> GhosttyConfig {
        GhosttyConfig.load(files: top.map { URL(fileURLWithPath: $0) }) { files[$0.standardizedFileURL.path] }
    }

    @Test func includesLoadAfterEveryTopLevelFileRelativeToTheirFile() {
        let config = load([
            "/x/ghostty/config": "font-size = 20\nconfig-file = ?local.conf\nconfig-file = ?missing.conf\n# comment\nkeybind = shift+enter=text:\\n",
            "/x/ghostty/local.conf": "font-size = 22\nconfig-file = ../ghostty/config",
            "/support/config": "font-size = 21",
        ], top: ["/x/ghostty/config", "/support/config"])
        #expect(config.entries == [Entry("font-size", "20"), Entry("keybind", "shift+enter=text:\\n"), Entry("font-size", "21"), Entry("font-size", "22")])
        #expect(GhosttyConfig.value("font-size", in: config.entries) == "22", "an include loads last, and a cycle stops")
    }

    @Test func themes() {
        #expect(GhosttyConfig.themes("Hardcore") == ("Hardcore", "Hardcore"))
        #expect(GhosttyConfig.themes("\"Catppuccin Mocha\"") == ("Catppuccin Mocha", "Catppuccin Mocha"))
        #expect(GhosttyConfig.themes("dark:B, light:A") == ("A", "B"))
        #expect(GhosttyConfig.themes("dark:B") == ("B", "B"))
        let config = load(["/c": "theme = one\ntheme = light:A,dark:B"], top: ["/c"])
        #expect(config.lightTheme == "A" && config.darkTheme == "B", "the last theme wins")
        #expect(config.entries.isEmpty)
        let dirs = [URL(fileURLWithPath: "/user/themes"), URL(fileURLWithPath: "/app/themes")]
        #expect(GhosttyConfig.themeFile("A", directories: dirs, isFile: { $0 == "/app/themes/A" })?.path == "/app/themes/A")
        #expect(GhosttyConfig.themeFile("A", directories: dirs, isFile: { _ in true })?.path == "/user/themes/A", "the user's theme shadows Ghostty's")
    }

    @Test func userSettingsBeatTheThemeAndCanvasKeepsItsOwn() {
        let config = GhosttyConfig(entries: [Entry("background", "#101010"), Entry("command", "fish"), Entry("background-opacity", "0.8"), Entry("font-size", "24"),
                                             Entry("background-image", "~/wall.png"), Entry("font-family", "JetBrains Mono")])
        let settings = config.settings(theme: [Entry("background", "#ffffff"), Entry("palette", "0=#000000")])
        #expect(GhosttyConfig.value("background", in: settings) == "#101010")
        #expect(GhosttyConfig.value("font-family", in: settings) == "JetBrains Mono")
        #expect(GhosttyConfig.value("command", in: settings) == nil)
        #expect(GhosttyConfig.value("background-opacity", in: settings) == "1")
        #expect(GhosttyConfig.value("font-size", in: settings) == nil, "tile sizes assume Ghostty's default size; zoom scales text")
        #expect(GhosttyConfig.value("background-image", in: settings) == nil, "cards and renders can't draw it")
        #expect(settings.first == Entry("background", "#ffffff"), "the theme comes first")
    }

    @Test func repeatableValuesHonorResets() {
        let settings = [Entry("font-family", "A"), Entry("font-family", ""), Entry("font-family", "\"B C\""), Entry("font-family", "D")]
        #expect(GhosttyConfig.values("font-family", in: settings) == ["B C", "D"])
        #expect(GhosttyConfig.value("font-size", in: [Entry("font-size", "20"), Entry("font-size", "")]) == nil)
    }

    @Test func defaultFilesFollowXdg() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(GhosttyConfig.defaultFiles(home: home, environment: [:]).map(\.path) == [
            "/Users/me/.config/ghostty/config", "/Users/me/.config/ghostty/config.ghostty",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config", "/Users/me/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        #expect(GhosttyConfig.defaultFiles(home: home, environment: ["XDG_CONFIG_HOME": "/tmp/x"]).first?.path == "/tmp/x/ghostty/config")
    }

    @Test func appActionKeybindsNeverReachGhosttyAndNewWindowTabSplitOpenATerminal() {
        typealias Chord = GhosttyConfig.KeyChord
        let config = load(["/c": """
            keybind = super+t=new_window
            keybind = ctrl+shift+enter=new_split:right
            keybind = super+w=close_surface
            keybind = super+==new_tab
            keybind = global:super+key_n=new_tab
            keybind = super+shift+w=close_window
            keybind = super+ctrl+f=toggle_fullscreen
            keybind = ctrl+a>n=new_tab
            keybind = ctrl+shift+x=text:hello
            keybind = super+k=clear_screen
            """], top: ["/c"])
        #expect(GhosttyConfig.values("keybind", in: config.settings(theme: [])) == ["ctrl+shift+x=text:hello", "super+k=clear_screen"],
                "only bindings the library performs itself are handed to it")
        #expect(config.remaps == [
            Chord(.command, "t"): .newTerminal, Chord([.control, .shift], "enter"): .newTerminal, Chord(.command, "w"): .closeTerminal,
            Chord(.command, "="): .newTerminal, Chord(.command, "n"): .newTerminal,
        ])
        #expect(config.appKeybinds.filter { $0.action == nil || $0.chord == nil }.map(\.entry.value) == [
            "super+shift+w=close_window", "super+ctrl+f=toggle_fullscreen", "ctrl+a>n=new_tab",
        ], "dropped: actions easl has no equivalent of, and a sequence it can't match")
    }

    @Test func aLaterBindingOfTheSameChordOrAClearUndoesARemap() {
        let rebound = load(["/c": "keybind = super+t=new_window\nkeybind = super+d=new_split\nkeybind = super+t=unbind"], top: ["/c"])
        #expect(rebound.remaps == [GhosttyConfig.KeyChord(.command, "d"): .newTerminal])
        #expect(GhosttyConfig.values("keybind", in: rebound.settings(theme: [])) == ["super+t=unbind"])
        let cleared = load(["/c": "keybind = super+t=new_window\nkeybind = clear\nkeybind = ctrl+shift+t=new_tab"], top: ["/c"])
        #expect(cleared.remaps == [GhosttyConfig.KeyChord([.control, .shift], "t"): .newTerminal])
    }

    /// A key pressed in a terminal matches a menu item only when both name the key alike:
    /// ⌃⇥ is "tab", and Window › Show Next Tab's key equivalent is "\t".
    @Test func menuKeyEquivalentsNameKeysAsTerminalKeyPressesDo() {
        typealias Chord = GhosttyConfig.KeyChord
        #expect(Chord(menuKey: "\t", modifiers: .control) == Chord(.control, "tab"), "Show Next Tab")
        #expect(Chord(menuKey: "\t", modifiers: [.control, .shift]) == Chord([.control, .shift], "tab"), "Show Previous Tab")
        #expect(Chord(menuKey: "\u{19}", modifiers: .control) == Chord([.control, .shift], "tab"), "back-tab is Shift-Tab")
        #expect(Chord(menuKey: "\u{1b}", modifiers: .command) == Chord(.command, "escape"), "Leave Tile")
        #expect(Chord(menuKey: "\u{8}", modifiers: .command) == Chord(.command, "backspace"))
        #expect(Chord(menuKey: "\r", modifiers: .command) == Chord(.command, "enter"))
        #expect(Chord(menuKey: "\u{F700}", modifiers: [.command, .option]) == Chord([.command, .option], "arrow_up"))
        #expect(Chord(menuKey: "\u{F704}", modifiers: []) == Chord([], "f1"))
        #expect(Chord(menuKey: "Z", modifiers: .command) == Chord([.command, .shift], "z"), "an uppercase letter is Shift")
        #expect(Chord(menuKey: "}", modifiers: .command) == Chord([.command, .shift], "]"), "a shifted symbol is its key with Shift")
        #expect(Chord(menuKey: "=", modifiers: [.control, .command]) == Chord([.control, .command], "="))
    }
}
