import Foundation

/// Board objects attached to a prompt for one terminal: an agent's `agent.prompt` `mentions`, or
/// the composer's tokens for a terminal that isn't the tray's target (`byUser`). They wait for
/// that terminal only, never in the user's tray, and reach it the way staged Hyper-click mentions
/// do: resolved when its integration drains the next prompt it submits (the one `agent.prompt`
/// typed). An agent's come under a block that names the sending terminal; the user's come first,
/// numbered from 1 in a block like the tray's, so the `[n]` in the composer's prompt is theirs.
/// In memory only.
public struct Handoff: Equatable, Sendable {
    public var mention: Mention
    /// The prompting terminal, and how the tray names it (`PromptTarget.label`); nil for a script
    /// or the user.
    public var from: ObjectID?
    public var fromName: String?
    /// Sent from the composer by the user.
    public var byUser: Bool

    public init(mention: Mention, from: ObjectID?, fromName: String?, byUser: Bool = false) {
        self.mention = mention
        self.from = from
        self.fromName = fromName
        self.byUser = byUser
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
    /// Queues mentions for `terminal`'s next drained prompt, after any of the same sender's (the
    /// user, or any agent or script) already waiting there; a target already waiting from that
    /// side isn't queued twice. Returns the queued mentions.
    @discardableResult
    public func handOff(_ targets: [MentionTarget], to terminal: ObjectID, from: ObjectID?, fromName: String?, byUser: Bool = false) throws -> [Mention] {
        let tile = try object(terminal)
        guard tile.type == .terminal else { throw BoardError.invalidParams("\(terminal) is not a terminal tile") }
        var queued: [Mention] = []
        for target in targets {
            for id in target.objectIDs where objects[id] == nil { throw BoardError.notFound("object \(id)") }
            if handoffs[terminal]?.contains(where: { $0.byUser == byUser && $0.mention.target == target }) == true || queued.contains(where: { $0.target == target }) { continue }
            queued.append(Mention(id: IDs.make("men"), target: target, label: MentionContext.label(for: target, on: self), stagedAt: Date()))
        }
        handoffs[terminal, default: []].append(contentsOf: queued.map { Handoff(mention: $0, from: from, fromName: fromName, byUser: byUser) })
        return queued
    }

    /// The mentions handed to `caller`, resolved now and numbered from `index`: the user's first
    /// (one block without a header, like the tray's), then one block per sending terminal (in the
    /// order they were sent).
    func resolveHandoffs(for caller: ObjectID, from index: Int) async -> (mentions: [MentionContext.Resolved], blocks: [String]) {
        let waiting = handoffs[caller] ?? []
        var groups: [[Handoff]] = []
        let user = waiting.filter(\.byUser)
        if !user.isEmpty { groups.append(user) }
        var senders: [ObjectID?] = []
        for handoff in waiting where !handoff.byUser && !senders.contains(handoff.from) { senders.append(handoff.from) }
        for sender in senders { groups.append(waiting.filter { !$0.byUser && $0.from == sender }) }
        var resolved: [MentionContext.Resolved] = []
        var blocks: [String] = []
        for group in groups {
            var part: [MentionContext.Resolved] = []
            for handoff in group {
                part.append(await MentionContext.resolve(handoff.mention, index: index + resolved.count + part.count, on: self, caller: caller))
            }
            resolved.append(contentsOf: part)
            let targets = group.map(\.mention.target)
            guard let first = group.first, !first.byUser else {
                blocks.append(MentionContext.render(part, board: self, targets: targets))
                continue
            }
            let name = first.fromName.map { " \"\($0)\"" } ?? ""
            let header = first.from.map { "Attached by terminal \($0)\(name) to its prompt to you (agent.prompt):" } ?? "Attached by a script to its prompt to you (agent.prompt):"
            blocks.append(MentionContext.render(part, board: self, targets: targets, from: first.from, header: header))
        }
        return (resolved, blocks)
    }

    /// Drops delivered (or withdrawn) handed mentions.
    func commitHandoffs(_ ids: [MentionID]) {
        for (terminal, waiting) in handoffs {
            let left = waiting.filter { !ids.contains($0.mention.id) }
            handoffs[terminal] = left.isEmpty ? nil : left
        }
    }

    /// A deleted object takes the mentions of it with it; a deleted terminal its queue and its
    /// last answer.
    func forgetHandoffs(of id: ObjectID) {
        handoffs[id] = nil
        finalAnswers[id] = nil
        turnErrors[id] = nil
        for (terminal, waiting) in handoffs {
            let left = waiting.filter { !$0.mention.target.objectIDs.contains(id) }
            handoffs[terminal] = left.isEmpty ? nil : left
        }
    }
}
