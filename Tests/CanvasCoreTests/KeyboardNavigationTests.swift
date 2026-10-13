import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// Keyboard zoom steps, the mouse wheel and trackpad gestures over tiles, ⌥⌘-arrow neighbors, Go to's file matching, and the tray's prompt target.
struct KeyboardNavigationTests {
    @Test func keyboardZoomStepsThroughBrowserLevelsWithinTheLimits() {
        let limits: ClosedRange<CGFloat> = 0.1...1
        var zoom: CGFloat = 1
        var outs: [CGFloat] = []
        while true {
            let next = Layout.zoomStep(from: zoom, in: false, limits: limits)
            if next == zoom { break }
            outs.append(next)
            zoom = next
        }
        #expect(outs == [0.9, 0.75, 0.67, 0.5, 0.33, 0.25, 0.15, 0.1], "finer than halving, ending at the minimum")
        #expect(Layout.zoomStep(from: 0.1, in: true, limits: limits) == 0.15)
        #expect(Layout.zoomStep(from: 0.42, in: true, limits: limits) == 0.5, "an arbitrary zoom (a fit) steps to the next level up")
        #expect(Layout.zoomStep(from: 0.42, in: false, limits: limits) == 0.33)
        #expect(Layout.zoomStep(from: 1 / 3, in: false, limits: limits) == 0.25, "a hair off a level counts as on it")
        #expect(Layout.zoomStep(from: 0.95, in: true, limits: limits) == 1, "never past the maximum")
        #expect(Layout.zoomStep(from: 1, in: true, limits: limits) == 1)
        #expect(Layout.zoomStep(from: 0.12, in: false, limits: limits) == 0.1)
    }

    @Test func aWheelNotchPansAUsefulDistanceAndCommandScrollZooms() {
        let line = CanvasWheel.lineHeight
        #expect(CanvasWheel.action(dx: 0, dy: -1, precise: false, command: false, shift: false) == .pan(dx: 0, dy: -line), "a notch down pans a line, not a point")
        #expect(CanvasWheel.action(dx: 0, dy: 2, precise: false, command: false, shift: true) == .pan(dx: 2 * line, dy: 0), "⇧ turns a vertical wheel sideways")
        #expect(CanvasWheel.action(dx: -1, dy: 0, precise: false, command: false, shift: true) == .pan(dx: -line, dy: 0), "a wheel AppKit already turned sideways stays so")
        #expect(CanvasWheel.action(dx: 3, dy: -40, precise: true, command: false, shift: false) == .system, "a trackpad keeps the scroll view's own pan")
        guard case .zoom(let zoomIn) = CanvasWheel.action(dx: 0, dy: 1, precise: false, command: true, shift: false),
              case .zoom(let zoomOut) = CanvasWheel.action(dx: 0, dy: -1, precise: false, command: true, shift: false),
              case .zoom(let trackpad) = CanvasWheel.action(dx: 0, dy: line, precise: true, command: true, shift: false) else {
            Issue.record("⌘-scroll doesn't zoom")
            return
        }
        #expect(zoomIn > 1 && zoomOut < 1, "⌘-scroll up zooms in, down out")
        #expect(abs(zoomIn * zoomOut - 1) < 1e-9, "a notch in and a notch out come back")
        #expect(abs(trackpad - zoomIn) < 1e-9, "a trackpad's ⌘-scroll zooms by the same measure, in points")
        #expect(CanvasWheel.action(dx: -2, dy: 0, precise: false, command: true, shift: false) == .pan(dx: -2 * line, dy: 0), "a sideways ⌘-scroll still pans")
    }

    @Test func aShiftWheelLeftVerticalCountsAsSideways() {
        #expect(CanvasWheel.sideways(dx: 0, dy: 2, precise: false, shift: true), "a ⇧-wheel AppKit left vertical")
        #expect(CanvasWheel.sideways(dx: -2, dy: 0, precise: false, shift: true), "a ⇧-wheel AppKit turned sideways")
        #expect(CanvasWheel.sideways(dx: 5, dy: -2, precise: true, shift: false), "a horizontal-dominant trackpad step")
        #expect(!CanvasWheel.sideways(dx: 0, dy: 2, precise: false, shift: false), "a plain wheel notch")
        #expect(!CanvasWheel.sideways(dx: 0, dy: 20, precise: true, shift: true), "a trackpad's vertical scroll, ⇧ or not")
    }

    @Test func aScrollGestureKeepsTheOwnerItsFirstMovementChose() {
        var gesture = ScrollGesture()
        #expect(gesture.owner(of: .began, dx: 0, dy: 0, tileTakes: true) == nil, "nothing decided before it moves")
        #expect(gesture.owner(of: .changed, dx: 0, dy: -6, tileTakes: true) == .tile)
        #expect(gesture.owner(of: .changed, dx: 30, dy: 0, tileTakes: false) == .tile, "a later sideways step stays with the tile")
        #expect(gesture.owner(of: .ended, dx: 0, dy: 0, tileTakes: true) == .tile)
        #expect(gesture.owner(of: .momentumBegan, dx: 0, dy: -4, tileTakes: true) == .tile, "momentum keeps its owner")
        #expect(gesture.owner(of: .momentumChanged, dx: 0, dy: -2, tileTakes: false) == .tile)
        #expect(gesture.owner(of: .momentumEnded, dx: 0, dy: 0, tileTakes: false) == .tile)

        #expect(gesture.owner(of: .began, dx: 0, dy: 0, tileTakes: true) == nil, "a new gesture starts undecided")
        #expect(gesture.owner(of: .changed, dx: 0, dy: 0, tileTakes: false) == nil, "a step without movement decides nothing")
        #expect(gesture.owner(of: .changed, dx: 12, dy: 1, tileTakes: false) == .canvas)
        #expect(gesture.owner(of: .changed, dx: 0, dy: 9, tileTakes: true) == .canvas, "the canvas keeps it too")
        #expect(gesture.owner(of: .ended, dx: 0, dy: 0, tileTakes: true) == .canvas)
        #expect(gesture.owner(of: .momentumBegan, dx: 3, dy: 0, tileTakes: true) == .canvas)
    }

    @Test func aScrollGestureTheTileDidNotSeeBeginIsTheCanvas() {
        var gesture = ScrollGesture()
        _ = gesture.owner(of: .began, dx: 0, dy: 0, tileTakes: true)
        _ = gesture.owner(of: .changed, dx: 0, dy: -6, tileTakes: true)
        _ = gesture.owner(of: .ended, dx: 0, dy: 0, tileTakes: true)
        // A pan that began on empty board slides the tile under the pointer.
        #expect(gesture.owner(of: .changed, dx: 0, dy: -8, tileTakes: true) == .canvas, "a first .changed with no began is the canvas's")
        #expect(gesture.owner(of: .changed, dx: 0, dy: -8, tileTakes: true) == .canvas)
        #expect(gesture.owner(of: .ended, dx: 0, dy: 0, tileTakes: true) == .canvas)
        #expect(gesture.owner(of: .momentumBegan, dx: 0, dy: -5, tileTakes: true) == .canvas)

        var fresh = ScrollGesture()
        #expect(fresh.owner(of: .changed, dx: 0, dy: 0, tileTakes: true) == .canvas, "even without movement")
        var momentum = ScrollGesture()
        _ = momentum.owner(of: .began, dx: 0, dy: 0, tileTakes: true)
        _ = momentum.owner(of: .changed, dx: 0, dy: -6, tileTakes: true)
        _ = momentum.owner(of: .ended, dx: 0, dy: 0, tileTakes: true)
        #expect(momentum.owner(of: .momentumChanged, dx: 0, dy: -3, tileTakes: true) == .canvas, "another gesture's momentum sliding the tile under")
        #expect(momentum.owner(of: .began, dx: 0, dy: 0, tileTakes: true) == nil, "began resets the owner")
    }

    @Test func arrowNeighborPrefersTheSameRowThenTheNearest() {
        let from = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frames = [
            CGRect(x: 600, y: 700, width: 400, height: 300),   // 0: down-right, nearer by center
            CGRect(x: 1200, y: 50, width: 400, height: 300),   // 1: same row, farther
            CGRect(x: -900, y: 0, width: 400, height: 300),    // 2: left
            CGRect(x: 100, y: -800, width: 300, height: 300),  // 3: above
            CGRect(x: 0, y: 500, width: 400, height: 300),     // 4: below
        ]
        #expect(Layout.neighbor(of: from, among: frames, toward: .right) == 1, "a tile in the same row beats a nearer diagonal one")
        #expect(Layout.neighbor(of: from, among: frames, toward: .left) == 2)
        #expect(Layout.neighbor(of: from, among: frames, toward: .up) == 3)
        #expect(Layout.neighbor(of: from, among: frames, toward: .down) == 4)
        #expect(Layout.neighbor(of: frames[2], among: [from], toward: .left) == nil, "nothing that way")
        // Overlapping tiles still count when they lie past the near edge.
        let overlapping = CGRect(x: 300, y: 100, width: 400, height: 300)
        #expect(Layout.neighbor(of: from, among: [overlapping], toward: .right) == 0)
        #expect(Layout.neighbor(of: from, among: [from], toward: .right) == nil, "not itself")
    }

    /// Study geometry: ⌥⌘↓ from an omp terminal went to a code tile off to the right (just past
    /// the terminal's right edge, starting above its bottom) instead of the review tile below it.
    @Test func arrowNeighborPrefersTilesInLineOverNearerOnesBeside() {
        let terminal = CGRect(x: 0, y: 0, width: 1000, height: 620)
        let beside = CGRect(x: 1020, y: 470, width: 640, height: 446)
        let below = CGRect(x: -10, y: 690, width: 740, height: 600)
        #expect(Layout.neighbor(of: terminal, among: [beside, below], toward: .down) == 1, "the tile sharing the terminal's column")
        // A sliver of shared span is not in line: 10 pt of a 640 pt tile.
        let sliver = CGRect(x: 990, y: 470, width: 640, height: 446)
        #expect(Layout.neighbor(of: terminal, among: [sliver, below], toward: .down) == 1)
        // Far below but in line still beats near and off to the side.
        let farBelow = CGRect(x: 200, y: 3000, width: 400, height: 300)
        #expect(Layout.neighbor(of: terminal, among: [beside, farBelow], toward: .down) == 1)
        // With nothing in line, the diagonal one is still reachable.
        #expect(Layout.neighbor(of: terminal, among: [beside], toward: .down) == 0)
        // Across the other axis the same way: → picks the tile sharing the row.
        let right = CGRect(x: 1400, y: 100, width: 400, height: 400)
        let rightLow = CGRect(x: 1030, y: 600, width: 400, height: 400)
        #expect(Layout.neighbor(of: terminal, among: [rightLow, right], toward: .right) == 1)
    }

    /// Study geometry: ⌥⌘↑ from the terminal went to a code tile above it, and ⌥⌘↓ from there went
    /// on to the follow tile beside the terminal (nearer by center) instead of back.
    @Test func theOppositeArrowRightAfterAMoveGoesBack() {
        let terminal = CGRect(x: -474, y: 0, width: 1000, height: 620)
        let code = CGRect(x: 144, y: -500, width: 640, height: 450)
        let follow = CGRect(x: 550, y: 0, width: 640, height: 620)
        let right = CGRect(x: 1300, y: -500, width: 400, height: 450)
        let frames: [ObjectID: CGRect] = ["terminal": terminal, "code": code, "follow": follow, "right": right]
        func others(_ id: ObjectID?) -> [(id: ObjectID, frame: CGRect)] { frames.filter { $0.key != id }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
        #expect(Layout.neighbor(of: code, among: [terminal, follow], toward: .down) == 1, "plain geometry picks the follow tile")

        var walk = TileWalk()
        #expect(walk.step(from: "terminal", frame: terminal, toward: .up, among: others("terminal")) == "code")
        #expect(walk.step(from: "code", frame: code, toward: .down, among: others("code")) == "terminal", "back where it came from")
        #expect(walk.step(from: "terminal", frame: terminal, toward: .up, among: others("terminal")) == "code")
        #expect(walk.step(from: "code", frame: code, toward: .right, among: others("code")) == "right")
        #expect(walk.step(from: "right", frame: right, toward: .left, among: others("right")) == "code", "a run unwinds move by move")
        #expect(walk.step(from: "code", frame: code, toward: .down, among: others("code")) == "terminal")

        // Starting anywhere else forgets the trail: from the code tile, ↓ is plain geometry again.
        #expect(walk.step(from: "terminal", frame: terminal, toward: .up, among: others("terminal")) == "code")
        #expect(walk.step(from: "follow", frame: follow, toward: .left, among: others("follow")) == "terminal")
        #expect(walk.step(from: "code", frame: code, toward: .down, among: others("code")) == "follow")
        // A tile that is gone can't be gone back to: plain geometry instead.
        #expect(walk.step(from: "follow", frame: follow, toward: .up, among: others("follow").filter { $0.id != "code" }) == "right")
    }

    /// ⌘W keeps going: the tile that takes the selection after the selected one closes.
    @Test func theNearestTileByNeighborGeometryTakesOverAClosedOnesSelection() {
        let closed = CGRect(x: 0, y: 0, width: 600, height: 400)
        let below = CGRect(x: 100, y: 440, width: 600, height: 400)
        let diagonal = CGRect(x: 620, y: 420, width: 300, height: 300)
        let farRight = CGRect(x: 900, y: 0, width: 400, height: 400)
        #expect(Layout.nearest(to: closed, among: [farRight, diagonal, below]) == 2, "in line and nearest along its heading")
        #expect(Layout.nearest(to: closed, among: [farRight, diagonal]) == 0, "in line beats a nearer diagonal tile")
        #expect(Layout.nearest(to: closed, among: [diagonal]) == 0)
        let stacked = CGRect(x: 0, y: 0, width: 600, height: 400)
        #expect(Layout.nearest(to: closed, among: [stacked]) == 0, "one exactly under it, which no heading reaches")
        #expect(Layout.nearest(to: closed, among: []) == nil)
    }

    /// ⌘J: blocked agents first, then marked objects, then done agents not seen yet, each top to
    /// bottom; visiting a marked one clears its marker, visiting a done agent's terminal focuses
    /// it, which sees it (it turns idle), and the next press still moves on rather than starting
    /// over.
    @Test func nextNeedsYouVisitsBlockedAgentsThenMarkersThenDoneAgentsInReadingOrder() {
        func object(_ id: ObjectID, _ type: ObjectType, y: Double, state: String? = nil) -> CanvasObject {
            var props: [String: JSONValue] = [:]
            if let state { props["lifecycle"] = .object(["state": .string(state), "message": .string("approve Edit?"), "seen": .bool(false)]) }
            return CanvasObject(id: id, type: type, frame: Frame(x: 0, y: y, w: 100, h: 100), z: 0, parent: nil, createdBy: .user, createdAt: Date(), props: .object(props))
        }
        var objects = Dictionary(uniqueKeysWithValues: [
            object("lower-agent", .terminal, y: 900, state: "blocked"), object("upper-agent", .terminal, y: 0, state: "blocked"),
            object("idle-agent", .terminal, y: -500, state: "idle"), object("note", .note, y: -900), object("code", .code, y: 300),
            object("plain", .note, y: 50), object("lower-done", .terminal, y: 700, state: "done"), object("upper-done", .terminal, y: -700, state: "done"),
            object("marked-done", .terminal, y: 800, state: "done"),
        ].map { ($0.id, $0) })
        var attention = Dictionary(uniqueKeysWithValues: ["code", "note", "upper-agent", "marked-done"].map { ($0, Attention(object: $0, message: "look", raisedBy: nil, raisedAt: Date())) })
        let items = NeedsYouItem.all(objects, attention: attention)
        #expect(items.map(\.id) == ["upper-agent", "lower-agent", "note", "code", "marked-done", "upper-done", "lower-done"])
        #expect(items.map(\.reason) == [.blocked, .blocked, .marked, .marked, .marked, .done, .done], "a done agent with a marker is listed once, as marked")
        #expect(items.first?.message == "approve Edit?")

        var visited: [ObjectID] = []
        var last: NeedsYouItem?
        for _ in 0..<8 {
            guard let next = NeedsYouItem.next(after: last, in: NeedsYouItem.all(objects, attention: attention)) else { break }
            visited.append(next.id)
            attention[next.id] = nil
            // Focused: seen.
            if objects[next.id]?.props["lifecycle"]?["state"]?.string == "done" { objects[next.id]?.props = .object(["lifecycle": .object(["state": .string("idle"), "seen": .bool(true)])]) }
            last = next
        }
        #expect(visited == ["upper-agent", "lower-agent", "note", "code", "marked-done", "upper-done", "lower-done", "upper-agent"], "blocked agents stay until answered")
        #expect(!NeedsYouItem.all(objects, attention: attention).contains { $0.reason != .blocked })
        #expect(NeedsYouItem.next(after: nil, in: []) == nil)
    }

    @Test func fileSearchRanksFileNamesOverScatteredPathMatches() {
        let index = FileIndex(paths: [
            "docs/maintenance.md",
            "src/manager/index.ts",
            "trusted/cli/src/main.ts",
            "src/main.tsx",
            "packages/domain/src/main_test.ts",
            "README.md",
        ])
        let results = index.search("main.ts", limit: 10)
        #expect(results.first == "src/main.tsx" || results.first == "trusted/cli/src/main.ts")
        #expect(Array(results.prefix(2)).sorted() == ["src/main.tsx", "trusted/cli/src/main.ts"], "the file name itself first")
        #expect(!results.contains("README.md"), "not a subsequence")
        #expect(index.search("main.ts", limit: 1).count == 1, "capped")
        #expect(index.search("", limit: 10).isEmpty, "an empty query lists no files")
        // A subsequence across directories still matches: s·c·l·m → trusted/cli/src/main.ts's words.
        #expect(index.search("clisrcmain", limit: 10) == ["trusted/cli/src/main.ts"])
        #expect(index.search("MAIN", limit: 10).contains("src/main.tsx"), "case-insensitive")
        #expect(index.search("main ts", limit: 3).first.map { $0.hasSuffix("main.ts") || $0.hasSuffix("main.tsx") } == true, "spaces ignored")
        // Word starts beat letters buried inside words.
        let words = FileIndex(paths: ["abc/xyzfoobar.swift", "abc/foo_bar.swift"])
        #expect(words.search("fb", limit: 2).first == "abc/foo_bar.swift")
    }

    @Test func goToQueriesTakeALineOrASymbol() {
        func parse(_ query: String) -> GoToQuery { GoToQuery.parse(query) }
        #expect(parse("core.py:1428") == GoToQuery(text: "core.py", lines: LineRange(start: 1428, end: 1428)))
        #expect(parse(" src/click/core.py:10-20 ") == GoToQuery(text: "src/click/core.py", lines: LineRange(start: 10, end: 20)))
        #expect(parse("core.py:12:7") == GoToQuery(text: "core.py", lines: LineRange(start: 12, end: 12)), "a column is ignored")
        #expect(parse("core.py#L10-L20") == GoToQuery(text: "core.py", lines: LineRange(start: 10, end: 20)))
        #expect(parse("core.py#L7") == GoToQuery(text: "core.py", lines: LineRange(start: 7, end: 7)))
        #expect(parse("core.py:30-10") == GoToQuery(text: "core.py", lines: LineRange(start: 30, end: 30)), "a reversed range is its start")
        #expect(parse("core.py:") == GoToQuery(text: "core.py"), "half-typed: the file alone, still listed")
        #expect(parse("core.py#L") == GoToQuery(text: "core.py"))
        #expect(parse("core.py") == GoToQuery(text: "core.py"))
        #expect(parse(":42") == GoToQuery(text: ":42"), "a line needs a file")
        #expect(parse("@resolve_command") == GoToQuery(text: "resolve_command", symbol: true))
        #expect(parse("@ Group ") == GoToQuery(text: "Group", symbol: true))
        #expect(parse("tstopts") == GoToQuery(text: "tstopts"))
    }

    private func terminal(_ id: ObjectID, agent: String? = nil, running: Bool = false, name: String? = nil) -> CanvasObject {
        var props: [String: JSONValue] = ["cwd": .string("/")]
        if let agent { props["agent"] = .object(["kind": .string(agent)]) }
        if running { props["lifecycle"] = .object(["state": .string("idle")]) }
        if let name { props["name"] = .string(name) }
        return CanvasObject(id: id, type: .terminal, frame: Frame(x: 0, y: 0, w: 10, h: 10), z: 0, parent: nil, createdBy: .user, createdAt: Date(), props: .object(props))
    }

    @Test func promptTargetPrefersAgentsOverShellsTheUserTypedIn() {
        func choose(_ order: [ObjectID], chosen: ObjectID? = nil, _ objects: [ObjectID: CanvasObject]) -> ObjectID? {
            PromptTarget.choose(PromptTarget.State(focusOrder: order, chosen: chosen), objects: objects)
        }
        let omp = terminal("omp", agent: "omp", running: true)
        let nvim = terminal("nvim")
        let shell = terminal("shell")
        let objects = [omp.id: omp, nvim.id: nvim, shell.id: shell]
        #expect(choose(["omp", "nvim"], objects) == "omp", "an editor focused later doesn't take the target")
        #expect(choose([], objects) == "omp", "the only agent needs no click beside a dev-server shell")
        #expect(choose(["nvim", "shell"], objects) == "omp", "a shell typed in never takes it from the only agent")
        #expect(choose([], [nvim.id: nvim]) == "nvim", "a lone terminal needs no focus")
        #expect(choose(["gone", "shell"], [nvim.id: nvim, shell.id: shell]) == "shell", "no agent: the last focused, closed terminals skipped")
        #expect(choose([], [nvim.id: nvim, shell.id: shell]) == nil, "several plain terminals, none focused")
        // Two agents: the one focused last; none focused: the last focused terminal, else none.
        let claude = terminal("claude", agent: "claude", running: true)
        let both = objects.merging([claude.id: claude]) { $1 }
        #expect(choose(["claude", "omp", "shell"], both) == "omp")
        #expect(choose(["shell"], both) == "shell", "several agents, none ever focused: the shell the user typed in")
        #expect(choose([], both) == nil)
        // An agent that exited (lifecycle cleared, kind remembered) is a plain terminal again.
        let exited = terminal("omp", agent: "omp", running: false)
        #expect(choose(["omp", "nvim"], [exited.id: exited, nvim.id: nvim]) == "nvim")
        // The tray menu's pick beats every rule until another terminal takes the keyboard.
        #expect(choose(["omp", "shell"], chosen: "shell", objects) == "shell")
        #expect(choose(["omp"], chosen: "gone", objects) == "omp", "a picked terminal that closed no longer counts")
    }

    @Test func anAgentWithoutAnIntegrationIsATargetLikeAnyAgentAndHyperVGoesWhereTheUserTypes() {
        func choose(_ order: [ObjectID], _ objects: [ObjectID: CanvasObject]) -> ObjectID? {
            PromptTarget.choose(PromptTarget.State(focusOrder: order), objects: objects)
        }
        // aider as its wrapper announced it (`NotifyingAgent`).
        var aider = terminal("aider", agent: "aider")
        aider.props = aider.props.merging(.object(["lifecycle": .object(["state": .string("unknown"), "via": .string(NotifyingAgent.via)])]))
        let omp = terminal("omp", agent: "omp", running: true)
        let dev = terminal("dev")
        let objects = [aider.id: aider, omp.id: omp, dev.id: dev]
        #expect(choose(["aider"], objects) == "aider", "focused, it keeps the target from an integrated agent created beside it")
        #expect(choose(["omp", "aider"], objects) == "aider", "given the keyboard back, it takes the target again")
        #expect(choose(["aider", "dev"], objects) == "aider", "a dev-server shell focused later still doesn't take it")
        #expect(choose(["aider", "omp"], objects) == "omp")
        #expect(PromptTarget.drains(omp) && !PromptTarget.drains(aider), "only an integration takes the tray with its prompt")
        // Hyper-V pastes into the terminal holding the keyboard, else the tray's target.
        #expect(PromptTarget.pasteTarget(keyboard: "aider", target: "omp", objects: objects) == "aider")
        #expect(PromptTarget.pasteTarget(keyboard: "dev", target: "omp", objects: objects) == "dev")
        #expect(PromptTarget.pasteTarget(keyboard: nil, target: "omp", objects: objects) == "omp")
        #expect(PromptTarget.pasteTarget(keyboard: "gone", target: "omp", objects: objects) == "omp", "not a terminal on the board")
        #expect(PromptTarget.pasteTarget(keyboard: nil, target: nil, objects: objects) == nil)
    }

    @MainActor @Test func promptTargetMenuPickHoldsUntilAnotherTerminalIsFocused() throws {
        var state = PromptTarget.State()
        state.focused("omp")
        state.choose("shell")
        state.focused("shell")
        #expect(state.chosen == "shell", "typing into the picked terminal keeps the pick")
        state.focused("nvim")
        #expect(state.chosen == nil)
        let omp = terminal("omp", agent: "omp", running: true)
        let objects = [omp.id: omp, "shell": terminal("shell"), "nvim": terminal("nvim")]
        #expect(PromptTarget.choose(state, objects: objects) == "omp", "the pick gone, agents win again")
        // Saved with the board: the target survives a restart.
        let board = Board(id: "b", root: URL(fileURLWithPath: "/tmp"))
        board.create(type: .terminal, props: .object(["cwd": .string("/")]))
        let b = board.create(type: .terminal, props: .object(["cwd": .string("/")]))
        board.promptTarget.choose(b.id)
        let data = try JSONEncoder().encode(board.snapshot)
        let restored = Board(snapshot: try JSONDecoder().decode(BoardSnapshot.self, from: data))
        #expect(PromptTarget.choose(restored.promptTarget, objects: restored.objects) == b.id)
    }

    @Test func trayMenuListsAgentTerminalsFirstInReadingOrder() {
        func at(_ object: CanvasObject, x: Double, y: Double) -> CanvasObject {
            var moved = object
            moved.frame = Frame(x: x, y: y, w: 10, h: 10)
            return moved
        }
        let objects = [
            "shell": at(terminal("shell"), x: 0, y: 0),
            "omp": at(terminal("omp", agent: "omp", running: true), x: 500, y: 0),
            "codex": at(terminal("codex", agent: "codex", running: true), x: 0, y: 400),
            "nvim": at(terminal("nvim"), x: 0, y: 200),
        ]
        #expect(PromptTarget.menuOrder(objects).map(\.id) == ["omp", "codex", "shell", "nvim"])
    }

    @Test func trayNamesTheTargetByNameThenTitle() {
        #expect(PromptTarget.label(terminal("a", name: "fees"), shownTitle: "✳ Claude Code") == "fees")
        #expect(PromptTarget.label(terminal("a"), shownTitle: "✳ Claude Code") == "✳ Claude Code")
        #expect(PromptTarget.label(terminal("a"), shownTitle: " ") == "Terminal")
    }

    @Test func editHereUsesTheUsersEditorWithALineWhereItTakesOne() {
        #expect(EditorCommand.argv(editor: "nvim", fallback: "vi", line: 42, path: "a.swift") == ["nvim", "+42", "--", "a.swift"])
        #expect(EditorCommand.argv(editor: "/opt/homebrew/bin/emacsclient -t", fallback: "vi", line: 7, path: "a.swift") == ["/opt/homebrew/bin/emacsclient", "-t", "+7", "a.swift"])
        #expect(EditorCommand.argv(editor: "code -w", fallback: "vi", line: 7, path: "a.swift") == ["code", "-w", "a.swift"], "no +line for editors not known to take it")
        #expect(EditorCommand.argv(editor: nil, fallback: "vi", line: 3, path: "a.swift") == ["vi", "+3", "--", "a.swift"])
        #expect(EditorCommand.argv(editor: "  ", fallback: "nvim", line: 3, path: "a.swift").first == "nvim")
    }
}
