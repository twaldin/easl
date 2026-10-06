import Foundation

/// Board objects an agent attaches to its `agent.prompt` for another agent (`mentions`). They
/// wait for that terminal only, never in the user's tray, and reach it the way staged Hyper-click
/// mentions do: resolved when its integration drains the next prompt it submits (the one
/// `agent.prompt` typed), under a block that names the sending terminal. The board hands off the
/// same way on its own account (an answered question to its asker), under a `header` of its own.
/// In memory only.
public struct Handoff: Equatable, Sendable {
    public var mention: Mention
    /// The prompting terminal, and how the tray names it (`PromptTarget.label`); nil for a script.
    public var from: ObjectID?
    public var fromName: String?
    /// What the block says above the mentions instead of naming who attached them.
    public var header: String?

    public init(mention: Mention, from: ObjectID?, fromName: String?, header: String? = nil) {
        self.mention = mention
        self.from = from
        self.fromName = fromName
        self.header = header
    }
}

/// One `agent.prompt` mention as a caller gives it: an object, optionally lines of a code tile
/// or a pixel of an image tile, i.e. the places a Hyper-click can mention.
public struct HandoffMention: Sendable {
    public var object: ObjectID
    public var lines: LineRange?
    /// A pixel of an image tile's picture, in the image's own pixels from its top-left.
    public var point: (x: Int, y: Int)?

    public init(object: ObjectID, lines: LineRange? = nil, point: (x: Int, y: Int)? = nil) {
        self.object = object
        self.lines = lines
        self.point = point
    }

    static let keys: Set<String> = ["object", "lines", "point"]

    /// Parses `{object, lines?: {start, end}, point?: {x, y}}`, naming what is wrong.
    public init(json: JSONValue) throws {
        guard let fields = json.object else { throw BoardError.invalidParams("a mention is {object, lines?, point?}, not \(json)") }
        let unknown = fields.keys.filter { !Self.keys.contains($0) }.sorted()
        guard unknown.isEmpty else { throw BoardError.invalidParams("unknown mention field \(unknown.joined(separator: ", ")); a mention takes object, lines ({start, end}), point ({x, y})") }
        guard let object = fields["object"]?.string else { throw BoardError.invalidParams("a mention needs an object id") }
        self.object = object
        if let value = fields["lines"] {
            guard let start = value["start"]?.int, let end = value["end"]?.int, start >= 1, end >= start else {
                throw BoardError.invalidParams("mention lines are {start, end}, 1-based, end ≥ start")
            }
            lines = LineRange(start: start, end: end)
        }
        if let value = fields["point"] {
            guard let x = value["x"]?.int, let y = value["y"]?.int, x >= 0, y >= 0 else {
                throw BoardError.invalidParams("a mention point is {x, y}: pixels from the image's top-left")
            }
            point = (x, y)
        }
    }

    /// What a Hyper-click on the same place stages: lines of a code tile (without lines, the
    /// range the tile shows, if any) are a code mention of its file, at its pinned commit; a
    /// point of an image tile an image mention; anything else the whole object.
    @MainActor
    public func target(on board: Board) throws -> MentionTarget {
        guard let tile = board.objects[object] else {
            throw BoardError.notFound("object \(object) is not on board \(board.id), the target terminal's board")
        }
        switch tile.type {
        case .code where point == nil:
            let range = lines ?? tile.props["range"].flatMap { try? $0.decode(LineRange.self) }
            guard var path = tile.props["path"]?.string, let range else { return .object(object) }
            var commit = tile.props["pinnedCommit"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            // A branch-anchored tile: the file in the worktree that has the ref checked out, else
            // the SHA the tile last resolved it to.
            if commit == nil, let ref = RefSource.ref(of: tile.props) {
                if let live = RefSource.liveRoot(ref: ref, boardRoot: board.root) {
                    path = board.relativePath(path.hasPrefix("/") ? path : live.appendingPathComponent(path).path)
                } else {
                    commit = tile.props["refSha"]?.string ?? ref
                }
            }
            return .code(object: object, path: path, lines: range, symbol: lines == nil ? tile.props["symbol"]?.string : nil, commit: commit)
        case .image where lines == nil:
            guard let point, let path = tile.props["path"]?.string else { return .object(object) }
            return .image(object: object, path: path, x: point.x, y: point.y)
        default:
            guard lines == nil, point == nil else {
                throw BoardError.invalidParams("lines take a code tile and point an image tile; mention \(tile.type.rawValue) \(object) by its id alone")
            }
            return .object(object)
        }
    }
}

extension Board {
    /// Queues mentions for `terminal`'s next drained prompt, after any already waiting there (a
    /// target already waiting isn't queued twice). Returns the queued mentions. `header` replaces
    /// the block's "Attached by …" line (the board's own hand-offs).
    @discardableResult
    public func handOff(_ targets: [MentionTarget], to terminal: ObjectID, from: ObjectID?, fromName: String?, header: String? = nil) throws -> [Mention] {
        let tile = try object(terminal)
        guard tile.type == .terminal else { throw BoardError.invalidParams("\(terminal) is not a terminal tile") }
        var queued: [Mention] = []
        for target in targets {
            for id in target.objectIDs where objects[id] == nil { throw BoardError.notFound("object \(id)") }
            if handoffs[terminal]?.contains(where: { $0.mention.target == target }) == true || queued.contains(where: { $0.target == target }) { continue }
            queued.append(Mention(id: IDs.make("men"), target: target, label: MentionContext.label(for: target, on: self), stagedAt: Date()))
        }
        handoffs[terminal, default: []].append(contentsOf: queued.map { Handoff(mention: $0, from: from, fromName: fromName, header: header) })
        return queued
    }

    /// The mentions handed to `caller`, resolved now and numbered from `index`, with one context
    /// block per sending terminal (or board header), in the order they were sent. A question's
    /// answer whose question is no longer answered (or gone) is dropped, not delivered.
    func resolveHandoffs(for caller: ObjectID, from index: Int) async -> (mentions: [MentionContext.Resolved], blocks: [String]) {
        let waiting = (handoffs[caller] ?? []).filter(handoffStands)
        if waiting.count != handoffs[caller]?.count ?? 0 { handoffs[caller] = waiting.isEmpty ? nil : waiting }
        var senders: [(from: ObjectID?, header: String?)] = []
        for handoff in waiting where !senders.contains(where: { $0.from == handoff.from && $0.header == handoff.header }) {
            senders.append((handoff.from, handoff.header))
        }
        var resolved: [MentionContext.Resolved] = []
        var blocks: [String] = []
        for sender in senders {
            let group = waiting.filter { $0.from == sender.from && $0.header == sender.header }
            let block = await handoffBlock(group.map(\.mention), from: sender.from, fromName: group.first?.fromName, header: sender.header, for: caller, index: index + resolved.count)
            resolved.append(contentsOf: block.resolved)
            blocks.append(block.text)
        }
        return (resolved, blocks)
    }

    /// One sender's mentions for `caller`, resolved now and numbered from `index`, under the
    /// block header naming that sender (or `header`, a board's own): what a drain gives a
    /// hand-off and `agent.inbox` a message.
    func handoffBlock(_ mentions: [Mention], from sender: ObjectID?, fromName: String?, header: String? = nil, for caller: ObjectID, index: Int) async -> (resolved: [MentionContext.Resolved], text: String) {
        var part: [MentionContext.Resolved] = []
        for mention in mentions {
            part.append(await MentionContext.resolve(mention, index: index + part.count, on: self, caller: caller))
        }
        let name = fromName.map { " \"\($0)\"" } ?? ""
        let header = header ?? sender.map { "Attached by terminal \($0)\(name) to its prompt to you (agent.prompt):" } ?? "Attached by a script to its prompt to you (agent.prompt):"
        return (part, MentionContext.render(part, board: self, targets: mentions.map(\.target), from: sender, header: header))
    }

    /// Drops delivered (or withdrawn) handed mentions.
    func commitHandoffs(_ ids: [MentionID]) {
        for (terminal, waiting) in handoffs {
            let left = waiting.filter { !ids.contains($0.mention.id) }
            handoffs[terminal] = left.isEmpty ? nil : left
        }
    }

    /// A deleted object takes the mentions of it with it; a deleted terminal its queue, its
    /// messages and its last answer.
    func forgetHandoffs(of id: ObjectID) {
        handoffs[id] = nil
        finalAnswers[id] = nil
        turnErrors[id] = nil
        for (terminal, waiting) in handoffs {
            let left = waiting.filter { !$0.mention.target.objectIDs.contains(id) }
            handoffs[terminal] = left.isEmpty ? nil : left
        }
        forgetMessages(of: id)
    }
}
