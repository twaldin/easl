import Foundation

struct ViewerEdit: Equatable, Sendable {
    let viewer: String
    let step: Int

    init?(_ params: JSONValue) throws {
        let viewer = params["viewer"], step = params["step"]
        if viewer == nil, step == nil { return nil }
        guard viewer != nil, step != nil else {
            throw BoardError.invalidParams("viewer and step go together: a remote window's own edit gives both")
        }
        self.viewer = try Self.viewer(viewer)
        self.step = try Self.step(step)
    }

    static func viewer(_ value: JSONValue?) throws -> String {
        guard let text = value?.string, text.range(of: "^vw_[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil else {
            throw BoardError.invalidParams("viewer must be a remote window's id: vw_ and 8 to 64 letters, digits, _ or -")
        }
        return text
    }

    static func step(_ value: JSONValue?) throws -> Int {
        guard let number = value?.number, number >= 1, number == number.rounded(), number <= 9_007_199_254_740_991 else {
            throw BoardError.invalidParams("step must be a whole number from 1")
        }
        return Int(number)
    }
}

struct ViewerHistory {
    struct Step {
        let id: Int
        var changes: [UndoHistory.Change]
    }

    struct Receipt {
        let redo: Bool
        let step: Int
        let kept: [ObjectID]
        let touched: [ObjectID]
        let pushed: Bool
    }

    static let limit = 200

    private(set) var undo: [Step] = []
    private(set) var redo: [Step] = []
    private var receipts: [Int: Receipt] = [:]
    private(set) var floor = 0
    private var receiptFloor = 0
    var used: UInt64 = 0

    mutating func file(_ changes: [UndoHistory.Change], step id: Int) {
        guard !changes.isEmpty, id > floor else { return }
        forget(id)
        redo.removeAll()
        if let index = undo.firstIndex(where: { $0.id == id }) {
            undo[index].changes += changes
        } else {
            undo.insert(Step(id: id, changes: changes), at: undo.firstIndex { $0.id > id } ?? undo.count)
            if undo.count > Self.limit { raise(to: undo[0].id) }
        }
        trimReceipts()
    }

    func receipt(redo: Bool, asked: Int) -> Receipt? {
        receipts[asked].flatMap { $0.redo == redo ? $0 : nil }
    }

    func retired(redo: Bool, asked: Int) -> Bool {
        asked <= receiptFloor && !(redo ? self.redo : undo).contains { $0.id == asked }
    }

    func holds(_ receipt: Receipt) -> Bool {
        (receipt.redo ? undo : redo).contains { $0.id == receipt.step }
    }

    func step(redo: Bool, asked: Int) -> Step? {
        redo ? self.redo.last { $0.id == asked } : undo.last { $0.id <= asked }
    }

    mutating func replayed(_ step: Step, redo: Bool, asked: Int, did changes: [UndoHistory.Change], kept: [ObjectID]) -> Receipt {
        if redo {
            if let index = self.redo.lastIndex(where: { $0.id == step.id }) { self.redo.removeSubrange(index...) }
        } else {
            undo.removeAll { $0.id == step.id }
        }
        let pushed = !changes.isEmpty
        if pushed {
            let next = Step(id: step.id, changes: changes)
            if redo { undo.insert(next, at: undo.firstIndex { $0.id > step.id } ?? undo.count) } else { self.redo.append(next) }
        }
        forget(step.id)
        let receipt = Receipt(redo: redo, step: step.id, kept: kept, touched: Self.touched(changes), pushed: pushed)
        receipts[step.id] = receipt
        receipts[asked] = receipt
        trimReceipts()
        return receipt
    }

    private mutating func forget(_ id: Int) {
        var retired = receiptFloor
        receipts = receipts.filter {
            guard $0.key == id || $0.value.step == id else { return true }
            retired = max(retired, $0.key)
            return false
        }
        receiptFloor = retired
    }

    private mutating func raise(to id: Int) {
        floor = max(floor, id)
        undo.removeAll { $0.id <= floor }
        redo.removeAll { $0.id <= floor }
        var retired = receiptFloor
        receipts = receipts.filter {
            guard $0.key <= floor || $0.value.step <= floor else { return true }
            retired = max(retired, $0.key)
            return false
        }
        receiptFloor = retired
    }

    private mutating func trimReceipts() {
        let live = Set(undo.map(\.id) + redo.map(\.id))
        let consumed = receipts.compactMap { live.contains($0.value.step) ? nil : $0.key }.sorted()
        guard consumed.count > Self.limit else { return }
        for key in consumed.prefix(consumed.count - Self.limit) {
            receiptFloor = max(receiptFloor, key)
            receipts.removeValue(forKey: key)
        }
    }

    static func touched(_ changes: [UndoHistory.Change]) -> [ObjectID] {
        var ids: [ObjectID] = []
        for change in changes {
            let id: ObjectID
            switch change {
            case .created(let object), .deleted(let object): id = object.id
            case .updated(_, let after): id = after.id
            case .effect, .unstaged, .noteRecovery: continue
            }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}

struct ViewerHistories {
    static let limit = 16
    private var histories: [String: ViewerHistory] = [:]
    private var clock: UInt64 = 0

    func contains(_ viewer: String) -> Bool { histories[viewer] != nil }

    mutating func with<T>(_ viewer: String, _ body: (inout ViewerHistory) -> T) -> T {
        clock += 1
        if histories[viewer] == nil, histories.count >= Self.limit, let oldest = histories.min(by: { $0.value.used < $1.value.used })?.key {
            histories.removeValue(forKey: oldest)
        }
        histories[viewer, default: ViewerHistory()].used = clock
        return body(&histories[viewer, default: ViewerHistory()])
    }
}

/// What one `board.undo` or `board.redo` did.
public struct ViewerReplay: Equatable, Sendable {
    /// The viewer's step replayed, or requested when retired; nil when the host has none.
    public var step: Int?
    /// The objects the replay changed, as they are now.
    public var changed: [CanvasObject]
    /// The objects it removed (an undone create, a redone delete).
    public var deleted: [ObjectID]
    /// Objects it touched only partly or not at all: someone changed what the step left there.
    public var kept: [ObjectID]
    /// The step went onto the other stack: ⇧⌘Z (after an undo) or ⌘Z (after a redo) takes it back.
    public var pushed: Bool
    /// The requested outcome was retired; no step was replayed.
    public var retired: Bool

    public init(step: Int? = nil, changed: [CanvasObject] = [], deleted: [ObjectID] = [], kept: [ObjectID] = [], pushed: Bool = false, retired: Bool = false) {
        self.step = step
        self.changed = changed
        self.deleted = deleted
        self.kept = kept
        self.pushed = pushed
        self.retired = retired
    }

    init(reply: JSONValue) throws {
        step = reply["step"]?.int
        changed = try (reply["changed"]?.array ?? []).map { try $0.decode(CanvasObject.self) }
        deleted = (reply["deleted"]?.array ?? []).compactMap(\.string)
        kept = (reply["kept"]?.array ?? []).compactMap(\.string)
        pushed = reply["pushed"]?.bool ?? false
        retired = reply["retired"]?.bool ?? false
    }

    @MainActor func json(_ board: Board) -> JSONValue {
        var fields: [String: JSONValue] = [
            "changed": .array(board.reported(changed).map(JSONValue.init)), "deleted": .array(deleted.map(JSONValue.string)),
            "kept": .array(kept.map(JSONValue.string)), "pushed": .bool(pushed),
        ]
        if let step { fields["step"] = .number(Double(step)) }
        if retired { fields["retired"] = .bool(true) }
        return .object(fields)
    }
}

struct GuardedInverse {
    struct Patch {
        let id: ObjectID
        var x: Double?, y: Double?, w: Double?, h: Double?, z: Double?
        var props: [String: JSONValue] = [:]
        var expires: ObjectExpiryPatch = .unchanged

        var isEmpty: Bool { x == nil && y == nil && w == nil && h == nil && z == nil && props.isEmpty && expires == .unchanged }
    }

    var recreates: [CanvasObject] = []
    var patches: [Patch] = []
    var removes: [ObjectID] = []
    var restage: [PlacedMention] = []
    var kept: [ObjectID] = []

    var isEmpty: Bool { recreates.isEmpty && patches.isEmpty && removes.isEmpty }
}

extension Board {

    func asViewerEdit<T>(_ edit: ViewerEdit?, _ body: () throws -> T) throws -> T {
        guard let edit else { return try body() }
        guard !history.isOpen else {
            throw BoardError.invalidParams("viewer and step mark a remote window's own edit: they aren't taken inside object.batch")
        }
        history.begin()
        defer { endStep() }
        let result = try body()
        let changes = history.openChanges
        if !changes.isEmpty { viewerHistories.with(edit.viewer) { $0.file(changes, step: edit.step) } }
        return result
    }

    func replayViewer(_ viewer: String, step asked: Int, redo: Bool) throws -> ViewerReplay {
        guard !history.isOpen else { throw BoardError.invalidParams("board.\(redo ? "redo" : "undo") runs on its own, not inside another change") }
        guard viewerHistories.contains(viewer) else { return ViewerReplay() }
        let steps = viewerHistories.with(viewer) { $0 }
        if let receipt = steps.receipt(redo: redo, asked: asked) { return report(receipt, pushed: receipt.pushed && steps.holds(receipt)) }
        guard asked > steps.floor else {
            throw BoardError.conflict("step \(asked) is older than the \(ViewerHistory.limit) steps this board keeps for viewer \(viewer)")
        }
        if steps.retired(redo: redo, asked: asked) { return ViewerReplay(step: asked, retired: true) }
        guard let step = steps.step(redo: redo, asked: asked) else { return ViewerReplay() }
        let plan = inverse(of: step.changes)
        var replayed: [UndoHistory.Change] = []
        if !plan.isEmpty {
            replayVerb = redo ? "redo" : "undo"
            defer { replayVerb = nil }
            try atomically {
                try apply(plan)
                replayed = history.openChanges
            }
        }
        let receipt = viewerHistories.with(viewer) { $0.replayed(step, redo: redo, asked: asked, did: replayed, kept: plan.kept) }
        return report(receipt, pushed: receipt.pushed)
    }

    private func report(_ receipt: ViewerHistory.Receipt, pushed: Bool) -> ViewerReplay {
        ViewerReplay(step: receipt.step, changed: receipt.touched.compactMap { objects[$0] }, deleted: receipt.touched.filter { objects[$0] == nil },
                     kept: receipt.kept, pushed: pushed)
    }

    func inverse(of changes: [UndoHistory.Change]) -> GuardedInverse {
        var order: [ObjectID] = []
        var net: [ObjectID: (before: CanvasObject?, after: CanvasObject?)] = [:]
        var unstaged: [PlacedMention] = []
        func note(_ id: ObjectID, before: CanvasObject?, after: CanvasObject?) {
            if net[id] == nil {
                order.append(id)
                net[id] = (before, after)
            } else {
                net[id]?.after = after
            }
        }
        for change in changes {
            switch change {
            case .created(let object): note(object.id, before: nil, after: object)
            case .updated(let before, let after): note(after.id, before: before, after: after)
            case .deleted(let object): note(object.id, before: object, after: nil)
            case .unstaged(let placed, _): unstaged += placed
            case .effect, .noteRecovery: break
            }
        }
        var plan = GuardedInverse()
        func keep(_ id: ObjectID) { if !plan.kept.contains(id) { plan.kept.append(id) } }
        func heldByAnother(_ key: String?, _ id: ObjectID) -> Bool {
            guard let key, !key.isEmpty else { return false }
            return keyHolders[key]?.contains { $0 != id } == true
        }
        for id in order.reversed() {
            guard let effect = net[id] else { continue }
            let current = objects[id]
            switch (effect.before, effect.after) {
            case (nil, nil):
                continue
            case (nil, let after?):
                guard let current else { continue }
                var now = UndoHistory.content(current)
                let left = UndoHistory.content(after)
                if current.type == .group { now.frame = left.frame }
                if now == left { plan.removes.append(id) } else { keep(id) }
            case (let before?, nil):
                guard current == nil, !heldByAnother(Self.key(before.props), id) else {
                    keep(id)
                    continue
                }
                plan.recreates.append(before)
            case (let before?, let after?):
                guard let current else {
                    keep(id)
                    continue
                }
                var patch = GuardedInverse.Patch(id: id)
                func field(_ old: Double, _ new: Double, _ now: Double) -> Double? {
                    guard old != new else { return nil }
                    guard now == new else {
                        keep(id)
                        return nil
                    }
                    return old
                }
                if current.type != .group {
                    patch.x = field(before.frame.x, after.frame.x, current.frame.x)
                    patch.y = field(before.frame.y, after.frame.y, current.frame.y)
                    patch.w = field(before.frame.w, after.frame.w, current.frame.w)
                    patch.h = field(before.frame.h, after.frame.h, current.frame.h)
                }
                patch.z = field(before.z, after.z, current.z)
                if before.expires != after.expires {
                    if current.expires == after.expires { patch.expires = .set(before.expires) }
                    else { keep(id) }
                }
                let old = UndoHistory.contentProps(before).object ?? [:], new = UndoHistory.contentProps(after).object ?? [:]
                let now = current.props.object ?? [:]
                for key in Set(old.keys).union(new.keys).sorted() where old[key] != new[key] {
                    let value = old[key] ?? .null
                    guard now[key] == new[key], !(key == "key" && heldByAnother(value.string, id)) else {
                        keep(id)
                        continue
                    }
                    patch.props[key] = value
                }
                if !patch.isEmpty { plan.patches.append(patch) }
            }
        }
        plan.recreates.sort { $0.z < $1.z }
        let recreated = Set(plan.recreates.map(\.id))
        for index in plan.recreates.indices {
            if let parent = plan.recreates[index].parent, objects[parent] == nil, !recreated.contains(parent) { plan.recreates[index].parent = nil }
        }
        plan.restage = unstaged.filter { !recreated.isDisjoint(with: $0.mention.target.objectIDs) }
        return plan
    }

    private func apply(_ plan: GuardedInverse) throws {
        for object in plan.recreates { recreate(object) }
        for patch in plan.patches {
            let current = try object(patch.id)
            var frame = current.frame
            frame.x = patch.x ?? frame.x
            frame.y = patch.y ?? frame.y
            frame.w = patch.w ?? frame.w
            frame.h = patch.h ?? frame.h
            _ = try update(patch.id, frame: frame == current.frame ? nil : frame, z: patch.z, props: patch.props.isEmpty ? nil : .object(patch.props), expires: patch.expires)
        }
        for id in plan.removes where objects[id] != nil { try delete(id) }
        if !plan.restage.isEmpty { restageMentions(plan.restage) }
    }

    private func recreate(_ object: CanvasObject) {
        var object = object
        object.updatedAt = Date()
        object.updatedBy = .user
        restore(object)
        guard let restored = objects[object.id] else { return }
        history.record(.created(restored))
        refitGroups(containing: restored.id, actor: .user, caller: nil)
    }


    func replayViewerOwned(_ step: UndoHistory.Step, redo: Bool) {
        for change in redo ? step.changes : Array(step.changes.reversed()) {
            switch change {
            case .unstaged(let placed, _):
                if redo { unstageMentions(placed) } else { restageMentions(placed) }
            case .effect(let effect):
                if redo { effect.redo() } else { effect.undo() }
            case .created, .updated, .deleted, .noteRecovery:
                break
            }
        }
    }

    func reconcile(_ reply: ViewerReplay, asked: UndoHistory.Step, redo: Bool) -> UndoHistory.Step? {
        if reply.retired {
            history.remove(redo: redo) { $0.id == asked.id }
            return nil
        }
        if redo {
            guard let id = reply.step else {
                history.remove(redo: true) { $0.changesBoard }
                return nil
            }
            guard let step = history.remove(redo: true, where: { $0.id == id }).first ?? (asked.id == id ? asked : nil) else { return nil }
            replayViewerOwned(step, redo: true)
            if reply.pushed { history.insertUndo(step) }
            return step
        }
        let landed = reply.step ?? 0
        history.remove(redo: false) { $0.changesBoard && $0.id > landed && $0.id <= asked.id }
        guard let id = reply.step, let step = history.remove(redo: false, where: { $0.id == id }).first else { return nil }
        replayViewerOwned(step, redo: false)
        if reply.pushed, !history.undoSteps.contains(where: { $0.id > asked.id }) { history.pushRedo(step) }
        return step
    }
}
