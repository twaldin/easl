import Foundation

/// An out-of-band `agent.prompt` (docs/contracts.md, Peer messages): queued for a terminal whose
/// agent integration takes messages (`PromptTarget.takesMessages`), which takes it with
/// `agent.inbox` and hands it to its agent without typing into the terminal. In memory only.
public struct AgentMessage: Equatable, Sendable {
    public enum When: String, Sendable {
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
}

extension PromptTarget {
    /// The terminal's integration takes out-of-band messages (agent.report `protocol` ≥ 1), so
    /// `agent.prompt` queues for it instead of typing.
    public static func takesMessages(_ terminal: CanvasObject) -> Bool {
        drains(terminal) && (terminal.props["agent"]?["protocol"]?.int ?? 0) >= 1
    }
}

extension Board {
    /// Queues `message` for `terminal`, after those already waiting.
    public func queueMessage(_ message: AgentMessage, to terminal: ObjectID) throws {
        let tile = try object(terminal)
        guard tile.type == .terminal else { throw BoardError.invalidParams("\(terminal) is not a terminal tile") }
        messages[terminal, default: []].append(message)
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
        let left = waiting.filter { !ids.contains($0.id) }
        messages[terminal] = left.isEmpty ? nil : left
        return acked
    }

    /// A released agent or a deleted terminal takes its undelivered messages along; a deleted
    /// object leaves the messages that mentioned it, without that mention.
    func forgetMessages(of id: ObjectID) {
        messages[id] = nil
        for (terminal, waiting) in messages {
            messages[terminal] = waiting.map { message in
                var message = message
                message.mentions.removeAll { $0.target.objectIDs.contains(id) }
                return message
            }
        }
    }

    /// The message as `agent.inbox` hands it to `terminal`'s integration: the sender's name and
    /// address as they are now, and its mentions resolved now into the hand-off block a drain
    /// gives (`handoffBlock`).
    func delivered(_ message: AgentMessage, to terminal: ObjectID, boards: [Board]) async -> JSONValue {
        var from: [String: JSONValue] = [:]
        var senderName: String?
        if let sender = message.from {
            from["tile"] = .string(sender)
            if let board = boards.first(where: { $0.objects[sender] != nil }), let tile = board.objects[sender] {
                senderName = PromptTarget.label(tile, shownTitle: nil)
                from["name"] = .string(senderName!)
                from["address"] = .string(AgentAddress.address(of: tile, on: board))
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
