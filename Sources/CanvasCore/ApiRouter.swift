import Foundation

/// All open boards in the app, plus event fan-out to socket subscribers.
@MainActor
public final class BoardRegistry {
    public private(set) var boards: [BoardID: Board] = [:]
    /// Board of the key window; the default target when a call names no board or caller.
    public var frontmost: BoardID?
    public let store: BoardStore
    private var subscribers: [(connection: SocketServer.Connection, board: BoardID?, events: Set<String>?)] = []
    /// App-level observer for every board's events (UI reconciliation). Socket subscribers are fed separately.
    public var onEvent: ((Board, BoardEvent) -> Void)?
    /// The router's own observer (agent.wait), kept apart from the app-level hook.
    var routerHook: ((Board, BoardEvent) -> Void)?
    /// The router's handler of messages that bounced on any open board (`Board.onMessagesBounced`).
    var messagesBounced: ((Board, MessageBounce) -> Void)?
    /// Terminal tiles deleted for good on any open board (`Board.onTerminalsEnded`), as they last
    /// were: the app ends their sessions.
    public var onTerminalsEnded: ((Board, [CanvasObject]) -> Void)?
    /// Where agent integrations spool the reports they couldn't deliver (`AgentReportSpool`);
    /// nil replays nothing.
    public let agentReports: URL?

    public init(store: BoardStore = BoardStore(), agentReports: URL? = nil) {
        self.store = store
        self.agentReports = agentReports
    }

    /// The board for a directory: its repository's board (rooted at the repository's canonical
    /// root) when it is in git, tagged with the worktree it was opened from
    /// (`Board.opened(from:)`), else the directory's own board.
    @discardableResult
    public func open(root: URL) -> Board {
        let worktree = GitWorktree.containing(root.standardizedFileURL.path)
        let id = worktree.map { BoardStore.repoID(commonDir: $0.commonDir) } ?? BoardStore.pathID(root)
        if let existing = boards[id] {
            if let worktree { existing.opened(from: worktree) }
            return existing
        }
        let board = store.load(root: worktree.map { URL(fileURLWithPath: $0.canonicalRoot) } ?? root, id: id, repo: worktree?.commonDir)
        if let worktree { board.opened(from: worktree) }
        board.onEvent = { [weak self, weak board] event in
            guard let self, let board else { return }
            self.onEvent?(board, event)
            self.routerHook?(board, event)
            self.broadcast(event, board: board.id)
        }
        board.onTerminalsEnded = { [weak self, weak board] ended in
            guard let self, let board else { return }
            self.onTerminalsEnded?(board, ended)
        }
        board.onMessagesBounced = { [weak self, weak board] bounce in
            guard let self, let board else { return }
            self.messagesBounced?(board, bounce)
        }
        boards[id] = board
        board.activity.record(.restart, actor: .system, rev: board.revision,
                              summary: "easl started (pid \(ProcessInfo.processInfo.processIdentifier)); board opened with \(board.objects.count) objects")
        frontmost = frontmost ?? id
        replayAgentReports(on: board)
        // Questions that expired while the board was closed expire now.
        board.scheduleQuestionExpiry()
        return board
    }

    /// What the board's agents said while easl was away (`AgentReportSpool`): read off the
    /// main actor, applied in `seq` order, then deleted.
    private func replayAgentReports(on board: Board) {
        guard let directory = agentReports else { return }
        let tiles = board.objects.values.filter { $0.type == .terminal }.map(\.id)
        guard !tiles.isEmpty else { return }
        Task { @MainActor [weak board] in
            let entries = await offPool { AgentReportSpool.read(from: directory, tiles: tiles) }
            guard !entries.isEmpty else { return }
            board?.replay(entries)
            await offPool { AgentReportSpool.remove(entries) }
        }
    }

    /// The open board `id` names: its own, or a legacy per-branch board's id that a repository
    /// board merged (`RepoRecord.merged`), which terminals started before the migration still
    /// carry in `EASL_BOARD_ID`.
    public func board(id: BoardID) -> Board? {
        boards[id] ?? boards.values.first { $0.repo?.merged?.contains(id) == true }
    }

    public func close(_ id: BoardID) {
        if let board = boards.removeValue(forKey: id) { store.save(board) }
        if frontmost == id { frontmost = boards.keys.first }
    }

    public func board(containing object: ObjectID) -> Board? {
        boards.values.first { $0.objects[object] != nil }
    }

    func subscribe(_ connection: SocketServer.Connection, board: BoardID?, events: [String]?) {
        subscribers.append((connection, board, events.map(Set.init)))
    }

    private func broadcast(_ event: BoardEvent, board: BoardID) {
        subscribers.removeAll { !$0.connection.isOpen }
        Metrics.shared.gauge("events.subscribers", Double(subscribers.count))
        let receivers = subscribers.filter { subscriber in
            (subscriber.board == nil || subscriber.board == board) && (subscriber.events?.contains(event.name) ?? true)
        }
        guard !receivers.isEmpty else { return }
        // Encoded once for every subscriber (an html tile's update carries its whole page).
        let message: JSONValue = .object(["event": .string(event.name), "board": .string(board), "data": event.data])
        guard let line = try? JSONEncoder().encode(message) else { return }
        Metrics.shared.record("event.\(event.name)", bytes: (line.count + 1) * receivers.count)
        for subscriber in receivers { subscriber.connection.send(encoded: line) }
    }
}

/// Maps schema/easl-api.json methods onto boards. App-level capabilities (object images,
/// attention markers, pasting into terminals) are injected as closures by the app.
@MainActor
public final class ApiRouter {
    public struct Failure: Error {
        public var code: String
        public var message: String

        public init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    public let registry: BoardRegistry
    /// Types text into a terminal tile (bracketed paste) and presses Enter once the paste landed;
    /// false when the surface isn't attached.
    public var submitToTerminal: ((Board, ObjectID, String) async -> Bool)?
    /// The board's window as currently shown, encoded in `format`, with the viewport it shows.
    public var snapshotBoard: ((Board, ImageFormat) async -> (output: RenderOutput, viewport: Viewport)?)?
    /// Offscreen render for `view.render`; throws `Failure` for bad targets.
    public var renderView: ((Board, RenderRequest, ImageFormat) async throws -> RenderOutput)?
    /// What the board's window shows; nil when it has none.
    public var viewState: ((Board) -> ViewState?)?
    /// The window of `board` shows a browser tile a link opened (`view.open_url`): the least pan
    /// that shows it, never so far that `source` (the caller's terminal, on this board) leaves
    /// view; the tile, new or already open, is selected and keyboard focus stays.
    public var showOpenedLink: ((Board, _ opened: ObjectID, _ source: ObjectID?) -> Void)?
    /// The last `lines` lines of a terminal tile's session text (a `TerminalTail`, soft-wrapped
    /// rows joined when the tile knows its width), read and trimmed off the main actor; nil when
    /// the session doesn't exist.
    public var readTerminal: ((Board, ObjectID, _ lines: Int) async -> TerminalTail.Tail?)?
    /// A terminal tile's command block (`agent.read` `block`: -1 the last command the shell
    /// finished, -2 the one before): what ran and its output, from Ghostty's prompt marks and
    /// the terminal's command log; throws `Failure` when there's none to read.
    public var readTerminalBlock: ((Board, ObjectID, _ index: Int) async throws -> (command: TerminalCommand, output: String))?
    /// A terminal tile's live title (OSC 0/2), foreground program (`TerminalName.program`) and
    /// last finished command, as its tile knows them now; nil without the app UI.
    public var terminalStatus: ((Board, ObjectID) -> TerminalStatus)?
    /// Inside tmux, what the active pane of a terminal tile's tmux client runs
    /// (`TerminalName.program`; its shell at that pane's prompt); nil when the tile's foreground
    /// program isn't tmux or tmux doesn't say.
    public var tmuxPane: ((Board, ObjectID) async -> String?)?
    /// A browser tile's page as `object.get` reports it (`PageReport`): its visibility, what it
    /// reported since it loaded, and the log of the page easl last released; nil without the tile.
    public var pageReport: ((Board, ObjectID) async -> PageReport?)?
    /// A note tile's anchored fences resolved against disk now, with the text it captured, by
    /// fence key (the tile shows them too); nil without the tile, and `object.get` resolves them
    /// itself.
    public var noteExcerpts: ((Board, ObjectID) async -> [String: NoteExcerpt]?)?
    /// A code tile's range resolved against disk now with the text the tile last found there
    /// (it may re-anchor the range first); nil without the tile, and `object.get` resolves the
    /// range by `props.anchor` alone.
    public var codeRangeStatus: ((Board, ObjectID) async -> NoteExcerpt?)?
    /// Reloads a browser tile's page as its reload button does (a failed load is retried),
    /// crediting what follows to the terminal given, and waits up to `timeoutMs` for it to load:
    /// its `url`, whether it `loaded` in time, and a load failure's reason (`failed`).
    public var reloadBrowser: ((Board, ObjectID, _ caller: ObjectID?, _ timeoutMs: Int) async throws -> JSONValue)?
    /// Computes a diagram tile's graph afresh from the code (`DiagramRefresh`): its
    /// `DiagramRefresh.summary` once done. The router bounds the wait (`computeDiagram`).
    public var refreshDiagram: ((Board, ObjectID) async throws -> JSONValue)?
    /// Opens a directory's board in the UI (a tab of the frontmost board window), selecting its tab when asked.
    public var openBoard: ((URL, _ select: Bool) -> Board)?
    public static let schemaVersion = 1
    static let readLinesDefault = 100
    static let readLinesMax = 2000
    /// How much of a terminal `agent.prompt` remembers from just before it submits: enough to
    /// cover the screen the reply is compared against (`agent.read` `since: "prompt"`).
    static let promptMarkLines = 400

    /// Terminals prompted through the API that have not yet reported work, with when each was
    /// prompted: `agent.wait` must not answer from the pre-prompt state (`promptStartGrace`).
    private var pendingPrompts: [ObjectID: Date] = [:]
    /// Each prompted terminal's text just before its last `agent.prompt` submitted.
    private var promptMarks: [ObjectID: TerminalTail.Tail] = [:]
    private var waiters: [Waiter] = []
    /// Which connection holds each message `agent.inbox` handed out and its integration hasn't
    /// acked yet: offered again once that connection closes.
    private var messageHolds: [String: SocketServer.Connection] = [:]
    /// `agent.inbox` long polls waiting for a message to their terminal.
    private var inboxWaiters: [InboxWaiter] = []

    private struct InboxWaiter {
        let token = UUID()
        let id: JSONValue
        let connection: SocketServer.Connection
        let tile: ObjectID
    }

    private struct Waiter {
        let token = UUID()
        let id: JSONValue
        let connection: SocketServer.Connection
        let tile: ObjectID
        let until: Set<String>
        /// Until when a terminal that hasn't reported a lifecycle may still start to.
        let firstReportDeadline: Date
    }

    /// How long `agent.wait` gives a terminal with no lifecycle to start reporting one: an agent
    /// launched a moment ago (a tile just created with `omp`) reports within seconds, a shell never.
    public var firstReportGrace: TimeInterval = 15
    /// How long `agent.wait` gives a prompt sent by `agent.prompt` to start the agent's turn
    /// (`working` or `blocked`): the integrations report within a second, but a `/` command or `!`
    /// escape is no turn, and text the agent didn't take as a prompt starts none.
    public var promptStartGrace: TimeInterval = 60

    public init(registry: BoardRegistry) {
        self.registry = registry
        registry.routerHook = { [weak self] board, event in self?.observe(event, on: board) }
        registry.messagesBounced = { [weak self] board, bounce in self?.bounce(bounce, on: board) }
    }

    /// Entry point for SocketServer. Returns the response line, or nil when the reply is deferred
    /// (agent.wait) or the connection became an event stream.
    public func handle(_ request: JSONValue, connection: SocketServer.Connection) async -> JSONValue? {
        let id = request["id"] ?? .null
        guard let method = request["method"]?.string else {
            return Self.error(id, Failure("invalid_params", "missing method"))
        }
        ApiActivity.shared.began(method)
        defer { ApiActivity.shared.ended(method) }
        let params = request["params"] ?? .object([:])
        do {
            try Self.checkParams(method, params)
            if method == "events.subscribe" {
                registry.subscribe(connection, board: params["board"]?.string.map { registry.board(id: $0)?.id ?? $0 }, events: params["events"]?.array?.compactMap(\.string))
                connection.send(.object(["id": id, "ok": .bool(true), "result": .object([:])]))
                return nil
            }
            if method == "agent.wait" { return try wait(id, params, connection) }
            if method == "agent.inbox" { return try await inbox(id, params, connection) }
            if method == "agent.read" { return Self.ok(id, try await read(params)) }
            if method == "agent.prompt" { return Self.ok(id, try await prompt(params)) }
            if method == "view.render" { return Self.ok(id, try await render(params)) }
            if method == "view.snapshot" { return Self.ok(id, try await snapshot(params)) }
            if method == "tray.drain" { return Self.ok(id, try await drain(params)) }
            if method == "object.get" { return Self.ok(id, try await get(params)) }
            if method == "object.find" { return Self.ok(id, try await find(params)) }
            switch method {
            case "object.measure": return Self.ok(id, try await measure(params))
            case "object.reload": return Self.ok(id, try await reload(params))
            case "object.batch": return Self.ok(id, try await batch(params))
            case "layout.check": return Self.ok(id, try await check(params))
            case "object.create", "object.update", "object.upsert":
                // An upsert is the create or update it is on the board now; `created` says which.
                let upsert = method == "object.upsert"
                let (method, resolved) = upsert ? try upserted(params) : (method, params)
                let params = try await anchored(method, try await referenced(method, try inCallersCheckout(method, resolved)))
                // A keyed tile is its own: a create that gives a key never takes over another.
                if method == "object.create", Board.key(params["props"] ?? .null) == nil, let reused = try reusableChanges(params) {
                    let size = try await fitSize("object.update", reused)
                    let result = try dispatch("object.update", try fitted("object.update", reused, size: size)).merging(.object(["reused": .bool(true)]))
                    return Self.ok(id, size == nil ? result : withOverlaps(result))
                }
                if method == "object.create", let result = try await createFittedDiagram(params) {
                    return Self.ok(id, upsert ? result.merging(.object(["created": .bool(true)])) : result)
                }
                let size = try await fitSize(method, params)
                // A frame given outright (a browser tile resized to a desktop viewport) that now
                // covers objects it didn't says so, as a refit does.
                let covered = method == "object.update" && size == nil && params["frame"] != nil
                    ? params["id"]?.string.flatMap { id in (try? board(forObject: id)).map { Set($0.overlaps(of: id)) } } : nil
                var result = try dispatch(method, try fitted(method, params, size: size))
                if size != nil || covered != nil { result = withOverlaps(result, beyond: covered ?? []) }
                return Self.ok(id, upsert ? result.merging(.object(["created": .bool(method == "object.create")])) : result)
            default: break
            }
            return Self.ok(id, try dispatch(method, params))
        } catch let failure as Failure {
            return Self.error(id, failure)
        } catch let error as BoardError {
            switch error {
            case .notFound(let message): return Self.error(id, Failure("not_found", message))
            case .conflict(let message): return Self.error(id, Failure("conflict", message))
            case .invalidParams(let message): return Self.error(id, Failure("invalid_params", message))
            }
        } catch let failure as ObjectMeasure.Failure {
            switch failure {
            case .unsupported(let message): return Self.error(id, Failure("unsupported", message))
            case .unavailable(let message): return Self.error(id, Failure("unavailable", message))
            case .notFound(let message): return Self.error(id, Failure("not_found", message))
            case .invalidParams(let message): return Self.error(id, Failure("invalid_params", message))
            }
        } catch {
            return Self.error(id, Failure("invalid_params", String(describing: error)))
        }
    }

    static func ok(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["id": id, "ok": .bool(true), "result": result])
    }

    static func error(_ id: JSONValue, _ failure: Failure) -> JSONValue {
        .object(["id": id, "ok": .bool(false), "error": .object(["code": .string(failure.code), "message": .string(failure.message)])])
    }

    /// Rejects a param the method's schema doesn't list and a required one that is missing,
    /// naming what the method accepts (`ApiParams`, generated from the schema), so a caller
    /// that guessed (`delta` for `dx`/`dy`) can correct itself from the error alone.
    static func checkParams(_ method: String, _ params: JSONValue) throws {
        guard let spec = ApiParams.methods[method], let given = params.object else { return }
        let unknown = given.keys.filter { !spec.accepted.contains($0) }.sorted()
        let missing = spec.required.filter { given[$0] == nil || given[$0] == .null }
        guard !unknown.isEmpty || !missing.isEmpty else { return }
        var problems: [String] = []
        if !unknown.isEmpty { problems.append("unknown param\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", "))") }
        if !missing.isEmpty { problems.append("missing \(missing.joined(separator: ", "))") }
        let accepted = spec.accepted.isEmpty ? "no params" : spec.accepted.map { spec.required.contains($0) ? "\($0) (required)" : $0 }.joined(separator: ", ")
        throw Failure("invalid_params", "\(problems.joined(separator: "; ")); \(method) takes \(accepted)")
    }

    /// A result with `warnings` (unknown props) when there are any.
    static func withWarnings(_ result: [String: JSONValue], _ warnings: [String]) -> JSONValue {
        var result = result
        if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }
        return .object(result)
    }

    // MARK: agent.wait

    private func wait(_ id: JSONValue, _ p: JSONValue, _ connection: SocketServer.Connection) throws -> JSONValue? {
        let (board, terminal) = try agentTile(try string(p, "target"), caller: p["caller"]?.string)
        let until = try waitStates(p["until"])
        let waiter = Waiter(id: id, connection: connection, tile: terminal.id, until: until, firstReportDeadline: Date().addingTimeInterval(firstReportGrace))
        if let reply = reply(to: waiter, on: board) { return reply }
        waiters.append(waiter)
        let token = waiter.token
        if let timeout = p["timeoutMs"]?.int {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, timeout))) { [weak self] in
                MainActor.assumeIsolated { self?.expire(token) }
            }
        }
        // A terminal still silent when the grace ends has nothing reporting in it.
        DispatchQueue.main.asyncAfter(deadline: .now() + firstReportGrace) { [weak self] in
            MainActor.assumeIsolated { self?.recheck(token) }
        }
        // A prompt that hasn't started its turn when its grace ends never will.
        if let prompted = pendingPrompts[terminal.id] { recheck(token, at: prompted.addingTimeInterval(promptStartGrace)) }
        return nil
    }

    /// `agent.wait`'s `until`: an array of lifecycle states, by default the ones a turn ends in.
    /// Anything else fails rather than falling back to the default.
    private func waitStates(_ value: JSONValue?) throws -> Set<String> {
        guard let value, value != .null else { return ["idle", "done", "blocked"] }
        let states: Set<String> = ["working", "blocked", "idle", "done", "unknown"]
        guard let items = value.array else { throw Failure("invalid_params", "until must be an array of states, e.g. [\"working\"]") }
        return Set(try items.map { item in
            guard let state = item.string, states.contains(state) else {
                throw Failure("invalid_params", "unknown state \(item) in until; one of \(states.sorted().joined(separator: ", "))")
            }
            return state
        })
    }

    /// The response for a satisfied waiter, or nil while it must keep waiting. A terminal with no
    /// lifecycle gets `firstReportGrace` to start reporting; one whose agent exited (`exited`, a
    /// release; or its message integration died, `Board.agentExited`) or that stays silent can
    /// never satisfy it. An agent reporting by notification (`NotifyingAgent`) at `unknown`
    /// waits for its next notification.
    private func reply(to waiter: Waiter, on board: Board, exited: Bool = false) -> JSONValue? {
        guard let terminal = board.objects[waiter.tile] else {
            return Self.error(waiter.id, Failure("not_found", "terminal \(waiter.tile) was closed"))
        }
        let state = Self.state(of: terminal)
        if state == LifecycleState.unknown.rawValue, !waiter.until.contains(state) {
            if !exited, NotifyingAgent.reports(terminal) { return nil }
            guard exited || Date() >= waiter.firstReportDeadline else { return nil }
            return Self.error(waiter.id, Self.lifecycleUnknown(terminal))
        }
        if board.agentExited(waiter.tile) { return Self.error(waiter.id, Self.agentExited(terminal)) }
        // A message the terminal's integration hasn't delivered yet: its turn hasn't started.
        if board.messages[waiter.tile]?.isEmpty == false { return nil }
        if let prompted = pendingPrompts[waiter.tile] {
            guard Date().timeIntervalSince(prompted) >= promptStartGrace else { return nil }
            return Self.error(waiter.id, Failure("unavailable", "\(terminal.id)'s last agent.prompt started no turn within \(promptStartGrace.formatted()) s "
                + "(its agent reported neither working nor blocked: a / command or ! escape is no turn, or the agent didn't take the text as a prompt), "
                + "so agent.wait can't tell when it is done; read what followed with agent.read since: \"prompt\""))
        }
        guard waiter.until.contains(state) else { return nil }
        return Self.ok(waiter.id, .object(["agent": agentEntry(terminal, on: board)]))
    }

    /// An integration that took messages died without its release (`Board.agentExited`).
    static func agentExited(_ terminal: CanvasObject) -> Failure {
        let kind = terminal.props["agent"]?["kind"]?.string.map { " (\($0))" } ?? ""
        return Failure("unavailable", "\(terminal.id)'s agent\(kind) exited without releasing the terminal (killed or crashed: its shell is back at the prompt), "
            + "so nothing there takes a prompt; what was queued for it bounced")
    }

    static func lifecycleUnknown(_ terminal: CanvasObject) -> Failure {
        Failure("unavailable", "terminal \(terminal.id) reports no agent lifecycle (nothing in it has an easl integration, or its agent exited), "
            + "so agent.wait can't tell when it is done; poll agent.read with since: \"prompt\" instead")
    }

    private func observe(_ event: BoardEvent, on board: Board) {
        let tile: ObjectID
        var exited = false
        switch event {
        case .agentLifecycle(let id, let lifecycle):
            tile = id
            exited = lifecycle == .null
            let state = lifecycle["state"]?.string
            if exited || state == LifecycleState.working.rawValue || state == LifecycleState.blocked.rawValue {
                pendingPrompts.removeValue(forKey: id)
            }
        case .objectDeleted(let id):
            tile = id
            pendingPrompts.removeValue(forKey: id)
            promptMarks.removeValue(forKey: id)
        default:
            return
        }
        waiters.removeAll { waiter in
            guard waiter.connection.isOpen else { return true }
            guard waiter.tile == tile, let reply = reply(to: waiter, on: board, exited: exited) else { return false }
            waiter.connection.send(reply)
            return true
        }
    }

    /// Answers the waiter if it is satisfied now. One left waiting on a prompt's turn looks again
    /// when that prompt's grace ends: a later prompt to the same terminal moves the grace on.
    private func recheck(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters[index]
        guard let (board, _) = try? agentTile(waiter.tile) else { return }
        guard let reply = reply(to: waiter, on: board) else {
            if let prompted = pendingPrompts[waiter.tile] { recheck(token, at: prompted.addingTimeInterval(promptStartGrace)) }
            return
        }
        waiters.remove(at: index)
        waiter.connection.send(reply)
    }

    private func recheck(_ token: UUID, at date: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow)) { [weak self] in
            MainActor.assumeIsolated { self?.recheck(token) }
        }
    }

    private func expire(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.connection.send(Self.error(waiter.id, Failure("timeout", "\(waiter.tile) did not reach \(waiter.until.sorted().joined(separator: "|")) in time")))
    }

    // MARK: Agents

    static func state(of terminal: CanvasObject) -> String {
        terminal.props["lifecycle"]?["state"]?.string ?? LifecycleState.unknown.rawValue
    }

    /// The terminal `target` addresses (AgentAddress: a tile id, `name` or `name@board`) on the
    /// open boards; a bare name on `caller`'s board first.
    func agentTile(_ target: String, caller: ObjectID? = nil) throws -> (Board, CanvasObject) {
        try AgentAddress.resolve(target, caller: caller, boards: Array(registry.boards.values))
    }

    func agentEntry(_ terminal: CanvasObject, on board: Board) -> JSONValue {
        let agent = terminal.props["agent"]
        let status = terminalStatus?(board, terminal.id)
        let aliases = board.aliases(of: terminal.id)
        let entry: [String: JSONValue] = [
            "tile": .string(terminal.id), "board": .string(board.id), "root": .string(board.root.path),
            "address": .string(AgentAddress.address(of: terminal, on: board, among: Array(registry.boards.values))),
            "kind": agent?["kind"] ?? .string("unknown"),
            "name": terminal.props["name"] ?? .null,
            "aliases": aliases.isEmpty ? .null : .array(aliases.map(JSONValue.string)),
            "protocol": agent?["protocol"] ?? .null,
            "title": status?.title.map(JSONValue.string) ?? .null,
            "program": status?.program.map(JSONValue.string) ?? .null,
            "sessionId": agent?["sessionId"] ?? .null,
            "lifecycle": terminal.props["lifecycle"] ?? .object(["state": .string(LifecycleState.unknown.rawValue)]),
            "lastCommand": status?.lastCommand.map { $0.command.json(finishedAt: $0.finishedAt) } ?? .null,
        ]
        return .object(entry.filter { $0.value != .null })
    }

    /// `agent.read`: the tail of the session text, or with `since: "prompt"` what the terminal
    /// printed after the last `agent.prompt` to it, with `block` the output of a command its
    /// shell finished (`"last"` or -1, -2 the one before), or with `final` its agent's last
    /// answer as its integration reported it. The read runs off the main actor (it spawns
    /// `zmx history`), and the reply stays in order because each connection is served serially.
    private func read(_ p: JSONValue) async throws -> JSONValue {
        let (board, terminal) = try agentTile(try string(p, "target"), caller: p["caller"]?.string)
        if p["final"]?.bool == true { return try finalAnswer(of: terminal, on: board, p) }
        let since = p["since"]?.string
        guard since == nil || since == "prompt" else { throw Failure("invalid_params", "since must be \"prompt\"") }
        var block: Int?
        if let value = p["block"], value != .null {
            if value.string == "last" {
                block = -1
            } else if let number = value.number, number <= -1, number == number.rounded(), number >= -Double(TerminalCommandLog.capacity) {
                block = Int(number)
            } else {
                throw Failure("invalid_params", "block must be \"last\" or a whole number from -1 (the last command) to -\(TerminalCommandLog.capacity): -2 is the one before the last")
            }
        }
        guard block == nil || since == nil else { throw Failure("invalid_params", "since and block don't combine: block reads a command's output, since the reply to the last agent.prompt") }
        let requested = p["lines"]?.int ?? (since == nil && block == nil ? Self.readLinesDefault : Self.readLinesMax)
        guard requested >= 1 else { throw Failure("invalid_params", "lines must be at least 1") }
        if let block { return try await readBlock(board, terminal, block, lines: min(requested, Self.readLinesMax)) }
        guard let readTerminal else { throw Failure("unsupported", "reading terminals needs the app UI") }
        var mark: TerminalTail.Tail?
        if since != nil {
            guard let found = promptMarks[terminal.id] else {
                throw Failure("not_found", "no agent.prompt has reached terminal \(terminal.id) since easl started; read with lines instead")
            }
            mark = found
        }
        // A reply is compared against the screen it followed, so it reads the most there is.
        guard let tail = await readTerminal(board, terminal.id, mark == nil ? min(requested, Self.readLinesMax) : Self.readLinesMax) else {
            throw Failure("unavailable", "terminal \(terminal.id) has no running session")
        }
        var result: [String: JSONValue] = [:]
        var shown = tail
        if let mark {
            let boundary = tail.boundary(after: mark)
            let reply = tail.rows(from: boundary)
            shown = reply.suffix(min(requested, Self.readLinesMax))
            // Cut by `lines`, or the reply is longer than the tail reaches.
            result["truncated"] = .bool(shown.lines < reply.lines || (tail.positions.first ?? 0) > boundary)
        }
        let current = board.objects[terminal.id] ?? terminal
        result["agent"] = agentEntry(current, on: board)
        result["text"] = .string(shown.text)
        result["lines"] = .number(Double(shown.lines))
        return .object(result)
    }

    /// `agent.read` `block`: a finished command's output (its last `lines` lines) with what ran,
    /// its exit status and duration.
    private func readBlock(_ board: Board, _ terminal: CanvasObject, _ index: Int, lines limit: Int) async throws -> JSONValue {
        guard let readTerminalBlock else { throw Failure("unsupported", "reading terminals needs the app UI") }
        let block = try await readTerminalBlock(board, terminal.id, index)
        let output = TerminalExcerpt.lines(block.output)
        let shown = output.suffix(limit)
        var result: [String: JSONValue] = [
            "text": .string(shown.joined(separator: "\n")),
            "lines": .number(Double(shown.count)),
            "command": block.command.json(),
        ]
        if shown.count < output.count { result["truncated"] = .bool(true) }
        result["agent"] = agentEntry(board.objects[terminal.id] ?? terminal, on: board)
        return .object(result)
    }

    /// `agent.prompt`: to a terminal whose integration takes messages (`PromptTarget.takesMessages`)
    /// it queues an out-of-band message (`queueMessage`); to any other it remembers the
    /// terminal's text as it is just before submitting (the reply boundary for `agent.read`
    /// `since: "prompt"`), then pastes and presses Enter. From then on `agent.wait` ignores the
    /// state the agent was in before this prompt, unless the agent was in its turn (`working`):
    /// the prompt joins that turn, whose end answers it. A `blocked` agent is refused unless
    /// `force`: its screen holds a dialog or selector, which would take the text. A terminal whose
    /// message integration died (`Board.agentExited`) takes neither: `unavailable`.
    private func prompt(_ p: JSONValue) async throws -> JSONValue {
        try Self.checkComposer(p)
        let caller = p["caller"]?.string
        let (board, resolved) = try agentTile(try string(p, "target"), caller: caller)
        let text = try string(p, "text")
        let mentions = p["mentions"]?.array ?? []
        if p["composer"]?.bool == true {
            // A composer in another app (a remote board's viewer): what this app's composer sends.
            let answer = p["answer"]?.bool == true
            let given: [Mention] = answer ? [] : try mentions.map { json in
                let target = try HandoffMention(json: json).target(on: board)
                return Mention(id: IDs.make("men"), target: target, label: MentionContext.label(for: target, on: board), stagedAt: Date())
            }
            return try await submitPrompt(text, to: resolved, on: board, attached: .composer(given, answer: answer), caller: nil, force: false)
        }
        let when: AgentMessage.When
        switch p["when"] {
        case nil, .null?: when = .now
        case let value?:
            guard let parsed = value.string.flatMap(AgentMessage.When.init(rawValue:)) else { throw Failure("invalid_params", "when is \"now\" (the default) or \"next-turn\"") }
            when = parsed
        }
        var label: String?
        if let value = p["from"], value != .null {
            guard let text = value.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure("invalid_params", "from is a sender label such as \"machine-watch\"") }
            label = text
        }
        // The foreground program now: a message integration killed since it last reported is
        // found here (`Board.terminalProgram`), before anything is queued for it.
        _ = terminalStatus?(board, resolved.id)
        guard let terminal = board.objects[resolved.id] else { throw Failure("not_found", "terminal \(resolved.id) was closed") }
        if board.agentExited(terminal.id) { throw Self.agentExited(terminal) }
        if PromptTarget.takesMessages(terminal) {
            return try await queueMessage(text, to: terminal, on: board, mentions: mentions, caller: caller, label: label, when: when)
        }
        if when == .nextTurn, Self.state(of: terminal) == LifecycleState.working.rawValue {
            throw Failure("conflict", "\(terminal.id) is in its turn and its integration takes no messages, so typed text would join that turn; agent.wait for it and send again, or send with when: \"now\"")
        }
        return try await submitPrompt(text, to: terminal, on: board, attached: .agent { try mentions.map { try HandoffMention(json: $0).target(on: board) } },
                                      caller: caller, force: p["force"]?.bool == true)
    }

    /// An out-of-band `agent.prompt` (docs/contracts.md, Peer messages): queued for `terminal`,
    /// whose integration takes it with `agent.inbox`; nothing is typed, so none of typing's
    /// refusals apply. From a terminal (`caller`, honored when it is a terminal on an open
    /// board) the message is the agent's; with a `label` (`from`) or none, the user's. It is
    /// queued for the agent session there when the prompt arrived: one that ended while the
    /// terminal's text was read (released, died, replaced: `Board.agentSession(of:)`) gets
    /// nothing, and the sender `unavailable`.
    private func queueMessage(_ text: String, to terminal: CanvasObject, on board: Board, mentions: [JSONValue], caller: ObjectID?, label: String?, when: AgentMessage.When) async throws -> JSONValue {
        let attached = try board.messageMentions(try mentions.map { try HandoffMention(json: $0).target(on: board) })
        let sender = caller.flatMap { caller in registry.boards.values.contains { $0.objects[caller]?.type == .terminal } ? caller : nil }
        let session = board.agentSession(of: terminal.id)
        let before = await readTerminal?(board, terminal.id, Self.promptMarkLines)
        guard let current = board.objects[terminal.id] else { throw Failure("not_found", "terminal \(terminal.id) was closed") }
        if board.agentExited(terminal.id) { throw Self.agentExited(current) }
        guard PromptTarget.takesMessages(current), board.agentSession(of: terminal.id) == session else {
            throw Failure("unavailable", "\(terminal.id)'s agent session ended while the message was being sent (its agent was released, exited, "
                + "or another session took the terminal), so nothing was queued; agent.list shows what runs there now")
        }
        let message = AgentMessage(text: text, from: sender, label: label, when: when, mentions: attached)
        try board.queueMessage(message, to: terminal.id)
        promptMarks[terminal.id] = before ?? TerminalTail.Tail(rows: [], positions: [])
        serveInbox(terminal.id, on: board)
        var result: [String: JSONValue] = [
            "agent": agentEntry(current, on: board),
            "submittedAt": .string(message.queuedAt.formatted(.iso8601)),
            "waitable": .bool(true),
            "delivery": .string("message"),
            "message": .string(message.id),
        ]
        if !attached.isEmpty { result["mentions"] = try JSONValue.encode(attached) }
        return .object(result)
    }

    /// `agent.inbox`: a terminal's integration acks what it delivered, then takes what waits
    /// for it (held by this connection until acked, offered again once it closes), or waits up
    /// to `waitMs` for a message.
    private func inbox(_ id: JSONValue, _ p: JSONValue, _ connection: SocketServer.Connection) async throws -> JSONValue? {
        let tile = try string(p, "tile")
        let board = try board(forObject: tile)
        guard board.objects[tile]?.type == .terminal else { throw Failure("invalid_params", "\(tile) is not a terminal tile") }
        let waitMs = p["waitMs"]?.int ?? 0
        guard (0...60_000).contains(waitMs) else { throw Failure("invalid_params", "waitMs is from 0 to 60000") }
        messageHolds = messageHolds.filter { $0.value.isOpen }
        let ack = p["ack"]?.array?.compactMap(\.string) ?? []
        if !ack.isEmpty {
            for message in ack { messageHolds.removeValue(forKey: message) }
            if !board.ackMessages(ack, of: tile).isEmpty { messagesDelivered(to: tile, on: board, started: p["started"]?.bool == true) }
        }
        let offered = offer(tile, on: board, to: connection)
        guard offered.isEmpty, waitMs > 0 else { return Self.ok(id, try await inboxResult(offered, to: tile, on: board)) }
        let waiter = InboxWaiter(id: id, connection: connection, tile: tile)
        inboxWaiters.append(waiter)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(waitMs)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let index = self.inboxWaiters.firstIndex(where: { $0.token == waiter.token }) else { return }
                self.inboxWaiters.remove(at: index)
                waiter.connection.send(Self.ok(waiter.id, .object(["messages": .array([])])))
            }
        }
        return nil
    }

    /// The messages for `tile` no open connection holds, now held by `connection`.
    private func offer(_ tile: ObjectID, on board: Board, to connection: SocketServer.Connection) -> [AgentMessage] {
        let free = (board.messages[tile] ?? []).filter { messageHolds[$0.id]?.isOpen != true }
        for message in free { messageHolds[message.id] = connection }
        return free
    }

    private func inboxResult(_ messages: [AgentMessage], to tile: ObjectID, on board: Board) async throws -> JSONValue {
        var rendered: [JSONValue] = []
        for message in messages { rendered.append(await board.delivered(message, to: tile, boards: Array(registry.boards.values))) }
        return .object(["messages": .array(rendered)])
    }

    /// A message reached `tile`'s queue: the oldest open long poll for it takes it.
    private func serveInbox(_ tile: ObjectID, on board: Board) {
        inboxWaiters.removeAll { !$0.connection.isOpen }
        guard let index = inboxWaiters.firstIndex(where: { $0.tile == tile }) else { return }
        let waiter = inboxWaiters.remove(at: index)
        let offered = offer(tile, on: board, to: waiter.connection)
        Task { @MainActor in
            let result = (try? await inboxResult(offered, to: tile, on: board)) ?? .object(["messages": .array([])])
            waiter.connection.send(Self.ok(waiter.id, result))
        }
    }

    /// `tile`'s integration delivered messages. One that started a new turn (`started`) is
    /// waited on as a prompt to an idle agent is, unless that turn already reported; one that
    /// joined the running turn ends with it.
    private func messagesDelivered(to tile: ObjectID, on board: Board, started: Bool) {
        guard let terminal = board.objects[tile] else { return }
        let state = Self.state(of: terminal)
        if started, state != LifecycleState.working.rawValue, state != LifecycleState.blocked.rawValue, state != LifecycleState.unknown.rawValue {
            pendingPrompts[tile] = Date()
        }
        for waiter in waiters where waiter.tile == tile { recheck(waiter.token) }
    }

    /// `agent.prompt`'s `composer` and `answer`, checked before the target: only the user answers
    /// (`answer` needs `composer`), and the composer's prompt is the user's (no `caller`, no `force`).
    static func checkComposer(_ p: JSONValue) throws {
        let composer = p["composer"]?.bool == true
        if p["answer"]?.bool == true, !composer {
            throw Failure("invalid_params", "answer is the user's answer from a composer: it needs composer: true (an agent or script sends force: true instead)")
        }
        guard composer else { return }
        if p["caller"].map({ $0 != .null }) == true { throw Failure("invalid_params", "a composer's prompt is the user's: it takes no caller") }
        if p["force"]?.bool == true { throw Failure("invalid_params", "a composer's prompt never forces: answer: true answers a blocked target") }
    }

    /// Messages whose receiver's agent session ended before its integration took them
    /// (`Board.endAgentSession`): never dropped silently. Each goes back to a sending terminal
    /// whose integration takes messages, as a message from easl ("undelivered to bob@canvas: its
    /// first line…"); a script's, or one whose sender takes no messages or has closed, is logged
    /// in the receiver's board.history (`message`). Waits on the receiver look again.
    private func bounce(_ bounce: MessageBounce, on board: Board) {
        let boards = Array(registry.boards.values)
        let receiver = board.objects[bounce.tile].map { AgentAddress.address(of: $0, on: board, among: boards) }
            ?? bounce.name.map { "\($0)@\(AgentAddress.boardName(board.root))" } ?? bounce.tile
        for message in bounce.messages {
            messageHolds.removeValue(forKey: message.id)
            let notice = "undelivered to \(receiver): \(message.gist)"
            let home = message.from.flatMap { registry.board(containing: $0) }
            if let sender = message.from, let home, let tile = home.objects[sender], PromptTarget.takesMessages(tile),
               (try? home.queueMessage(AgentMessage(text: notice, from: nil, label: AgentMessage.bounceSender, when: .now, mentions: []), to: sender)) != nil {
                serveInbox(sender, on: home)
                continue
            }
            let from = message.label ?? message.from.map { sender in
                home.flatMap { home in home.objects[sender].map { AgentAddress.address(of: $0, on: home, among: boards) } } ?? sender
            } ?? AgentMessage.scriptName
            board.activity.record(.message, actor: .system, rev: board.revision, id: bounce.tile, type: .terminal, summary: "\(notice) (from \(from))")
        }
        for waiter in waiters where waiter.tile == bounce.tile { recheck(waiter.token) }
    }

    /// What goes with a prompt: an agent's `mentions` (`Board.handOff`), or the composer's.
    private enum Attached {
        case agent(() throws -> [MentionTarget])
        case composer([Mention], answer: Bool)
    }

    /// The composer's send to one terminal (docs/design.md, Composer): `agent.prompt` from the
    /// user, with every check it makes. For a terminal whose integration drains, a prompt with
    /// mentions is queued with its own copies of them (`Board.queueComposerPrompt`): the
    /// integration's submission drain of that text (`Board.drain`, compared folded) takes them,
    /// numbered from 1, and never the tray. A prompt without mentions queues nothing and drains
    /// as any prompt does. A text the integration doesn't drain for (`PromptTarget.skipsDrain`)
    /// queues nothing and takes no mentions. `answer`: the agent is blocked on a question or
    /// approval and the text is the user's answer, which only the user gives: it passes the
    /// blocked check alone, unlike `force`, carries no mentions, and is queued as an answer only
    /// where the integration submits answers as prompts (`PromptTarget.answersAsPrompt`).
    public func composerPrompt(_ text: String, to terminal: ObjectID, on board: Board, mentions: [Mention], answer: Bool) async throws {
        guard let tile = board.objects[terminal], tile.type == .terminal else { throw Failure("not_found", "terminal \(terminal) was closed") }
        _ = try await submitPrompt(text, to: tile, on: board, attached: .composer(answer ? [] : mentions, answer: answer), caller: nil, force: false)
    }

    private func submitPrompt(_ text: String, to terminal: CanvasObject, on board: Board, attached: Attached, caller sender: ObjectID?, force: Bool) async throws -> JSONValue {
        let answering: Bool
        if case .composer(_, let answer) = attached { answering = answer } else { answering = false }
        if Self.state(of: terminal) == LifecycleState.blocked.rawValue, !force, !answering {
            let blocker = terminal.props["lifecycle"]?["message"]?.string.map { " (“\($0)”)" } ?? ""
            throw Failure("conflict", "\(terminal.id) is blocked, waiting on its user\(blocker): the prompt would go into that dialog. Leave it to the user. force: true types into the dialog and presses Return, which in an approval menu picks the highlighted option (usually allow), so never force an answer to an approval")
        }
        // `working` saved before easl last closed, with no report since (an agent whose
        // integration predates the spool, or that ended meanwhile): it may be sitting in a
        // question or approval now, which the text and Return would answer.
        if Self.state(of: terminal) == LifecycleState.working.rawValue, terminal.props["lifecycle"]?["restored"]?.bool == true, !force {
            throw Failure("conflict", "\(terminal.id) was working when easl last closed and its agent hasn't reported since, so it may now wait on a question or approval that the prompt would answer. Read its screen (agent.read) first; force: true sends anyway")
        }
        // An agent reporting from inside tmux (or an editor it started) isn't what the typing
        // reaches, unless it runs in tmux's active pane.
        if PromptTarget.runsAgent(terminal), !force {
            let kind = terminal.props["agent"]?["kind"]?.string
            if let program = PromptTarget.foreignProgram(kind: kind, program: terminalStatus?(board, terminal.id).program) {
                let pane = await tmuxPane?(board, terminal.id)
                if let pane, let other = PromptTarget.foreignProgram(kind: kind, program: pane) {
                    throw Failure("conflict", "\(terminal.id)'s foreground program is \(program), whose active pane runs \(other), not \(kind ?? "the agent"): the text would go to \(other). Leave it to the user, or once the agent's pane is active send again; force: true sends it anyway")
                } else if pane == nil {
                    throw Failure("conflict", "\(terminal.id)'s foreground program is \(program), not \(kind ?? "the agent"): the text would go to it (in tmux, to whichever pane is active); force: true sends it anyway")
                }
            }
        }
        guard let submitToTerminal else { throw Failure("unsupported", "prompting needs the app UI") }
        let mentions: [MentionTarget]
        switch attached {
        case .agent(let parse): mentions = try parse()
        case .composer(let given, _): mentions = given.map(\.target)
        }
        if !mentions.isEmpty, !PromptTarget.drains(terminal) {
            throw Failure("unavailable", "\(terminal.id) runs no agent with an easl integration, so nothing there would take the mentions; name the objects in the text instead")
        }
        if case .composer(let given, _) = attached, !given.isEmpty, PromptTarget.skipsDrain(text, in: terminal) {
            throw Failure("invalid_params", "a slash command or shell escape takes no mentions: its agent drains nothing for it")
        }
        let before = await readTerminal?(board, terminal.id, Self.promptMarkLines)
        guard let current = board.objects[terminal.id] else { throw Failure("not_found", "terminal \(terminal.id) was closed") }
        // Queued before the text goes in: the target's integration drains them with this prompt.
        var handed: [Mention] = []
        var queued: String?
        switch attached {
        case .agent:
            let senderName = sender.flatMap { try? agentTile($0) }.map { PromptTarget.label($0.1, shownTitle: terminalStatus?($0.0, $0.1.id).title) }
            handed = try board.handOff(mentions, to: terminal.id, from: sender, fromName: senderName)
        case .composer(let given, let answer):
            if PromptTarget.drains(current), !PromptTarget.skipsDrain(text, in: current), answer ? PromptTarget.answersAsPrompt(current) : !given.isEmpty {
                queued = board.queueComposerPrompt(text, to: terminal.id, mentions: given, answer: answer)
            }
        }
        guard await submitToTerminal(board, terminal.id, text) else {
            board.commit(handed.map { $0.id })
            if let queued { board.withdrawComposerPrompt(queued) }
            throw Failure("unavailable", "terminal \(terminal.id) has no attached surface")
        }
        // Only a reporting agent's next report can end the pre-prompt state. An agent reporting
        // by notification is `unknown` from now until its next one (`NotifyingAgent`). An agent
        // still in its turn as the text lands takes it into that turn (omp as a steering message
        // before the turn ends; Codex before its next tool call, or right after its last answer,
        // with one Stop for both): no report may come until that turn ends, which answers it.
        let notifying = NotifyingAgent.reports(current)
        let waitable = notifying || Self.state(of: current) != LifecycleState.unknown.rawValue
        let midTurn = board.objects[terminal.id].map(Self.state) == LifecycleState.working.rawValue
        if notifying { board.notifyingAgentSubmitted(terminal.id) } else if waitable, !midTurn { pendingPrompts[terminal.id] = Date() }
        promptMarks[terminal.id] = before ?? TerminalTail.Tail(rows: [], positions: [])
        var result: [String: JSONValue] = [
            "agent": agentEntry(current, on: board),
            "submittedAt": .string(Date().formatted(.iso8601)),
            "waitable": .bool(waitable),
            "delivery": .string("typed"),
        ]
        if !handed.isEmpty { result["mentions"] = try JSONValue.encode(handed) }
        return .object(result)
    }

    /// `agent.read` `final`: the answer the terminal's integration reported when its last turn
    /// ended (`Board.finalAnswers`), never its screen.
    private func finalAnswer(of terminal: CanvasObject, on board: Board, _ p: JSONValue) throws -> JSONValue {
        guard p["lines"] == nil, p["since"] == nil else { throw Failure("invalid_params", "final takes no lines or since: it returns the whole last answer") }
        let state = Self.state(of: terminal)
        if pendingPrompts[terminal.id] != nil || board.messages[terminal.id]?.isEmpty == false || state == LifecycleState.working.rawValue || state == LifecycleState.blocked.rawValue {
            throw Failure("unavailable", "\(terminal.id) is still in its turn (\(pendingPrompts[terminal.id] != nil || board.messages[terminal.id]?.isEmpty == false ? "prompted" : state)): agent.wait for it, then read final")
        }
        let cutOff = board.turnErrors[terminal.id]
        guard let answer = board.finalAnswers[terminal.id] else {
            if let cutOff { throw Failure("unavailable", "\(terminal.id)'s last turn ended on an error before any answer: \(cutOff)") }
            throw Failure("unavailable", "no final answer is known for \(terminal.id)'s last turn: its agent (\(terminal.props["agent"]?["kind"]?.string ?? "none reporting")) reported none, or the turn was interrupted. Read the screen with since: \"prompt\" instead")
        }
        return .object([
            "agent": agentEntry(terminal, on: board),
            "text": .string(answer),
            "lines": .number(Double(answer.split(separator: "\n", omittingEmptySubsequences: false).count)),
        ].merging(cutOff.map { ["cutOff": .string($0)] } ?? [:]) { first, _ in first })
    }

    /// `tray.drain`: the tray's mentions go to the terminal the tray shows (the board's prompt
    /// target), so a caller tile gets them only when it is that terminal; any other caller gets
    /// only what agents handed to it (`agent.prompt` `mentions`), and the tray stays as it is.
    /// Without a caller (a script) or a window, anyone drains the tray. A caller's submission
    /// drain (with `prompt`) of a text the composer typed there takes that prompt's own mentions
    /// instead (`Board.drain`).
    private func drain(_ p: JSONValue) async throws -> JSONValue {
        let board = try board(p)
        let caller = p["caller"]?.string
        let state = caller == nil ? nil : viewState?(board)
        let showsTray = state.map { $0.promptTarget == caller } ?? true
        let drained = await board.drain(peek: p["peek"]?.bool ?? false, caller: caller, prompt: p["prompt"]?.string, tray: showsTray)
        var result: [String: JSONValue] = ["mentions": try JSONValue.encode(drained.mentions), "context": .string(drained.context)]
        if !showsTray {
            result["held"] = .number(Double(board.tray.count))
            if let target = state?.promptTarget { result["target"] = .string(target) }
        }
        return .object(result)
    }

    // MARK: Images

    /// `view.render`: parse the target, render offscreen in the app, then deliver the image.
    private func render(_ p: JSONValue) async throws -> JSONValue {
        let inline = p["inline"]?.bool == true
        if inline, p["out"] != nil { throw Failure("invalid_params", "inline returns the image in the reply and out writes it to a file: pass one of them") }
        let board: Board
        let target: RenderTarget
        switch p["target"] {
        case .string(let id)?:
            board = try p["board"] == nil ? self.board(forObject: id) : self.board(p)
            target = .objects([id])
        case .array(let values)?:
            let ids = values.compactMap(\.string)
            guard !ids.isEmpty, ids.count == values.count else { throw Failure("invalid_params", "target list must be object ids") }
            board = try p["board"] == nil ? self.board(forObject: ids[0]) : self.board(p)
            target = .objects(ids)
        case .object?:
            board = try self.board(p)
            let rect = try p["target"]!.decode(Frame.self)
            guard rect.w > 0, rect.h > 0 else { throw Failure("invalid_params", "target rect must have a positive size") }
            target = .rect(rect)
        default:
            throw Failure("invalid_params", "target must be an object id, a list of ids, or a rect {x, y, w, h}")
        }
        if case .objects(let ids) = target {
            for id in ids where board.objects[id] == nil { throw Failure("not_found", "object \(id) is not on board \(board.id)") }
        }
        let scale = p["scale"]?.number ?? 1
        guard (0.1...4).contains(scale) else { throw Failure("invalid_params", "scale must be between 0.1 and 4") }
        let exclude = try RenderExclusion(p["exclude"]?.array ?? [], objects: board.objects)
        let timeout = min(max(p["timeoutMs"]?.int ?? 8000, 0), 60_000)
        let request = RenderRequest(target: target, scale: scale, full: p["full"]?.bool ?? false, exclude: exclude,
                                    padding: max(0, p["padding"]?.number ?? 0), timeout: .milliseconds(timeout))
        let (format, out) = try imageDestination(p, name: "render")
        guard let renderView else { throw Failure("unsupported", "rendering needs the app UI") }
        let output = try await renderView(board, request, format)
        var result = inline ? Self.inlined(output) : try await deliver(output, to: out)
        result["canvasRect"] = RenderMath.json(output.canvasRect)
        result["scale"] = .number(output.scale)
        result["objects"] = .array(output.objects.map(\.json))
        return .object(result)
    }

    /// `view.render` `inline`: the image in the reply, base64, and no file written.
    static func inlined(_ output: RenderOutput) -> [String: JSONValue] {
        [
            "data": .string(output.image.base64EncodedString()), "format": .string(output.format.rawValue),
            "width": .number(Double(output.width)), "height": .number(Double(output.height)),
        ]
    }

    /// `view.snapshot`: the window as shown, with the viewport it shows.
    private func snapshot(_ p: JSONValue) async throws -> JSONValue {
        let board = try board(p)
        let (format, out) = try imageDestination(p, name: "snapshot")
        guard let snapshotBoard else { throw Failure("unsupported", "snapshots need the app UI") }
        guard let shot = await snapshotBoard(board, format) else { throw Failure("unavailable", "board \(board.id) has no window") }
        var result = try await deliver(shot.output, to: out)
        result["viewport"] = shot.viewport.json
        result["scale"] = .number(shot.output.scale)
        result["objects"] = .array(shot.output.objects.map(\.json))
        return .object(result)
    }

    /// Where renders and snapshots without `out` go: out of the user's repo, in the app's
    /// temporary directory; the app deletes the ones older than a day at launch (`Housekeeping`).
    public static var scratchImages: URL { FileManager.default.temporaryDirectory.appendingPathComponent("easl-renders", isDirectory: true) }

    /// Format and path from `out` (absolute, in an existing directory; format from its
    /// extension), else a new file `<name>-<ms>-<n>` in `scratchImages` in `format` (default png).
    private func imageDestination(_ p: JSONValue, name: String) throws -> (ImageFormat, String) {
        if let out = p["out"]?.string {
            guard out.hasPrefix("/") else { throw Failure("invalid_params", "out must be an absolute path (clients resolve relative paths)") }
            guard let format = ImageFormat(path: out) else { throw Failure("invalid_params", "out must end in .png, .jpg, or .jpeg") }
            return (format, out)
        }
        var format = ImageFormat.png
        if let requested = p["format"]?.string {
            guard let named = ImageFormat(rawValue: requested) else { throw Failure("invalid_params", "format must be png or jpeg") }
            format = named
        }
        scratchCount += 1
        let file = "\(name)-\(Int(Date().timeIntervalSince1970 * 1000))-\(scratchCount).\(format == .png ? "png" : "jpg")"
        return (format, Self.scratchImages.appendingPathComponent(file).path)
    }

    /// Numbers scratch images, so renders in the same millisecond never overwrite each other.
    private var scratchCount = 0

    private func deliver(_ output: RenderOutput, to out: String) async throws -> [String: JSONValue] {
        let image = output.image
        let scratch = Self.scratchImages
        let failure: String? = await offPool {
            do {
                let url = URL(fileURLWithPath: out)
                if url.deletingLastPathComponent().path == scratch.path {
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                }
                try image.write(to: url, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if let failure { throw Failure("unavailable", "cannot write \(out): \(failure)") }
        return [
            "path": .string(out), "format": .string(output.format.rawValue),
            "width": .number(Double(output.width)), "height": .number(Double(output.height)),
        ]
    }

    /// The synchronous part of a method, on the main actor: timed as `api.main.<method>` (what a
    /// long main-thread stretch names, `Metrics`).
    func dispatch(_ method: String, _ p: JSONValue) throws -> JSONValue {
        try Metrics.shared.span("api", "api.main.\(method)", detail: p["id"]?.string ?? "") {
            try ApiActivity.shared.dispatch { try dispatchMethod(method, p) }
        }
    }

    private func dispatchMethod(_ method: String, _ p: JSONValue) throws -> JSONValue {
        switch method {
        case "system.ping":
            return .object(["version": .number(Double(Self.schemaVersion)), "app": .string("easl")])

        case "app.metrics":
            if p["watch"]?.bool == true { Metrics.shared.watching() }
            let snapshot = Metrics.shared.snapshot()
            if p["reset"]?.bool == true { Metrics.shared.reset() }
            return snapshot

        case "board.get":
            let board = try board(p)
            var snapshot = board.snapshot.objects
            var regions: [ObjectID]?
            if let branch = p["branch"]?.string {
                // One branch's part of a repository board (docs/design/repo-boards.md "Per-branch filter").
                let ids = board.objects(ofBranch: branch)
                snapshot = snapshot.filter { ids.contains($0.id) }
                regions = board.regions(ofBranch: branch)
            }
            let objects = board.reported(snapshot).map(summarized)
            var result: [String: JSONValue] = [
                "board": .string(board.id), "root": .string(board.root.path),
                "revision": .number(Double(board.revision)), "objects": .array(objects.map(JSONValue.init)),
            ]
            if let regions { result["regions"] = .array(regions.map(JSONValue.string)) }
            if let since = p["since"]?.int { result["changed"] = .array(board.changed(since: since).map(JSONValue.string)) }
            return .object(result)

        case "board.history":
            let board = try board(p)
            let since: ActivityLog.Since?
            switch p["since"] {
            case .number(let value): since = .seq(Int(value))
            case .string(let text):
                guard let time = try? Date(text, strategy: .iso8601) else { throw Failure("invalid_params", "since must be a seq cursor or an ISO 8601 time") }
                since = .time(time)
            case nil, .null?: since = nil
            default: throw Failure("invalid_params", "since must be a seq cursor or an ISO 8601 time")
            }
            let limit = min(max(p["limit"]?.int ?? 100, 1), board.activity.capacity)
            var kinds: Set<ActivityEntry.Kind>?
            if let names = p["kinds"]?.array {
                kinds = Set(try names.map { name in
                    guard let kind = name.string.flatMap(ActivityEntry.Kind.init(rawValue:)) else { throw Failure("invalid_params", "unknown history kind \(name)") }
                    return kind
                })
            }
            let page = board.activity.query(since: since, limit: limit, kinds: kinds)
            return .object([
                "board": .string(board.id), "cursor": .number(Double(page.cursor)), "entries": .array(page.entries.map(\.json)),
                "truncated": .bool(page.truncated), "restarted": .bool(page.restarted),
            ])

        case "board.list":
            // Open boards are the truth for root and contents: a moved worktree's new root and any
            // unsaved edits aren't on disk yet. The save time stays the disk's.
            var stored = registry.store.list()
            for board in registry.boards.values {
                let index: Int
                if let found = stored.firstIndex(where: { $0.id == board.id }) {
                    index = found
                } else {
                    stored.append(.init(id: board.id, root: "", archived: false, updatedAt: nil, objectCount: 0))
                    index = stored.count - 1
                }
                stored[index].root = board.root.path
                stored[index].archived = !BoardStore.isDirectory(board.root.path)
                stored[index].objectCount = board.objects.count
                stored[index].repo = board.repo?.commonDir
                stored[index].worktrees = board.repo?.worktreeList(objects: board.objects)
            }
            let boards = stored.map { entry -> JSONValue in
                var info: [String: JSONValue] = [
                    "board": .string(entry.id), "root": .string(entry.root), "archived": .bool(entry.archived),
                    "open": .bool(registry.boards[entry.id] != nil), "objects": .number(Double(entry.objectCount)),
                ]
                if let updatedAt = entry.updatedAt { info["updatedAt"] = .string(updatedAt.formatted(.iso8601)) }
                if let repo = entry.repo { info["repo"] = .string(repo) }
                if let worktrees = entry.worktrees { info["worktrees"] = .array(worktrees.map(\.json)) }
                return .object(info)
            }
            return .object(["boards": .array(boards)])

        case "board.open":
            guard let path = p["root"]?.string, !path.isEmpty else { throw Failure("invalid_params", "root is required") }
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw Failure("invalid_params", "root must be an absolute path (or start with ~)") }
            let root = URL(fileURLWithPath: expanded).standardizedFileURL
            guard BoardStore.isDirectory(root.path) else { throw Failure("not_found", "no directory at \(root.path)") }
            let board = openBoard?(root, p["select"]?.bool ?? false) ?? registry.open(root: root)
            var result: [String: JSONValue] = ["board": .string(board.id), "root": .string(board.root.path), "objects": .number(Double(board.objects.count))]
            if let worktree = GitWorktree.containing(root.path), worktree.commonDir == board.repo?.commonDir {
                var info: [String: JSONValue] = ["path": .string(worktree.toplevel), "main": .bool(worktree.isMain)]
                if let branch = worktree.branch { info["branch"] = .string(branch) }
                if let region = board.region(for: worktree) { info["region"] = .string(region) }
                result["worktree"] = .object(info)
            }
            return .object(result)

        case "board.export":
            let board = try board(p)
            let url = board.absoluteURL(p["path"]?.string ?? ".easl/board.json").standardizedFileURL
            do {
                try BoardStore.export(board, to: url)
            } catch {
                throw Failure("unavailable", "cannot write \(url.path): \(error.localizedDescription)")
            }
            return .object(["path": .string(url.path), "objects": .number(Double(board.objects.count))])

        case "object.get":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            let object = try board.object(id)
            var result: [String: JSONValue] = ["object": JSONValue(board.reported(object))]
            switch p["as"]?.string ?? "raw" {
            case "graph": result["graph"] = graph(of: object, on: board)
            case "raw": break
            case "image": throw Failure("invalid_params", "object.get no longer renders images: use view.render with target \(id)")
            case let other: throw Failure("invalid_params", "unknown as: \(other)")
            }
            return .object(result)

        case "object.create":
            let board = try board(p)
            guard let type = ObjectType(rawValue: try string(p, "type")) else { throw Failure("invalid_params", "unknown object type") }
            guard var props = p["props"], props.object != nil else { throw Failure("invalid_params", "props must be an object") }
            try Self.checkProps(p)
            // Just w and h: that size, placed as a create without a frame is (near the caller).
            let frame = try p["frame"].map { value in
                if value["x"]?.number == nil, value["y"]?.number == nil, let w = value["w"]?.number, let h = value["h"]?.number {
                    return board.place(width: w, height: h, near: caller(p), stacking: true)
                }
                return try Self.frame(value, onto: nil)
            }
            if type == .note || type == .html, let root = props["root"]?.string, !root.isEmpty { try board.checkLinkRoot(root) }
            try board.checkKey(props, for: nil)
            if type == .diagram, let problem = DiagramSpec.problem(props) { throw Failure("invalid_params", problem) }
            if type == .question { props = try board.questionToCreate(props, caller: caller(p)) }
            let object = board.create(type: type, props: props, frame: frame, parent: p["parent"]?.string, caller: caller(p))
            return Self.withWarnings(["object": JSONValue(board.reported(object))], type.unknownPropWarnings(props))

        case "object.update":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            try Self.checkProps(p)
            var frame = try p["frame"].map { try Self.frame($0, onto: board.object(id).frame) }
            var props = p["props"]
            if let root = props?["root"]?.string, !root.isEmpty, [.note, .html].contains(try board.object(id).type) { try board.checkLinkRoot(root) }
            if let patch = props, try board.object(id).type == .diagram, let problem = DiagramSpec.problem(try board.object(id).props.merging(patch)) {
                throw Failure("invalid_params", problem)
            }
            (props, frame) = try board.questionUpdate(id, props: props, frame: frame, caller: caller(p))
            let object = try board.update(id, rev: p["rev"]?.int, frame: frame, props: props, caller: caller(p))
            return Self.withWarnings(["object": JSONValue(board.reported(object))], object.type.unknownPropWarnings(p["props"]))

        case "object.delete":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            try board.delete(id, caller: caller(p))
            return .object([:])

        case "layout.place":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            let near = try string(p, "near")
            guard board.objects[near] != nil else { throw BoardError.notFound("object \(near) on this board") }
            let frames = try board.place(id, near: near, side: try option(p, "side", Layout.Side.self) ?? .right, gap: p["gap"]?.number ?? Layout.defaultGap,
                                         align: try option(p, "align", Layout.Align.self) ?? .start, caller: caller(p))
            return .object(["frames": try JSONValue.encode(frames)])

        case "layout.stack":
            guard let ids = p["ids"]?.array?.compactMap(\.string), !ids.isEmpty else { throw Failure("invalid_params", "ids must be a non-empty array of object ids") }
            let board = try board(forObject: ids[0])
            for id in ids where board.objects[id] == nil { throw BoardError.notFound("object \(id) on this board") }
            let frames = try board.stack(ids, direction: try option(p, "direction", Layout.Direction.self) ?? .row, gap: p["gap"]?.number ?? Layout.defaultGap,
                                         wrapAt: p["wrapAt"]?.number, align: try option(p, "align", Layout.Align.self) ?? .start, origin: try point(p, "origin"), caller: caller(p))
            return .object(["frames": try JSONValue.encode(frames)])

        case "layout.translate":
            guard let ids = p["ids"]?.array?.compactMap(\.string), !ids.isEmpty else { throw Failure("invalid_params", "ids must be a non-empty array of object ids") }
            guard let dx = p["dx"]?.number, let dy = p["dy"]?.number else { throw Failure("invalid_params", "dx and dy are required numbers") }
            let board = try board(forObject: ids[0])
            for id in ids where board.objects[id] == nil { throw BoardError.notFound("object \(id) on this board") }
            return .object(["frames": try JSONValue.encode(try board.translate(ids, dx: dx, dy: dy, caller: caller(p)))])

        case "layout.grid":
            guard let raw = p["cells"]?.array, !raw.isEmpty else { throw Failure("invalid_params", "cells must be a non-empty array of {id, row, col}") }
            let cells = try raw.map { cell -> (id: ObjectID, row: Int, col: Int) in
                guard let id = cell["id"]?.string, let row = cell["row"]?.int, let col = cell["col"]?.int else {
                    throw Failure("invalid_params", "each cell needs id, row, and col (integers)")
                }
                return (id, row, col)
            }
            let board = try board(forObject: cells[0].id)
            for cell in cells where board.objects[cell.id] == nil { throw BoardError.notFound("object \(cell.id) on this board") }
            let placed = try board.grid(cells, colGap: p["colGap"]?.number ?? Layout.defaultGap, rowGap: p["rowGap"]?.number ?? Layout.defaultGap,
                                        colAlign: try option(p, "colAlign", Layout.Align.self) ?? .start, rowAlign: try option(p, "rowAlign", Layout.Align.self) ?? .start,
                                        origin: try point(p, "origin"), caller: caller(p))
            return .object([
                "frames": try JSONValue.encode(placed.frames),
                "columns": .array(placed.grid.columns.map { .object(["col": .number(Double($0.index)), "x": .number($0.start), "w": .number($0.length)]) }),
                "rows": .array(placed.grid.rows.map { .object(["row": .number(Double($0.index)), "y": .number($0.start), "h": .number($0.length)]) }),
            ])

        case "tray.list":
            return .object(["mentions": try JSONValue.encode(try board(p).tray)])

        case "tray.stage":
            guard let target = p["target"] else { throw Failure("invalid_params", "missing target") }
            let mention = try board(p).stage(try target.decode(MentionTarget.self))
            return .object(["mention": try JSONValue.encode(mention)])

        case "tray.unstage":
            let id = try string(p, "id")
            guard let board = registry.boards.values.first(where: { $0.tray.contains { $0.id == id } }) else { throw BoardError.notFound("mention \(id)") }
            try board.unstage(id)
            return .object([:])

        case "tray.commit":
            try board(p).commit(p["ids"]?.array?.compactMap(\.string) ?? [])
            return .object([:])

        case "agent.report":
            try board(forObject: try string(p, "tile")).reportLifecycle(params: p)
            return .object([:])

        case "agent.report_session":
            let tile = try string(p, "tile")
            try board(forObject: tile).reportSession(tile: tile, kind: try string(p, "kind"), sessionId: p["sessionId"]?.string, sessionPath: p["sessionPath"]?.string)
            return .object([:])

        case "agent.release":
            let tile = try string(p, "tile")
            try board(forObject: tile).releaseAgent(tile: tile)
            return .object([:])

        case "agent.list":
            // Every terminal: one whose agent never reported (a shell, aider, an unhooked CLI) is
            // kind and lifecycle `unknown`, so tools still see it and can prompt and read it.
            var agents: [JSONValue] = []
            for board in registry.boards.values.sorted(by: { $0.id < $1.id }) {
                for object in board.objects.values.sorted(by: { $0.id < $1.id }) where object.type == .terminal {
                    agents.append(agentEntry(object, on: board))
                }
            }
            return .object(["agents": .array(agents)])

        case "follow.report":
            let tile = try string(p, "tile")
            let range = try p["range"].map { try $0.decode(LineRange.self) }
            let changes = try p["changes"].map { try $0.decode([LineRange].self) } ?? []
            try board(forObject: tile).follow(tile: tile, path: try string(p, "path"), range: range, changes: changes, action: try string(p, "action"))
            return .object([:])

        case "view.attention":
            let id = try string(p, "id")
            let board = try board(forObject: id)
            if p["clear"]?.bool == true {
                board.clearAttention(id)
                return .object(["id": .string(id), "active": .bool(false)])
            }
            let raised = try board.raiseAttention(id, message: p["message"]?.string, caller: caller(p))
            var result: [String: JSONValue] = ["id": .string(id), "active": .bool(true)]
            if !raised.cleared.isEmpty { result["cleared"] = .array(raised.cleared.map(JSONValue.string)) }
            return .object(result)

        case "view.open_url":
            let board = try board(p)
            let raw = try string(p, "url")
            guard let url = WebLink.parse(raw) else { throw Failure("invalid_params", "view.open_url opens http and https addresses, not \(raw)") }
            let caller = caller(p)
            let source = caller.flatMap { board.objects[$0] == nil ? nil : $0 }
            let opened = board.openLink(url, near: source, caller: caller)
            showOpenedLink?(board, opened.object.id, source)
            return .object(["object": try JSONValue.encode(board.reported(opened.object)), "existing": .bool(opened.existing)])

        case "view.get":
            let board = try board(p)
            guard let viewState else { throw Failure("unsupported", "the viewport needs the app UI") }
            guard let state = viewState(board) else { throw Failure("unavailable", "board \(board.id) has no window") }
            var result: [String: JSONValue] = [
                "board": .string(board.id), "viewport": state.viewport.json,
                "selection": .array(state.selection.map(JSONValue.string)), "visible": .bool(state.visible),
                "appearance": .string(state.appearance),
            ]
            if let target = state.promptTarget { result["promptTarget"] = .string(target) }
            if let focused = state.focused { result["focused"] = .string(focused) }
            if let group = state.enteredGroup { result["enteredGroup"] = .string(group) }
            return .object(result)

        case "session.spawn", "session.list", "session.kill", "relay.open":
            // A hosted terminal's session runs under the host's easld, which relays its way back
            // here (docs/contracts.md "Hosted terminals"); the app's own sessions are its tiles'.
            throw Failure("unsupported", "\(method) is easld's: the app runs its terminals' sessions itself")

        default:
            throw Failure("invalid_params", "unknown method \(method)")
        }
    }

    // MARK: Layout

    /// An optional `{x, y}` parameter.
    func point(_ p: JSONValue, _ key: String) throws -> CGPoint? {
        try p[key].map { value -> CGPoint in
            guard let x = value["x"]?.number, let y = value["y"]?.number else { throw Failure("invalid_params", "\(key) needs x and y") }
            return CGPoint(x: x, y: y)
        }
    }

    /// An optional enum parameter; an unknown value is invalid rather than ignored.
    func option<T: RawRepresentable & CaseIterable>(_ p: JSONValue, _ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
        guard let raw = p[key]?.string else { return nil }
        guard let value = T(rawValue: raw) else {
            throw Failure("invalid_params", "\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    }

    /// `object.reload`: a browser tile's page loaded again (`reloadBrowser`), any browser tile on
    /// any open board, whoever opened it; a diagram computed afresh from the code
    /// (`refreshDiagram`). Other tiles reload what they show by themselves.
    private func reload(_ p: JSONValue) async throws -> JSONValue {
        let id = try string(p, "id")
        let board = try board(forObject: id)
        guard let object = board.objects[id] else { throw Failure("not_found", "no object \(id)") }
        guard object.type == .browser || object.type == .diagram else {
            throw Failure("invalid_params", "\(id) is a \(object.type.rawValue) tile: only browser and diagram tiles reload (code, note and changes tiles follow their files by themselves; an HTML tile re-renders when its props change)")
        }
        let timeout = p["timeoutMs"]?.int ?? (object.type == .diagram ? diagramTimeoutMs : Self.reloadTimeoutMs)
        guard timeout >= 0 else { throw Failure("invalid_params", "timeoutMs must be 0 or more") }
        if object.type == .diagram { return try await computeDiagram(board, id, timeoutMs: timeout) }
        guard let reloadBrowser else { throw Failure("unsupported", "reloading pages needs the app UI") }
        return try await reloadBrowser(board, id, p["caller"]?.string, timeout)
    }

    static let reloadTimeoutMs = 15_000
    /// How long `object.reload` (by default) and a fitted create wait for a diagram's graph: a
    /// language server's first answers in a project can take a while (sourcekit-lsp loading the
    /// package and its index).
    public var diagramTimeoutMs = 60_000

    /// `refreshDiagram` for `id`: its summary once computed, or the graph the tile has now, not
    /// loaded, once `timeoutMs` passes first; the computation goes on, and the tile shows its graph
    /// when it comes. A task's value can only be awaited whole (a task group waits for every child,
    /// cancelled or not), so whichever of the two ends first resumes the wait.
    private func computeDiagram(_ board: Board, _ id: ObjectID, timeoutMs: Int) async throws -> JSONValue {
        guard let refreshDiagram else { throw Failure("unsupported", "computing diagrams needs the app") }
        let computing = Task { try await refreshDiagram(board, id) }
        var timer: Task<Void, Never>?
        let computed: Result<JSONValue, any Error>? = await withCheckedContinuation { continuation in
            let first = FirstResume(continuation)
            Task { first.resume(await computing.result) }
            timer = Task {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                first.resume(nil)
            }
        }
        timer?.cancel()
        if let computed { return try computed.get() }
        return DiagramRefresh.summary(id, graph: DiagramGraph(board.objects[id]?.props["graph"]), computed: false)
    }

    /// `object.measure`: the intrinsic frame size for a type and props (notes and text wrap at
    /// `width`). Paths resolve against the caller's (or the given) board.
    private func measure(_ p: JSONValue) async throws -> JSONValue {
        guard let type = ObjectType(rawValue: try string(p, "type")) else { throw Failure("invalid_params", "unknown object type") }
        try Self.checkProps(p)
        let board = try board(p)
        let props = board.inCallersCheckout(p["props"] ?? .object([:]), type: type, caller: caller(p))
        let size = try await ObjectMeasure.size(type: type, props: props, width: p["width"]?.number, root: pathRoot(board, type: type, props: props))
        return .object(["w": .number(size.width), "h": .number(size.height)])
    }

    /// `object.get`; a changes tile's result adds `changes`: its files and hunks as git has them
    /// now (`ChangeSet.json`), next to the actions the user took in `props.reviewed`; a terminal's
    /// adds `lastCommand`, the last command its shell finished (not a prop: it changes no `rev`);
    /// a browser tile's adds `page`, what its page reported since it loaded (`PageLog`), after
    /// the `since` cursor when given; a note's adds `fences`, how each anchored fence resolves
    /// now; a code tile showing a range it anchors adds `rangeStatus`, the same for its range.
    private func get(_ p: JSONValue) async throws -> JSONValue {
        let result = try dispatch("object.get", p)
        guard let id = p["id"]?.string, let board = registry.board(containing: id), let object = board.objects[id] else { return result }
        if object.type == .browser, let pageReport {
            let since = try p["since"]?.string.map { text in
                guard let cursor = PageLog.Cursor(text) else { throw Failure("invalid_params", "since must be a page cursor (`page.cursor` of an earlier object.get)") }
                return cursor
            }
            let page = await pageReport(board, id)?.json(since: since) ?? .object(["loaded": .bool(false), "visibility": .string(PageReport.Visibility.released.rawValue)])
            return result.merging(.object(["page": page]))
        }
        if object.type == .terminal, let last = terminalStatus?(board, id).lastCommand {
            return result.merging(.object(["lastCommand": last.command.json(finishedAt: last.finishedAt)]))
        }
        if object.type == .note {
            let fences = NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(object.props["markdown"]?.string ?? ""))
            let excerpts = await noteExcerpts?(board, id) ?? [:]
            let unresolved = fences.filter { excerpts[$0.key] == nil }
            let reading = await board.linkSource(of: object)
            let resolved = excerpts.merging(await NoteSource.excerpts(for: reading.fences(unresolved), root: reading.root)) { tile, _ in tile }
            return result.merging(.object(["fences": NoteMarkdown.status(of: fences, excerpts: resolved)]))
        }
        if object.type == .code, let fence = CodeAnchor.fence(object.props) {
            var excerpt = await codeRangeStatus?(board, id)
            if excerpt == nil {
                if let ref = RefSource.ref(of: object.props) {
                    do {
                        let source = try await RefSource.resolve(ref: ref, lastKnownSha: object.props["refSha"]?.string, boardRoot: board.root)
                        excerpt = await NoteSource.excerpt(for: source.fence(fence), root: source.root, captured: nil)
                    } catch {
                        excerpt = NoteExcerpt(path: fence.path ?? "", range: nil, lines: [], status: .stale(RefSource.describe(error, ref: ref)), missing: true)
                    }
                } else {
                    excerpt = await NoteSource.excerpt(for: fence, root: board.root, captured: nil)
                }
            }
            // The tile may have written a re-found range back meanwhile.
            let current = try dispatch("object.get", p)
            return current.merging(.object(["rangeStatus": .object(excerpt?.statusJSON ?? [:])]))
        }
        guard object.type == .changes else { return result }
        let set = await ChangeSet.load(root: board.root, spec: ChangesSpec(object.props), highlight: false)
        return result.merging(.object(["changes": set.json(viewed: object.props["viewed"])]))
    }

    /// `object.find`: `key` → the object holding it, as `object.get` returns it; `keyPrefix` →
    /// every object whose key starts with it, summarized as `board.get` lists them; `type` →
    /// every object of that type (with `status`, whose `props.status` is that: open questions),
    /// summarized likewise, oldest first.
    private func find(_ p: JSONValue) async throws -> JSONValue {
        let board = try board(p)
        let key = p["key"]?.string, prefix = p["keyPrefix"]?.string, type = p["type"]?.string
        guard [key, prefix, type].compactMap({ $0 }).count == 1 else { throw Failure("invalid_params", "object.find takes one of key, keyPrefix, or type") }
        let status = p["status"]?.string
        if status != nil, type == nil { throw Failure("invalid_params", "object.find takes status only with type (e.g. type question, status open)") }
        if let key {
            guard let object = try board.holder(ofKey: key) else { throw BoardError.notFound("no object on board \(board.id) has key \"\(key)\"") }
            var params: [String: JSONValue] = ["id": .string(object.id)]
            if let view = p["as"] { params["as"] = view }
            return try await get(.object(params))
        }
        if let prefix {
            return .object(["objects": .array(board.reported(board.objects(keyPrefix: prefix)).map(summarized).map(JSONValue.init))])
        }
        guard let kind = type.flatMap(ObjectType.init) else { throw Failure("invalid_params", "unknown object type") }
        let found = board.objects.values.filter { $0.type == kind && (status == nil || $0.props["status"]?.string == status) }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return .object(["objects": .array(board.reported(found).map(summarized).map(JSONValue.init))])
    }

    /// What the ops of a batch before an upsert do to keys, which the board doesn't show until
    /// they apply: keys they give (to an id, or "$n" for what op n creates, with its type), and
    /// ids whose key on the board no longer counts (deleted, or given another).
    struct KeyPlan {
        var given: [String: (id: String, type: ObjectType)] = [:]
        var dropped: Set<String> = []

        mutating func drop(_ id: String) {
            dropped.insert(id)
            given = given.filter { $0.value.id != id }
        }
    }

    /// `object.upsert` params as the `object.create` or `object.update` they are now: the
    /// object holding `key` on the board (as `plan` leaves it) updated, else a new one created
    /// with `key` in its props.
    func upserted(_ p: JSONValue, plan: KeyPlan = KeyPlan()) throws -> (method: String, params: JSONValue) {
        let key = try string(p, "key")
        guard !key.isEmpty else { throw Failure("invalid_params", "key must not be empty") }
        guard let type = ObjectType(rawValue: try string(p, "type")) else { throw Failure("invalid_params", "unknown object type") }
        guard let props = p["props"], props.object != nil else { throw Failure("invalid_params", "props must be an object") }
        if let given = props["key"], given != .string(key) { throw Failure("invalid_params", "props.key, when given, must be key") }
        let board = try board(p)
        let holder = try plan.given[key] ?? board.holder(ofKey: key).flatMap { plan.dropped.contains($0.id) ? nil : (id: $0.id, type: $0.type) }
        var params = p.object ?? [:]
        params.removeValue(forKey: "key")
        guard let holder else {
            params["board"] = .string(board.id)
            params["props"] = props.merging(.object(["key": .string(key)]))
            return ("object.create", .object(params))
        }
        guard holder.type == type else { throw Failure("conflict", "key \"\(key)\" is held by \(holder.id), a \(holder.type.rawValue), not a \(type.rawValue)") }
        params.removeValue(forKey: "type")
        params.removeValue(forKey: "board")
        params["id"] = .string(holder.id)
        return ("object.update", .object(params))
    }

    /// An `object.create` of a changes tile an agent already made for the same `root`, `base`,
    /// `head`, `ref`, and `paths` (its own tile, on that board): the update that brings that tile the call's
    /// other props, `frame`, and `size`, so the agent gets it back (`reused: true`) instead of
    /// a duplicate beside the user's review. Nil for anything else.
    func reusableChanges(_ p: JSONValue) throws -> JSONValue? {
        guard p["type"]?.string == ObjectType.changes.rawValue, let props = p["props"], props.object != nil else { return nil }
        let board = try board(p)
        guard let caller = caller(p) else { return nil }
        let spec = ChangesSpec(props)
        let root = spec.directory(boardRoot: board.root).path
        let existing = board.objects.values
            .filter { $0.type == .changes && $0.createdBy == .agent(tile: caller) }
            .filter { object in
                let other = ChangesSpec(object.props)
                return other.baseProp == spec.baseProp && other.head == spec.head && other.ref == spec.ref && other.paths == spec.paths
                    && other.directory(boardRoot: board.root).path == root
            }
            .max { $0.z < $1.z }
        guard let existing else { return nil }
        var update: [String: JSONValue] = ["id": .string(existing.id), "caller": .string(caller)]
        var given = props.object ?? [:]
        for key in ["root", "base", "head", "ref", "paths"] { given.removeValue(forKey: key) }
        if !given.isEmpty { update["props"] = .object(given) }
        if let frame = p["frame"] { update["frame"] = frame }
        if let size = p["size"] { update["size"] = size }
        return .object(update)
    }

    /// `object.create`/`object.update` params with a note's markdown anchored the way its tile
    /// would write it back (`NoteMarkdown.anchoringRanges`), so the result's `rev` is the one the
    /// next update needs. `pending` are the params of creates earlier in the same batch.
    /// A create's or update's `ref` on a code, note, HTML, or changes tile resolved now
    /// (`RefSource`): `refSha` records the SHA it resolved to, a ref that resolves to nothing is
    /// `not_found` (a changes tile's names the `git fetch` that brings it), and clearing the ref
    /// clears `refSha`. A code tile's `pinnedCommit` wins: its ref isn't resolved.
    /// `object.create`/`object.update` params with the caller's relative paths meaning its own
    /// checkout when it works in another worktree of the board's repository
    /// (`Board.inCallersCheckout`). `pending` are the creates earlier in the same batch, for `$n`.
    func inCallersCheckout(_ method: String, _ p: JSONValue, pending: [Int: JSONValue] = [:]) throws -> JSONValue {
        guard var params = p.object, let props = p["props"], props.object != nil, let caller = caller(p) else { return p }
        if method == "object.create" {
            guard let type = p["type"]?.string.flatMap(ObjectType.init(rawValue:)) else { return p }
            params["props"] = try board(p).inCallersCheckout(props, type: type, caller: caller)
        } else if method == "object.update", let id = p["id"]?.string {
            if let index = Self.reference(id) {
                guard let created = pending[index], let type = created["type"]?.string.flatMap(ObjectType.init(rawValue:)) else { return p }
                params["props"] = try board(created).inCallersCheckout(props, type: type, caller: caller, existing: created["props"] ?? .object([:]))
            } else {
                guard let board = try? board(forObject: id), let object = board.objects[id] else { return p }
                params["props"] = board.inCallersCheckout(props, type: object.type, caller: caller, existing: object.props)
            }
        } else {
            return p
        }
        return .object(params)
    }

    func referenced(_ method: String, _ p: JSONValue, pending: [Int: JSONValue] = [:]) async throws -> JSONValue {
        guard var params = p.object, var props = p["props"]?.object, let value = props["ref"] else { return p }
        let board: Board, type: ObjectType?, existing: JSONValue
        if method == "object.create" {
            board = try self.board(p)
            type = p["type"]?.string.flatMap(ObjectType.init(rawValue:))
            existing = .object([:])
        } else {
            let id = try string(p, "id")
            if let index = Self.reference(id) {
                guard let created = pending[index] else { return p }
                board = try self.board(created)
                type = created["type"]?.string.flatMap(ObjectType.init(rawValue:))
                existing = created["props"] ?? .object([:])
            } else {
                let found = try self.board(forObject: id)
                board = found
                let object = try found.object(id)
                type = object.type
                existing = object.props
            }
        }
        guard let type, [.code, .note, .html, .changes].contains(type) else { return p }
        guard let ref = value.string, !ref.isEmpty else {
            guard value == .null || value.string == "" else { throw Failure("invalid_params", "ref must be a branch or other ref name") }
            props["refSha"] = .null
            params["props"] = .object(props)
            return .object(params)
        }
        let merged = existing.merging(.object(props))
        if type == .code, let pinned = merged["pinnedCommit"]?.string, !pinned.isEmpty { return p }
        // Another ref than before falls back only to a SHA given with it.
        let known = existing["ref"]?.string == ref ? merged["refSha"]?.string : props["refSha"]?.string
        do {
            let source = try await RefSource.resolve(ref: ref, lastKnownSha: known, boardRoot: board.root)
            props["refSha"] = .string(source.resolution.sha)
        } catch GitRefs.Failure.notRevision {
            throw Failure("invalid_params", RefSource.describe(GitRefs.Failure.notRevision(ref), ref: ref))
        } catch GitRefs.Failure.notRepository {
            throw Failure("invalid_params", "ref needs a board in a git repository")
        } catch {
            guard type == .changes else { throw Failure("not_found", RefSource.describe(error, ref: ref)) }
            throw Failure("not_found", await ChangeSet.missing(ref, in: GitDiffEngine.existingAncestor(of: board.root)))
        }
        params["props"] = .object(props)
        return .object(params)
    }

    func anchored(_ method: String, _ p: JSONValue, pending: [Int: JSONValue] = [:]) async throws -> JSONValue {
        guard var params = p.object, var props = p["props"]?.object, let markdown = props["markdown"]?.string else { return p }
        let root: URL, board: Board, merged: JSONValue
        if method == "object.create" {
            guard p["type"]?.string == ObjectType.note.rawValue else { return p }
            board = try self.board(p)
            merged = .object(props)
            root = pathRoot(board, type: .note, props: merged)
        } else {
            let id = try string(p, "id")
            if let index = Self.reference(id) {
                guard let created = pending[index], created["type"]?.string == ObjectType.note.rawValue else { return p }
                board = try self.board(created)
                merged = (created["props"] ?? .object([:])).merging(.object(props))
                root = pathRoot(board, type: .note, props: merged)
            } else {
                guard let found = try? self.board(forObject: id), let note = found.objects[id], note.type == .note else { return p }
                board = found
                merged = note.props.merging(.object(props))
                root = pathRoot(board, type: .note, props: merged)
            }
        }
        // A note anchored to a branch anchors its ranges on the text at the ref.
        let reading = RefSource.ref(of: merged) == nil ? LinkReading(root: root) : await board.linkSource(props: merged)
        let text = await NoteMarkdown.anchoringRanges(markdown, reading: reading)
        guard text != markdown else { return p }
        props["markdown"] = .string(text)
        params["props"] = .object(props)
        return .object(params)
    }

    /// The measured size an `object.create`/`object.update` with `size: "fit"` gets, or a note or
    /// image created without a frame height (sized to fit its markdown or picture); nil otherwise. Notes and text
    /// wrap at the given frame's `w` (a new note defaults to `ObjectMeasure.defaultNoteWidth`; an
    /// update keeps its current width); code takes the given `w` as its widest (default
    /// `CodeMetrics.defaultFitWidth`, also on an update, so a re-fit can widen a tile as well as
    /// narrow it; an image likewise, default `LocalImage.defaultMaxWidth`). `pending` are the params of creates earlier in the same batch, for updates of `$n`.
    func fitSize(_ method: String, _ p: JSONValue, pending: [Int: JSONValue] = [:]) async throws -> CGSize? {
        let fitsNote = method == "object.create" && [ObjectType.note.rawValue, ObjectType.image.rawValue].contains(p["type"]?.string) && p["frame"]?["h"] == nil
        guard let size = p["size"] ?? (fitsNote ? .string("fit") : nil) else { return nil }
        guard size.string == "fit" else { throw Failure("invalid_params", "size must be \"fit\"") }
        let width = p["frame"]?["w"]?.number
        if method == "object.create" {
            guard let type = ObjectType(rawValue: try string(p, "type")) else { throw Failure("invalid_params", "unknown object type") }
            return try await ObjectMeasure.size(type: type, props: p["props"] ?? .object([:]), width: width,
                                                root: pathRoot(try board(p), type: type, props: p["props"] ?? .object([:])))
        }
        let id = try string(p, "id")
        let base: (type: ObjectType, props: JSONValue, width: Double?, root: URL)
        if let index = Self.reference(id) {
            guard let created = pending[index], let type = ObjectType(rawValue: try string(created, "type")) else {
                throw Failure("invalid_params", "\(id) must name an earlier create op")
            }
            let props = p["props"].map { (created["props"] ?? .object([:])).merging($0) } ?? created["props"] ?? .object([:])
            base = (type, props, created["frame"]?["w"]?.number, pathRoot(try board(created), type: type, props: props))
        } else {
            let board = try board(forObject: id)
            let object = try board.object(id)
            let props = p["props"].map { object.props.merging($0) } ?? object.props
            base = (object.type, props, object.frame.w, pathRoot(board, type: object.type, props: props))
        }
        return try await ObjectMeasure.size(type: base.type, props: base.props, width: width ?? ([.code, .image].contains(base.type) ? nil : base.width), root: base.root)
    }

    /// `object.create` of a diagram with `size: "fit"` and no `props.graph`: its size is its graph's,
    /// which only the language server gives. Created at the default size (at the given origin),
    /// computed (`refreshDiagram`, waiting up to `diagramTimeoutMs` as `object.reload` does: a
    /// language server's first answer in a project takes a while), then fitted to the graph as
    /// the tile sizes itself to its first graph: the app's write, not an undo step of its own.
    /// The result adds `diagram`, `object.reload`'s summary; a graph still computing when the wait
    /// ends leaves the tile at the default size, with a warning. Nil for any other create.
    private func createFittedDiagram(_ p: JSONValue) async throws -> JSONValue? {
        guard p["type"]?.string == ObjectType.diagram.rawValue, p["size"]?.string == "fit", DiagramGraph(p["props"]?["graph"]) == nil,
              refreshDiagram != nil, var params = p.object else { return nil }
        params.removeValue(forKey: "size")
        let origin = p["frame"]?["x"]?.number.flatMap { x in p["frame"]?["y"]?.number.map { (x: x, y: $0) } }
        if let origin {
            let size = Board.defaultSize(.diagram)
            params["frame"] = JSONValue(Frame(x: origin.x, y: origin.y, w: size.w, h: size.h))
        } else {
            params.removeValue(forKey: "frame")
        }
        var result = try dispatch("object.create", .object(params)).object ?? [:]
        guard let id = result["object"]?["id"]?.string else { return .object(result) }
        let board = try board(forObject: id)
        let summary = try await computeDiagram(board, id, timeoutMs: diagramTimeoutMs)
        result["diagram"] = summary
        var warning: String?
        if let object = board.objects[id], summary["loaded"] == .bool(true), DiagramGraph(object.props["graph"]) != nil {
            let size = try await ObjectMeasure.size(type: .diagram, props: object.props, width: nil, root: board.root)
            // Where it is now: the user may have moved it while it computed.
            if let current = board.objects[id]?.frame {
                let frame = try origin == nil ? board.refitFrame(id, to: size) : Frame(x: current.x, y: current.y, w: size.width, h: size.height)
                try board.update(id, frame: frame, actor: .system)
            }
        } else {
            warning = "the graph is still being computed (the language server hasn't answered within \((Double(diagramTimeoutMs) / 1000).formatted()) s): "
                + "object.reload \(id) waits for it again, then object.update size \"fit\""
        }
        // Deleted meanwhile (the user's ⌘⌫): created all the same, and the reply says so.
        let now = board.objects[id]
        if now == nil { warning = "\(id) was deleted while its graph was computed" }
        if let warning { result["warnings"] = .array((result["warnings"]?.array ?? []) + [.string(warning)]) }
        guard let now else { return .object(result) }
        result["object"] = JSONValue(board.reported(now))
        return withOverlaps(.object(result))
    }

    /// The directory a create's or update's paths resolve against, once `inCallersCheckout` has
    /// made a worktree caller's paths its own: a note's or HTML tile's link root (`Board.linkRoot`),
    /// else the board root.
    func pathRoot(_ board: Board, type: ObjectType, props: JSONValue) -> URL {
        type == .note || type == .html ? board.linkRoot(props: props) : board.root
    }

    /// Params with `size: "fit"` resolved into a whole frame: the measured size at the given (or
    /// automatically placed) origin; an update that gives no origin re-fits clear of what it
    /// didn't already cover (`Board.refitFrame`).
    func fitted(_ method: String, _ p: JSONValue, size: CGSize?) throws -> JSONValue {
        guard var params = p.object, let size else { return p }
        params.removeValue(forKey: "size")
        let origin: (x: Double, y: Double)
        if method == "object.update" {
            let id = try string(p, "id")
            let board = try board(forObject: id)
            guard p["frame"]?["x"]?.number != nil || p["frame"]?["y"]?.number != nil else {
                params["frame"] = JSONValue(try board.refitFrame(id, to: size))
                return .object(params)
            }
            let current = try board.object(id).frame
            origin = (p["frame"]?["x"]?.number ?? current.x, p["frame"]?["y"]?.number ?? current.y)
        } else if let x = p["frame"]?["x"]?.number, let y = p["frame"]?["y"]?.number {
            origin = (x, y)
        } else {
            let board = try board(p)
            let placed = board.place(width: size.width, height: size.height, near: caller(p), stacking: true)
            origin = (placed.x, placed.y)
        }
        params["frame"] = JSONValue(Frame(x: origin.x, y: origin.y, w: size.width, h: size.height))
        return .object(params)
    }

    /// Why an `object.create`/`object.update` can't be applied before it reaches the board: a
    /// `props.scale`, which `zoom` and `textSize` replaced (`ObjectZoom.retiredProblem`).
    static func checkProps(_ p: JSONValue) throws {
        if let problem = ObjectZoom.retiredProblem(p["props"]) { throw Failure("invalid_params", problem) }
    }

    /// A fitted `object.create`/`object.update` result with `overlaps`, the objects the fitted
    /// object now covers (`Board.overlaps(of:)`), when it covers any beyond those in `before`
    /// (what a frame given outright already covered).
    func withOverlaps(_ result: JSONValue, beyond before: Set<ObjectID> = []) -> JSONValue {
        guard let id = result["object"]?["id"]?.string, let board = try? board(forObject: id) else { return result }
        let covered = board.overlaps(of: id)
        return Set(covered).isSubset(of: before) ? result : result.merging(.object(["overlaps": .array(covered.map(JSONValue.string))]))
    }

    /// A `frame` param: all of x, y, w, h, or, onto `base` (an update's current frame), any of
    /// them, the rest kept.
    static func frame(_ value: JSONValue, onto base: Frame?) throws -> Frame {
        guard value.object != nil else { throw Failure("invalid_params", "frame must be an object with x, y, w, h") }
        func side(_ key: String, _ current: Double?) throws -> Double {
            if let given = value[key], given != .null {
                guard let number = given.number else { throw Failure("invalid_params", "frame.\(key) must be a number") }
                return number
            }
            guard let current else { throw Failure("invalid_params", "frame needs x, y, w, and h (missing \(key)); w and h alone place it automatically; with size: \"fit\", x and y (and w) are enough") }
            return current
        }
        return Frame(x: try side("x", base?.x), y: try side("y", base?.y), w: try side("w", base?.w), h: try side("h", base?.h))
    }

    /// `$n` → n, the index of an earlier batch op.
    static func reference(_ text: String) -> Int? {
        guard text.hasPrefix("$") else { return nil }
        return Int(text.dropFirst())
    }

    static let batchMethods: Set<String> = ["object.create", "object.update", "object.upsert", "object.delete", "layout.place", "layout.stack", "layout.translate", "layout.grid"]

    /// `object.batch`: every op applies or none does, as one board revision and one undo step.
    /// Sizes are measured before anything changes, so nothing else interleaves with the writes.
    /// An upsert becomes its create or update then too, from the board and the ops before it
    /// (`KeyPlan`); if its key's holder is another by the time it applies, the batch fails.
    private func batch(_ p: JSONValue) async throws -> JSONValue {
        guard var ops = p["ops"]?.array, !ops.isEmpty else { throw Failure("invalid_params", "ops must be a non-empty array") }
        let board = try board(p)
        func prepared(_ method: String, _ raw: JSONValue) -> JSONValue {
            var params = raw.object ?? [:]
            if method == "object.create" || method == "object.upsert" { params["board"] = .string(board.id) }
            if params["caller"] == nil, let caller = p["caller"] { params["caller"] = caller }
            return .object(params)
        }
        var pending: [Int: JSONValue] = [:]
        var sizes: [CGSize?] = []
        var plan = KeyPlan()
        // Per upsert: its key and what holds it when the op applies (an id, "$m" for what op m
        // creates, "$n" for itself: nothing, it creates). An upsert that updates is that object for
        // "$n" in later ops (`updating`), so they are measured against it.
        var upserts: [Int: (key: String, holder: String)] = [:]
        var updating: [Int: String] = [:]
        let names = ops.map { $0["method"]?.string ?? "" }
        for (index, op) in ops.enumerated() {
            var method = names[index]
            guard Self.batchMethods.contains(method) else {
                throw Failure("invalid_params", "op \(index): method must be one of \(Self.batchMethods.sorted().joined(separator: ", "))")
            }
            let params: JSONValue
            do {
                try Self.checkParams(method, op["params"] ?? .object([:]))
                var raw = prepared(method, try Self.replacingReferences(op["params"] ?? .object([:])) { n, _ in updating[n].map(JSONValue.string) })
                if method == "object.upsert" {
                    let key = try string(raw, "key")
                    (method, raw) = try upserted(raw, plan: plan)
                    let holder = raw["id"]?.string ?? "$\(index)"
                    upserts[index] = (key, holder)
                    if method == "object.update" { updating[index] = holder }
                }
                params = try await anchored(method, try await referenced(method, try inCallersCheckout(method, raw, pending: pending), pending: pending), pending: pending)
                ops[index] = .object(["method": .string(method), "params": params])
                sizes.append(try await fitSize(method, params, pending: pending))
            } catch {
                throw Self.labelled(error, op: index, names[index])
            }
            switch method {
            case "object.create":
                pending[index] = params
                if let key = params["props"].flatMap(Board.key), let type = params["type"]?.string.flatMap(ObjectType.init) { plan.given[key] = ("$\(index)", type) }
            case "object.update":
                guard let id = params["id"]?.string, let value = params["props"]?["key"] else { break }
                let type = Self.reference(id).flatMap { pending[$0]?["type"]?.string }.flatMap(ObjectType.init) ?? board.objects[id]?.type
                plan.drop(id)
                if let key = value.string, !key.isEmpty, let type { plan.given[key] = (id, type) }
            case "object.delete":
                if let id = params["id"]?.string { plan.drop(id) }
            default: break
            }
        }
        var results: [JSONValue] = []
        try board.atomically {
            for (index, op) in ops.enumerated() {
                let method = op["method"]?.string ?? ""
                do {
                    let params = prepared(method, try resolve(op["params"] ?? .object([:]), results: results, index: index))
                    if let upsert = upserts[index] {
                        let planned = upsert.holder == "$\(index)" ? nil : try resolve(.string(upsert.holder), results: results, index: index).string
                        let holder = try board.holder(ofKey: upsert.key)?.id
                        guard holder == planned else {
                            throw BoardError.conflict("key \"\(upsert.key)\" is held by \(holder ?? "nothing") now, not \(planned ?? "nothing") as when the batch was planned; send it again")
                        }
                    }
                    let named = [params["id"], params["near"]].compactMap({ $0?.string }) + (params["ids"]?.array?.compactMap(\.string) ?? [])
                        + (params["cells"]?.array?.compactMap { $0["id"]?.string } ?? [])
                    for id in named where board.objects[id] == nil {
                        throw BoardError.notFound("object \(id) on board \(board.id)")
                    }
                    let result = try dispatch(method, try fitted(method, params, size: sizes[index]))
                    results.append(upserts[index] == nil ? result : result.merging(.object(["created": .bool(method == "object.create")])))
                } catch {
                    throw Self.labelled(error, op: index, names[index])
                }
            }
        }
        // Fitted objects report what they cover once the whole batch has laid them out.
        for index in results.indices where sizes[index] != nil {
            results[index] = withOverlaps(results[index])
        }
        // Arrows report the route the whole batch leaves them on (a tile a later op adds may be in
        // their way), routed together once the step has closed.
        let arrows = results.compactMap { result -> CanvasObject? in
            guard result["object"]?["type"] == .string(ObjectType.arrow.rawValue), let id = result["object"]?["id"]?.string else { return nil }
            return board.objects[id]
        }
        if !arrows.isEmpty {
            let frames = Dictionary(board.reported(arrows).map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
            for index in results.indices {
                guard let object = results[index]["object"], let id = object["id"]?.string, let frame = frames[id] else { continue }
                results[index] = results[index].merging(.object(["object": object.merging(.object(["frame": JSONValue(frame)]))]))
            }
        }
        return .object(["results": .array(results), "revision": .number(Double(board.revision))])
    }

    /// A batch op's failure, naming the op, with the code it would have had on its own.
    static func labelled(_ error: Error, op index: Int, _ method: String) -> Error {
        let prefix = "op \(index) (\(method)): "
        switch error {
        case let failure as Failure: return Failure(failure.code, prefix + failure.message)
        case BoardError.notFound(let message): return Failure("not_found", prefix + message)
        case BoardError.conflict(let message): return Failure("conflict", prefix + message)
        case BoardError.invalidParams(let message): return Failure("invalid_params", prefix + message)
        case ObjectMeasure.Failure.unsupported(let message): return Failure("unsupported", prefix + message)
        case ObjectMeasure.Failure.unavailable(let message): return Failure("unavailable", prefix + message)
        case ObjectMeasure.Failure.notFound(let message): return Failure("not_found", prefix + message)
        case ObjectMeasure.Failure.invalidParams(let message): return Failure("invalid_params", prefix + message)
        default: return Failure("invalid_params", prefix + String(describing: error))
        }
    }

    /// Replaces every string `"$n"` in `value` with the id op n created (or an upsert updated).
    private func resolve(_ value: JSONValue, results: [JSONValue], index: Int) throws -> JSONValue {
        try Self.replacingReferences(value) { n, text in
            guard n < index, let id = results[n]["object"]?["id"] else { throw Failure("invalid_params", "\(text) must name an earlier create or upsert op") }
            return id
        }
    }

    /// `value` with each string `"$n"` replaced by what `replacement` gives for n (kept when nil).
    static func replacingReferences(_ value: JSONValue, _ replacement: (Int, String) throws -> JSONValue?) rethrows -> JSONValue {
        switch value {
        case .string(let text):
            guard let n = reference(text) else { return value }
            return try replacement(n, text) ?? value
        case .array(let items): return .array(try items.map { try replacingReferences($0, replacement) })
        case .object(let fields): return .object(try fields.mapValues { try replacingReferences($0, replacement) })
        default: return value
        }
    }

    /// `layout.check`: accidental overlaps, arrows through tiles, labels on tiles or labels,
    /// content that doesn't fit its frame (`overflow`; a code tile's rows past its frame are
    /// `scrolls`: it wraps at its width and scrolls to its range, so only its height can be
    /// short, and a fixed-height viewer is often meant), and truncated captions and note tables, for `ids`, for
    /// what intersects `rect`, or for the whole board. Follow tiles are fixed-size viewers:
    /// never reported. The board is judged as it was when the call arrived: files are read
    /// concurrently and routes computed off the main actor on that snapshot (a whole-board check
    /// is dozens of file reads and an `avoid` grid search per arrow).
    private func check(_ p: JSONValue) async throws -> JSONValue {
        let board: Board
        var scope: Set<ObjectID>?
        var rect: Frame?
        if let ids = p["ids"]?.array?.compactMap(\.string) {
            guard let first = ids.first else { throw Failure("invalid_params", "ids must not be empty") }
            board = try self.board(forObject: first)
            for id in ids where board.objects[id] == nil { throw BoardError.notFound("object \(id) on this board") }
            scope = Set(ids)
        } else {
            board = try self.board(p)
            rect = try p["rect"].map { try $0.decode(Frame.self) }
        }
        let geometry = board.geometry
        let objects = geometry.objects
        let root = board.root
        if let rect {
            let routes = await offPool { geometry.routes() }
            scope = Set(objects.values.filter { object in
                if let path = routes[object.id] { return DrawingGeometry.path(path, crosses: rect.rect) || path.contains { rect.rect.contains($0) } }
                return object.frame.intersects(rect)
            }.map(\.id))
        }
        // Code tiles read from disk: those checked for fit, and those line-bound arrows attach to
        // (their line count bounds the scroll their anchors assume): arrows in scope, and arrows
        // whose route and label may lie on a scoped object (reported too).
        let scoped = scope.map { ids in ids.compactMap { objects[$0]?.frame.rect } }
        var lineBound = Set<ObjectID>()
        for object in objects.values where object.type == .arrow {
            guard let spec = ArrowSpec(object.props) else { continue }
            if let scope, !scope.contains(object.id) {
                let ends = [spec.from, spec.to].compactMap { binding -> CGRect? in
                    switch binding {
                    case .object(let id, _, _, _): objects[id]?.frame.rect
                    case .point(let point): CGRect(origin: point, size: .zero)
                    }
                }
                guard let reach = ends.dropFirst().reduce(ends.first, { $0?.union($1) })?.insetBy(dx: -300, dy: -300),
                      scoped?.contains(where: { $0.intersects(reach) }) == true else { continue }
            }
            for case .object(let id, .some, _, _) in [spec.from, spec.to] { lineBound.insert(id) }
        }
        let read = objects.values.filter { $0.type == .code && ((scope?.contains($0.id) ?? true) || lineBound.contains($0.id)) }
        let excerpts = await withTaskGroup(of: (ObjectID, NoteExcerpt?).self) { group in
            for object in read {
                let props = object.props
                group.addTask { (object.id, try? await ObjectMeasure.codeExcerpt(props, root: root)) }
            }
            var excerpts: [ObjectID: NoteExcerpt] = [:]
            for await (id, excerpt) in group { excerpts[id] = excerpt }
            return excerpts
        }
        let rows = await Self.lineRows(of: lineBound.filter { excerpts[$0] != nil }.compactMap { objects[$0] }, excerpts: excerpts, root: root)
        let measurable = objects.values
            .filter { scope?.contains($0.id) ?? true }
            .filter { $0.type == .code && $0.props["followOf"]?.string == nil || $0.type == .note || ($0.type == .shape && ShapeSpec($0.props)?.kind == .text)
                || ($0.type == .html && ObjectMeasure.html != nil) }
            .sorted { $0.id < $1.id }
        // HTML: each page laid out at its frame's width by the app's WebKit, concurrently.
        let htmlSizes = await withTaskGroup(of: (ObjectID, CGSize?).self) { group in
            for object in measurable where object.type == .html {
                let props = object.props, width = object.frame.w, pageRoot = board.linkRoot(of: object)
                group.addTask { (object.id, try? await ObjectMeasure.htmlExtent(props, width: width, root: pageRoot)) }
            }
            var sizes: [ObjectID: CGSize] = [:]
            for await (id, size) in group { sizes[id] = size }
            return sizes
        }
        // Code: the rows' own extent, wrapped at the frame's (natural) width, so only the height
        // can overflow, zoomed like the tile; a caption too long for the frame is `truncated`.
        let code = measurable.filter { $0.type == .code }
        let (report, codeSizes, captionMissing) = await offPool { [scope] in
            var sizes: [ObjectID: CGSize] = [:]
            var missing: [ObjectID: CGFloat] = [:]
            for object in code {
                guard let excerpt = excerpts[object.id] else { continue }
                let caption = object.props["caption"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                let zoom = object.zoom
                let rows = ObjectMeasure.codeRows(lines: excerpt.lines, fileLineCount: excerpt.fileLineCount, caption: caption != nil, follow: false,
                                                  maxWidth: CGFloat(object.naturalFrame.w))
                sizes[object.id] = ObjectZoom.zoomed(rows, zoom: zoom)
                if let caption { missing[object.id] = (ObjectMeasure.captionWidth(caption) - object.naturalFrame.w) * zoom }
            }
            return (geometry.layoutCheck(scope: scope, rows: rows), sizes, missing)
        }
        var overflow: [JSONValue] = []
        var scrolls: [JSONValue] = []
        var truncated: [JSONValue] = []
        for object in measurable {
            let size: CGSize
            let current = object.frame
            if object.type == .code {
                guard let measured = codeSizes[object.id] else { continue }
                size = measured
                if let missing = captionMissing[object.id], missing >= 1 {
                    truncated.append(.object(["id": .string(object.id), "what": .string("caption"), "x": .number(missing.rounded(.up))]))
                }
            } else if object.type == .html {
                guard let measured = htmlSizes[object.id] else { continue }
                size = measured
            } else if object.type == .note {
                // Wrapped at the frame's (natural) width; a table too wide for it even with its
                // cells wrapped is cut, `truncated`.
                let zoom = CGFloat(object.zoom)
                let measured = await ObjectMeasure.note(object.props, width: CGFloat(object.naturalFrame.w), root: root)
                size = ObjectZoom.zoomed(measured.size, zoom: zoom)
                if measured.tableShortfall >= 1 {
                    truncated.append(.object(["id": .string(object.id), "what": .string("table"), "x": .number((measured.tableShortfall * zoom).rounded(.up))]))
                }
            } else {
                // Text wraps at the frame's width.
                guard let measured = try? await ObjectMeasure.size(type: object.type, props: object.props, width: current.w, root: root) else { continue }
                size = measured
            }
            let x = max(0, size.width - current.w)
            let y = max(0, size.height - current.h)
            guard x >= 1 || y >= 1 else { continue }
            // A code tile wraps at its width and scrolls to its range: rows past its frame are a
            // viewer's scrolling, often meant, not content cut off.
            if object.type == .code {
                scrolls.append(.object(["id": .string(object.id), "y": .number(y.rounded(.up))]))
            } else {
                overflow.append(.object(["id": .string(object.id), "x": .number(x.rounded(.up)), "y": .number(y.rounded(.up))]))
            }
        }
        var result: [String: JSONValue] = [
            "overlaps": .array(report.overlaps.map { .array($0.map(JSONValue.string)) }),
            "arrowCrossings": .array(report.crossings.map { .object(["arrow": .string($0.arrow), "crosses": .array($0.crosses.map(JSONValue.string))]) }),
            "labelOverlaps": .array(report.labelOverlaps.map { overlap in
                let frame = overlap.frame
                return .object(["arrow": .string(overlap.arrow), "label": .string(overlap.label),
                                "frame": .object(["x": .number(frame.x.rounded(.down)), "y": .number(frame.y.rounded(.down)),
                                                  "w": .number(frame.w.rounded(.up)), "h": .number(frame.h.rounded(.up))]),
                                "overlaps": .array(overlap.overlaps.map(JSONValue.string)), "lines": .array(overlap.lines.map(JSONValue.string))])
            }),
            "arrowOverlaps": .array(report.arrowOverlaps.map { overlap in
                .object(["arrows": .array(overlap.arrows.map(JSONValue.string)), "length": .number(overlap.length.rounded()),
                         "at": .object(["x": .number(overlap.at.x.rounded()), "y": .number(overlap.at.y.rounded())])])
            }),
            "arrowIntersections": .array(report.arrowIntersections.map { crossing in
                .object(["arrows": .array(crossing.arrows.map(JSONValue.string)), "count": .number(Double(crossing.count)),
                         "at": .object(["x": .number(crossing.at.x.rounded()), "y": .number(crossing.at.y.rounded())])])
            }),
            "overflow": .array(overflow),
            "scrolls": .array(scrolls),
            "truncated": .array(truncated),
        ]
        if !report.hints.isEmpty { result["hints"] = .array(report.hints.map(JSONValue.string)) }
        return .object(result)
    }

    /// The visual rows line anchors sit on for each of `tiles` (code tiles with an excerpt): its
    /// whole file (at its `pinnedCommit`, if any) wrapped at its natural frame width, the way the
    /// tile shows it, or one row per line when the file can't be read. Each file is read once and
    /// wrapped once per width, concurrently.
    static func lineRows(of tiles: [CanvasObject], excerpts: [ObjectID: NoteExcerpt], root: URL) async -> [ObjectID: CodeRows] {
        struct File: Hashable { var path: String, commit: String?, root: URL }
        // A branch-anchored tile's file is where its ref is now (`RefSource`); a pinned commit wins.
        var fileOf: [ObjectID: File] = [:]
        for tile in tiles {
            guard let path = tile.props["path"]?.string else { continue }
            let pinned = tile.props["pinnedCommit"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            if pinned == nil, let ref = RefSource.ref(of: tile.props) {
                guard let source = try? await RefSource.resolve(ref: ref, lastKnownSha: tile.props["refSha"]?.string, boardRoot: root) else { continue }
                fileOf[tile.id] = File(path: source.fence(NoteFence(path: path)).path ?? path, commit: source.commit, root: source.root)
            } else {
                fileOf[tile.id] = File(path: path, commit: pinned, root: root)
            }
        }
        func file(_ tile: CanvasObject) -> File? { fileOf[tile.id] }
        let files = Set(fileOf.values)
        let texts = await withTaskGroup(of: (File, String?).self) { group in
            for file in files { group.addTask { (file, try? await NoteSource.read(file.path, commit: file.commit, root: file.root)) } }
            var texts: [File: String] = [:]
            for await (file, text) in group { texts[file] = text }
            return texts
        }
        struct Key: Hashable { var file: File, width: Double }
        let keys = Set(tiles.compactMap { tile in file(tile).flatMap { texts[$0] != nil ? Key(file: $0, width: tile.naturalFrame.w) : nil } })
        let wrapped = await withTaskGroup(of: (Key, CodeRows).self) { group in
            for key in keys {
                let text = texts[key.file]!
                group.addTask { (key, await offPool { CodeRows(file: text, width: CGFloat(key.width)) }) }
            }
            var wrapped: [Key: CodeRows] = [:]
            for await (key, rows) in group { wrapped[key] = rows }
            return wrapped
        }
        var rows: [ObjectID: CodeRows] = [:]
        for tile in tiles {
            if let file = file(tile), let found = wrapped[Key(file: file, width: tile.naturalFrame.w)] {
                rows[tile.id] = found
            } else if let excerpt = excerpts[tile.id] {
                rows[tile.id] = CodeRows(lineCount: excerpt.fileLineCount)
            }
        }
        return rows
    }

    // MARK: Helpers

    func string(_ p: JSONValue, _ key: String) throws -> String {
        guard let value = p[key]?.string else { throw Failure("invalid_params", "missing \(key)") }
        return value
    }

    /// Target board: explicit `board`, else the caller tile's board, else the frontmost board.
    func board(_ p: JSONValue) throws -> Board {
        if let id = p["board"]?.string {
            guard let board = registry.board(id: id) else { throw BoardError.notFound("board \(id)") }
            return board
        }
        if let caller = p["caller"]?.string, let board = registry.board(containing: caller) { return board }
        if let id = registry.frontmost, let board = registry.boards[id] { return board }
        throw Failure("not_found", "no open board")
    }

    func board(forObject id: ObjectID) throws -> Board {
        guard let board = registry.board(containing: id) else { throw BoardError.notFound("object \(id)") }
        return board
    }

    /// A caller is only honored when it is a terminal tile, on any open board: an agent working
    /// on another board (`board` given) is credited there as on its own. Placement near it
    /// (`Board.place(near:)`) applies only on its own board.
    func caller(_ p: JSONValue) -> ObjectID? {
        guard let caller = p["caller"]?.string, registry.board(containing: caller)?.objects[caller]?.type == .terminal else { return nil }
        return caller
    }

    /// Heavy props (HTML source, long markdown, a follow tile's location history) are trimmed in
    /// the manifest; object.get returns them whole.
    func summarized(_ object: CanvasObject) -> CanvasObject {
        var copy = object
        if object.type == .html, let html = object.props["html"]?.string {
            copy.props = object.props.merging(.object(["html": .string("(\(html.utf8.count) bytes, use object.get)")]))
        }
        if object.type == .note, let markdown = object.props["markdown"]?.string, markdown.count > 400 {
            copy.props = object.props.merging(.object(["markdown": .string(String(markdown.prefix(400)) + "…")]))
        }
        if object.type == .code, let history = object.props["history"]?.array {
            copy.props = object.props.merging(.object(["history": .string("(\(history.count) locations, use object.get)")]))
        }
        return copy
    }

    func graph(of object: CanvasObject, on board: Board) -> JSONValue {
        let others = board.objects.values.filter { $0.id != object.id && $0.type != .arrow }
        let encloses = board.enclosed(by: object).map(\.id)
        let enclosedBy = others.filter { $0.frame.contains(object.frame) }.map(\.id).sorted()
        let overlaps = others.filter { $0.frame.intersects(object.frame) && !encloses.contains($0.id) && !enclosedBy.contains($0.id) }.map(\.id).sorted()
        var arrowsOut: [JSONValue] = []
        var arrowsIn: [JSONValue] = []
        for arrow in board.objects.values where arrow.type == .arrow {
            let relation = arrow.props["relation"] ?? .null
            if arrow.props["from"]?["object"]?.string == object.id, let to = arrow.props["to"]?["object"]?.string {
                arrowsOut.append(.object(["arrow": .string(arrow.id), "to": .string(to), "relation": relation]))
            }
            if arrow.props["to"]?["object"]?.string == object.id, let from = arrow.props["from"]?["object"]?.string {
                arrowsIn.append(.object(["arrow": .string(arrow.id), "from": .string(from), "relation": relation]))
            }
        }
        // Arrows drawn inside the object connect what it encloses: the structure a drawn box means.
        let arrows: [JSONValue] = board.arrows(enclosedBy: object).map { arrow, spec in
            .object(["arrow": .string(arrow.id), "from": spec.from.json, "to": spec.to.json,
                     "relation": spec.relation.map(JSONValue.string) ?? .null, "label": spec.label.map(JSONValue.string) ?? .null])
        }
        var graph: [String: JSONValue] = [
            "encloses": .array(encloses.map(JSONValue.string)),
            "enclosedBy": .array(enclosedBy.map(JSONValue.string)),
            "overlaps": .array(overlaps.map(JSONValue.string)),
            "arrowsOut": .array(arrowsOut),
            "arrowsIn": .array(arrowsIn),
            "arrows": .array(arrows),
        ]
        if let spec = ArrowSpec(object.props), object.type == .arrow {
            graph["from"] = spec.from.json
            graph["to"] = spec.to.json
        }
        return .object(graph)
    }
}

/// A continuation resumed by the first of several racers; later ones are ignored.
@MainActor
private final class FirstResume<T: Sendable> {
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
