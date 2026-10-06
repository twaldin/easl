import Foundation

// Agent control (docs/contracts.md, Agent control): what agent.list says about each terminal
// beyond its lifecycle (pid, focus, draft, closed boards' tiles) and agent.restart.

extension Board {
    /// What every `agent.report` states besides the lifecycle, as `props.agent` keeps it: the
    /// agent's `draft` and `pid`; a report without one leaves it unknown (removed).
    static func reportedAgentState(draft: Bool?, pid: Int?) -> [String: JSONValue] {
        ["draft": draft.map(JSONValue.bool) ?? .null, "pid": pid.map { .number(Double($0)) } ?? .null]
    }
}

/// A terminal's zmx session as this instance sees it (`ApiRouter.terminalSessions`).
public struct TerminalSession: Equatable, Sendable {
    /// Its `canvas.board` label.
    public var board: BoardID?
    /// The foreground process of its shell (the agent, when one runs); nil at the prompt.
    public var pid: Int32?

    public init(board: BoardID?, pid: Int32?) {
        self.board = board
        self.pid = pid
    }
}

extension AgentResume {
    /// What agent.restart runs: `argv` in the new session, and the tile's `command` from then on
    /// (`argv` without the session selector), which a reboot reruns, resuming the session the
    /// new agent records (`TerminalTile.initialCommand`).
    public struct Relaunch: Equatable, Sendable {
        public var argv: [String]
        public var command: [String]
    }

    /// How each agent's command line names a model, and which options it already has for one.
    /// omp 18.6.1 `--help`: `--model=<value>` ("fuzzy match: opus, gpt-5.2, or openai/gpt-5.2"),
    /// `--thinking=<value>` (off, minimal, low, medium, high, xhigh, max, auto), `-r, --resume=<value>`
    /// ("by ID prefix, path, or picker").
    static func modelOption(_ kind: String) -> (names: Set<String>, words: (String) -> [String])? {
        switch kind {
        case "omp": (["--model"], { ["--model=\($0)"] })
        case "claude": (["--model"], { ["--model", $0] })
        case "codex", "gemini", "opencode": (["-m", "--model"], { ["-m", $0] })
        default: nil
        }
    }

    static func thinkingOption(_ kind: String) -> (names: Set<String>, words: (String) -> [String])? {
        kind == "omp" ? (["--thinking"], { ["--thinking=\($0)"] }) : nil
    }

    /// The relaunch of a terminal whose agent is `kind` (nil: none recorded) and whose tile runs
    /// `command`: with `session`, its agent resuming that session; without, a fresh start. The
    /// command's options are kept when it runs that agent (`options(of:)`: its session selectors
    /// and prompt left out), the recorded `model` and `thinking` replace any it gave, and `args`
    /// follow. A terminal with no known agent reruns its `command`, fresh only. Nil when there is
    /// nothing to relaunch.
    public static func relaunch(kind: String?, command: [String], session: String?, model: String?, thinking: String?, args: [String]) -> Relaunch? {
        guard let kind, let grammar = grammar(kind) else {
            guard session == nil, !command.isEmpty else { return nil }
            return Relaunch(argv: command + args, command: command + args)
        }
        let modelFlag = model == nil ? nil : modelOption(kind)
        let thinkingFlag = thinking == nil ? nil : thinkingOption(kind)
        let replaced = (modelFlag?.names ?? Set()).union(thinkingFlag?.names ?? Set())
        let (program, kept) = options(of: command, grammar, dropping: replaced)
        var words = kept
        if let model, let modelFlag { words += modelFlag.words(model) }
        if let thinking, let thinkingFlag { words += thinkingFlag.words(thinking) }
        words += args
        let fresh = [program] + words
        return Relaunch(argv: session.map { grammar.resume(program, words, $0) } ?? fresh, command: fresh)
    }

    /// The session agent.restart resumes from what the agent recorded (`props.agent`): omp's
    /// session file when it reported one (`--resume` takes a path), else the session id.
    static func session(of agent: JSONValue?) -> String? {
        let path = agent?["kind"]?.string == "omp" ? agent?["sessionPath"]?.string : nil
        return (path ?? agent?["sessionId"]?.string).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The terminals of a stored board, as its file has them (agent.list for closed boards).
struct StoredTerminals: Sendable {
    var modified: Date
    var board: BoardID
    var root: String
    var terminals: [CanvasObject]

    /// Every board file in `directory` with its terminals, reusing `cache` entries whose file
    /// hasn't changed since. Reads and decodes files: call it off the main actor.
    static func read(directory: URL, cache: [String: StoredTerminals]) -> [String: StoredTerminals] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var read: [String: StoredTerminals] = [:]
        for file in files where file.pathExtension == "json" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if let cached = cache[file.lastPathComponent], cached.modified == modified {
                read[file.lastPathComponent] = cached
                continue
            }
            guard let data = try? Data(contentsOf: file), let snapshot = try? decoder.decode(BoardSnapshot.self, from: data) else { continue }
            read[file.lastPathComponent] = StoredTerminals(modified: modified, board: snapshot.id, root: snapshot.root,
                                                           terminals: snapshot.objects.filter { $0.type == .terminal })
        }
        return read
    }
}

extension ApiRouter {
    /// What agent control adds to an open board's terminal entry (`agentEntry`). A hosted
    /// terminal's processes are its host's: no pid of this Mac's stands for its agent.
    func agentControlFields(_ terminal: CanvasObject, status: TerminalStatus?) -> [String: JSONValue] {
        var fields = Self.reportedFields(terminal.props["agent"])
        fields["open"] = .bool(true)
        fields["focused"] = .bool(status?.focused ?? false)
        if HostedTerminal.host(of: terminal) == nil, let pid = Self.agentPid(reported: terminal.props["agent"]?["pid"]?.int, session: status?.pid) {
            fields["pid"] = .number(Double(pid))
        }
        return fields
    }

    /// What the agent's integration reported about it that agent.list shows as is.
    private static func reportedFields(_ agent: JSONValue?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        for key in ["protocol", "draft", "model", "thinking"] {
            if let value = agent?[key], value != .null { fields[key] = value }
        }
        return fields
    }

    /// The agent's process: the pid its integration reported while that process lives, else the
    /// foreground process of its session.
    static func agentPid(reported: Int?, session: Int32?) -> Int32? {
        if let reported, reported > 0, reported <= Int(Int32.max), kill(pid_t(reported), 0) == 0 || errno == EPERM { return pid_t(reported) }
        return session
    }

    /// agent.list: every terminal of the open boards, then of the closed ones (their saved files).
    /// With zmx, each local terminal says whether its session runs (`live`), and the session's
    /// foreground process stands in for a pid no integration reported; a hosted terminal's
    /// `live` is its host's easld's session list (`hostedSessions`), when it answers.
    func agentList() async -> JSONValue {
        var terminals: [(object: CanvasObject, entry: JSONValue)] = []
        var listed: Set<ObjectID> = []
        for board in registry.boards.values.sorted(by: { $0.id < $1.id }) {
            for object in board.objects.values.sorted(by: { $0.id < $1.id }) where object.type == .terminal {
                listed.insert(object.id)
                terminals.append((object, agentEntry(object, on: board)))
            }
        }
        let directory = registry.store.directory, cache = storedTerminals
        let stored = await offPool { StoredTerminals.read(directory: directory, cache: cache) }
        storedTerminals = stored
        for board in stored.values.sorted(by: { $0.board < $1.board }) where registry.board(id: board.board) == nil {
            for object in board.terminals.sorted(by: { $0.id < $1.id }) where !listed.contains(object.id) {
                terminals.append((object, Self.closedAgentEntry(object, board: board.board, root: board.root)))
            }
        }
        let local = await terminalSessions?()
        let hosts = Set(terminals.compactMap { HostedTerminal.host(of: $0.object) })
        var hosted: [String: Set<ObjectID>] = [:]
        if !hosts.isEmpty, let hostedSessions { hosted = await hostedSessions(hosts.sorted()) }
        let agents = terminals.map { Self.withSession($0.entry, host: HostedTerminal.host(of: $0.object), local: local, hosted: hosted) }
        return .object(["agents": .array(agents)])
    }

    /// `entry` with what its terminal's session says. A local terminal's is this Mac's zmx, when
    /// sessions are known (`local` non-nil): `live`; without a session no process of it runs (a
    /// pid reported before is stale, or another process's by now); with one, its foreground
    /// process stands in for a pid no integration reported. A hosted terminal's (`host`) is its
    /// host's: `live` when its easld listed its sessions (`hosted`), never this Mac's zmx.
    private static func withSession(_ entry: JSONValue, host: String?, local: [ObjectID: TerminalSession]?, hosted: [String: Set<ObjectID>]) -> JSONValue {
        guard case .object(var fields) = entry, let tile = fields["tile"]?.string else { return entry }
        if let host {
            guard let running = hosted[host] else { return entry }
            fields["live"] = .bool(running.contains(tile))
            return .object(fields)
        }
        guard let local else { return entry }
        let session = local[tile]
        fields["live"] = .bool(session != nil)
        if session == nil { fields["pid"] = nil } else if fields["pid"] == nil, let pid = session?.pid { fields["pid"] = .number(Double(pid)) }
        return .object(fields)
    }

    /// A closed board's terminal as its saved file has it: a saved `working` or `blocked` is only
    /// what it was (`restored`, as opening the board marks it), and nothing is focused there.
    static func closedAgentEntry(_ terminal: CanvasObject, board: BoardID, root: String) -> JSONValue {
        let agent = terminal.props["agent"]
        var lifecycle = terminal.props["lifecycle"]?.object ?? ["state": .string(LifecycleState.unknown.rawValue)]
        if let state = lifecycle["state"]?.string, state == LifecycleState.working.rawValue || state == LifecycleState.blocked.rawValue {
            lifecycle["restored"] = .bool(true)
        }
        let name = terminal.props["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        var entry = reportedFields(agent)
        entry["tile"] = .string(terminal.id)
        entry["board"] = .string(board)
        entry["root"] = .string(root)
        entry["address"] = .string(name.map { "\($0)@\(URL(fileURLWithPath: root).lastPathComponent)" } ?? terminal.id)
        entry["kind"] = agent?["kind"] ?? .string(LifecycleState.unknown.rawValue)
        entry["lifecycle"] = .object(lifecycle)
        entry["open"] = .bool(false)
        entry["focused"] = .bool(false)
        if let name { entry["name"] = .string(name) }
        if let session = agent?["sessionId"], session != .null { entry["sessionId"] = session }
        if HostedTerminal.host(of: terminal) == nil, let pid = agentPid(reported: agent?["pid"]?.int, session: nil) { entry["pid"] = .number(Double(pid)) }
        return .object(entry)
    }

    /// agent.restart: refused while the agent works, has a prompt it hasn't started, waits on its
    /// user, may hold a draft, or the user is in its terminal (unless `force`), and while another
    /// restart of it runs or a prompt's paste is going into it (`pasting`, even with `force`: it
    /// would land in the relaunched agent; a prompt still reading the screen types nothing once
    /// the agent session it was for ended). The terminal is then reserved (`restarting`):
    /// nothing else reaches it until the restart is done. The app checks again just before it
    /// kills the tile's session, and once the session is confirmed gone the killed agent's
    /// session ends (`Board.endAgentSession`: the messages still queued for it bounce, in either
    /// mode) and the tile records the relaunch (`Board.restartedAgent`) before it starts, so what
    /// the relaunched agent reports is its own.
    func restart(_ p: JSONValue) async throws -> JSONValue {
        let (board, terminal) = try agentTile(try string(p, "target"), caller: p["caller"]?.string)
        let mode = try string(p, "mode")
        guard mode == "resume" || mode == "fresh" else { throw Failure("invalid_params", "mode is resume or fresh, not \(mode)") }
        var args: [String] = []
        if let given = p["args"], given != .null {
            let items = given.array ?? []
            args = items.compactMap(\.string)
            guard given.array != nil, args.count == items.count else { throw Failure("invalid_params", "args is an array of strings") }
        }
        guard !restarting.contains(terminal.id) else {
            throw Failure("conflict", "\(terminal.id) is already restarting (another agent.restart): wait for that one to finish")
        }
        if pasting[terminal.id] != nil { throw Self.pastingFailure(terminal.id) }
        let force = p["force"]?.bool == true
        if !force { try refuseRestart(terminal, on: board) }
        let agent = terminal.props["agent"]
        let kind = agent?["kind"]?.string
        let session = mode == "resume" ? AgentResume.session(of: agent) : nil
        if mode == "resume", session == nil || kind.flatMap(AgentResume.grammar) == nil {
            throw Failure("unavailable", "\(terminal.id) has no recorded agent session to resume (its agent never reported one, or it exited); mode fresh starts it anew")
        }
        let command = terminal.props["command"]?.array?.compactMap(\.string) ?? []
        guard let launch = AgentResume.relaunch(kind: kind, command: command, session: session, model: agent?["model"]?.string,
                                                thinking: agent?["thinking"]?.string, args: args) else {
            throw Failure("unavailable", "\(terminal.id) runs no known agent and has no command to relaunch")
        }
        guard let restartTerminal else { throw Failure("unsupported", "restarting needs the app UI") }
        // What the relaunched agent is until it reports: the same agent, model and thinking (and
        // session, resumed), without what only the killed process knew. Taken before the kill:
        // the old agent's release as it exits clears `props.agent`.
        var kept = agent?.object
        kept?["draft"] = nil
        kept?["pid"] = nil
        if mode == "fresh" {
            kept?["sessionId"] = nil
            kept?["sessionPath"] = nil
        }
        let relaunched = kept.map(JSONValue.object) ?? .null
        let tile = terminal.id
        restarting.insert(tile)
        defer {
            restarting.remove(tile)
            serveInbox(tile, on: board)
        }
        try await restartTerminal(board, tile, launch.argv, {
            // Checked again at the kill: a turn, prompt, draft or focus that came since would be lost too.
            guard let current = board.objects[tile] else { throw Failure("not_found", "terminal \(tile) was closed") }
            if self.pasting[tile] != nil { throw Self.pastingFailure(tile) }
            if !force { try self.refuseRestart(current, on: board) }
        }, {
            // Closed while its session was killed: its delete ended the agent session and
            // bounced the queue; there is nothing to relaunch into.
            guard board.objects[tile] != nil else { throw Failure("not_found", "terminal \(tile) was closed while it restarted: nothing was relaunched") }
            board.endAgentSession(tile)
            self.forgetPrompts(to: tile)
            try board.restartedAgent(tile: tile, command: launch.command, agent: relaunched)
        })
        guard let current = board.objects[tile] else { throw Failure("not_found", "terminal \(tile) was closed while it restarted") }
        return .object(["agent": agentEntry(current, on: board), "command": .array(launch.argv.map(JSONValue.string))])
    }

    /// Why agent.restart leaves `terminal` alone without `force`: the dialog, turn, prompt or
    /// draft a restart would lose, in that order, or the user in it. A draft no integration
    /// reports is one the user may have.
    private func refuseRestart(_ terminal: CanvasObject, on board: Board) throws {
        switch Self.state(of: terminal) {
        case LifecycleState.blocked.rawValue:
            let blocker = terminal.props["lifecycle"]?["message"]?.string.map { " (“\($0)”)" } ?? ""
            throw Failure("conflict", "\(terminal.id) is blocked, waiting on its user\(blocker): restarting would drop that dialog; force: true restarts anyway")
        case LifecycleState.working.rawValue:
            throw Failure("conflict", "\(terminal.id) is working: restarting would kill its turn. Wait for it (agent.wait), or force: true restarts anyway")
        default: break
        }
        if promptPending(to: terminal.id) {
            throw Failure("conflict", "\(terminal.id) was just prompted and hasn't started that turn: restarting would lose the prompt. Wait for it (agent.wait), or force: true restarts anyway")
        }
        switch terminal.props["agent"]?["draft"]?.bool {
        case true?:
            throw Failure("conflict", "\(terminal.id)'s input editor holds a draft the user hasn't sent: restarting would lose it; force: true restarts anyway")
        case nil:
            throw Failure("conflict", "nothing in \(terminal.id) reports whether its input holds a draft the user hasn't sent (omp's easl extension does), so restarting could lose one; force: true restarts anyway")
        case false?:
            break
        }
        if terminalStatus?(board, terminal.id).focused == true {
            throw Failure("conflict", "\(terminal.id) has keyboard focus: the user may be typing in it; force: true restarts anyway")
        }
    }
}
