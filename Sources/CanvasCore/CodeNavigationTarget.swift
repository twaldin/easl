import Foundation

/// Where a code tile points: its file (board-relative when under the root), lines and symbol,
/// and the version of the file it shows: the commit it is pinned to (`pinnedCommit`), or the
/// branch it follows (`ref`); neither: the working tree.
public struct CodeAim: Equatable, Sendable {
    public var path: String
    public var range: LineRange?
    public var symbol: String?
    public var pinnedCommit: String?
    public var ref: String?

    public init(path: String, range: LineRange?, symbol: String? = nil, pinnedCommit: String? = nil, ref: String? = nil) {
        self.path = path
        self.range = range
        self.symbol = symbol
        self.pinnedCommit = pinnedCommit
        self.ref = ref
    }

    /// Whether a code tile's props show the same version of a file as this aim.
    func sameVersion(_ props: JSONValue) -> Bool {
        props["pinnedCommit"]?.string.flatMap { $0.isEmpty ? nil : $0 } == pinnedCommit && RefSource.ref(of: props) == ref
    }

    /// The aim of a code tile; nil for anything else.
    public init?(_ object: CanvasObject) {
        guard object.type == .code else { return nil }
        self.init(props: object.props)
    }

    /// The aim `props` carry (a code tile's, or an entry of a follow tile's history); nil
    /// without a path.
    public init?(props: JSONValue) {
        guard let path = props["path"]?.string else { return nil }
        let start = props["range"]?["start"]?.int
        self.init(path: path, range: start.map { LineRange(start: $0, end: props["range"]?["end"]?.int ?? $0) }, symbol: props["symbol"]?.string,
                  pinnedCommit: props["pinnedCommit"]?.string.flatMap { $0.isEmpty ? nil : $0 }, ref: RefSource.ref(of: props))
    }

    /// The props that aim a tile here (null clears a range, symbol, pin, or ref it had).
    var props: JSONValue {
        .object(["path": .string(path), "range": range?.json ?? .null, "symbol": symbol.map(JSONValue.string) ?? .null,
                 "pinnedCommit": pinnedCommit.map(JSONValue.string) ?? .null, "ref": ref.map(JSONValue.string) ?? .null])
    }

    /// `path:12`, `path:12-20`, or the path alone.
    public var label: String {
        guard let range else { return path }
        return range.end > range.start ? "\(path):\(range.start)-\(range.end)" : "\(path):\(range.start)"
    }
}

/// A code tile a navigation re-aimed: what it showed before and what it shows after.
public struct CodeReaim: Equatable, Sendable {
    public var tile: ObjectID
    public var before: CodeAim
    public var after: CodeAim

    public init(tile: ObjectID, before: CodeAim, after: CodeAim) {
        self.tile = tile
        self.before = before
        self.after = after
    }

    /// The same tile the other way round (Back).
    public var inverted: CodeReaim { CodeReaim(tile: tile, before: after, after: before) }
}

/// What a navigation to code did: the tile that shows it, whether it is new, the re-aim of an
/// existing tile when there was one, and whether the tile already showed the lines (`existing`:
/// nothing changed, the navigation goes to it wherever it is).
public struct CodeOpened: Equatable, Sendable {
    public var id: ObjectID
    public var created: Bool
    public var reaim: CodeReaim?
    public var existing: Bool

    public init(id: ObjectID, created: Bool, reaim: CodeReaim?, existing: Bool = false) {
        self.id = id
        self.created = created
        self.reaim = reaim
        self.existing = existing
    }
}

extension Board {
    /// Whether code tile `id` is plain navigation surface that navigating may re-aim: a tile the
    /// user made and an agent hasn't touched since, with no caption, in no group, not a follow
    /// tile. An agent's walkthrough tile, an Open All excerpt (captioned, grouped) and a follow
    /// tile keep their range: navigation opens another tile instead.
    public func isNavigationSurface(_ id: ObjectID) -> Bool {
        guard let object = objects[id], object.type == .code, object.createdBy == .user,
              object.updatedBy.map({ $0 == .user }) ?? true,
              object.props["followOf"] == nil, object.parent == nil else { return false }
        if let caption = object.props["caption"]?.string, !caption.isEmpty { return false }
        return !objects.values.contains { $0.type == .group && GroupSpec($0.props)?.members.contains(id) == true }
    }

    /// The code tile already showing `aim`, which navigating there goes to wherever it is on the
    /// board: a tile showing exactly its path and lines (the path alone for an aim without lines),
    /// else a captioned tile of that path whose range contains the lines (a walkthrough's stop).
    /// Follow tiles never count: they belong to their agent and move on as it reads. Among
    /// several, one in view first, then the nearest `center` (the viewport's center without
    /// one), then the topmost.
    public func tileShowing(_ aim: CodeAim, near center: Frame?) -> ObjectID? {
        let view = viewport()
        let center = center ?? view
        var best: (id: ObjectID, rank: (Int, Int, Double, Double))?
        for object in objects.values where object.props["followOf"] == nil {
            guard let shown = CodeAim(object), shown.path == aim.path, aim.sameVersion(object.props) else { continue }
            let exact = shown.range == aim.range
            if !exact {
                guard let lines = aim.range, let range = shown.range, range.start <= lines.start, lines.end <= range.end,
                      let caption = object.props["caption"]?.string, !caption.isEmpty else { continue }
            }
            let key = (exact ? 0 : 1, view.map { $0.intersects(object.frame) ? 0 : 1 } ?? 0, center.map(object.frame.centerDistance) ?? 0, -object.z)
            if best == nil || key < best!.rank || (key == best!.rank && object.id < best!.id) { best = (object.id, key) }
        }
        return best?.id
    }

    /// Opens code the user navigated to (Go to, a definition, a changes tile's line, a page's or
    /// note's link) near where the user is, never re-aiming someone else's tile and never far away:
    /// - a code tile already showing `aim` (`tileShowing`), anywhere on the board, is the answer
    ///   as it is (`existing`: the caller goes to it);
    /// - `preview` (a changes tile): the tile this source last created, while nobody changed it
    ///   since and it is still plain navigation surface (`isNavigationSurface`), is re-aimed,
    ///   even at another file, like a terminal's ⌘-click preview;
    /// - else a plain navigation tile in view showing the same file is re-aimed, the one nearest
    ///   the source (the viewport center without one);
    /// - else a new tile opens beside the source (at the viewport center without one) with
    ///   `extra` props, shrunk down to a follow tile's minimum to land wholly in view.
    /// Re-aims are navigation, not content changes: never an undo step (Back undoes them).
    /// Without a viewport (no window) every tile counts as in view.
    @discardableResult
    public func openForNavigation(_ aim: CodeAim, from source: ObjectID?, preview: Bool = false, extra: [String: JSONValue] = [:]) -> CodeOpened {
        let near = source.flatMap { objects[$0]?.frame }
        if let shown = tileShowing(aim, near: near) {
            return CodeOpened(id: shown, created: false, reaim: nil, existing: true)
        }
        if preview, let source, let previous = codePreviews[source], let object = objects[previous.tile], object.rev == previous.rev,
           isNavigationSurface(object.id), let reaim = reaimForNavigation(object.id, to: aim) {
            return CodeOpened(id: object.id, created: false, reaim: reaim)
        }
        let view = viewport()
        let center = near ?? view
        func distance(_ object: CanvasObject) -> Double { center.map(object.frame.centerDistance) ?? 0 }
        let nearest = objects.values.filter { object in
            object.type == .code && object.props["path"]?.string == aim.path && aim.sameVersion(object.props)
                && (view.map { $0.intersects(object.frame) } ?? true) && isNavigationSurface(object.id)
        }.min { (distance($0), $0.id) < (distance($1), $1.id) }
        if let nearest, let reaim = reaimForNavigation(nearest.id, to: aim) {
            return CodeOpened(id: nearest.id, created: false, reaim: reaim)
        }
        var props = extra
        props["path"] = .string(aim.path)
        if let range = aim.range { props["range"] = range.json }
        if let symbol = aim.symbol { props["symbol"] = .string(symbol) }
        if let pinnedCommit = aim.pinnedCommit { props["pinnedCommit"] = .string(pinnedCommit) }
        if let ref = aim.ref { props["ref"] = .string(ref) }
        // As wide as the file's lines need; only its height may be cut down to land in view.
        let size = newCodeSize(.object(props))
        let frame = source.map { place(width: size.w, height: size.h, near: $0, shrinkingTo: (size.w, Board.followMinimumSize.h)) }
            ?? place(width: size.w, height: size.h, near: nil)
        let created = create(type: .code, props: .object(props), frame: frame)
        if preview, let source { codePreviews[source] = (created.id, created.rev) }
        return CodeOpened(id: created.id, created: true, reaim: nil)
    }

    /// Back or Forward re-aiming tile `reaim.tile` from `reaim.before` to `reaim.after`, only
    /// while it is still plain navigation surface showing `before` (nobody aimed it elsewhere
    /// meanwhile). True when it was re-aimed.
    @discardableResult
    public func restoreAim(_ reaim: CodeReaim) -> Bool {
        guard isNavigationSurface(reaim.tile), let object = objects[reaim.tile], CodeAim(object) == reaim.before else { return false }
        return reaimForNavigation(reaim.tile, to: reaim.after) != nil
    }

    /// Re-aims code tile `id` as navigation (Go to, a link, a ⌘-click preview, Back and Forward,
    /// a follow tile's history strip): credited to the user, not an undo step (Back and Forward
    /// undo it). A preview (`codePreviews`) nobody else changed stays its source's preview, so
    /// the next ⌘-click or changes-tile click re-aims it again.
    @discardableResult
    public func reaimForNavigation(_ id: ObjectID, to aim: CodeAim) -> CodeReaim? {
        guard let object = objects[id], let before = CodeAim(object) else { return nil }
        guard before != aim else { return CodeReaim(tile: id, before: before, after: aim) }
        guard let aimed = try? unrecorded({ try update(id, props: aim.props) }) else { return nil }
        for (source, preview) in codePreviews where preview.tile == id && preview.rev == object.rev { codePreviews[source] = (id, aimed.rev) }
        return CodeReaim(tile: id, before: before, after: aim)
    }
}

extension Board {
    /// Review Changes' existing answer: a changes tile of the whole of `root` (nil: the board
    /// root) against `base`, the one in view when there is one, else the one nearest the view.
    public func changesTile(root: String?, base: String) -> ObjectID? {
        let directory = ChangesSpec(.object(root.map { ["root": .string($0)] } ?? [:])).directory(boardRoot: self.root).standardizedFileURL.path
        let view = viewport()
        let matching = objects.values.filter { object in
            guard object.type == .changes else { return false }
            let spec = ChangesSpec(object.props)
            return spec.head == nil && spec.ref == nil && spec.paths.isEmpty && spec.baseProp == base
                && spec.directory(boardRoot: self.root).standardizedFileURL.path == directory
        }
        func rank(_ object: CanvasObject) -> (Int, Double, ObjectID) {
            guard let view else { return (0, 0, object.id) }
            return (view.intersects(object.frame) ? 0 : 1, object.frame.centerDistance(to: view), object.id)
        }
        return matching.min { rank($0) < rank($1) }?.id
    }
}

extension Frame {
    /// How far this frame's center is from `other`'s.
    func centerDistance(to other: Frame) -> Double {
        hypot(x + w / 2 - (other.x + other.w / 2), y + h / 2 - (other.y + other.h / 2))
    }
}
