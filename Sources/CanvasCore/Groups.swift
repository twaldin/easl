import CoreGraphics
import Foundation

/// Typed view of `GroupProps`. A group is a region: its frame is always its members' bounds
/// plus `padding`, with a title band on top, recomputed whenever a member moves, resizes, or
/// goes away, so `encloses` and hit tests see what is drawn.
public struct GroupSpec: Equatable, Sendable {
    public static let defaultPadding = 24.0
    /// Band above the members holding the title (the group's drag handle).
    public static let titleHeight = 32.0
    /// `cause` of a group's re-fit in the activity log.
    public static let refitCause = "fit to its members"

    public var members: [ObjectID]
    public var title: String?
    /// Palette name or #rrggbb, as ShapeProps.color; nil draws a neutral region.
    public var color: String?
    public var padding: Double
    /// Which way the diagram inside reads; arrows among its members leave downstream sides and
    /// enter upstream ones (`ConnectorRouter.Flow`). Nil infers it from the arrows.
    public var flow: ConnectorRouter.Flow?

    public init?(_ props: JSONValue) {
        guard let members = props["members"]?.array else { return nil }
        self.members = members.compactMap(\.string)
        title = props["title"]?.string
        color = props["color"]?.string
        padding = max(0, props["padding"]?.number ?? Self.defaultPadding)
        flow = props["flow"]?.string.flatMap(ConnectorRouter.Flow.init(rawValue:))
    }

    /// The region around member rects (any coordinates): their union, `padding` on every side,
    /// and the title band on top. Nil without members.
    public func frame(around rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let inset = CGFloat(padding)
        return CGRect(x: union.minX - inset, y: union.minY - inset - Self.titleHeight,
                      width: union.width + 2 * inset, height: union.height + 2 * inset + Self.titleHeight)
    }
}

extension Board {
    /// The frame around visible geometric members. Archiving the last one collapses the group;
    /// genuinely empty groups retain their existing frame behavior.
    func fittedFrame(ofGroup group: CanvasObject) -> Frame? {
        guard group.type == .group, let spec = GroupSpec(group.props) else { return nil }
        let members = spec.members.compactMap { objects[$0] }.filter { $0.type != .arrow && $0.id != group.id }
        let rects = members.filter { !$0.isHidden && ($0.type != .group || ($0.frame.w > 0 && $0.frame.h > 0)) }.map(\.frame.rect)
        if let frame = spec.frame(around: rects) { return Frame(frame) }
        if members.contains(where: { $0.isHidden || ($0.type == .group && ($0.frame.w == 0 || $0.frame.h == 0)) }) {
            return Frame(x: group.frame.x, y: group.frame.y, w: 0, h: 0)
        }
        return nil
    }

    /// Re-bounds every group that lists `id`, recursively for nested groups, as part of the
    /// caller's change (and so its undo step), credited to that change's actor. Undo/redo
    /// restore recorded frames instead. Inside `deferringRefits` it waits for the scope's end.
    func refitGroups(containing id: ObjectID, actor: ActivityActor, caller: ObjectID?, visited: Set<ObjectID> = []) {
        guard !history.replaying else { return }
        if refitDeferral > 0 {
            pendingRefits.append((id, actor, caller))
            return
        }
        let parents = objects.values
            .filter { $0.type == .group && !visited.contains($0.id) && GroupSpec($0.props)?.members.contains(id) == true }
            .sorted { $0.id < $1.id }
        for group in parents {
            guard let frame = fittedFrame(ofGroup: group), frame != objects[group.id]?.frame else { continue }
            _ = try? write(group.id, rev: nil, frame: frame, z: nil, props: nil, caller: caller, actor: actor,
                           cause: GroupSpec.refitCause, refitting: visited.union([id]))
        }
    }

    /// Runs `body` with group re-fits held back, then re-fits each affected group once: moving
    /// a group's 20 members writes the group once, not 20 times through intermediate frames.
    /// Group frames are stale inside `body`; read them after it returns.
    func deferringRefits<T>(_ body: () throws -> T) rethrows -> T {
        refitDeferral += 1
        defer {
            refitDeferral -= 1
            if refitDeferral == 0 {
                let pending = pendingRefits
                pendingRefits = []
                var seen: Set<ObjectID> = []
                for refit in pending where seen.insert(refit.member).inserted {
                    refitGroups(containing: refit.member, actor: refit.actor, caller: refit.caller)
                }
            }
        }
        return try body()
    }

    /// Groups (transitively) listing `id`.
    public func groups(containing id: ObjectID) -> [ObjectID] {
        var found: [ObjectID] = []
        var queue = [id]
        while let next = queue.popLast() {
            for group in objects.values where group.type == .group && !found.contains(group.id) && GroupSpec(group.props)?.members.contains(next) == true {
                found.append(group.id)
                queue.append(group.id)
            }
        }
        return found.sorted()
    }
}
