import Foundation

/// An agent without a lifecycle integration (aider, crush, amp …) still says when it waits for the
/// user: a terminal notification (OSC 9, OSC 777 `notify`) or a bell. Such a notification from a
/// terminal where a program holds the foreground and no integration reports becomes the tile's
/// lifecycle (`via: "notifications"`), so the tab's dot, ⌘J, Go to and `agent.wait` treat it as
/// they treat integrated agents:
///
/// - a notification: `done` with its message (the agent waits, not seen yet), or `idle` when the
///   user is looking at the terminal; seeing it turns `done` into `idle`, as for any agent;
/// - Return typed into it (or `agent.prompt`): `unknown` again. A notification comes only when
///   the agent waits after model work (aider rings after an LLM reply, not after `/add` or an
///   answer to its question), so Return can't reliably mean `working`: the state is unknown until
///   the next notification;
/// - never `blocked`: a notification doesn't say whether the agent asks a question or finished;
/// - the shell back at its prompt: the agent exited and the tile is a plain shell again.
///
/// A wrapper that knows its program is an agent (`bin/aider`) reports `unknown` as it starts
/// (`agent.report`), so the tile counts as an agent (the tray's target, `agent.wait`) before the
/// first notification.
public enum NotifyingAgent {
    /// `props.lifecycle.via` of a lifecycle that comes from terminal notifications.
    public static let via = "notifications"

    /// A bell this soon after a key the user typed in the terminal answers that key (vim at Esc,
    /// less at the end, a line editor at a key it has no use for); it says nothing about waiting.
    public static let bellAfterKey: TimeInterval = 1

    /// The terminal's lifecycle comes from its program's terminal notifications.
    public static func reports(_ terminal: CanvasObject) -> Bool {
        terminal.props["lifecycle"]?["via"]?.string == via
    }

    /// An agent integration (omp's extension, the hooks, opencode's plugin) reports the
    /// terminal's lifecycle: its badge already shows done and blocked, and the command marks and
    /// titles in the terminal are the agent's, not the user's shell commands.
    public static func integrationReports(_ terminal: CanvasObject) -> Bool {
        guard let state = terminal.props["lifecycle"]?["state"]?.string, state != LifecycleState.unknown.rawValue else { return false }
        return !reports(terminal)
    }

    /// The agent kind a notifying program reports as: its name's first word (`aider`, `crush`).
    public static func kind(program: String) -> String {
        program.split(separator: " ").first.map(String.init) ?? program
    }
}

/// What a terminal's notification did (`Board.terminalNotified`).
public enum TerminalNoticeEffect: Equatable, Sendable {
    /// Nothing: an integration reports the terminal, or the user is looking at it.
    case none
    /// An attention marker on the terminal (the shell at its prompt, or a bell answering a key).
    case marker
    /// The terminal's lifecycle (`NotifyingAgent`).
    case lifecycle
}

extension Board {
    /// A program in terminal `tile` asked for the user: a desktop notification (OSC 9, OSC 777
    /// `notify`) or a bell. `program` is its foreground program (`TerminalName.program`), nil at
    /// the shell's prompt; `watched`: the user is looking at the terminal; `answersKey`: the user
    /// typed in it within `NotifyingAgent.bellAfterKey`. With a program holding the foreground,
    /// it is the lifecycle of the agent in it (`NotifyingAgent`), except a bell that answers a
    /// key; otherwise a marker (`raiseTerminalNotice`) unless watched. A terminal an integration
    /// reports gets neither.
    @discardableResult
    public func terminalNotified(_ tile: ObjectID, message: String, bell: Bool, program: String?, watched: Bool, answersKey: Bool = false) -> TerminalNoticeEffect {
        guard let terminal = objects[tile], terminal.type == .terminal, !NotifyingAgent.integrationReports(terminal) else { return .none }
        if let program, !(bell && answersKey) {
            let kind = (NotifyingAgent.reports(terminal) ? terminal.props["agent"]?["kind"]?.string : nil) ?? NotifyingAgent.kind(program: program)
            if watched { seenSinceWorking.insert(tile) } else { seenSinceWorking.remove(tile) }
            setNotifiedLifecycle(tile, kind: kind, state: watched ? .idle : .done, message: message, seen: watched)
            return .lifecycle
        }
        guard !watched else { return .none }
        return raiseTerminalNotice(tile, message: message, bell: bell) ? .marker : .none
    }

    /// Return was pressed in terminal `tile` (typed, or `agent.prompt`): an agent reporting by
    /// notification may now work on it, or not (a command, an answer to its question), so its
    /// state is `unknown` until its next notification. False when the terminal's lifecycle
    /// doesn't come from notifications or is unknown already.
    @discardableResult
    public func notifyingAgentSubmitted(_ tile: ObjectID) -> Bool {
        guard let terminal = objects[tile], NotifyingAgent.reports(terminal),
              terminal.props["lifecycle"]?["state"]?.string != LifecycleState.unknown.rawValue,
              let kind = terminal.props["agent"]?["kind"]?.string else { return false }
        setNotifiedLifecycle(tile, kind: kind, state: .unknown, message: nil, seen: nil)
        return true
    }

    /// Terminal `tile`'s foreground program is now `program` (nil: the shell is at its prompt).
    /// An agent reporting by notification ends with its program: at the prompt the tile is a
    /// plain shell again (`releaseAgent`). A program it runs meanwhile (an editor) doesn't end it.
    /// So does an integrated agent still said to be `working` or `blocked` (killed, or exited
    /// while easl was away, without the `agent.release` its integration sends at exit): the
    /// shell holds the terminal, so nothing there is in a turn, and nothing there drains the
    /// composer's prompts.
    public func terminalProgram(_ tile: ObjectID, is program: String?) {
        guard program == nil, let terminal = objects[tile] else { return }
        dropComposerPrompts(of: tile)
        let state = terminal.props["lifecycle"]?["state"]?.string
        let busy = state == LifecycleState.working.rawValue || state == LifecycleState.blocked.rawValue
        guard NotifyingAgent.reports(terminal) || busy else { return }
        try? releaseAgent(tile: tile)
    }

    private func setNotifiedLifecycle(_ tile: ObjectID, kind: String, state: LifecycleState, message: String?, seen: Bool?) {
        guard let terminal = objects[tile] else { return }
        var lifecycle: [String: JSONValue] = ["state": .string(state.rawValue), "via": .string(NotifyingAgent.via)]
        if let seen { lifecycle["seen"] = .bool(seen) }
        if let message { lifecycle["message"] = .string(message) }
        let agent: JSONValue = .object(["kind": .string(kind)])
        guard terminal.props["lifecycle"] != .object(lifecycle) || terminal.props["agent"] != agent else { return }
        _ = try? update(tile, props: .object(["lifecycle": .object(lifecycle), "agent": agent]), caller: tile)
        onEvent?(.agentLifecycle(tile: tile, lifecycle: .object(lifecycle)))
    }
}
