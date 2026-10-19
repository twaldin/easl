import CoreGraphics
import Foundation

/// `props.zoom` of a tile: how big what it shows is, in place. Size is the frame, and only
/// resizing changes it; zoom is the stuff inside. The title bar stays at 1×; the body's content
/// lays out at the body's size divided by the zoom and draws that many times its size, so a
/// terminal at 150% shows bigger text in fewer columns and rows (its program gets the new grid),
/// a page at 67% lays out in a wider viewport, and code, notes and changes rewrap.
///
/// Image tiles don't zoom: the picture is already fitted to the frame (never past its pixels),
/// so zooming in place would either change nothing or crop it without a way to pan, and seeing
/// it bigger is making the tile bigger.
public enum ObjectZoom {
    public static let range: ClosedRange<Double> = 0.25...8
    /// Where Zoom Content In/Out and the title bar's − and + step: the levels browsers use.
    public static let levels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
    /// The Content Zoom menu's choices; its Actual Size item sets 1.
    public static let presets: [Double] = [0.5, 0.75, 1.25, 1.5, 2]

    /// The zoom Zoom Content In (`bigger`) or Out steps to from `zoom`: the next of `levels`
    /// past it; nil past the last level that way.
    public static func step(from zoom: Double, bigger: Bool) -> Double? {
        bigger ? levels.first { $0 > zoom + 0.001 } : levels.last { $0 < zoom - 0.001 }
    }

    /// `props.zoom` clamped to `range`; 1 when absent or not a positive number.
    public static func of(_ props: JSONValue) -> Double {
        guard let value = props["zoom"]?.number, value.isFinite, value > 0 else { return 1 }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    public static func applies(to type: ObjectType) -> Bool {
        RenderMath.isTile(type) && type != .image && type != .video
    }

    /// `zoom` as the title bar and the menus show it: "150%".
    public static func percent(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }

    /// `props.zoom` as written: 1 removes it.
    public static func prop(_ zoom: Double) -> JSONValue {
        abs(zoom - 1) < 0.001 ? .null : .number((zoom * 1000).rounded() / 1000)
    }

    /// The frame a tile at `frame` lays its content out in at `zoom`: same origin and title bar,
    /// the body divided by the zoom (the tile as it would be at 100%).
    public static func natural(_ frame: Frame, zoom: Double) -> Frame {
        let title = RenderMath.tileTitleHeight
        return Frame(x: frame.x, y: frame.y, w: frame.w / zoom, h: title + max(0, frame.h - title) / zoom)
    }

    /// The frame size that shows a tile's content laid out at `natural` (the whole tile at 100%,
    /// title bar included) at `zoom`: the body times the zoom under a 1× title bar.
    public static func zoomed(_ natural: CGSize, zoom: Double) -> CGSize {
        let title = CGFloat(RenderMath.tileTitleHeight), zoom = CGFloat(zoom)
        return CGSize(width: natural.width * zoom, height: title + max(0, natural.height - title) * zoom)
    }

    /// `rect` in a tile's content (its body's own points) in canvas coordinates, for a tile at
    /// `frame` with its content at `zoom`.
    public static func canvasRect(_ rect: CGRect, inBodyOf frame: Frame, zoom: Double) -> CGRect {
        let zoom = CGFloat(zoom)
        return CGRect(x: CGFloat(frame.x) + zoom * rect.minX, y: CGFloat(frame.y + RenderMath.tileTitleHeight) + zoom * rect.minY,
                      width: zoom * rect.width, height: zoom * rect.height)
    }

    /// Why `props` can't be set: `scale`, the prop zoom replaced (a tile's content zoom is
    /// `zoom`, a text shape's font `textSize`, and neither changes the other's meaning).
    public static func retiredProblem(_ props: JSONValue?) -> String? {
        guard props?["scale"] != nil else { return nil }
        return "props.scale is gone: a tile's content zoom is props.zoom (the frame keeps its size; 1.5 is 150%), a text shape's font size props.textSize"
    }

    /// `object` as saved before `zoom` (board format 2 and older): a tile's `scale` magnified its
    /// title bar and content inside the frame, so it becomes the content's `zoom` with the frame
    /// as it is (the tile keeps its size on screen and its content its size; only the title bar
    /// is 1× again); an image's is dropped (images don't zoom); a text shape's is its `textSize`.
    /// A `zoom` or `textSize` already there wins. Idempotent: nothing without `scale` changes.
    public static func migrated(_ object: CanvasObject) -> CanvasObject {
        guard var props = object.props.object, let scale = props.removeValue(forKey: "scale") else { return object }
        var object = object
        let key: String? = applies(to: object.type) ? "zoom" : object.type == .shape && props["kind"]?.string == ShapeSpec.Kind.text.rawValue ? "textSize" : nil
        if let key, props[key] == nil, let value = scale.number, value.isFinite, value > 0, abs(value - 1) >= 0.001 { props[key] = .number(value) }
        object.props = .object(props)
        return object
    }
}

extension CanvasObject {
    /// `props.zoom` for tiles that zoom; 1 for everything else.
    public var zoom: Double { ObjectZoom.applies(to: type) ? ObjectZoom.of(props) : 1 }

    /// The frame a tile's content lays out in (`ObjectZoom.natural`): the tile as it would be at 100%.
    public var naturalFrame: Frame { ObjectZoom.natural(frame, zoom: zoom) }
}
