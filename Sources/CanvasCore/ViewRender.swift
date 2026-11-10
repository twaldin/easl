import Foundation

/// `view.render` / `view.snapshot` types and the geometry that maps canvas space to image pixels.
public enum RenderState: String, Sendable {
    /// The content painted.
    case rendered
    /// Content not loaded in time or not renderable here; a stand-in was drawn.
    case placeholder
    /// Rendering errored.
    case failed
}

public enum ImageFormat: String, Sendable {
    case png, jpeg

    /// Format named by a file's extension; nil for anything we can't write.
    public init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        default: return nil
        }
    }
}

public enum RenderTarget: Equatable, Sendable {
    case objects([ObjectID])
    case rect(Frame)
}

/// What `view.render` leaves out of the picture (targets are always drawn): every object of
/// `types`, and the objects `ids` (a group's id takes its members, nested groups included, with it).
public struct RenderExclusion: Equatable, Sendable {
    public var types: Set<ObjectType>
    public var ids: Set<ObjectID>

    public init(types: Set<ObjectType> = [], ids: Set<ObjectID> = []) {
        self.types = types
        self.ids = ids
    }

    /// `exclude`'s entries, each an object type or the id of an object in `objects`; a group's id
    /// expands to its members. Throws `invalid_params` for anything else, naming it.
    public init(_ entries: [JSONValue], objects: [ObjectID: CanvasObject]) throws {
        var types: Set<ObjectType> = [], ids: Set<ObjectID> = []
        for entry in entries {
            if let type = entry.string.flatMap(ObjectType.init(rawValue:)) {
                types.insert(type)
            } else if let id = entry.string, let object = objects[id] {
                ids.insert(id)
                guard object.type == .group else { continue }
                var queue = [id]
                while let next = queue.popLast() {
                    for member in GroupSpec(objects[next]?.props ?? .null)?.members ?? [] where objects[member] != nil && ids.insert(member).inserted {
                        queue.append(member)
                    }
                }
            } else {
                let named = entry.string.map { "\"\($0)\"" } ?? "\(entry)"
                throw ApiRouter.Failure("invalid_params", "exclude takes object types or ids of objects on this board, not \(named)")
            }
        }
        self.init(types: types, ids: ids)
    }

    public func hides(_ object: CanvasObject) -> Bool {
        types.contains(object.type) || ids.contains(object.id)
    }
}

public struct RenderRequest: Sendable {
    public var target: RenderTarget
    /// Pixels per canvas point, as asked.
    public var scale: Double
    public var full: Bool
    public var exclude: RenderExclusion
    public var padding: Double
    public var timeout: Duration
    /// False for a picture that leaves the app (Export Selection as PNG, Copy as Image): drawn
    /// like View › Hide Board Chrome, without author marks, close buttons or the dot grid.
    /// `view.render` keeps them: agents see the board as the user does.
    public var chrome: Bool

    public init(target: RenderTarget, scale: Double = 1, full: Bool = false, exclude: RenderExclusion = RenderExclusion(), padding: Double = 0,
                timeout: Duration = .seconds(8), chrome: Bool = true) {
        self.target = target
        self.scale = scale
        self.full = full
        self.exclude = exclude
        self.padding = padding
        self.timeout = timeout
        self.chrome = chrome
    }
}

public struct RenderedObject: Equatable, Sendable {
    public var id: ObjectID
    public var type: ObjectType
    /// Image pixels, top-left origin.
    public var pixelRect: Frame
    public var state: RenderState
    public var reason: String?
    /// The content's own extent in canvas points (tiles): a scaled tile's layout extent times its scale.
    public var contentSize: CGSize?
    public var overflow: CGSize?

    public init(id: ObjectID, type: ObjectType, pixelRect: Frame, state: RenderState, reason: String? = nil, contentSize: CGSize? = nil, overflow: CGSize? = nil) {
        self.id = id
        self.type = type
        self.pixelRect = pixelRect
        self.state = state
        self.reason = reason
        self.contentSize = contentSize
        self.overflow = overflow
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "type": .string(type.rawValue), "pixelRect": RenderMath.json(pixelRect), "state": .string(state.rawValue)]
        if let reason { fields["reason"] = .string(reason) }
        if let contentSize { fields["contentSize"] = .object(["w": .number(contentSize.width.rounded()), "h": .number(contentSize.height.rounded())]) }
        if let overflow { fields["overflow"] = .object(["x": .number(overflow.width.rounded()), "y": .number(overflow.height.rounded())]) }
        return .object(fields)
    }
}

/// A rendered image and where everything landed in it.
public struct RenderOutput: Sendable {
    public var image: Data
    public var format: ImageFormat
    public var width: Int
    public var height: Int
    public var canvasRect: Frame
    public var scale: Double
    public var objects: [RenderedObject]

    public init(image: Data, format: ImageFormat, width: Int, height: Int, canvasRect: Frame, scale: Double, objects: [RenderedObject]) {
        self.image = image
        self.format = format
        self.width = width
        self.height = height
        self.canvasRect = canvasRect
        self.scale = scale
        self.objects = objects
    }
}

/// `view.get`: what the user is looking at.
public struct ViewState: Sendable {
    public var viewport: Viewport
    public var promptTarget: ObjectID?
    public var focused: ObjectID?
    public var selection: [ObjectID]
    public var enteredGroup: ObjectID?
    public var visible: Bool
    /// The window's effective appearance, `dark` or `light`: what tiles, pages, and renders draw in.
    public var appearance: String

    public init(viewport: Viewport, promptTarget: ObjectID?, focused: ObjectID?, selection: [ObjectID], enteredGroup: ObjectID?, visible: Bool, appearance: String) {
        self.viewport = viewport
        self.promptTarget = promptTarget
        self.focused = focused
        self.selection = selection
        self.enteredGroup = enteredGroup
        self.visible = visible
        self.appearance = appearance
    }
}

public enum RenderMath {
    /// Title bar at the top of every tile, inside its frame: a tile's `frame` is its whole drawn
    /// box, and its content (the body) is the frame below this.
    public static let tileTitleHeight: Double = 34
    /// Largest image `view.render` produces; bigger requests render at a lower scale.
    public static let pixelBudget: Double = 32_000_000
    /// Tallest a tile's full content is drawn, in points (a runaway page can't allocate gigabytes).
    public static let maxContentExtent: Double = 20_000

    /// A tile's content area in its content's own points: its frame below the title bar,
    /// divided by its `zoom` (the body the content lays out in).
    public static func body(of object: CanvasObject) -> CGSize {
        let frame = object.naturalFrame
        return CGSize(width: frame.w, height: max(0, frame.h - tileTitleHeight))
    }

    /// Below this, a tile's content is too small on screen to use: the tile is a card (one
    /// handle, tinted by its agent's state) and the canvas lets its live view go.
    public static let liveThreshold: Double = 0.3

    /// Whether content at `zoom` on a board at `magnification` is below `liveThreshold`: how big
    /// it shows is the board's magnification times the content's zoom, so a tile zoomed to 200%
    /// stays readable on a board zoomed out twice as far.
    public static func isZoomedOut(magnification: Double, zoom: Double) -> Bool {
        magnification * zoom < liveThreshold
    }

    public static func isZoomedOut(_ object: CanvasObject, magnification: Double) -> Bool {
        isZoomedOut(magnification: magnification, zoom: object.zoom)
    }

    public static func isTile(_ type: ObjectType) -> Bool {
        ![.shape, .arrow, .group].contains(type)
    }

    /// The background dot grid at `scale` screen points per canvas unit. Dots sit on multiples of
    /// `spacing` (40 · 2ⁿ units, the first at least 16 points apart on screen); the next finer
    /// level's dots (the midpoints) show at opacity `fade`, which rises from 0 to 1 as their own
    /// spacing grows from 8 to 16 points. So zooming never makes dots pop: at each doubling the
    /// finer dots are fully shown just as they become the coarse level.
    public static func gridLevel(scale: Double) -> (spacing: Double, fade: Double) {
        var spacing = 40.0
        while spacing * scale < 16 { spacing *= 2 }
        guard spacing > 40 else { return (spacing, 0) }
        let t = min(1, max(0, (spacing / 2 * scale - 8) / 8))
        return (spacing, t * t * (3 - 2 * t))
    }

    /// A tile's frame grown to show `content` (body coordinates) when drawing full content
    /// (never shrunk).
    public static func extended(_ frame: Frame, body: CGSize, content: CGSize) -> Frame {
        let w = min(max(Double(body.width), Double(content.width)), maxContentExtent)
        let h = min(max(Double(body.height), Double(content.height)), maxContentExtent)
        return Frame(x: frame.x, y: frame.y, w: w, h: frame.h - Double(body.height) + h)
    }

    /// Content beyond the frame, in points; nil when it fits (sub-point differences are layout noise).
    public static func overflow(content: CGSize, body: CGSize) -> CGSize? {
        let x = max(0, (content.width - body.width).rounded()), y = max(0, (content.height - body.height).rounded())
        return x >= 1 || y >= 1 ? CGSize(width: x, height: y) : nil
    }

    public static func union(_ frames: [Frame]) -> Frame? {
        guard let first = frames.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for frame in frames.dropFirst() {
            minX = min(minX, frame.x)
            minY = min(minY, frame.y)
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }
        return Frame(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// Canvas rect snapped out to whole points, so pixel rects land on whole pixels at integer scales.
    public static func snapped(_ rect: Frame, padding: Double = 0) -> Frame {
        let minX = (rect.x - padding).rounded(.down), minY = (rect.y - padding).rounded(.down)
        let maxX = (rect.maxX + padding).rounded(.up), maxY = (rect.maxY + padding).rounded(.up)
        return Frame(x: minX, y: minY, w: max(1, maxX - minX), h: max(1, maxY - minY))
    }

    /// The requested scale, lowered so the image stays within `pixelBudget`.
    public static func fittedScale(_ requested: Double, for rect: Frame) -> Double {
        let area = max(rect.w * rect.h, 1)
        let cap = (pixelBudget / area).squareRoot()
        return min(requested, cap)
    }

    /// Image size in pixels for a canvas rect at a scale.
    public static func pixelSize(_ rect: Frame, scale: Double) -> (width: Int, height: Int) {
        (max(1, Int((rect.w * scale).rounded())), max(1, Int((rect.h * scale).rounded())))
    }

    /// Where a canvas-space rect lands in the image: top-left origin, whole pixels (rounded out),
    /// clipped to the image.
    public static func pixelRect(_ frame: Frame, in canvasRect: Frame, scale: Double) -> Frame {
        let size = pixelSize(canvasRect, scale: scale)
        let minX = max(0, ((frame.x - canvasRect.x) * scale).rounded(.down))
        let minY = max(0, ((frame.y - canvasRect.y) * scale).rounded(.down))
        let maxX = min(Double(size.width), ((frame.maxX - canvasRect.x) * scale).rounded(.up))
        let maxY = min(Double(size.height), ((frame.maxY - canvasRect.y) * scale).rounded(.up))
        return Frame(x: minX, y: minY, w: max(0, maxX - minX), h: max(0, maxY - minY))
    }

    public static func json(_ frame: Frame) -> JSONValue {
        .object(["x": .number(frame.x), "y": .number(frame.y), "w": .number(frame.w), "h": .number(frame.h)])
    }
}
