import Foundation

/// Mirrors `definitions` in schema/easl-api.json. Change the schema first.
public typealias ObjectID = String
public typealias BoardID = String
public typealias MentionID = String

public enum IDs {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Prefixed, time-sortable id: `obj_01J…`.
    public static func make(_ prefix: String) -> String {
        var value = UInt64(Date().timeIntervalSince1970 * 1000)
        var time = ""
        for _ in 0..<10 {
            time.insert(alphabet[Int(value & 31)], at: time.startIndex)
            value >>= 5
        }
        let random = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return "\(prefix)_\(time)\(String(random))"
    }
}

public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }

    public func intersects(_ other: Frame) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func contains(_ other: Frame) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }
}

public enum Actor: Codable, Equatable, Sendable {
    case user
    case agent(tile: ObjectID)

    private enum CodingKeys: String, CodingKey { case kind, tile }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "agent": self = .agent(tile: try container.decode(String.self, forKey: .tile))
        default: self = .user
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .kind)
        case .agent(let tile):
            try container.encode("agent", forKey: .kind)
            try container.encode(tile, forKey: .tile)
        }
    }

    /// Callers identify themselves by terminal tile id; no caller means the user.
    public init(caller: ObjectID?) {
        self = caller.map { .agent(tile: $0) } ?? .user
    }
}

public enum ObjectType: String, Codable, Sendable, CaseIterable {
    case terminal, browser, code, note, html, changes, image, diagram, shape, arrow, group

    /// The props this type defines (schema `TerminalProps` … `GroupProps`), `key` among them for
    /// every type (`Board+Keys.swift`). Others are kept but reported: `object.create`/`object.update`
    /// name them in `warnings`.
    public var knownProps: Set<String> {
        let own: Set<String> = switch self {
        case .terminal: ["cwd", "command", "zmxSession", "title", "name", "agent", "lifecycle", "follow", "zoom", "worktree", "branch"]
        case .browser: ["url", "title", "pageTitle", "zoom", "profile", "reloadOnChange"]
        case .code: ["path", "range", "anchor", "symbol", "caption", "diffBase", "followOf", "lastAction", "lastChanges", "history", "pinnedCommit", "ref", "refSha", "zoom"]
        case .note: ["markdown", "title", "root", "ref", "refSha", "zoom"]
        case .html: ["html", "title", "root", "ref", "refSha", "allowNetwork", "state", "zoom"]
        case .changes: ["root", "base", "head", "ref", "refSha", "paths", "title", "reviewed", "viewed", "zoom"]
        case .image: ["path", "caption", "title"]
        case .diagram: ["kind", "path", "symbol", "line", "direction", "depth", "expanded", "title", "graph", "zoom"]
        case .shape: ["kind", "text", "points", "color", "fill", "textSize"]
        case .arrow: ["from", "to", "relation", "label", "color", "route"]
        case .group: ["members", "title", "color", "padding", "flow"]
        }
        return own.union(["key"])
    }

    /// One warning per key of `props` this type doesn't define, in key order.
    public func unknownPropWarnings(_ props: JSONValue?) -> [String] {
        guard let keys = props?.object?.keys else { return [] }
        let known = knownProps
        return keys.filter { !known.contains($0) }.sorted().map { key in
            "unknown prop \"\(key)\" for \(rawValue) (kept, but nothing reads it; \(rawValue) props: \(known.sorted().joined(separator: ", ")))"
        }
    }
}

public struct CanvasObject: Codable, Equatable, Sendable {
    public var id: ObjectID
    public var type: ObjectType
    public var frame: Frame
    public var z: Double
    public var rev: Int
    public var parent: ObjectID?
    public var createdBy: Actor
    public var updatedBy: Actor?
    public var createdAt: Date
    public var updatedAt: Date
    public var props: JSONValue

    public init(id: ObjectID, type: ObjectType, frame: Frame, z: Double, rev: Int = 1, parent: ObjectID? = nil, createdBy: Actor, createdAt: Date, props: JSONValue) {
        self.id = id
        self.type = type
        self.frame = frame
        self.z = z
        self.rev = rev
        self.parent = parent
        self.createdBy = createdBy
        self.updatedBy = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.props = props
    }
}

public struct LineRange: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// `{"start": N, "end": M}`, as props and API results carry it.
    public var json: JSONValue {
        .object(["start": .number(Double(start)), "end": .number(Double(end))])
    }
}

/// Where a Hyper-click fell on a picture element (`<canvas>`, `<video>`, `<img>`), in the
/// element's own pixels from its top-left (a canvas's drawing buffer, a video's frame, an image's
/// natural size, through CSS scaling and `object-fit`), and the element's size in them.
public struct ElementPoint: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public enum MentionTarget: Codable, Equatable, Sendable {
    case object(ObjectID)
    /// `commit`: with `side` old or absent, the commit whose version of `path` holds `lines`
    /// (a deleted diff row, a pinned excerpt); with `side` new, the base the working-tree lines
    /// were diffed against. Absent: the lines are in the working tree. `diff`: a changes tile's
    /// word on the lines, e.g. `added line · unstaged hunk` (`ChangeSet.mentionDetail`).
    case code(object: ObjectID, path: String, lines: LineRange, side: String? = nil, symbol: String? = nil, commit: String? = nil, diff: String? = nil)
    /// An element of a page; `point`, for a Hyper-click on a picture (`<canvas>`, `<video>`,
    /// `<img>`), is where in its own pixels.
    case dom(object: ObjectID, url: String, selector: String, text: String?, point: ElementPoint? = nil)
    /// Terminal text: the user's selection, the screen rows around a click, or one command's
    /// block (its output; `command` says what ran, with exit status and duration when known).
    case terminal(object: ObjectID, text: String, part: TerminalPart = .selection, command: TerminalCommand? = nil)
    case group(objects: [ObjectID], name: String?)
    /// A point on an image tile's picture, in the image's own pixels from its top-left.
    case image(object: ObjectID, path: String, x: Int, y: Int)
    /// A block of a note (`NoteItem`) as it read when staged: the drain re-finds it by `text`.
    case note(object: ObjectID, item: NoteItem)
    /// What a browser tile's page reported (a console message, an uncaught error, a failed
    /// request), from the tile's problems list; `url` is the page's.
    case console(object: ObjectID, url: String, entry: PageLogEntry)

    private enum CodingKeys: String, CodingKey { case kind, object, path, lines, side, symbol, commit, diff, url, selector, text, objects, name, x, y, block, headings, part, command, entry, point }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "code":
            self = .code(object: try c.decode(String.self, forKey: .object), path: try c.decode(String.self, forKey: .path), lines: try c.decode(LineRange.self, forKey: .lines), side: try c.decodeIfPresent(String.self, forKey: .side), symbol: try c.decodeIfPresent(String.self, forKey: .symbol), commit: try c.decodeIfPresent(String.self, forKey: .commit), diff: try c.decodeIfPresent(String.self, forKey: .diff))
        case "dom":
            self = .dom(object: try c.decode(String.self, forKey: .object), url: try c.decode(String.self, forKey: .url), selector: try c.decode(String.self, forKey: .selector), text: try c.decodeIfPresent(String.self, forKey: .text),
                        point: try c.decodeIfPresent(ElementPoint.self, forKey: .point))
        case "terminal":
            self = .terminal(object: try c.decode(String.self, forKey: .object), text: try c.decode(String.self, forKey: .text),
                             part: try c.decodeIfPresent(TerminalPart.self, forKey: .part) ?? .selection, command: try c.decodeIfPresent(TerminalCommand.self, forKey: .command))
        case "group":
            self = .group(objects: try c.decode([String].self, forKey: .objects), name: try c.decodeIfPresent(String.self, forKey: .name))
        case "image":
            self = .image(object: try c.decode(String.self, forKey: .object), path: try c.decode(String.self, forKey: .path), x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y))
        case "note":
            self = .note(object: try c.decode(String.self, forKey: .object), item: NoteItem(kind: try c.decode(NoteItem.Kind.self, forKey: .block), headings: try c.decode([String].self, forKey: .headings), lines: try c.decode(LineRange.self, forKey: .lines), text: try c.decode(String.self, forKey: .text)))
        case "console":
            self = .console(object: try c.decode(String.self, forKey: .object), url: try c.decode(String.self, forKey: .url), entry: try c.decode(PageLogEntry.self, forKey: .entry))
        case "object":
            self = .object(try c.decode(String.self, forKey: .object))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown mention kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .object(let id):
            try c.encode("object", forKey: .kind)
            try c.encode(id, forKey: .object)
        case .code(let object, let path, let lines, let side, let symbol, let commit, let diff):
            try c.encode("code", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(path, forKey: .path)
            try c.encode(lines, forKey: .lines)
            try c.encodeIfPresent(side, forKey: .side)
            try c.encodeIfPresent(symbol, forKey: .symbol)
            try c.encodeIfPresent(commit, forKey: .commit)
            try c.encodeIfPresent(diff, forKey: .diff)
        case .dom(let object, let url, let selector, let text, let point):
            try c.encode("dom", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(url, forKey: .url)
            try c.encode(selector, forKey: .selector)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(point, forKey: .point)
        case .terminal(let object, let text, let part, let command):
            try c.encode("terminal", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(text, forKey: .text)
            if part != .selection { try c.encode(part, forKey: .part) }
            try c.encodeIfPresent(command, forKey: .command)
        case .group(let objects, let name):
            try c.encode("group", forKey: .kind)
            try c.encode(objects, forKey: .objects)
            try c.encodeIfPresent(name, forKey: .name)
        case .image(let object, let path, let x, let y):
            try c.encode("image", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(path, forKey: .path)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case .note(let object, let item):
            try c.encode("note", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(item.kind, forKey: .block)
            try c.encode(item.headings, forKey: .headings)
            try c.encode(item.lines, forKey: .lines)
            try c.encode(item.text, forKey: .text)
        case .console(let object, let url, let entry):
            try c.encode("console", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(url, forKey: .url)
            try c.encode(entry, forKey: .entry)
        }
    }

    /// Objects this mention depends on; deleting any of them removes the mention.
    public var objectIDs: [ObjectID] {
        switch self {
        case .object(let id): [id]
        case .code(let object, _, _, _, _, _, _), .dom(let object, _, _, _, _), .terminal(let object, _, _, _), .image(let object, _, _, _), .note(let object, _), .console(let object, _, _): [object]
        case .group(let objects, _): objects
        }
    }
}

extension MentionTarget {
    /// Props that say how an object looks or what the app keeps about it, not what it holds:
    /// a tile's content zoom, a text shape's text size, a changes tile's Viewed folds, a
    /// terminal's lifecycle and agent, a page's own title.
    static let bookkeepingProps: Set<String> = ["zoom", "textSize", "viewed", "lifecycle", "agent", "pageTitle"]

    /// Whether an update of one of its objects (`before` → `after`) changed what this mention
    /// holds, so the chip and the context say "edited". Moving, resizing, zooming or restacking
    /// never does, nor bookkeeping (`bookkeepingProps`). A code mention holds its file's lines,
    /// not the tile's view of them: re-aiming the code tile it came from changes nothing, and
    /// from a changes tile only another base, head, ref, or worktree, or a Stage, Unstage or Discard (or its
    /// undo) of a hunk of that file over the mentioned lines, does; staging another file in the
    /// same tile doesn't. Terminal text and page log entries are what they were when staged.
    public func isEdited(from before: CanvasObject, to after: CanvasObject) -> Bool {
        switch self {
        case .code(_, let path, let lines, let side, _, _, _):
            guard after.type == .changes else { return false }
            if ["base", "root", "head", "ref"].contains(where: { before.props[$0] != after.props[$0] }) { return true }
            let old = before.props["reviewed"]?.array ?? [], new = after.props["reviewed"]?.array ?? []
            // An action appends its entry (the oldest may drop off past the limit); undo removes it.
            let added = new.filter { !old.contains($0) }
            let changed = added.isEmpty ? old.filter { !new.contains($0) } : added
            return changed.contains { Self.review($0, touches: path, lines, side: side) }
        case .terminal, .console:
            return false
        case .object, .dom, .group, .image, .note:
            return Self.content(of: before) != Self.content(of: after)
        }
    }

    private static func content(of object: CanvasObject) -> [String: JSONValue] {
        (object.props.object ?? [:]).filter { !bookkeepingProps.contains($0.key) }
    }

    /// Whether a `props.reviewed` entry acted on these lines of `path`: its whole file, or a
    /// hunk whose span on the mention's side (either side without one) meets them.
    private static func review(_ entry: JSONValue, touches path: String, _ lines: LineRange, side: String?) -> Bool {
        guard entry["path"]?.string == path else { return false }
        guard entry["scope"]?.string != "file" else { return true }
        guard let header = entry["header"]?.string, let mapping = UnifiedDiff.mapping(fromHeader: Substring(header)) else { return true }
        func meets(_ span: Range<Int>) -> Bool {
            // An empty span sits after its line: it touches that line and the next.
            let low = span.isEmpty ? span.lowerBound - 1 : span.lowerBound, high = span.isEmpty ? span.lowerBound : span.upperBound - 1
            return low <= lines.end && lines.start <= high
        }
        switch side {
        case DiffSide.old.rawValue: return meets(mapping.original)
        case DiffSide.new.rawValue: return meets(mapping.modified)
        default: return meets(mapping.original) || meets(mapping.modified)
        }
    }
}

/// Which part of a terminal a terminal mention holds.
public enum TerminalPart: String, Codable, Sendable {
    /// What the user selected.
    case selection
    /// The screen rows around a Hyper-click, the clicked row marked.
    case rows
    /// One command's output, as the shell integration marks it.
    case command
}

public struct Mention: Codable, Equatable, Sendable {
    public var id: MentionID
    public var target: MentionTarget
    public var label: String
    public var stagedAt: Date
    public var edited: Bool

    public init(id: MentionID, target: MentionTarget, label: String, stagedAt: Date, edited: Bool = false) {
        self.id = id
        self.target = target
        self.label = label
        self.stagedAt = stagedAt
        self.edited = edited
    }
}

public enum LifecycleState: String, Codable, Sendable {
    case working, blocked, idle, done, unknown
}
