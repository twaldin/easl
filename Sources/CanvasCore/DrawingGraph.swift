import CoreGraphics
import Foundation

/// Spatial structure a drawn object carries: what it encloses and the arrows drawn inside it.
/// Shared by `object.get --as graph` and the mention context so both describe the same thing.
extension Board {
    /// Objects (other than arrows and `object` itself) lying wholly inside `object`'s frame.
    public func enclosed(by object: CanvasObject) -> [CanvasObject] {
        guard !object.isHidden, object.type != .group || (object.frame.w > 0 && object.frame.h > 0) else { return [] }
        return objects.values
            .filter { !$0.isHidden && ($0.type != .group || ($0.frame.w > 0 && $0.frame.h > 0))
                && $0.id != object.id && $0.type != .arrow && object.frame.contains($0.frame) }
            .sorted { $0.id < $1.id }
    }

    /// Arrows drawn inside `object`: each end is either a free point inside its frame or bound to
    /// an object it encloses. Arrows bound to `object` itself are its own in/out arrows, not these.
    public func arrows(enclosedBy object: CanvasObject) -> [(arrow: CanvasObject, spec: ArrowSpec)] {
        guard !object.isHidden else { return [] }
        let inside = Set(enclosed(by: object).map(\.id))
        let region = object.frame.rect
        func within(_ binding: ArrowBinding) -> Bool {
            switch binding {
            case .object(let id, _, _, _): inside.contains(id)
            case .point(let point): region.contains(point)
            }
        }
        return objects.values
            .filter { $0.type == .arrow && $0.id != object.id }
            .compactMap { arrow in ArrowSpec(arrow.props).map { (arrow, $0) } }
            .filter { within($0.spec.from) && within($0.spec.to) }
            .sorted { $0.arrow.id < $1.arrow.id }
    }

    /// Before `id` is deleted, every arrow bound to it gets a free end where it last attached, so
    /// the arrow keeps its drawn direction (also after a reload) and its other end keeps routing.
    /// The rewrite is a cascade of the delete, credited to whoever deleted.
    func detachArrows(from id: ObjectID, actor: ActivityActor, caller: ObjectID?) {
        let bound = objects.values.sorted(by: { $0.id < $1.id }).compactMap { arrow -> (CanvasObject, ArrowSpec)? in
            guard arrow.type == .arrow, arrow.id != id, let spec = ArrowSpec(arrow.props), spec.from.objectID == id || spec.to.objectID == id else { return nil }
            return (arrow, spec)
        }
        guard !bound.isEmpty else { return }
        var paths = arrowPaths(bound.map(\.0.id))
        let missing = Set(bound.map(\.0.id)).subtracting(paths.keys)
        if !missing.isEmpty {
            var visible = objects
            func showEndpoint(_ end: ObjectID?) {
                guard let end, var object = visible[end], object.isHidden else { return }
                object.props = object.props.merging(.object(["archived": .bool(false)]))
                visible[end] = object
            }
            for (_, spec) in bound where spec.hasHiddenEndpoint(in: objects) {
                showEndpoint(spec.from.objectID)
                showEndpoint(spec.to.objectID)
            }
            paths.merge(BoardGeometry(objects: visible, labelSizes: [:]).routes(only: missing)) { drawn, _ in drawn }
        }
        for (arrow, var spec) in bound {
            guard let path = paths[arrow.id] else { continue }
            if spec.from.objectID == id { spec.from = .point(path[0]) }
            if spec.to.objectID == id { spec.to = .point(path[path.count - 1]) }
            _ = try? write(arrow.id, rev: nil, frame: nil, z: nil, props: .object(["from": spec.from.json, "to": spec.to.json]),
                           caller: caller, actor: actor, cause: "bound object \(id) deleted", refitting: [])
        }
    }

    /// Each arrow's routed line: as the app draws it, else routed from object frames (the ones
    /// the app hasn't drawn, together). Arrows whose ends are gone have none.
    func arrowPaths(_ ids: [ObjectID]) -> [ObjectID: [CGPoint]] {
        var paths: [ObjectID: [CGPoint]] = [:]
        var missing: Set<ObjectID> = []
        for id in ids {
            if let arrow = objects[id], let spec = ArrowSpec(arrow.props), spec.hasHiddenEndpoint(in: objects) { continue }
            if let drawn = arrowPath?(id), drawn.count >= 2 { paths[id] = drawn } else { missing.insert(id) }
        }
        if !missing.isEmpty {
            paths.merge(BoardGeometry(objects: objects, labelSizes: [:], settled: settledRouting?()).routes(only: missing)) { drawn, _ in drawn }
        }
        return paths
    }

    /// Objects as the API reports them: an arrow's frame is the bounds of its routed line (what
    /// is drawn; the stored frame means nothing once an end is bound), everything else as stored.
    /// Outside a step the drawing layer first routes what it has pending (`settleArrows`), so a
    /// new or changed `avoid` arrow reports its route, not the provisional one it holds until then.
    public func reported(_ list: [CanvasObject]) -> [CanvasObject] {
        let arrows = list.filter { $0.type == .arrow }.map(\.id)
        guard !arrows.isEmpty else { return list }
        if !history.isOpen { settleArrows?() }
        let paths = arrowPaths(arrows)
        return list.map { object in
            guard let path = paths[object.id] else { return object }
            var copy = object
            copy.frame = Self.bounds(of: path)
            return copy
        }
    }

    public func reported(_ object: CanvasObject) -> CanvasObject { reported([object])[0] }

    static func bounds(of path: [CGPoint]) -> Frame {
        let xs = path.map(\.x), ys = path.map(\.y)
        let minX = xs.min()!, minY = ys.min()!
        return Frame(x: Double(minX), y: Double(minY), w: Double(xs.max()! - minX), h: Double(ys.max()! - minY))
    }
}
