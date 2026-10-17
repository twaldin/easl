import Foundation

/// Linear undo/redo of board content changes, whoever made them: ⌘Z undoes the latest change
/// even when an agent made it. Bookkeeping nobody chose to change is never recorded and never
/// rewound: what tracks a terminal (agent lifecycle, session, title), a page's title, where a
/// follow tile is aimed and its history, a follow tile appearing, and the app's own write-backs
/// (`ActivityActor.system`), so ⌘Z reaches the user's last own action through an agent's work.
@MainActor
public final class UndoHistory {
    public enum Change: Sendable {
        case created(CanvasObject)
        case updated(before: CanvasObject, after: CanvasObject)
        case deleted(CanvasObject)
        /// Something outside the board the step did (a changes tile's git action), undone and
        /// redone with it.
        case effect(UndoEffect)
        /// Mentions the step took out of the tray, each with its place there: a deleted
        /// object's, or the ones Hyper-V pasted into the terminal `pastedInto`. Undo puts them
        /// back where they were; redo takes them out again.
        case unstaged([PlacedMention], pastedInto: ObjectID?)
        /// Text the user kept out of a remote note. Replayed through a guarded host write,
        /// never through the host's history cursor.
        case noteRecovery(NoteRecovery)
    }

    /// Props a terminal's integrations keep current on their own.
    static let terminalBookkeeping: Set<String> = ["lifecycle", "agent", "title"]
    /// Props a follow tile's agent keeps current with every report (`Board.follow`).
    static let followBookkeeping: Set<String> = ["path", "range", "lastAction", "lastChanges", "history"]

    /// The props of `object` nobody sets on purpose: a terminal's lifecycle, session and title;
    /// a browser page's own title (`props.pageTitle`, the app's write-back; `title` is the
    /// creator's and stays undoable); a follow tile's aim and history; a diagram's computed graph.
    static func bookkeeping(_ object: CanvasObject) -> Set<String> {
        switch object.type {
        case .terminal: terminalBookkeeping
        case .browser: ["pageTitle"]
        case .code where object.props["followOf"]?.string != nil: followBookkeeping
        case .diagram: ["graph"]
        default: []
        }
    }

    /// One undo step: its changes, oldest first, and who made it (an agent when one made any
    /// of it, else the user), so undoing someone else's work can say so. `id` is the step's own,
    /// unique in its history: a remote board sends it with the step's writes, and its host's
    /// undo and redo answer for that step by it.
    public struct Step: Sendable {
        public var id: Int
        public var changes: [Change]
        public var author: Actor

        /// The step created, changed or deleted board objects (what a remote board's host
        /// reverts), not only what is the viewer's own (a tray's chips, an effect).
        public var changesBoard: Bool {
            changes.contains { change in
                if case .effect = change { return false }
                if case .unstaged = change { return false }
                if case .noteRecovery = change { return false }
                return true
            }
        }

        public var noteRecoveries: [NoteRecovery] {
            changes.compactMap {
                if case .noteRecovery(let recovery) = $0 { return recovery }
                return nil
            }
        }
    }

    public private(set) var undoSteps: [Step] = []
    public private(set) var redoSteps: [Step] = []
    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public let limit: Int
    private var depth = 0
    private var open: [Change] = []
    private var openAuthor: Actor = .user
    private var nextID = 1
    private(set) var openID = 0
    /// Where in `open` each object's update sits, so another update of it in the same step (a
    /// group re-fit once per member change, an arrow freed at both ends) amends it instead of
    /// adding a change. Only changes at or after `mergeFloor` amend, so `discard(from:)` of a
    /// later mark never has to reach back before it.
    private var openUpdates: [ObjectID: Int] = [:]
    private var mergeFloor = 0
    /// Set while an undo or redo applies its changes, which must not record themselves.
    var replaying = false
    /// Above zero while changes nobody chose (`Board.unrecorded`) are being made.
    var muted = 0

    public init(limit: Int = 200) {
        self.limit = limit
    }

    func record(_ change: Change, by author: Actor = .user) {
        guard !replaying, muted == 0 else { return }
        if author != .user { openAuthor = author }
        switch change {
        case .updated(let before, let after):
            if Self.content(before) == Self.content(after) { return }
            if let index = openUpdates[after.id], index >= mergeFloor, case .updated(let first, _) = open[index] {
                open[index] = .updated(before: first, after: after)
                return
            }
            openUpdates[after.id] = open.count
        case .created(let object), .deleted(let object):
            openUpdates.removeValue(forKey: object.id)
        case .effect, .unstaged, .noteRecovery:
            break
        }
        open.append(change)
        if depth == 0 { close() }
    }

    func recordNoteRecovery(_ recovery: NoteRecovery) {
        guard !replaying, muted == 0 else { return }
        if !open.isEmpty { close() }
        open = [.noteRecovery(recovery)]
        close()
        if depth > 0 { openID = takeID() }
    }

    func begin() {
        if depth == 0 { openID = takeID() }
        depth += 1
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    var openChanges: [Change] { open }

    var lastID: Int { nextID - 1 }

    /// True while a step is open (between the outermost `begin` and its `end`).
    var isOpen: Bool { depth > 0 }

    /// Marks the open step's current end for a later `discard(from:)`.
    func mark() -> Int {
        mergeFloor = open.count
        return open.count
    }

    /// Drops the open step's changes after the first `mark` and returns them, oldest first.
    func discard(from mark: Int) -> [Change] {
        let dropped = Array(open[mark...])
        open.removeSubrange(mark...)
        openUpdates = openUpdates.filter { $0.value < mark }
        return dropped
    }

    func end() {
        depth -= 1
        if depth == 0 { close() }
    }

    private func close() {
        openUpdates = [:]
        mergeFloor = 0
        let author = openAuthor
        openAuthor = .user
        let id = openID > 0 ? openID : takeID()
        openID = 0
        guard !open.isEmpty else { return }
        undoSteps.append(Step(id: id, changes: open, author: author))
        open = []
        if undoSteps.count > limit { undoSteps.removeFirst(undoSteps.count - limit) }
        redoSteps.removeAll()
    }

    func popUndo() -> Step? { undoSteps.popLast() }
    func popRedo() -> Step? { redoSteps.popLast() }
    func pushRedo(_ step: Step) { redoSteps.append(step) }
    func pushUndo(_ step: Step) { undoSteps.append(step) }

    @discardableResult
    func remove(redo: Bool, where picked: (Step) -> Bool) -> [Step] {
        let taken = (redo ? redoSteps : undoSteps).filter(picked)
        guard !taken.isEmpty else { return [] }
        if redo { redoSteps.removeAll(where: picked) } else { undoSteps.removeAll(where: picked) }
        return taken
    }

    func insertUndo(_ step: Step) {
        undoSteps.insert(step, at: undoSteps.firstIndex { $0.id > step.id } ?? undoSteps.count)
    }

    /// What an undo compares and restores: everything the user can see change, minus bookkeeping.
    struct Content: Equatable {
        var frame: Frame
        var z: Double
        var parent: ObjectID?
        var props: JSONValue
    }

    static func content(_ object: CanvasObject) -> Content {
        Content(frame: object.frame, z: object.z, parent: object.parent, props: contentProps(object))
    }

    static func contentProps(_ object: CanvasObject) -> JSONValue {
        props(of: object, without: bookkeeping(object))
    }

    static func props(of object: CanvasObject, without keys: Set<String>) -> JSONValue {
        guard !keys.isEmpty, var props = object.props.object else { return object.props }
        for key in keys { props.removeValue(forKey: key) }
        return .object(props)
    }

    /// `target`'s content applied to `current`, keeping current's bookkeeping props.
    static func restoring(_ target: CanvasObject, onto current: CanvasObject) -> CanvasObject {
        var object = current
        object.frame = target.frame
        object.z = target.z
        object.parent = target.parent
        var props = contentProps(target).object ?? [:]
        if let live = current.props.object {
            for key in bookkeeping(current) { props[key] = live[key] }
        }
        object.props = .object(props)
        return object
    }
}

/// A step's change outside the board: what undo and redo run for it (on the main actor; slow
/// work goes to a task of its own), and what it is called when undone (`Stage of src/a.rs`),
/// so undoing a change to the user's files or git index always says what it undid.
public struct UndoEffect: Sendable {
    public let name: String
    public let undo: @MainActor @Sendable () -> Void
    public let redo: @MainActor @Sendable () -> Void

    public init(name: String, undo: @escaping @MainActor @Sendable () -> Void, redo: @escaping @MainActor @Sendable () -> Void) {
        self.name = name
        self.undo = undo
        self.redo = redo
    }
}

/// A mention taken out of the tray and where it sat there (its index), so undo puts it back in
/// its place and the chips keep their numbers.
public struct PlacedMention: Sendable, Equatable {
    public var index: Int
    public var mention: Mention

    public init(index: Int, mention: Mention) {
        self.index = index
        self.mention = mention
    }
}

extension Board {
    /// Groups every change made inside `body` into one undo step (a multi-object gesture).
    public func transaction<T>(_ body: () throws -> T) rethrows -> T {
        history.begin()
        defer { endStep() }
        return try body()
    }

    func stepping<T>(_ body: (Int?) throws -> T) rethrows -> T {
        history.begin()
        defer { endStep() }
        return try body(history.muted == 0 && !history.replaying ? history.openID : nil)
    }

    /// Makes changes no one chose, which ⌘Z skips (a follow tile appearing or re-aiming, the
    /// app's write-backs): nothing inside is recorded, and later undos keep what it did.
    func unrecorded<T>(_ body: () throws -> T) rethrows -> T {
        history.muted += 1
        defer { history.muted -= 1 }
        return try body()
    }

    /// Reverts the latest recorded step. False when there is nothing to undo, or the step needs
    /// an asynchronous host write (remote board changes and note recovery use `BoardMirror.undo`).
    @discardableResult
    public func undo() -> Bool {
        guard let next = nextUndo, !(isRemote && next.changesBoard), next.noteRecoveries.isEmpty,
              let step = history.popUndo() else { return false }
        replayVerb = "undo"
        defer { replayVerb = nil }
        history.pushRedo(UndoHistory.Step(id: step.id, changes: revert(step.changes), author: step.author))
        return true
    }

    /// Reverts recorded changes, newest first; returns them as a redo step (oldest first).
    @discardableResult
    func revert(_ step: [UndoHistory.Change]) -> [UndoHistory.Change] {
        var replayed: [UndoHistory.Change] = []
        replay {
            for change in step.reversed() {
                switch change {
                case .created(let object):
                    replayed.append(.created(removeLive(object)))
                case .updated(let before, _):
                    put(before)
                    replayed.append(change)
                case .deleted(let object):
                    put(object)
                    replayed.append(change)
                case .effect(let effect):
                    effect.undo()
                    replayed.append(change)
                case .unstaged(let placed, _):
                    restageMentions(placed)
                    replayed.append(change)
                case .noteRecovery:
                    break
                }
            }
        }
        return replayed.reversed()
    }

    /// Re-applies the latest undone step. False when there is nothing to redo, or the step needs
    /// an asynchronous host write (`undo`).
    @discardableResult
    public func redo() -> Bool {
        guard let next = nextRedo, !(isRemote && next.changesBoard), next.noteRecoveries.isEmpty,
              let step = history.popRedo() else { return false }
        replayVerb = "redo"
        defer { replayVerb = nil }
        var replayed: [UndoHistory.Change] = []
        replay {
            for change in step.changes {
                switch change {
                case .created(let object):
                    put(object)
                    replayed.append(change)
                case .updated(_, let after):
                    put(after)
                    replayed.append(change)
                case .deleted(let object):
                    replayed.append(.deleted(removeLive(object)))
                case .effect(let effect):
                    effect.redo()
                    replayed.append(change)
                case .unstaged(let placed, _):
                    unstageMentions(placed)
                    replayed.append(change)
                case .noteRecovery:
                    break
                }
            }
        }
        history.pushUndo(UndoHistory.Step(id: step.id, changes: replayed, author: step.author))
        return true
    }

    /// Deletes an object for undo/redo and returns what to bring back later: the live object,
    /// whose content matches the recorded snapshot (later steps were already reverted) and whose
    /// bookkeeping (agent session, lifecycle, title) is the latest the integrations reported. A
    /// terminal's follow tile, whose appearance was never a step, goes with it.
    private func removeLive(_ recorded: CanvasObject) -> CanvasObject {
        guard let live = objects[recorded.id] else { return recorded }
        try? delete(recorded.id)
        if live.type == .terminal { for follow in followTiles(of: live.id) { try? delete(follow.id) } }
        return live
    }

    private func replay(_ body: () -> Void) {
        history.replaying = true
        defer { history.replaying = false }
        body()
    }

    /// Brings an object back to `target`'s content: in place when it exists, else re-created
    /// with the same id and z (undo of a delete).
    private func put(_ target: CanvasObject) {
        var object = objects[target.id].map { UndoHistory.restoring(target, onto: $0) } ?? target
        object.updatedAt = Date()
        object.updatedBy = .user
        restore(object)
    }
}
