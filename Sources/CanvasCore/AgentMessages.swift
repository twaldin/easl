import Foundation

/// An out-of-band `agent.prompt` (docs/contracts.md, Peer messages): queued for a terminal whose
/// agent integration takes messages (`PromptTarget.takesMessages`), which takes it with
/// `agent.inbox` and hands it to its agent without typing into the terminal. Saved with the board
/// until that integration acks it; when the agent session it was queued for ends first, it
/// bounces (`Board.endAgentSession`).
public struct AgentMessage: Codable, Equatable, Sendable {
    public enum When: String, Codable, Sendable {
        case now
        case nextTurn = "next-turn"
    }

    public var id: String
    public var text: String
    /// The sending terminal; nil for a script.
    public var from: ObjectID?
    /// A script's sender label (`from`); set, the message is the user's even with a caller.
    public var label: String?
    public var when: When
    /// The board objects the sender attached, as a hand-off's (`HandoffMention`).
    public var mentions: [Mention]
    public var queuedAt: Date

    public init(id: String = IDs.make("msg"), text: String, from: ObjectID?, label: String?, when: When, mentions: [Mention], queuedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.from = label == nil ? from : nil
        self.label = label
        self.when = when
        self.mentions = mentions
        self.queuedAt = queuedAt
    }

    /// `agent` when a terminal sent it, `user` for a script (no tile, or a `from` label).
    public var attribution: String { from == nil ? "user" : "agent" }

    /// What a script with no label is called.
    public static let scriptName = "script"
    /// The sender a bounce names (a script's label): easl itself.
    public static let bounceSender = "easl"

    /// What a bounce quotes: the first line, cut at 80 characters, with "…" when anything was cut.
    public var gist: String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        let cut = first.count > 80
        return (cut ? String(first.prefix(80)) : first) + (cut || lines.count > 1 ? "…" : "")
    }
}

/// Messages whose receiver's agent session ended before its integration took them
/// (`Board.endAgentSession`), handed to `Board.onMessagesBounced` once no step is open.
public struct MessageBounce: Sendable {
    /// The terminal they were queued for.
    public let tile: ObjectID
    /// Its name then (`props.name`): a deleted terminal's is gone with it.
    public let name: String?
    public let messages: [AgentMessage]
    /// Its terminal was deleted: bounced only when the step closes with it still gone (a failed
    /// batch puts it back, queue and all).
    let deleted: Bool
}

extension PromptTarget {
    /// The terminal's integration takes out-of-band messages (agent.report `protocol` ≥ 1), so
    /// `agent.prompt` queues for it instead of typing.
    public static func takesMessages(_ terminal: CanvasObject) -> Bool {
        drains(terminal) && (terminal.props["agent"]?["protocol"]?.int ?? 0) >= 1
    }
}

extension Board {
    /// The generation of the agent session in `terminal`: it moves on each time that session ends
    /// (`endAgentSession`), so a message being sent while it does is never queued for whatever
    /// runs there next.
    public func agentSession(of terminal: ObjectID) -> Int { agentSessions[terminal] ?? 0 }

    /// The terminal's integration took messages and died without its `agent.release` (killed, or
    /// crashed: its shell came back to the prompt, `terminalProgram`); nothing there takes a
    /// prompt until an agent reports there again or the tile is released.
    public func agentExited(_ terminal: ObjectID) -> Bool { exitedAgents.contains(terminal) }

    /// Queues `message` for `terminal`, after those already waiting.
    public func queueMessage(_ message: AgentMessage, to terminal: ObjectID) throws {
        let tile = try object(terminal)
        guard tile.type == .terminal else { throw BoardError.invalidParams("\(terminal) is not a terminal tile") }
        messages[terminal, default: []].append(message)
        onChange?()
    }

    /// The mentions `targets` name as a message carries them: one each, in order (a target given
    /// twice once), every object on this board.
    public func messageMentions(_ targets: [MentionTarget]) throws -> [Mention] {
        var mentions: [Mention] = []
        for target in targets where !mentions.contains(where: { $0.target == target }) {
            for id in target.objectIDs where objects[id] == nil { throw BoardError.notFound("object \(id)") }
            mentions.append(Mention(id: IDs.make("men"), target: target, label: MentionContext.label(for: target, on: self), stagedAt: Date()))
        }
        return mentions
    }

    /// Drops the messages `ids` names from `terminal`'s queue (its integration delivered them);
    /// returns those it dropped.
    @discardableResult
    public func ackMessages(_ ids: [String], of terminal: ObjectID) -> [AgentMessage] {
        guard let waiting = messages[terminal] else { return [] }
        let acked = waiting.filter { ids.contains($0.id) }
        guard !acked.isEmpty else { return [] }
        let left = waiting.filter { !ids.contains($0.id) }
        messages[terminal] = left.isEmpty ? nil : left
        onChange?()
        return acked
    }

    /// The agent session in `terminal` ended: released, its integration died, or another session
    /// (another agent, or the same agent's new conversation) took the tile. Its generation moves
    /// on, and the messages still queued for it bounce.
    func endAgentSession(_ terminal: ObjectID) {
        agentSessions[terminal, default: 0] += 1
        guard let waiting = messages.removeValue(forKey: terminal) else { return }
        bouncing.append(MessageBounce(tile: terminal, name: objects[terminal].flatMap(AgentAddress.name(of:)), messages: waiting, deleted: false))
        onChange?()
        flushBounces()
    }

    /// An integration that took messages, idle or done, died without its release (`terminalProgram`):
    /// it takes none any more (`props.agent.protocol` goes), what was queued for it bounces, and
    /// `agent.prompt` and `agent.wait` say it exited. Its lifecycle and last answer stay.
    func messageIntegrationDied(_ tile: ObjectID) {
        guard let terminal = objects[tile], let lifecycle = terminal.props["lifecycle"] else { return }
        exitedAgents.insert(tile)
        let agent = (terminal.props["agent"] ?? .object([:])).merging(.object(["protocol": .null]))
        _ = try? update(tile, props: .object(["agent": agent]), caller: tile)
        endAgentSession(tile)
        onEvent?(.agentLifecycle(tile: tile, lifecycle: lifecycle))
    }

    /// A deleted terminal's undelivered messages bounce once the step that deleted it closes with
    /// it still gone; a deleted object leaves the messages that mentioned it, without that mention.
    func forgetMessages(of removed: CanvasObject) {
        if let waiting = messages.removeValue(forKey: removed.id) {
            bouncing.append(MessageBounce(tile: removed.id, name: AgentAddress.name(of: removed), messages: waiting, deleted: true))
        }
        for (terminal, waiting) in messages where waiting.contains(where: { $0.mentions.contains { $0.target.objectIDs.contains(removed.id) } }) {
            messages[terminal] = waiting.map { message in
                var message = message
                message.mentions.removeAll { $0.target.objectIDs.contains(removed.id) }
                return message
            }
        }
    }

    /// Hands the bounces due to `onMessagesBounced` once no step is open: a deleted terminal's
    /// only if it is still gone.
    func flushBounces() {
        guard !history.isOpen, !bouncing.isEmpty else { return }
        let due = bouncing.filter { !$0.deleted || objects[$0.tile] == nil }
        bouncing = []
        for bounce in due { onMessagesBounced?(bounce) }
    }

    /// The message as `agent.inbox` hands it to `terminal`'s integration: the sender's name and
    /// address as they are now (`boards`, the open boards), and its mentions resolved now into
    /// the hand-off block a drain gives (`handoffBlock`).
    func delivered(_ message: AgentMessage, to terminal: ObjectID, boards: [Board]) async -> JSONValue {
        var from: [String: JSONValue] = [:]
        var senderName: String?
        if let sender = message.from {
            from["tile"] = .string(sender)
            if let board = boards.first(where: { $0.objects[sender] != nil }), let tile = board.objects[sender] {
                senderName = PromptTarget.label(tile, shownTitle: nil)
                from["name"] = .string(senderName!)
                from["address"] = .string(AgentAddress.address(of: tile, on: board, among: boards))
                from["board"] = .string(board.id)
            } else {
                // Closed since it sent: its id still names it.
                from["name"] = .string(sender)
            }
        } else {
            from["name"] = .string(message.label ?? AgentMessage.scriptName)
        }
        var result: [String: JSONValue] = [
            "id": .string(message.id), "text": .string(message.text), "from": .object(from),
            "attribution": .string(message.attribution), "when": .string(message.when.rawValue),
            "queuedAt": .string(message.queuedAt.formatted(.iso8601)),
        ]
        if !message.mentions.isEmpty {
            result["mentions"] = (try? JSONValue.encode(message.mentions)) ?? .array([])
            let block = await handoffBlock(message.mentions, from: message.from, fromName: senderName, for: terminal, index: 1)
            result["context"] = .string(block.text)
        }
        return .object(result)
    }
}
