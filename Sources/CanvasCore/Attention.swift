import Foundation

/// An agent's "look here" on one object (`view.attention`), kept by the board until the user
/// sees the object or someone clears it. Stored with the board, so unseen markers survive
/// restarts; a marker whose object is deleted goes with it.
public struct Attention: Codable, Equatable, Sendable {
    public var object: ObjectID
    public var message: String?
    /// The agent terminal that raised it (the call's `caller`); nil for a call without one.
    public var raisedBy: ObjectID?
    public var raisedAt: Date
    /// Its agent has started a later turn since (its lifecycle went to `working` from idle, done, or no state), so the
    /// agent's next marker replaces it. Absent while the turn that raised it is current.
    public var earlierTurn: Bool?

    public init(object: ObjectID, message: String?, raisedBy: ObjectID?, raisedAt: Date, earlierTurn: Bool? = nil) {
        self.object = object
        self.message = message
        self.raisedBy = raisedBy
        self.raisedAt = raisedAt
        self.earlierTurn = earlierTurn
    }

    /// What a one-line pill (a marker's or blocked agent's bubble, an edge pill) shows of
    /// `message`: its first non-empty line, ending in "…" when more follows (an agent's
    /// multi-paragraph question); the whole message is the pill's tooltip. Nil for no text.
    public static func pillLine(_ message: String?) -> String? {
        let lines = (message ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        return lines.count > 1 ? first + " …" : first
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(object), "active": .bool(true)]
        if let message { fields["message"] = .string(message) }
        if let raisedBy { fields["raisedBy"] = .string(raisedBy) }
        return .object(fields)
    }
}

extension Board {
    /// Raises (or re-raises, replacing the message) the marker on `id`. A marker belongs to its
    /// agent's turn: raising one clears the markers the same agent raised in earlier turns
    /// (before its lifecycle last went to `working` from idle, done, or no state; blocked → working
    /// continues a turn), returned as `cleared`; markers from the
    /// current turn stay, since one answer may point at several things.
    @discardableResult
    public func raiseAttention(_ id: ObjectID, message: String?, caller: ObjectID?) throws -> (marker: Attention, cleared: [ObjectID]) {
        guard objects[id] != nil else { throw BoardError.notFound("object \(id)") }
        var cleared: [ObjectID] = []
        if let caller {
            for old in attention.values.sorted(by: { $0.object < $1.object }) where old.raisedBy == caller && old.earlierTurn == true && old.object != id {
                clearAttention(old.object)
                cleared.append(old.object)
            }
        }
        let marker = Attention(object: id, message: message, raisedBy: caller, raisedAt: Date())
        attention[id] = marker
        onChange?()
        onEvent?(.attentionChanged(object: id, attention: marker))
        return (marker, cleared)
    }

    /// Removes the marker on `id` (the user saw it, or an agent took it back); false when it had none.
    @discardableResult
    public func clearAttention(_ id: ObjectID) -> Bool {
        guard attention.removeValue(forKey: id) != nil else { return false }
        onChange?()
        onEvent?(.attentionChanged(object: id, attention: nil))
        return true
    }

    /// Removes every marker on the board (the user cleared them all at once); the ids cleared.
    /// Markers aren't board history, so this is no undo step.
    @discardableResult
    public func clearAllAttention() -> [ObjectID] {
        let ids = attention.keys.sorted()
        for id in ids { clearAttention(id) }
        return ids
    }

    /// A program in terminal `tile` asked for the user: a desktop notification (OSC 9, OSC 777
    /// `notify`) or a bell. The marker goes on the terminal itself, raised by the app rather than
    /// an agent (no `raisedBy`, so no turn ever clears it; looking at the terminal does). Repeats
    /// coalesce: the same message again changes nothing, and a bell never replaces a marker already
    /// on the terminal, whose message says more. A terminal whose agent integration reports a
    /// lifecycle already shows done and blocked itself, so its notifications (omp posts "Complete"
    /// after every turn) raise nothing (`NotifyingAgent.integrationReports`). False when nothing
    /// changed. A program's notifications go through `terminalNotified` first.
    @discardableResult
    public func raiseTerminalNotice(_ tile: ObjectID, message: String, bell: Bool) -> Bool {
        guard let terminal = objects[tile], terminal.type == .terminal, !NotifyingAgent.integrationReports(terminal) else { return false }
        if let current = attention[tile], bell || current.message == message { return false }
        _ = try? raiseAttention(tile, message: message, caller: nil)
        return true
    }

    /// The marker text for a desktop notification: "title: body", or whichever part is there.
    public static func noticeMessage(title: String, body: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines), body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return body.isEmpty ? "Notification" : body }
        return body.isEmpty ? title : "\(title): \(body)"
    }

    /// `tile`'s agent started a new turn: its markers so far belong to earlier turns.
    func agentStartedTurn(_ tile: ObjectID) {
        var changed = false
        for (id, marker) in attention where marker.raisedBy == tile && marker.earlierTurn != true {
            attention[id]?.earlierTurn = true
            changed = true
        }
        if changed { onChange?() }
    }
}

/// What a board's agents need from the user, for places that stand for the whole board (its
/// tab): a blocked agent (waiting on an approval or answer) first, else one that finished and
/// hasn't been seen (`done`). Working and idle agents need nothing and say nothing.
public struct NeedsYou: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case done, blocked
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var level: Level
    /// Terminals at that level.
    public var terminals: [ObjectID]
    /// The first such terminal's lifecycle message (a blocked agent's "approve Edit?").
    public var message: String?

    public init(level: Level, terminals: [ObjectID], message: String?) {
        self.level = level
        self.terminals = terminals
        self.message = message
    }

    /// Nil when no terminal is blocked or done.
    public static func of<Objects: Sequence>(_ objects: Objects) -> NeedsYou? where Objects.Element == CanvasObject {
        var found: [Level: [CanvasObject]] = [:]
        for object in objects where object.type == .terminal {
            switch object.props["lifecycle"]?["state"]?.string {
            case LifecycleState.blocked.rawValue: found[.blocked, default: []].append(object)
            case LifecycleState.done.rawValue: found[.done, default: []].append(object)
            default: break
            }
        }
        guard let level = found.keys.max(), let terminals = found[level]?.sorted(by: { $0.id < $1.id }) else { return nil }
        let message = terminals.lazy.compactMap { $0.props["lifecycle"]?["message"]?.string }.first { !$0.isEmpty }
        return NeedsYou(level: level, terminals: terminals.map(\.id), message: message)
    }
}

/// One thing on a board that needs the user, for Go to Next Needs-You (⌘J) and the top of Go to:
/// a blocked agent's terminal (waiting on an approval or answer), an open question tile (an ask
/// waiting on the user's answer: Question.swift), an object with an attention marker, or a done
/// agent's terminal (finished, its result not seen yet).
public struct NeedsYouItem: Equatable, Sendable {
    public enum Reason: Int, Comparable, Sendable {
        case blocked, question, marked, done
        public static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: ObjectID
    public var reason: Reason
    /// The lifecycle's or the marker's message; a question's question.
    public var message: String?
    public var frame: Frame

    public init(id: ObjectID, reason: Reason, message: String?, frame: Frame) {
        self.id = id
        self.reason = reason
        self.message = message
        self.frame = frame
    }

    /// Blocked terminals first, then open questions, then marked objects, then done terminals,
    /// each in reading order (top to bottom, then left to right).
    static func precedes(_ lhs: NeedsYouItem, _ rhs: NeedsYouItem) -> Bool {
        (lhs.reason.rawValue, lhs.frame.y, lhs.frame.x, lhs.id) < (rhs.reason.rawValue, rhs.frame.y, rhs.frame.x, rhs.id)
    }

    /// What needs the user on a board at `now`, in visiting order; an object is listed once:
    /// blocked, else an open question (not past its `expiresAt`), else marked, else done. A done
    /// agent stops being listed once seen (it turns `idle`), a question once it is answered,
    /// cancelled or expired.
    public static func all(_ objects: [ObjectID: CanvasObject], attention: [ObjectID: Attention], now: Date = Date()) -> [NeedsYouItem] {
        var items: [NeedsYouItem] = []
        for object in objects.values {
            let state = object.type == .terminal ? object.props["lifecycle"]?["state"]?.string : nil
            let question = object.type == .question ? QuestionSpec(object.props) : nil
            if state == LifecycleState.blocked.rawValue {
                items.append(NeedsYouItem(id: object.id, reason: .blocked, message: object.props["lifecycle"]?["message"]?.string, frame: object.frame))
            } else if let question, question.isWaiting(at: now) {
                items.append(NeedsYouItem(id: object.id, reason: .question, message: question.question, frame: object.frame))
            } else if let marker = attention[object.id] {
                items.append(NeedsYouItem(id: object.id, reason: .marked, message: marker.message, frame: object.frame))
            } else if state == LifecycleState.done.rawValue, object.props["lifecycle"]?["seen"]?.bool != true {
                items.append(NeedsYouItem(id: object.id, reason: .done, message: object.props["lifecycle"]?["message"]?.string, frame: object.frame))
            }
        }
        return items.sorted(by: precedes)
    }

    /// The item after `last` (the one visited last, as it was then) in visiting order, wrapping
    /// around; the first without one. Visiting a marked object clears its marker, so `last` is
    /// often gone from `items`: the next is still the one after its place.
    public static func next(after last: NeedsYouItem?, in items: [NeedsYouItem]) -> NeedsYouItem? {
        last.flatMap { following($0, in: items) } ?? items.first
    }
}
