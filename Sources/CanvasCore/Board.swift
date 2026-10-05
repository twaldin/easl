import Foundation

public enum BoardError: Error, Equatable {
    case notFound(String)
    case conflict(String)
    case invalidParams(String)
}

public enum BoardEvent: Sendable {
    case objectCreated(CanvasObject)
    case objectUpdated(CanvasObject)
    case objectDeleted(ObjectID)
    case trayChanged([Mention])
    case agentLifecycle(tile: ObjectID, lifecycle: JSONValue)
    case followUpdated(tile: ObjectID, follow: ObjectID)
    /// A marker raised or replaced (`attention`), or removed (nil).
    case attentionChanged(object: ObjectID, attention: Attention?)

    public var name: String {
        switch self {
        case .objectCreated: "object.created"
        case .objectUpdated: "object.updated"
        case .objectDeleted: "object.deleted"
        case .trayChanged: "tray.changed"
        case .agentLifecycle: "agent.lifecycle"
        case .followUpdated: "follow.updated"
        case .attentionChanged: "attention.changed"
        }
    }

    public var data: JSONValue {
        switch self {
        case .objectCreated(let object), .objectUpdated(let object):
            (try? JSONValue.encode(object)) ?? .null
        case .objectDeleted(let id):
            .object(["id": .string(id)])
        case .trayChanged(let mentions):
            .object(["mentions": (try? JSONValue.encode(mentions)) ?? .array([])])
        case .agentLifecycle(let tile, let lifecycle):
            .object(["tile": .string(tile), "lifecycle": lifecycle])
        case .followUpdated(let tile, let follow):
            .object(["tile": .string(tile), "follow": .string(follow)])
        case .attentionChanged(let id, let attention):
            attention?.json ?? .object(["id": .string(id), "active": .bool(false)])
        }
    }
}

/// Serializable board state; what BoardStore persists.
public struct BoardSnapshot: Codable, Sendable {
    /// On-disk format (`Board.format`); absent in boards saved before tile frames included the
    /// title bar (format 1).
    public var format: Int?
    public var id: BoardID
    public var root: String
    public var revision: Int
    public var objects: [CanvasObject]
    /// Staged mentions survive quit and rebuild; optional so older board files still load.
    public var tray: [Mention]?
    /// Attention markers the user hasn't seen yet; optional so older board files still load.
    public var attention: [Attention]?
    /// What the prompt target rule remembers (`PromptTarget.State`); optional so older board
    /// files still load.
    public var promptTarget: PromptTarget.State?
    /// Each terminal's last answer and the error its last turn ended on (`Board.finalAnswers`,
    /// `Board.turnErrors`), and the highest lifecycle `seq` accepted per "tile|source", so
    /// `agent.read` `final` and the staleness rule survive a restart; optional so older board
    /// files still load.
    public var finalAnswers: [ObjectID: String]?
    public var turnErrors: [ObjectID: String]?
    public var lifecycleSeq: [String: Int]?
    /// The repository this board is for and the worktrees it has seen (RepoBoards.swift); absent
    /// on a board for a directory outside git, and on boards saved before boards were per
    /// repository (legacy boards, `RepoBoardMigration`).
    public var repo: RepoRecord?
}

/// One canvas: all objects for one root directory, the selection tray, and agent lifecycle.
/// Main-actor only; the socket server and UI both mutate it through these methods.
@MainActor
public final class Board {
    public let id: BoardID
    public let root: URL
    public private(set) var objects: [ObjectID: CanvasObject] = [:]
    public private(set) var revision = 0
    public private(set) var tray: [Mention] = []
    /// Mentions that left the tray with a prompt (`drain`) or Hyper-V (`commit`) since the board
    /// opened, never by unstaging or a delete; in memory only (Help › Get Started's last step).
    public private(set) var delivered = 0
    /// Unseen attention markers by object (see Attention.swift).
    public internal(set) var attention: [ObjectID: Attention] = [:]
    /// The repository this board is for (RepoBoards.swift); nil outside git. Saved with the board.
    public internal(set) var repo: RepoRecord?
    /// The worktree the board was last opened from when that isn't the main checkout (in memory):
    /// New Terminal starts there, the window names it (RepoBoards.swift).
    public internal(set) var workingWorktree: GitWorktree?
    /// What the prompt target rule remembers; saved with the board, so the tray targets the
    /// same terminal after a restart. Set by the board's window.
    public var promptTarget = PromptTarget.State() {
        didSet { if promptTarget != oldValue { onChange?() } }
    }
    /// Mentions agents attached to their `agent.prompt` for each terminal, waiting for its next
    /// drained prompt (Handoff.swift); in memory only.
    public internal(set) var handoffs: [ObjectID: [Handoff]] = [:]
    /// Each terminal's last answer: the final assistant message of its agent's last finished
    /// turn, as its integration reported it with `idle` (`agent.read` `final`). A new turn clears
    /// it; saved with the board.
    public internal(set) var finalAnswers: [ObjectID: String] = [:]
    /// The error each terminal's last turn ended on (an API error, an abort, the output limit),
    /// as its integration reported it with `idle`: that turn's `finalAnswers` entry is cut off.
    /// A new turn clears it; saved with the board.
    public internal(set) var turnErrors: [ObjectID: String] = [:]

    /// Board revision at which each object last changed (for `board.get since`).
    private var changedAt: [ObjectID: Int] = [:]
    /// Who holds each `props.key` (`Board+Keys.swift`), kept with `objects` wherever it changes
    /// (commit, delete, load), so undo, redo, and a failed batch's rollback leave it exact. A set,
    /// so a board file that holds one key twice (edited by hand) still loads and says so on lookup.
    private(set) var keyHolders: [String: Set<ObjectID>] = [:]
    /// Terminal tiles the user has seen since their agent last reported `working` (or, reporting
    /// by notification, last notified: `NotifyingAgent`).
    var seenSinceWorking: Set<ObjectID> = []
    /// Highest accepted lifecycle seq per "tile|source"; saved with the board, so a report
    /// replayed after a restart (`AgentReportSpool`) that is older than one already applied is
    /// dropped like any stale report.
    var lifecycleSeq: [String: Int] = [:]
    /// Tool calls each terminal's agent waits on the user to approve, oldest first, with the
    /// blocker message each was reported with (`reportLifecycle` `call`).
    private var pendingApprovals: [ObjectID: [(call: String, message: String?)]] = [:]
    /// Highest `rev` ever issued per object, kept across deletes so an object brought back by
    /// undo/redo never reuses a revision a stale writer might still hold.
    private var revHighWater: [ObjectID: Int] = [:]
    /// While an atomic step runs, every change shares this one board revision.
    private var pinnedRevision: Int?
    /// Per terminal, the code tile its last ⌘-click opened or re-aimed and that tile's `rev`
    /// then (`openCode`); in memory only.
    var codePreviews: [ObjectID: (tile: ObjectID, rev: Int)] = [:]

    public var onEvent: ((BoardEvent) -> Void)?
    /// Content changes by anyone, for ⌘Z; see UndoHistory.
    public let history = UndoHistory()
    /// Who did what, for `board.history` (in memory; see ActivityLog).
    public let activity = ActivityLog()
    /// Set while a change's own entry is written by its caller (follow re-aims).
    private var activityMuted = false
    /// "undo"/"redo" while one replays, so its changes are logged as such, credited to `replayActor`.
    var replayVerb: String?
    var replayActor: ActivityActor = .user
    /// Cascade entries logged in `cascadeRevision`, per object: a later cascade on the same
    /// object in the same revision amends that entry (see `log`).
    private var cascades: [ObjectID: (seq: Int, actor: ActivityActor, before: CanvasObject)] = [:]
    private var cascadeRevision = -1
    /// While positive, group re-fits wait in `pendingRefits` for the end of the outermost
    /// `deferringRefits` (see Groups.swift).
    var refitDeferral = 0
    var pendingRefits: [(member: ObjectID, actor: ActivityActor, caller: ObjectID?)] = []
    /// Called after any persisted change; BoardStore debounces saves.
    public var onChange: (() -> Void)?
    /// The canvas rect the board's window shows (canvas coordinates); nil without a window.
    /// Placement prefers slots inside it.
    public var viewport: () -> Frame? = { nil }
    /// The directory each terminal works in, as the app last read it (`terminalWorks(_:in:)`).
    var workingDirectories: [ObjectID: String] = [:]
    /// An arrow's routed line as currently drawn (canvas coordinates, at least two points), so
    /// deleting what it points at keeps its end exactly where the user saw it and its reported
    /// frame is what is drawn. Without it, routes come from object frames.
    public var arrowPath: ((ObjectID) -> [CGPoint]?)?
    /// Routes what the drawing layer has pending (its `avoid` re-route, which otherwise runs once
    /// per burst of changes, before the next frame), so `arrowPath` answers with what is drawn.
    /// `reported` calls it outside an open step: a batch reports its arrows once its step closes,
    /// routing them once, not once per op. Set by the app.
    public var settleArrows: (() -> Void)?
    /// The drawing layer's last routing of the board (`ConnectorRouter.Result`, canvas
    /// coordinates), which `geometry` routes on from, so layout math keeps the routes drawn for
    /// what hasn't changed since. Set by the app.
    public var settledRouting: (() -> ConnectorRouter.Result?)?
    /// The page elements under a canvas rect of a browser or HTML tile, for mentions of shapes
    /// drawn on it; nil when the page can't answer quickly (not loaded, not live). Set by the app.
    public var pageElements: (@MainActor (ObjectID, CGRect) async -> PageElements?)?
    /// A terminal tile's name as its header shows it (its `props.name`, else the program running
    /// in it and the title that program set), for mentions; nil without a window. Set by the app.
    public var terminalLabel: (@MainActor (ObjectID) -> String?)?
    /// What a mention of the whole terminal quotes: the rows its view shows (soft-wrapped rows
    /// joined), `scrolledBack` rows above its live screen while the user scrolled back, else its
    /// current screen (0); nil when its session isn't running. Set by the app.
    public var terminalScreen: (@MainActor (ObjectID) async -> (text: String, scrolledBack: Int)?)?
    /// Which of a terminal tile's finished commands `command` is now, from the newest (-1, as
    /// `agent.read` `block` counts), for a mention of its block; nil when `agent.read` can't read
    /// that block (older than easl's attach, cleared, trimmed from the scrollback). Set by the app.
    public var terminalBlockIndex: (@MainActor (ObjectID, TerminalCommand) -> Int?)?
    /// Terminal tiles that left the board for good, once the step that removed them is over:
    /// deleted by anyone (API, batch, UI, redo of a delete, undo of a create). A terminal a failed
    /// batch deleted and put back never counts. The app ends their sessions.
    public var onTerminalsEnded: (([ObjectID]) -> Void)?
    /// Terminals deleted in the open step; checked against `objects` when it closes.
    private var removedTerminals: [ObjectID] = []

    public init(id: BoardID, root: URL) {
        self.id = id
        self.root = root
    }

    /// Board format written by `snapshot`. 2: a tile's frame is its whole drawn box, title bar
    /// included (format 1 stored the body below the title bar).
    nonisolated public static let format = 2

    public init(snapshot: BoardSnapshot) {
        id = snapshot.id
        root = URL(fileURLWithPath: snapshot.root)
        revision = snapshot.revision
        let format = snapshot.format ?? 1
        // `props.scale` became a tile's content `zoom` (frame kept) and a text shape's `textSize`.
        for var object in snapshot.objects.map(ObjectZoom.migrated) {
            // Groups were labelled by `name` before they became titled regions.
            if object.type == .group, var props = object.props.object, let name = props.removeValue(forKey: "name") {
                if props["title"] == nil { props["title"] = name }
                object.props = .object(props)
            }
            // Format 1 stored a tile's body; the title bar drew above it. Same box on screen.
            if format < 2, RenderMath.isTile(object.type) { object.frame.h += RenderMath.tileTitleHeight }
            // A terminal saved `working` or `blocked` said so before easl last closed: until its
            // agent reports again (live, or a spooled report replayed), that is only what it was.
            if object.type == .terminal, var props = object.props.object, var lifecycle = props["lifecycle"]?.object,
               let state = lifecycle["state"]?.string, state == LifecycleState.working.rawValue || state == LifecycleState.blocked.rawValue {
                lifecycle["restored"] = .bool(true)
                props["lifecycle"] = .object(lifecycle)
                object.props = .object(props)
            }
            objects[object.id] = object
            changedAt[object.id] = snapshot.revision
            if let key = Self.key(object.props) { keyHolders[key, default: []].insert(object.id) }
        }
        // Group frames follow their members (older boards stored placeholders); nested groups
        // settle within a few passes.
        for _ in 0..<8 {
            var changed = false
            for group in objects.values where group.type == .group {
                guard let frame = fittedFrame(ofGroup: group), frame != group.frame else { continue }
                objects[group.id]?.frame = frame
                changed = true
            }
            if !changed { break }
        }
        tray = (snapshot.tray ?? []).filter { $0.target.objectIDs.allSatisfy { objects[$0] != nil } }
        for marker in snapshot.attention ?? [] where objects[marker.object] != nil { attention[marker.object] = marker }
        promptTarget = snapshot.promptTarget ?? PromptTarget.State()
        promptTarget.prune(objects)
        finalAnswers = (snapshot.finalAnswers ?? [:]).filter { objects[$0.key] != nil }
        turnErrors = (snapshot.turnErrors ?? [:]).filter { objects[$0.key] != nil }
        lifecycleSeq = (snapshot.lifecycleSeq ?? [:]).filter { objects[String($0.key.prefix { $0 != "|" })] != nil }
        repo = snapshot.repo
    }

    public var snapshot: BoardSnapshot {
        BoardSnapshot(format: Self.format, id: id, root: root.path, revision: revision, objects: objects.values.sorted { $0.z < $1.z }, tray: tray,
                      attention: attention.isEmpty ? nil : attention.values.sorted { $0.object < $1.object },
                      promptTarget: promptTarget == PromptTarget.State() ? nil : promptTarget,
                      finalAnswers: finalAnswers.isEmpty ? nil : finalAnswers, turnErrors: turnErrors.isEmpty ? nil : turnErrors,
                      lifecycleSeq: lifecycleSeq.isEmpty ? nil : lifecycleSeq, repo: repo)
    }

    public func object(_ id: ObjectID) throws -> CanvasObject {
        guard let object = objects[id] else { throw BoardError.notFound("object \(id)") }
        return object
    }

    public func changed(since cursor: Int) -> [ObjectID] {
        changedAt.filter { $0.value > cursor }.map(\.key).sorted()
    }

    // MARK: Objects

    @discardableResult
    public func create(type: ObjectType, props: JSONValue, frame: Frame? = nil, parent: ObjectID? = nil, caller: ObjectID? = nil) -> CanvasObject {
        let size = Self.defaultSize(type)
        let z = (objects.values.map(\.z).max() ?? 0) + 1
        var object = CanvasObject(id: IDs.make("obj"), type: type, frame: frame ?? Frame(x: 0, y: 0, w: size.w, h: size.h), z: z, parent: parent, createdBy: Actor(caller: caller), createdAt: Date(),
                                  props: type == .terminal ? stampingWorktree(props) : props)
        if let fitted = fittedFrame(ofGroup: object) {
            object.frame = fitted
        } else if frame == nil {
            object.frame = place(width: size.w, height: size.h, near: caller, stacking: true)
        }
        commit(object)
        history.record(.created(object), by: object.createdBy)
        log(.created, object, actor: ActivityActor(caller: caller), "created \(ActivityLog.describe(object)) at \(ActivityLog.position(reported(object).frame))")
        onEvent?(.objectCreated(object))
        return object
    }

    /// Patches an object. A group's frame is never taken from `frame`: it follows its members.
    /// `actor` names who the activity log credits when it isn't the caller (the app's own
    /// write-backs are `.system`, which ⌘Z skips: `Board.unrecorded`).
    @discardableResult
    public func update(_ id: ObjectID, rev: Int? = nil, frame: Frame? = nil, z: Double? = nil, props: JSONValue? = nil, caller: ObjectID? = nil, actor: ActivityActor? = nil) throws -> CanvasObject {
        if actor == .system { return try unrecorded { try write(id, rev: rev, frame: frame, z: z, props: props, caller: caller, actor: actor, refitting: []) } }
        return try write(id, rev: rev, frame: frame, z: z, props: props, caller: caller, actor: actor, refitting: [])
    }

    /// Writes props the app keeps about an object rather than its content (a browser's
    /// `pageTitle`; `UndoHistory.bookkeeping` names them per type): stored, persisted, and
    /// announced (`objectUpdated`, a new board revision for `board.get since`), but the object's
    /// `rev`, `updatedBy`, and `updatedAt` stay, so an agent's `object.update rev:` still holds;
    /// never an undo step, never rewound, never logged.
    public func writeBookkeeping(_ id: ObjectID, props: JSONValue) throws {
        let before = try object(id)
        let allowed = UndoHistory.bookkeeping(before)
        guard let keys = props.object?.keys, keys.allSatisfy(allowed.contains) else {
            throw BoardError.invalidParams("\(before.type.rawValue) bookkeeping is \(allowed.sorted()), not \(props.object.map { $0.keys.sorted() } ?? [])")
        }
        commitBookkeeping(before, props: props)
    }

    /// A code tile's range re-found by content (`NoteAnchor`, from the tile's reload of its
    /// file) and the first line it is anchored by, written like `writeBookkeeping`: the app keeps
    /// the range on the code it showed, nobody chose to move it, so no `rev`, undo step, or log.
    /// Only a code tile whose range anchors (`CodeAnchor.fence`).
    public func reanchor(_ id: ObjectID, range: LineRange, anchor: String?) throws {
        let before = try object(id)
        guard before.type == .code, CodeAnchor.fence(before.props) != nil else {
            throw BoardError.invalidParams("only a code tile showing a range, not a follow tile or pinned to a commit, is re-anchored")
        }
        commitBookkeeping(before, props: .object(["range": range.json, "anchor": anchor.map(JSONValue.string) ?? .null]))
    }

    func commitBookkeeping(_ before: CanvasObject, props: JSONValue) {
        var object = before
        object.props = object.props.merging(props)
        guard object != before else { return }
        commit(object)
        onEvent?(.objectUpdated(object))
    }

    /// `update`, re-bounding the groups that contain the object in the same undo step.
    /// `refitting` holds the groups already being re-bounded (nested groups, cycles). `cause`
    /// marks a cascade of another change (credited to that change's actor) and says why.
    func write(_ id: ObjectID, rev: Int?, frame: Frame?, z: Double?, props: JSONValue?, caller: ObjectID?, actor: ActivityActor? = nil, cause: String? = nil, refitting: Set<ObjectID>) throws -> CanvasObject {
        let before = try object(id)
        if let rev, rev != before.rev { throw BoardError.conflict("object \(id) is at rev \(before.rev), not \(rev)") }
        try checkKey(props, for: id)
        var object = before
        if let frame { object.frame = frame }
        if let z { object.z = z }
        if let props {
            object.props = object.props.merging(props)
            // A code tile aimed elsewhere without an anchor drops its old one, which named the
            // first line of the range it showed before.
            if object.type == .code, props["anchor"] == nil,
               object.props["range"] != before.props["range"] || object.props["path"] != before.props["path"] {
                object.props = object.props.merging(.object(["anchor": .null]))
            }
        }
        if let fitted = fittedFrame(ofGroup: object) { object.frame = fitted }
        object.rev += 1
        object.updatedAt = Date()
        object.updatedBy = Actor(caller: caller)
        let credited = actor ?? ActivityActor(caller: caller)
        history.begin()
        defer { endStep() }
        commit(object)
        history.record(.updated(before: before, after: object), by: Actor(caller: caller))
        if let changes = ActivityLog.changes(from: before, to: object) {
            log(.updated, object, actor: credited, "\(ActivityLog.describe(object)): \(changes)", cause: cause, before: before)
        }
        markMentionsEdited(from: before, to: object)
        onEvent?(.objectUpdated(object))
        if before.frame != object.frame { refitGroups(containing: id, actor: credited, caller: caller, visited: refitting) }
        return object
    }

    /// Removes an object. Within the same undo step: arrows bound to it detach; a deleted
    /// terminal takes its follow tile with it; a closed follow tile stops its terminal following
    /// (`props.follow` false) so the next report doesn't bring it back. Undo and redo replay
    /// exactly what was recorded.
    public func delete(_ id: ObjectID, caller: ObjectID? = nil) throws {
        guard objects[id] != nil else { throw BoardError.notFound("object \(id)") }
        let actor = ActivityActor(caller: caller)
        // Arrows bound to it detach within the same undo step, so one ⌘Z restores both.
        history.begin()
        defer { endStep() }
        detachArrows(from: id, actor: actor, caller: caller)
        guard let removed = objects.removeValue(forKey: id) else { throw BoardError.notFound("object \(id)") }
        changedAt.removeValue(forKey: id)
        reindexKey(id, from: removed.props, to: nil)
        bumpRevision()
        // Before the delete, so undo brings the object back first and then its chips.
        let unstaged = tray.enumerated().filter { $0.element.target.objectIDs.contains(id) }.map { PlacedMention(index: $0.offset, mention: $0.element) }
        if !unstaged.isEmpty { history.record(.unstaged(unstaged, pastedInto: nil), by: Actor(caller: caller)) }
        history.record(.deleted(removed), by: Actor(caller: caller))
        if removed.type == .terminal { removedTerminals.append(id) }
        log(.deleted, removed, actor: actor, "deleted \(ActivityLog.describe(removed))")
        let before = tray.count
        tray.removeAll { $0.target.objectIDs.contains(id) }
        forgetHandoffs(of: id)
        let marked = attention.removeValue(forKey: id) != nil
        onChange?()
        onEvent?(.objectDeleted(id))
        if tray.count != before { trayChanged() }
        if marked { onEvent?(.attentionChanged(object: id, attention: nil)) }
        refitGroups(containing: id, actor: actor, caller: caller)
        guard !history.replaying else { return }
        if removed.type == .terminal {
            for follow in followTiles(of: id) { try delete(follow.id, caller: caller) }
        } else if let terminal = removed.props["followOf"]?.string.flatMap({ objects[$0] }), terminal.props["follow"]?.bool != false {
            _ = try write(terminal.id, rev: nil, frame: nil, z: nil, props: .object(["follow": .bool(false)]), caller: caller, actor: actor,
                          cause: "its follow tile was closed", refitting: [])
        }
    }

    /// Logs a change. A cascade (`cause` set, with the object's state `before` it) that hits an
    /// object already cascaded in this revision by the same actor amends that entry to the net
    /// change, or drops it when the changes cancel out: one entry per group per batch, however
    /// many of its members the batch moved or deleted.
    private func log(_ kind: ActivityEntry.Kind, _ object: CanvasObject, actor: ActivityActor, _ summary: String, cause: String? = nil, before: CanvasObject? = nil) {
        guard !activityMuted else { return }
        guard replayVerb == nil else {
            activity.record(kind, actor: replayActor, rev: revision, id: object.id, type: object.type, summary: "\(replayVerb!): \(summary)")
            return
        }
        guard let cause, let before, kind == .updated else {
            activity.record(kind, actor: actor, rev: revision, id: object.id, type: object.type, summary: summary)
            return
        }
        if cascadeRevision != revision {
            cascades = [:]
            cascadeRevision = revision
        }
        var first = before
        if let earlier = cascades[object.id], earlier.actor == actor {
            guard let changes = ActivityLog.changes(from: earlier.before, to: object) else {
                activity.remove(seq: earlier.seq)
                cascades.removeValue(forKey: object.id)
                return
            }
            if activity.amend(seq: earlier.seq, summary: "\(ActivityLog.describe(object)): \(changes)") { return }
            first = earlier.before
        }
        activity.record(kind, actor: actor, rev: revision, id: object.id, type: object.type, summary: summary, cause: cause)
        cascades[object.id] = (activity.cursor, actor, first)
    }

    /// Undo/redo: puts an object state back verbatim (same id and z), announced as a normal change.
    /// The object gets a revision newer than any it has ever had.
    func restore(_ object: CanvasObject) {
        var object = object
        let previous = objects[object.id]
        object.rev = max(revHighWater[object.id] ?? 0, objects[object.id]?.rev ?? 0, object.rev) + 1
        commit(object)
        if let previous {
            if let changes = ActivityLog.changes(from: previous, to: object) {
                log(.updated, object, actor: replayActor, "\(ActivityLog.describe(object)): \(changes)")
            }
            markMentionsEdited(from: previous, to: object)
            onEvent?(.objectUpdated(object))
        } else {
            log(.created, object, actor: replayActor, "restored \(ActivityLog.describe(object)) at \(ActivityLog.position(reported(object).frame))")
            onEvent?(.objectCreated(object))
        }
    }

    private func commit(_ object: CanvasObject) {
        bumpRevision()
        reindexKey(object.id, from: objects[object.id]?.props, to: object.props)
        objects[object.id] = object
        changedAt[object.id] = revision
        revHighWater[object.id] = max(revHighWater[object.id] ?? 0, object.rev)
        onChange?()
    }

    private func reindexKey(_ id: ObjectID, from old: JSONValue?, to new: JSONValue?) {
        let before = old.flatMap(Self.key), after = new.flatMap(Self.key)
        guard before != after else { return }
        if let before {
            keyHolders[before]?.remove(id)
            if keyHolders[before]?.isEmpty == true { keyHolders.removeValue(forKey: before) }
        }
        if let after { keyHolders[after, default: []].insert(id) }
    }

    private func bumpRevision() {
        revision = pinnedRevision ?? revision + 1
    }

    /// Closes a step opened with `history.begin()`. When the outermost one closes, terminals it
    /// deleted that are still gone (a failed batch puts its deletes back) are reported ended.
    func endStep() {
        history.end()
        guard !history.isOpen, !removedTerminals.isEmpty else { return }
        let ended = removedTerminals.filter { objects[$0] == nil }
        removedTerminals = []
        if !ended.isEmpty { onTerminalsEnded?(ended) }
    }

    /// Runs `body` as one undo step and one board revision; when it throws, every change it
    /// made is reverted (announced as normal changes) and the error rethrown.
    public func atomically<T>(_ body: () throws -> T) throws -> T {
        let outermost = pinnedRevision == nil
        if outermost { pinnedRevision = revision + 1 }
        history.begin()
        let mark = history.mark()
        defer {
            endStep()
            if outermost { pinnedRevision = nil }
        }
        do {
            return try body()
        } catch {
            replayVerb = "reverted (batch failed)"
            replayActor = .system
            defer {
                replayVerb = nil
                replayActor = .user
            }
            revert(history.discard(from: mark))
            throw error
        }
    }

    /// Frame size a new object gets without one; a tile's includes its title bar.
    public static func defaultSize(_ type: ObjectType) -> (w: Double, h: Double) {
        switch type {
        case .terminal: (1000, 620)
        case .browser: (1000, 726)
        case .code: (640, 446)
        case .note: (280, 266)
        case .html: (640, 506)
        case .changes: (820, 620)
        case .image: (640, 506)
        case .diagram: (760, 480)
        case .shape: (160, 100)
        case .arrow, .group: (0, 0)
        }
    }

    /// Room kept between a placed object and its neighbours.
    public static let placementGap = 24.0
    /// The smallest a follow tile gets so that it lands wholly in view beside its terminal.
    public static let followMinimumSize = (w: 400.0, h: 300.0)
    /// How recent an agent's last object must be for its next one to stack beside it (`place`).
    public static let answerStackWindow: TimeInterval = 10 * 60
    /// How far (gap between the frames) a slot beside a tile may be from it and still win for
    /// being in view. Further out, the view no longer matters: on a busy board an in-view spot
    /// 1,600 pt away sits next to someone else's terminal and reads as theirs.
    public static let nearbyDistance = 600.0

    /// Where a new object goes when nobody gave it a frame: the free slot nearest the caller's
    /// tile, touching it at `placementGap` when there's room (right first, then below, left,
    /// above), else nearest the viewport center. Beside a tile, a slot in view beats one out of
    /// it only while it is within `nearbyDistance` of the tile; beyond that the nearest slot
    /// wins, in view or not (the agent raises a marker when the user should look). The app also
    /// places the user's own new objects here, beside the tile they came from (`near`, e.g. Edit
    /// Here's terminal) or at the viewport center. See `place(_:)` for what counts as free.
    /// `shrinkingTo` (a follow tile's minimum size): when nothing that size fits wholly in view,
    /// a smaller slot that does, down to the minimum, beats one partly outside it.
    ///
    /// `stacking` (an agent's own create without a frame; `caller` is that agent): its answers
    /// stack instead of going round the terminal. When the caller created a tile within
    /// `answerStackWindow` that is still on the board (not a follow tile), the slot beside the
    /// newest such tile, below first, then right, is taken if it touches that tile at
    /// `placementGap` below or right of it and is no less in view (wholly, partly, not at all)
    /// than the slot beside the caller; otherwise the caller rule above applies.
    public func place(width: Double, height: Double, near caller: ObjectID?, shrinkingTo minimum: (w: Double, h: Double)? = nil, stacking: Bool = false) -> Frame {
        guard let caller, let anchor = objects[caller] else {
            let view = viewport() ?? Frame(x: 0, y: 0, w: 0, h: 0)
            return place(Frame(x: view.x + view.w / 2 - width / 2, y: view.y + view.h / 2 - height / 2, w: width, h: height))
        }
        let beside = freeSlot(width: width, height: height, anchor: anchor.frame, beside: true, minimum: minimum)!
        guard stacking, let previous = latestAnswer(of: caller)?.frame else { return beside }
        let stacked = freeSlot(width: width, height: height, anchor: previous, beside: true, minimum: minimum, order: [.below, .right, .left, .above])!
        let gap = Self.placementGap
        let below = abs(stacked.y - (previous.maxY + gap)) < 1 && stacked.x < previous.maxX && stacked.maxX > previous.x
        let right = abs(stacked.x - (previous.maxX + gap)) < 1 && stacked.y < previous.maxY && stacked.maxY > previous.y
        return (below || right) && inViewClass(stacked) <= inViewClass(beside) ? stacked : beside
    }

    /// The tile `caller` (an agent) created last, within `answerStackWindow`, follow tiles aside.
    private func latestAnswer(of caller: ObjectID) -> CanvasObject? {
        let since = Date().addingTimeInterval(-Self.answerStackWindow)
        return objects.values
            .filter { $0.createdBy == .agent(tile: caller) && $0.createdAt >= since && RenderMath.isTile($0.type) && $0.props["followOf"] == nil }
            .max { ($0.createdAt, $0.z) < ($1.createdAt, $1.z) }
    }

    /// 0 wholly inside the viewport (kept `placementGap` from its edges) or no viewport, 1 partly, 2 outside.
    private func inViewClass(_ slot: Frame) -> Int {
        let gap = Self.placementGap
        guard let view = viewport(), view.w > 2 * gap, view.h > 2 * gap else { return 0 }
        let screen = Frame(x: view.x + gap, y: view.y + gap, w: view.w - 2 * gap, h: view.h - 2 * gap)
        return screen.contains(slot) ? 0 : screen.intersects(slot) ? 1 : 2
    }

    /// The free slot nearest `ideal` (a frame of the object's size, e.g. at a click point). A slot
    /// is free when it keeps `placementGap` from every object but drawings and arrows (other
    /// agents' tiles and groups included). While the ideal spot (or the caller's tile) is on
    /// screen, slots wholly inside the viewport (kept `placementGap` from its edges) win over
    /// nearer ones outside it, and when none fits, slots partly in view win over ones wholly out
    /// of it, those whose top edge (a tile's title bar) is in view first. Origins are whole points.
    public func place(_ ideal: Frame) -> Frame {
        freeSlot(width: ideal.w, height: ideal.h, anchor: ideal, beside: false, minimum: nil)!
    }

    /// Where `id` goes when it grows to `size` in place (`size: "fit"` without a given origin):
    /// grown from its top-left corner when that covers nothing it didn't already; else grown
    /// from another corner (`Layout.refit`: left, up, or both); else moved to the free slot
    /// nearest that top-left-grown frame (`place(_:)`'s rule, in view first, its own groups
    /// aside) among those no farther than its longer side; else grown from the top-left anyway
    /// (`overlaps(of:)` says onto what).
    public func refitFrame(_ id: ObjectID, to size: CGSize) throws -> Frame {
        let current = try object(id).frame
        let grown = Frame(x: current.x, y: current.y, w: size.width, h: size.height)
        let containers = Set(objects.values.filter { $0.type == .group && BoardGeometry.leafMembers(of: $0.id, in: objects).contains(id) }.map(\.id))
        let neighbours = objects.values.filter { $0.id != id && !containers.contains($0.id) && BoardGeometry.countsForOverlaps($0) }.map(\.frame)
        if let corner = Layout.refit(current, to: size, clearOf: neighbours) { return corner }
        if let nearby = freeSlot(width: grown.w, height: grown.h, anchor: grown, beside: false, minimum: nil, ignoring: containers.union([id]), within: max(grown.w, grown.h)) {
            return nearby
        }
        return Frame(x: grown.x.rounded(), y: grown.y.rounded(), w: grown.w, h: grown.h)
    }

    /// The frame a tile the app grows for its own content (a diagram whose graph gained nodes)
    /// takes toward `size`, covering nothing it doesn't already cover and staying where it is
    /// (never moved off to a free slot like `refitFrame`): the whole `size` from a corner when that is clear
    /// (`Layout.refit`), else grown from its top-left as far as the free space right of and
    /// below it allows, `placementGap` short of its neighbours (the largest such frame), never
    /// smaller than it is where `size` asks for more. What doesn't fit, the tile shows scaled.
    public func grownFrame(_ id: ObjectID, toward size: CGSize) throws -> Frame {
        let current = try object(id).frame
        let containers = Set(objects.values.filter { $0.type == .group && BoardGeometry.leafMembers(of: $0.id, in: objects).contains(id) }.map(\.id))
        let neighbours = objects.values.filter { $0.id != id && !containers.contains($0.id) && BoardGeometry.countsForOverlaps($0) }.map(\.frame)
        if let corner = Layout.refit(current, to: size, clearOf: neighbours) { return corner }
        let gap = Self.placementGap
        let start = (w: min(Double(size.width), current.w), h: min(Double(size.height), current.h))
        let reach = Frame(x: current.x, y: current.y, w: Double(size.width) + gap, h: Double(size.height) + gap)
        let blockers = neighbours.filter { !$0.intersects(current) && $0.intersects(reach) }
        let widths = Set([Double(size.width)] + blockers.map { $0.x - gap - current.x }).filter { $0 >= start.w && $0 <= Double(size.width) }
        let heights = Set([Double(size.height)] + blockers.map { $0.y - gap - current.y }).filter { $0 >= start.h && $0 <= Double(size.height) }
        var best = Frame(x: current.x, y: current.y, w: start.w, h: start.h)
        for w in widths.union([start.w]) {
            for h in heights.union([start.h]) where w * h > best.w * best.h || (w * h == best.w * best.h && w > best.w) {
                let frame = Frame(x: current.x, y: current.y, w: w, h: h)
                if !blockers.contains(where: { $0.intersects(frame) }) { best = frame }
            }
        }
        return best
    }

    /// The objects `id` overlaps by accident, by `layout.check`'s `overlaps` rule.
    public func overlaps(of id: ObjectID) -> [ObjectID] {
        BoardGeometry(objects: objects, labelSizes: [:]).overlaps(scope: [id]).flatMap { $0 }.filter { $0 != id }
    }

    /// `beside`: the slot goes next to `anchor` (an object), nearest by the gap between them, then
    /// by side in `order`; otherwise it replaces `anchor`, nearest by origin. `minimum`: a slot
    /// partly in view may be cut down to its part in view when that is at least this big.
    /// `ignoring`: objects that don't block (one being moved, and its groups). `within`: only
    /// slots whose origin is at most that far from `anchor`'s count, nil when there is none.
    /// Never nil without `within`: right of the rightmost blocker is always free.
    private func freeSlot(width w: Double, height h: Double, anchor: Frame, beside: Bool, minimum: (w: Double, h: Double)?,
                          order: [Layout.Side] = [.right, .below, .left, .above], ignoring: Set<ObjectID> = [], within: Double? = nil) -> Frame? {
        let gap = Self.placementGap
        let blocked = objects.values.filter { $0.type != .arrow && $0.type != .shape && !ignoring.contains($0.id) }
            .map { Frame(x: $0.frame.x - gap, y: $0.frame.y - gap, w: $0.frame.w + 2 * gap, h: $0.frame.h + 2 * gap) }
        let screen = viewport().flatMap { view in
            view.intersects(anchor) && view.w > 2 * gap && view.h > 2 * gap ? Frame(x: view.x + gap, y: view.y + gap, w: view.w - 2 * gap, h: view.h - 2 * gap) : nil
        }
        // Edges a best slot can rest against: the anchor's, each blocker's, and the viewport's.
        var xs: Set<Double> = [anchor.x.rounded(), (anchor.maxX - w).rounded()]
        var ys: Set<Double> = [anchor.y.rounded(), (anchor.maxY - h).rounded()]
        for frame in blocked {
            xs.formUnion([frame.maxX.rounded(.up), (frame.x - w).rounded(.down)])
            ys.formUnion([frame.maxY.rounded(.up), (frame.y - h).rounded(.down)])
        }
        if let screen {
            xs.formUnion([screen.x.rounded(.up), (screen.maxX - w).rounded(.down)])
            ys.formUnion([screen.y.rounded(.up), (screen.maxY - h).rounded(.down)])
        }
        // In view, cut down to fit in view, partly in view with its top edge (a tile's title
        // bar, what names it and moves it) in view, partly in view below its top, out of view
        // (beside a tile: only within `nearbyDistance` of it; further slots all rank after
        // those, by distance alone); then distance to the anchor, then side (in `order`), then
        // distance from where that side's slot would ideally start; ties go top-left first.
        typealias Cost = (Int, Double, Int, Double, Double, Double)
        func cost(_ slot: Frame, cut: Bool) -> Cost {
            let outside = cut ? 1 : screen.map { screen in
                if screen.contains(slot) { return 0 }
                guard screen.intersects(slot) else { return 4 }
                return slot.y >= screen.y && slot.y < screen.maxY ? 2 : 3
            } ?? 0
            guard beside else { return (outside, 0, 0, hypot(slot.x - anchor.x, slot.y - anchor.y), slot.y, slot.x) }
            let dx = max(0, anchor.x - slot.maxX, slot.x - anchor.maxX)
            let dy = max(0, anchor.y - slot.maxY, slot.y - anchor.maxY)
            let distance = hypot(dx, dy).rounded()
            let side: Layout.Side
            let ideal: (x: Double, y: Double)
            if slot.x >= anchor.maxX {
                (side, ideal) = (.right, (anchor.maxX + gap, anchor.y))
            } else if slot.y >= anchor.maxY {
                (side, ideal) = (.below, (anchor.x, anchor.maxY + gap))
            } else if slot.maxX <= anchor.x {
                (side, ideal) = (.left, (anchor.x - w - gap, anchor.y))
            } else {
                (side, ideal) = (.above, (anchor.x, anchor.y - h - gap))
            }
            return (distance > Self.nearbyDistance ? 5 : outside, distance, order.firstIndex(of: side) ?? order.count, hypot(slot.x - ideal.x, slot.y - ideal.y), slot.y, slot.x)
        }
        /// A slot partly in view cut down to its part in view, when that is at least `minimum`.
        func cut(_ slot: Frame) -> Frame? {
            guard let minimum, let screen, !screen.contains(slot) else { return nil }
            let x = max(slot.x, screen.x.rounded(.up)), y = max(slot.y, screen.y.rounded(.up))
            let cut = Frame(x: x, y: y, w: min(slot.maxX, screen.maxX.rounded(.down)) - x, h: min(slot.maxY, screen.maxY.rounded(.down)) - y)
            return cut.w >= minimum.w && cut.h >= minimum.h ? cut : nil
        }
        var best: (slot: Frame, cost: Cost)?
        func consider(_ slot: Frame, cut: Bool) {
            if let within, hypot(slot.x - anchor.x, slot.y - anchor.y) > within { return }
            let slotCost = cost(slot, cut: cut)
            if let best, !(slotCost < best.cost) { return }
            if blocked.contains(where: { $0.intersects(slot) }) { return }
            best = (slot, slotCost)
        }
        for x in xs {
            for y in ys {
                let slot = Frame(x: x, y: y, w: w, h: h)
                consider(slot, cut: false)
                if let smaller = cut(slot) { consider(smaller, cut: true) }
            }
        }
        return best?.slot
    }

    // MARK: Tray

    @discardableResult
    public func stage(_ target: MentionTarget) throws -> Mention {
        for id in target.objectIDs where objects[id] == nil { throw BoardError.notFound("object \(id)") }
        if let existing = tray.first(where: { $0.target == target }) { return existing }
        let mention = Mention(id: IDs.make("men"), target: target, label: MentionContext.label(for: target, on: self), stagedAt: Date())
        tray.append(mention)
        trayChanged()
        return mention
    }

    public func unstage(_ id: MentionID) throws {
        guard tray.contains(where: { $0.id == id }) else { throw BoardError.notFound("mention \(id)") }
        tray.removeAll { $0.id == id }
        trayChanged()
    }

    /// What a toggle did.
    public enum Toggled: Equatable, Sendable {
        case staged(Mention)
        /// It was in the tray already, and came out (the app says so: `TrayChips.unstagedNotice`).
        case unstaged(Mention)
        /// Something it points at is gone.
        case failed
    }

    /// What a Hyper-click does: stages `target`, or unstages it when it is already in the tray.
    @discardableResult
    public func toggle(_ target: MentionTarget) -> Toggled {
        if let staged = tray.first(where: { $0.target == target }) {
            try? unstage(staged.id)
            return .unstaged(staged)
        }
        return (try? stage(target)).map(Toggled.staged) ?? .failed
    }

    /// Resolve every staged mention at its current revision and return the prompt context.
    /// `peek` leaves the tray intact for a later `commit` of exactly these ids. `caller` is the
    /// terminal the context goes to: mentions of it say so, other terminals are named. The
    /// mentions other agents handed to `caller` (`handOff`) follow the tray's, one block per
    /// sender; `tray` false leaves the tray out (it shows another terminal).
    /// Old-side and pinned code excerpts are read from git, hence async.
    public func drain(peek: Bool = false, caller: ObjectID? = nil, tray includeTray: Bool = true) async -> (mentions: [MentionContext.Resolved], context: String) {
        let staged = includeTray ? tray : []
        var resolved = await resolve(staged, caller: caller)
        var blocks = resolved.isEmpty ? [] : [MentionContext.render(resolved, board: self, targets: staged.map(\.target))]
        if let caller {
            let handed = await resolveHandoffs(for: caller, from: resolved.count + 1)
            resolved.append(contentsOf: handed.mentions)
            blocks.append(contentsOf: handed.blocks)
        }
        if !peek { commit(resolved.map(\.id)) }
        return (resolved, blocks.joined(separator: "\n"))
    }

    /// The context block for `mentions`, numbered from 1 as a drain numbers the tray: what the
    /// composer pastes ahead of its prompt into a terminal without an agent integration, as
    /// Hyper-V would. Leaves the tray as it is.
    public func context(for mentions: [Mention], caller: ObjectID?) async -> String {
        let resolved = await resolve(mentions, caller: caller)
        return resolved.isEmpty ? "" : MentionContext.render(resolved, board: self, targets: mentions.map(\.target))
    }

    private func resolve(_ mentions: [Mention], caller: ObjectID?) async -> [MentionContext.Resolved] {
        var resolved: [MentionContext.Resolved] = []
        for (index, mention) in mentions.enumerated() {
            resolved.append(await MentionContext.resolve(mention, index: index + 1, on: self, caller: caller))
        }
        return resolved
    }

    /// Puts the tray in `order` (the composer's tokens), so the n-th token's mention is the one a
    /// drain numbers `[n]`; mentions `order` doesn't name keep their order after the rest. Not an
    /// undo step.
    public func arrangeTray(_ order: [MentionID]) {
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let arranged = tray.enumerated().sorted { a, b in
            (rank[a.element.id] ?? order.count + a.offset) < (rank[b.element.id] ?? order.count + b.offset)
        }.map(\.element)
        guard arranged != tray else { return }
        tray = arranged
        trayChanged()
    }

    /// Remove exactly these mentions (the ones whose context was delivered), from the tray and
    /// from what agents handed to terminals. Unknown ids are ignored. `pastedInto`: the user
    /// pasted them into that terminal (Hyper-V), an undo step that puts the chips back; a
    /// prompt's drain is the agent's delivery, never undone.
    public func commit(_ ids: [MentionID], pastedInto terminal: ObjectID? = nil) {
        commitHandoffs(ids)
        let removed = tray.enumerated().filter { ids.contains($0.element.id) }.map { PlacedMention(index: $0.offset, mention: $0.element) }
        guard !removed.isEmpty else { return }
        tray.removeAll { ids.contains($0.id) }
        delivered += removed.count
        if let terminal { history.record(.unstaged(removed, pastedInto: terminal)) }
        trayChanged()
    }

    /// Undo of a step that took these mentions out of the tray: each goes back to its place
    /// (in index order, so the chips before it are where they were), unless it is in the tray
    /// already or something it points at is gone.
    func restageMentions(_ placed: [PlacedMention]) {
        var changed = false
        for entry in placed.sorted(by: { $0.index < $1.index }) where !tray.contains(where: { $0.id == entry.mention.id || $0.target == entry.mention.target })
            && entry.mention.target.objectIDs.allSatisfy({ objects[$0] != nil }) {
            tray.insert(entry.mention, at: min(entry.index, tray.count))
            changed = true
        }
        if changed { trayChanged() }
    }

    /// Redo of such a step: the mentions come out again.
    func unstageMentions(_ placed: [PlacedMention]) {
        let ids = Set(placed.map(\.mention.id))
        let before = tray.count
        tray.removeAll { ids.contains($0.id) }
        if tray.count != before { trayChanged() }
    }

    /// Staged mentions of the object turn "edited" when the update changed what they hold
    /// (`MentionTarget.isEdited`), never for a move, resize, scale, or restack.
    private func markMentionsEdited(from before: CanvasObject, to after: CanvasObject) {
        var changed = false
        for index in tray.indices where !tray[index].edited && tray[index].target.objectIDs.contains(after.id) && tray[index].target.isEdited(from: before, to: after) {
            tray[index].edited = true
            changed = true
        }
        if changed { trayChanged() }
    }

    private func trayChanged() {
        onChange?()
        onEvent?(.trayChanged(tray))
    }

    // MARK: Agents

    /// `call` names the tool call a hook reports on. `blocked` with a call: that call waits for
    /// approval. `working` with a call: that call finished (its approval was answered). While any
    /// call waits, the terminal stays `blocked` with the oldest waiting call's message, whatever
    /// other calls (parallel siblings, subagents) finish meanwhile; finishing one re-raises the
    /// next. `working` without a call (a new prompt) and `idle` end every wait. A finished call
    /// reported out of order (lower `seq`) still ends its own wait but changes nothing else.
    /// `serial`: with `blocked` and a call, the agent asks one approval at a time (Codex), so this
    /// request is the one on screen and every earlier wait is over (an approval answered whose
    /// completion never matched or hasn't arrived): the message is always the current request's.
    /// `final`: with `idle`, the last answer of the turn that just ended (`finalAnswers`), kept
    /// until the next turn starts. `error`: with `idle`, the turn ended on this error (omp: an
    /// API error such as `overloaded_error`, an abort): the tile goes `idle`, never `done`, with
    /// the error as its message, and the answer is known to be cut off (`turnErrors`). `unknown`:
    /// an agent without a lifecycle integration runs here (`bin/aider` says so as aider starts);
    /// its terminal notifications report when it waits (`NotifyingAgent`, `via: "notifications"`).
    public func reportLifecycle(tile: ObjectID, kind: String, state: LifecycleState, message: String?, seq: Int?, source: String?, call: String? = nil, final: String? = nil,
                                serial: Bool = false, error: String? = nil) throws {
        let terminal = try object(tile)
        guard terminal.type == .terminal else { throw BoardError.invalidParams("\(tile) is not a terminal tile") }
        guard final == nil || state == .idle else { throw BoardError.invalidParams("final comes only with state idle: the answer of the turn that just ended") }
        guard error == nil || state == .idle else { throw BoardError.invalidParams("error comes only with state idle: what the turn that just ended stopped on") }
        let key = "\(tile)|\(source ?? kind)"
        if let seq {
            if let last = lifecycleSeq[key], seq <= last {
                if state == .working, let call { resolveApproval(tile, call: call) }
                return
            }
            lifecycleSeq[key] = seq
        }
        var state = state
        var message = message
        switch (state, call) {
        case (.blocked, let call?):
            if serial { pendingApprovals[tile] = [] }
            pendingApprovals[tile, default: []].append((call, message))
        case (.working, let call?):
            resolveApproval(tile, call: call)
        case (.blocked, nil):
            break
        default:
            pendingApprovals[tile] = nil
        }
        if let waiting = pendingApprovals[tile]?.first {
            state = .blocked
            message = waiting.message
        }
        if state == .working {
            seenSinceWorking.remove(tile)
            // Going to working from idle, done, or no state is the user's next prompt reaching the
            // agent: a new turn. From blocked (an approval answered) it continues the same answer.
            let previous = terminal.props["lifecycle"]?["state"]?.string
            if previous != LifecycleState.working.rawValue, previous != LifecycleState.blocked.rawValue {
                agentStartedTurn(tile)
                finalAnswers[tile] = nil
                turnErrors[tile] = nil
            }
        }
        if state == .idle, let final, !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finalAnswers[tile] = final }
        let failed = error.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if state == .idle, let failed {
            turnErrors[tile] = failed
            if message == nil { message = failed }
        }
        // A turn that died on an error isn't done: the user reads why in its message.
        let effective: LifecycleState = state == .idle && failed == nil && !seenSinceWorking.contains(tile) && wasWorking(terminal) ? .done : state
        var lifecycle: [String: JSONValue] = ["state": .string(effective.rawValue), "seen": .bool(seenSinceWorking.contains(tile))]
        if let message { lifecycle["message"] = .string(message) }
        if state == .unknown { lifecycle["via"] = .string(NotifyingAgent.via) }
        let agent = (terminal.props["agent"] ?? .object([:])).merging(.object(["kind": .string(kind)]))
        try update(tile, props: .object(["lifecycle": .object(lifecycle), "agent": agent]), caller: tile)
        onEvent?(.agentLifecycle(tile: tile, lifecycle: .object(lifecycle)))
    }

    /// Ends the wait for one approval of `call` (a finished call that waited on none: nothing).
    private func resolveApproval(_ tile: ObjectID, call: String) {
        guard var waiting = pendingApprovals[tile], let index = waiting.firstIndex(where: { $0.call == call }) else { return }
        waiting.remove(at: index)
        pendingApprovals[tile] = waiting.isEmpty ? nil : waiting
    }

    private func wasWorking(_ terminal: CanvasObject) -> Bool {
        let state = terminal.props["lifecycle"]?["state"]?.string
        return state == LifecycleState.working.rawValue || state == LifecycleState.done.rawValue
    }

    /// Gemini CLI's window title while it waits for a prompt (its dynamic window title, on unless
    /// the user turned `ui.dynamicWindowTitle` off or hid the title): `◇  Ready (<folder>)`, padded.
    public static let geminiReadyTitle = "\u{25C7}  Ready"

    /// Terminal `tile`'s program set its window title (OSC 0/2) to `title`. Gemini CLI reports an
    /// approval dialog through its `Notification` hook but fires no hook when the user cancels it
    /// with Esc ("Request cancelled."; the turn ends without `AfterTool` or `AfterAgent`), so a
    /// gemini tile `blocked` on it stayed orange, ⌘J going there, until the next prompt. Its title
    /// says `✋  Action Required` while a dialog is open and `◇  Ready` only once Gemini waits for a
    /// prompt, with no approval pending and nothing running: that ends the wait (`idle`, reported
    /// as the hooks report, at `seq` now, so a hook's report of the cancelled dialog arriving
    /// late changes nothing). Answering the dialog is still the hooks' (`AfterTool`: working).
    public func terminalTitled(_ tile: ObjectID, title: String, now: Date = Date()) {
        guard let terminal = objects[tile], terminal.type == .terminal, terminal.props["agent"]?["kind"]?.string == "gemini",
              terminal.props["lifecycle"]?["state"]?.string == LifecycleState.blocked.rawValue, !NotifyingAgent.reports(terminal),
              title.drop(while: \.isWhitespace).hasPrefix(Self.geminiReadyTitle) else { return }
        try? reportLifecycle(tile: tile, kind: "gemini", state: .idle, message: nil, seq: Int(now.timeIntervalSince1970 * 1_000_000), source: "canvas-gemini")
    }

    /// The user has looked at this terminal; a `done` agent becomes `idle`. Looking at an agent
    /// that is still working (or waiting on an approval) doesn't count: its answer isn't there
    /// yet, so a turn that ends after the user looked away stays `done` until they look again.
    public func markSeen(_ tile: ObjectID) {
        guard let terminal = objects[tile], terminal.type == .terminal, !seenSinceWorking.contains(tile) else { return }
        let state = terminal.props["lifecycle"]?["state"]?.string
        guard state != LifecycleState.working.rawValue, state != LifecycleState.blocked.rawValue else { return }
        seenSinceWorking.insert(tile)
        guard state == LifecycleState.done.rawValue else { return }
        var seen: [String: JSONValue] = ["state": .string(LifecycleState.idle.rawValue), "seen": .bool(true)]
        if let via = terminal.props["lifecycle"]?["via"] { seen["via"] = via }
        let lifecycle: JSONValue = .object(seen)
        _ = try? update(tile, props: .object(["lifecycle": lifecycle]))
        onEvent?(.agentLifecycle(tile: tile, lifecycle: lifecycle))
    }

    public func reportSession(tile: ObjectID, kind: String, sessionId: String?, sessionPath: String?) throws {
        let terminal = try object(tile)
        var agent = terminal.props["agent"]?.object ?? [:]
        agent["kind"] = .string(kind)
        if let sessionId { agent["sessionId"] = .string(sessionId) }
        if let sessionPath { agent["sessionPath"] = .string(sessionPath) }
        try update(tile, props: .object(["agent": .object(agent)]), caller: tile)
    }

    /// `agent.report` as its params (schema `agent.report`): a report over the socket, or one an
    /// integration spooled while easl was away (`AgentReportSpool`).
    public func reportLifecycle(params p: JSONValue) throws {
        guard let tile = p["tile"]?.string, let kind = p["kind"]?.string, let name = p["state"]?.string else {
            throw BoardError.invalidParams("agent.report needs tile, kind, and state")
        }
        guard let state = LifecycleState(rawValue: name) else { throw BoardError.invalidParams("unknown state") }
        try reportLifecycle(tile: tile, kind: kind, state: state, message: p["message"]?.string, seq: p["seq"]?.int, source: p["source"]?.string,
                            call: p["call"]?.string, final: p["final"]?.string, serial: p["serial"]?.bool ?? false, error: p["error"]?.string)
    }

    /// The agent exited (`agent.release`): the tile is a plain shell again. Its lifecycle and the
    /// recorded session go, so a reboot restores a shell instead of resuming a session the user quit.
    public func releaseAgent(tile: ObjectID) throws {
        _ = try object(tile)
        pendingApprovals[tile] = nil
        try update(tile, props: .object(["lifecycle": .null, "agent": .null]), caller: tile)
        onEvent?(.agentLifecycle(tile: tile, lifecycle: .null))
    }

    // MARK: Follow mode

    /// Recent locations kept on a follow tile (`CodeProps.history`), newest first.
    public static let followHistoryLimit = 8

    /// Whether a follow report or history entry's `action` changed the file.
    public static func isEdit(_ action: String?) -> Bool { action == "edit" || action == "write" }

    /// Where a follow tile aims among an edit's hunks: the one spanning the most lines, the last
    /// of equals (an edit's substance tends to come after the imports it needed); nil for none.
    public nonisolated static func followAim(_ changes: [LineRange]) -> LineRange? {
        changes.enumerated().max { ($0.element.end - $0.element.start, $0.offset) < ($1.element.end - $1.element.start, $1.offset) }?.element
    }

    /// Re-aim the terminal's follow tile at `path`/`range`, creating the tile on first use, and
    /// record the location at the front of the tile's history with its `action`. An edit's
    /// `changes` (its hunks, as lines of the file now) are kept on the tile (`lastChanges`) for it
    /// to flash; without a `range` the tile aims at the hunk that matters most (`followAim`). A
    /// location already there moves to the front and stays an edit once edited. Past
    /// `followHistoryLimit`, the oldest reads go first, so every edit of a burst (an agent's
    /// parallel edits land within milliseconds) stays listed. Ignored (returns nil) while the
    /// terminal doesn't follow (`props.follow` false) and for files `FollowFilter` rejects:
    /// outside the board root, the terminal's cwd, and every other worktree of their
    /// repositories, scratch files in the temp directory, missing files, files over the code
    /// tile's size limit, images, and other binaries. The tile keeps its last real file. A file
    /// outside the root keeps its absolute path, so the tile diffs it in its own worktree.
    @discardableResult
    public func follow(tile: ObjectID, path: String, range: LineRange?, changes: [LineRange] = [], action: String) throws -> CanvasObject? {
        let terminal = try object(tile)
        guard terminal.props["follow"]?.bool != false else { return nil }
        let projects = [root.path] + [terminal.props["cwd"]?.string].compactMap { $0 }
        guard FollowFilter.follows(absoluteURL(path).path, projects: projects) else { return nil }
        let relative = relativePath(path)
        let changes = changes.filter { $0.start >= 1 }.map { LineRange(start: $0.start, end: max($0.start, $0.end)) }
        let range = range ?? Self.followAim(changes)
        let rangeValue: JSONValue = range?.json ?? .null
        var props: [String: JSONValue] = ["path": .string(relative), "followOf": .string(tile), "lastAction": .string(action), "range": rangeValue,
                                          "lastChanges": changes.isEmpty ? .null : .array(changes.map(\.json))]
        let existing = followTiles(of: tile).first
        var entry: [String: JSONValue] = ["path": .string(relative), "action": .string(action)]
        if range != nil { entry["range"] = rangeValue }
        var history = existing?.props["history"]?.array ?? []
        let same = { (other: JSONValue) in other["path"] == entry["path"] && other["range"] == entry["range"] }
        if !Self.isEdit(action), let earlier = history.first(where: same)?["action"], Self.isEdit(earlier.string) { entry["action"] = earlier }
        history.removeAll(where: same)
        history.insert(.object(entry), at: 0)
        // The newest entry is the current location: never the one to go.
        while history.count > Self.followHistoryLimit {
            history.remove(at: history[1...].lastIndex { !Self.isEdit($0["action"]?.string) } ?? history.count - 1)
        }
        props["history"] = .array(history)
        let follow: CanvasObject
        activityMuted = true
        defer { activityMuted = false }
        // The agent's bookkeeping, not anyone's choice: never an undo step (`unrecorded`).
        if let existing {
            follow = try unrecorded { try update(existing.id, props: .object(props), caller: tile) }
        } else {
            props["diffBase"] = .string("merge-base")
            // Beside its terminal, wholly in view when the terminal is on screen, smaller when
            // only that fits (the view never moves for an agent's tile).
            let size = Self.defaultSize(.code)
            follow = unrecorded {
                create(type: .code, props: .object(props.filter { $0.value != .null }),
                       frame: place(width: size.w, height: size.h, near: tile, shrinkingTo: Self.followMinimumSize), caller: tile)
            }
        }
        activityMuted = false
        let at = range.map { ":\($0.start)-\($0.end)" } ?? ""
        activity.record(.follow, actor: .agent(tile), rev: revision, id: follow.id, type: .code,
                        summary: "\(existing == nil ? "follow tile created" : "follow tile re-aimed") at \(relative)\(at) (\(action))")
        onEvent?(.followUpdated(tile: tile, follow: follow.id))
        return follow
    }

    /// The code tiles following `terminal` (one, unless an undo or a copy made more).
    public func followTiles(of terminal: ObjectID) -> [CanvasObject] {
        objects.values.filter { $0.type == .code && $0.props["followOf"]?.string == terminal }
    }

    /// What `codeFileVanished` did with the tile.
    public enum VanishedFile: Equatable, Sendable {
        /// A follow tile stepped back to the newest history entry whose file still exists.
        case steppedBack(path: String)
        /// A follow tile with nowhere left to go, or a ⌘-click preview, closed.
        case closed
        /// Not a follow tile or an unkept preview (the user's tiles stay as they are), or it no
        /// longer shows `path`.
        case kept
    }

    /// Code tile `id` shows `path`, which is on neither the disk nor the diff base (an agent
    /// wrote a scratch file and removed it). A follow tile never shows "file not found": it
    /// steps back to the newest history entry whose file still exists (`existing`, the history
    /// paths found on disk) and drops the entries that don't; with none left it closes, and the
    /// terminal keeps following (its next report brings the tile back). A ⌘-click preview the
    /// user hasn't kept closes. Neither is an undo step; the activity log credits the system.
    @discardableResult
    public func codeFileVanished(_ id: ObjectID, path: String, existing: Set<String>) -> VanishedFile {
        guard let tile = objects[id], tile.type == .code, tile.props["path"]?.string == path else { return .kept }
        let isPreview = codePreviews.values.contains { $0.tile == id }
        guard tile.props["followOf"]?.string != nil || isPreview else { return .kept }
        let remaining = FollowFallback.prune(tile.props["history"]?.array ?? [], vanished: path, existing: existing)
        activityMuted = true
        defer { activityMuted = false }
        guard tile.props["followOf"]?.string != nil, let back = remaining.first, let backPath = back["path"]?.string else {
            keepCode(id)
            // Deleted as a replay would: a closed follow tile otherwise turns its terminal's
            // following off, and nobody chose this.
            unrecorded {
                history.replaying = true
                defer { history.replaying = false }
                try? delete(id)
            }
            activity.record(.deleted, actor: .system, rev: revision, id: id, type: .code, summary: "closed \(ActivityLog.describe(tile)): \(path) was deleted")
            return .closed
        }
        let props: JSONValue = .object(["path": .string(backPath), "range": back["range"] ?? .null, "lastChanges": .null,
                                        "lastAction": back["action"] ?? .string("read"), "history": .array(remaining)])
        _ = try? update(id, props: props, actor: .system)
        activity.record(.follow, actor: .system, rev: revision, id: id, type: .code, summary: "follow tile stepped back to \(backPath): \(path) was deleted")
        return .steppedBack(path: backPath)
    }

    /// Turns a terminal's follow mode on (the next report creates its tile) or off (its follow
    /// tile goes), in one undo step.
    public func setFollowing(_ tile: ObjectID, _ on: Bool, caller: ObjectID? = nil) throws {
        guard try object(tile).type == .terminal else { throw BoardError.invalidParams("\(tile) is not a terminal tile") }
        try atomically {
            try update(tile, props: .object(["follow": .bool(on)]), caller: caller)
            if !on { for follow in followTiles(of: tile) { try delete(follow.id, caller: caller) } }
        }
    }

    /// Keep what a follow tile shows (`path`/`range`, which a user holding the tile may keep
    /// behind its props) as a permanent code tile beside it, with the same diff base.
    @discardableResult
    public func pin(_ follow: ObjectID, path: String, range: LineRange?) throws -> CanvasObject {
        let tile = try object(follow)
        var props: [String: JSONValue] = ["path": .string(path), "diffBase": tile.props["diffBase"] ?? .string("merge-base")]
        if let range { props["range"] = range.json }
        if let caption = tile.props["caption"] { props["caption"] = caption }
        return create(type: .code, props: .object(props), frame: place(width: tile.frame.w, height: tile.frame.h, near: follow))
    }

    /// Paths are stored relative to the board root when they live under it, also when reached
    /// through a symlink: git, language servers and shells report resolved paths (/private/tmp
    /// for a /tmp root), so a path outside the root as written is compared resolved as well.
    public func relativePath(_ path: String) -> String {
        Self.relativePath(path, root: root)
    }

    /// `path` (absolute, or relative to `root`) relative to `root` when it lies under it, else absolute.
    nonisolated public static func relativePath(_ path: String, root: URL) -> String {
        let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.path : root.appendingPathComponent(path).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if absolute.hasPrefix(rootPath + "/") { return String(absolute.dropFirst(rootPath.count + 1)) }
        let real = GitDiffEngine.realPath(URL(fileURLWithPath: absolute)).path, realRoot = GitDiffEngine.realPath(root).path
        return real.hasPrefix(realRoot + "/") ? String(real.dropFirst(realRoot.count + 1)) : absolute
    }

    public func absoluteURL(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
}
