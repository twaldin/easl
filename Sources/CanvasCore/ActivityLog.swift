import Foundation

/// What the user's window shows: the visible canvas rect (canvas coordinates) and the zoom.
public struct Viewport: Codable, Equatable, Sendable {
    public var rect: Frame
    public var zoom: Double

    public init(rect: Frame, zoom: Double) {
        self.rect = rect
        self.zoom = zoom
    }

    /// Same view for the log's purposes: within a point and a percent of zoom.
    func matches(_ other: Viewport) -> Bool {
        abs(rect.x - other.rect.x) < 1 && abs(rect.y - other.rect.y) < 1 && abs(rect.w - other.rect.w) < 1
            && abs(rect.h - other.rect.h) < 1 && abs(zoom - other.zoom) < 0.01
    }

    public var json: JSONValue {
        .object(["rect": .object(["x": .number(rect.x), "y": .number(rect.y), "w": .number(rect.w), "h": .number(rect.h)]), "zoom": .number(zoom)])
    }
}

/// Who did something, as the activity log names them.
public enum ActivityActor: Equatable, Sendable {
    case user
    case system
    case agent(ObjectID)

    public init(caller: ObjectID?) {
        self = caller.map { .agent($0) } ?? .user
    }

    public var name: String {
        switch self {
        case .user: "user"
        case .system: "system"
        case .agent(let tile): "agent:\(tile)"
        }
    }
}

public struct ActivityEntry: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// `message`: a peer message that bounced, its receiver's agent gone before taking it.
        case created, updated, deleted, viewport, selection, follow, restart, message
    }

    public var seq: Int
    public var rev: Int
    public var at: Date
    public var actor: ActivityActor
    public var kind: Kind
    public var id: ObjectID?
    public var type: ObjectType?
    public var summary: String
    public var viewport: Viewport?
    public var selection: [ObjectID]?
    /// Set on cascades (a group re-fit to its members, an arrow end freed when what it pointed
    /// at was deleted): why this changed, credited to `actor`, whose change caused it.
    public var cause: String? = nil

    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "seq": .number(Double(seq)), "rev": .number(Double(rev)), "at": .string(at.formatted(.iso8601)),
            "actor": .string(actor.name), "kind": .string(kind.rawValue), "summary": .string(summary),
        ]
        if let id { fields["id"] = .string(id) }
        if let type { fields["type"] = .string(type.rawValue) }
        if let viewport { fields["viewport"] = viewport.json }
        if let selection { fields["selection"] = .array(selection.map(JSONValue.string)) }
        if let cause { fields["cause"] = .string(cause) }
        return .object(fields)
    }
}

/// A board's activity, newest `capacity` entries in memory (`board.history`): object changes
/// with their actor, where the user's view came to rest, what they selected, follow re-aims,
/// and app starts. Viewport and selection changes arrive continuously while the user pans or
/// drags a marquee; they are held until quiet for `settleInterval` and logged once, only when
/// they differ from the last logged state.
@MainActor
public final class ActivityLog {
    public static let defaultCapacity = 2000
    public static let settleInterval: TimeInterval = 0.8

    public enum Since: Equatable, Sendable {
        case seq(Int)
        case time(Date)
    }

    public struct Page: Sendable {
        public var entries: [ActivityEntry]
        /// Newest `seq` in the log.
        public var cursor: Int
        /// More entries matched than the limit, or the ring already dropped entries after `since`.
        public var truncated: Bool
        /// `since` names a cursor this log never issued: the app restarted.
        public var restarted: Bool
    }

    public let capacity: Int
    private let clock: () -> Date
    /// Ring storage: `ring[(head + i) % capacity]` is the i-th oldest entry.
    private var ring: [ActivityEntry] = []
    private var head = 0
    public private(set) var cursor = 0

    private struct Pending {
        var actor: ActivityActor
        var rev: Int
        var changedAt: Date
        var viewport: Viewport?
        var selection: [ObjectID]?
    }

    private var pendingViewport: Pending?
    private var pendingSelection: Pending?
    private var loggedViewport: Viewport?
    private var loggedSelection: [ObjectID] = []

    public init(capacity: Int = ActivityLog.defaultCapacity, clock: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.clock = clock
    }

    public var count: Int { ring.count }

    /// Entries, oldest first.
    public var entries: [ActivityEntry] {
        ring.count < capacity ? ring : Array(ring[head...] + ring[..<head])
    }

    public func record(_ kind: ActivityEntry.Kind, actor: ActivityActor, rev: Int, id: ObjectID? = nil, type: ObjectType? = nil, summary: String, cause: String? = nil) {
        settle()
        append(ActivityEntry(seq: 0, rev: rev, at: clock(), actor: actor, kind: kind, id: id, type: type, summary: summary, cause: cause))
    }

    /// Rewrites a logged entry's summary (a cascade that changed the same object again within
    /// its revision). False when the entry has left the ring.
    @discardableResult
    public func amend(seq: Int, summary: String) -> Bool {
        guard let index = ringIndex(seq) else { return false }
        ring[index].summary = summary
        return true
    }

    /// Drops a logged entry (a cascade whose changes within its revision cancelled out).
    public func remove(seq: Int) {
        guard ringIndex(seq) != nil else { return }
        ring = entries.filter { $0.seq != seq }
        head = 0
    }

    /// Seqs are consecutive in the ring except where `remove` left gaps, so search back from the newest.
    private func ringIndex(_ seq: Int) -> Int? {
        guard !ring.isEmpty else { return nil }
        for offset in 0..<ring.count {
            let index = (head + ring.count - 1 - offset) % ring.count
            if ring[index].seq == seq { return index }
            if ring[index].seq < seq { return nil }
        }
        return nil
    }

    /// The view moved (pan, zoom, window resize); logged once it has been still for `settleInterval`.
    public func viewportChanged(_ viewport: Viewport, actor: ActivityActor, rev: Int) {
        pendingViewport = Pending(actor: actor, rev: rev, changedAt: clock(), viewport: viewport)
    }

    public func selectionChanged(_ ids: [ObjectID], actor: ActivityActor, rev: Int) {
        pendingSelection = Pending(actor: actor, rev: rev, changedAt: clock(), selection: ids.sorted())
    }

    /// Logs held viewport/selection changes that have been quiet long enough. Cheap; call it on
    /// a timer after each change and before every read.
    public func settle() {
        let now = clock()
        if let pending = pendingViewport, now.timeIntervalSince(pending.changedAt) >= Self.settleInterval - 0.001, let viewport = pending.viewport {
            pendingViewport = nil
            if loggedViewport.map({ !$0.matches(viewport) }) ?? true {
                loggedViewport = viewport
                let summary = String(format: "view at (%.0f, %.0f) %.0f×%.0f, zoom %.0f%%", viewport.rect.x, viewport.rect.y, viewport.rect.w, viewport.rect.h, viewport.zoom * 100)
                append(ActivityEntry(seq: 0, rev: pending.rev, at: now, actor: pending.actor, kind: .viewport, summary: summary, viewport: viewport))
            }
        }
        if let pending = pendingSelection, now.timeIntervalSince(pending.changedAt) >= Self.settleInterval - 0.001, let ids = pending.selection {
            pendingSelection = nil
            if ids != loggedSelection {
                loggedSelection = ids
                let summary = ids.isEmpty ? "selection cleared" : "selected \(ids.count == 1 ? ids[0] : "\(ids.count) objects")"
                append(ActivityEntry(seq: 0, rev: pending.rev, at: now, actor: pending.actor, kind: .selection, summary: summary, selection: ids))
            }
        }
    }

    public func query(since: Since?, limit: Int, kinds: Set<ActivityEntry.Kind>? = nil) -> Page {
        settle()
        let all = entries
        var restarted = false
        var matching: ArraySlice<ActivityEntry> = all[...]
        switch since {
        case .seq(let cursor) where cursor > self.cursor:
            restarted = true
        case .seq(let cursor):
            matching = all.drop { $0.seq <= cursor }
        case .time(let time):
            matching = all.drop { $0.at <= time }
        case nil:
            break
        }
        // The ring dropped entries the caller hasn't seen.
        var truncated = false
        if case .seq(let cursor) = since, !restarted, let oldest = all.first?.seq, oldest > cursor + 1 { truncated = true }
        if case .time(let time) = since, let oldest = all.first, oldest.seq > 1, oldest.at > time { truncated = true }
        var filtered = kinds.map { kinds in matching.filter { kinds.contains($0.kind) } } ?? Array(matching)
        if filtered.count > limit {
            truncated = true
            filtered.removeFirst(filtered.count - max(0, limit))
        }
        return Page(entries: filtered, cursor: cursor, truncated: truncated, restarted: restarted)
    }

    private func append(_ entry: ActivityEntry) {
        var entry = entry
        cursor += 1
        entry.seq = cursor
        if ring.count < capacity {
            ring.append(entry)
        } else {
            ring[head] = entry
            head = (head + 1) % capacity
        }
    }
}

extension ActivityLog {
    /// One line naming an object for summaries: `note "Plan for…"`, `code src/a.ts:10-20`.
    public static func describe(_ object: CanvasObject) -> String {
        let props = object.props
        func quoted(_ text: String?) -> String {
            guard let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return "" }
            return " \"\(line.count > 40 ? String(line.prefix(40)) + "…" : line)\""
        }
        switch object.type {
        case .code:
            let range = props["range"].flatMap { range -> String? in
                guard let start = range["start"]?.int else { return nil }
                return ":\(start)-\(range["end"]?.int ?? start)"
            } ?? ""
            return "code \(props["path"]?.string ?? "?")\(range)"
        case .note: return "note" + quoted(props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? props["markdown"]?.string)
        case .html: return "html" + quoted(props["title"]?.string)
        case .changes: return ChangesSpec(props).name + quoted(props["title"]?.string)
        case .image: return "image \(props["path"]?.string ?? "?")" + quoted(props["title"]?.string)
        case .diagram: return "diagram" + quoted(DiagramSpec.title(props))
        case .question: return "question" + quoted(props["question"]?.string)
        case .browser: return "browser \(props["url"]?.string ?? "")"
        case .terminal: return "terminal" + quoted(props["name"]?.string ?? props["title"]?.string)
        case .shape: return "shape \(props["kind"]?.string ?? "")" + quoted(props["text"]?.string)
        case .arrow:
            let from = props["from"]?["object"]?.string ?? "point"
            let to = props["to"]?["object"]?.string ?? "point"
            return "arrow \(from) → \(to)" + quoted(props["label"]?.string)
        case .group: return "group" + quoted(props["name"]?.string) + " (\(props["members"]?.array?.count ?? 0) members)"
        }
    }

    static func position(_ frame: Frame) -> String {
        String(format: "(%.0f, %.0f) %.0f×%.0f", frame.x, frame.y, frame.w, frame.h)
    }

    /// What changed between two revisions of an object, or nil when nothing a person sees did.
    static func changes(from before: CanvasObject, to after: CanvasObject) -> String? {
        var parts: [String] = []
        if before.frame.x != after.frame.x || before.frame.y != after.frame.y {
            parts.append(String(format: "moved (%.0f, %.0f) → (%.0f, %.0f)", before.frame.x, before.frame.y, after.frame.x, after.frame.y))
        }
        if before.frame.w != after.frame.w || before.frame.h != after.frame.h {
            parts.append(String(format: "resized %.0f×%.0f → %.0f×%.0f", before.frame.w, before.frame.h, after.frame.w, after.frame.h))
        }
        if before.z != after.z { parts.append("restacked") }
        // A terminal's own bookkeeping is too frequent to log; a page's title and a follow tile's
        // aim are what the history is for, even though ⌘Z skips them.
        let skipped = before.type == .terminal ? UndoHistory.terminalBookkeeping : []
        let old = UndoHistory.props(of: before, without: skipped).object ?? [:]
        let new = UndoHistory.props(of: after, without: skipped).object ?? [:]
        let keys = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
        if !keys.isEmpty { parts.append("props " + keys.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
