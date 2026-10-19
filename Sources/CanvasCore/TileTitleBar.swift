import CoreGraphics

/// A tile's title bar, `RenderMath.tileTitleHeight` tall above its content: where its buttons
/// sit and what a press on it is. The bar is the tile's handle: a press anywhere on it but a
/// button, on its title, dot, author mark, command status or the gaps between them, at any
/// zoom, selects the tile, turns the keyboard to it (`KeyboardFocus.afterTitleBarPress`) and
/// starts a move. A press on a button does the button's work and turns to the tile as well, so
/// typing never stays behind in the tile that had the keyboard.
public enum TileTitleBar {
    public enum Part: Equatable, Sendable {
        /// Select, focus, drag.
        case handle
        case close
        /// The content zoom control (− / % / +).
        case zoomControl
        case drawingMachine
    }

    public static let height = CGFloat(RenderMath.tileTitleHeight)

    /// The close button of a bar `width` wide, at its trailing end.
    public static func closeFrame(width: CGFloat) -> CGRect {
        CGRect(x: width - 28, y: 3, width: 22, height: 20)
    }

    /// The content zoom control, `controlWidth` wide as it shows now, just before the close
    /// button; nil while it is hidden (0 wide).
    public static func zoomControlFrame(width: CGFloat, controlWidth: CGFloat) -> CGRect? {
        controlWidth > 0 ? CGRect(x: width - 30 - controlWidth, y: 4, width: controlWidth, height: 18) : nil
    }

    public static func machineControlFrame(width: CGFloat, zoomControlWidth: CGFloat, controlWidth: CGFloat) -> CGRect? {
        guard controlWidth > 0 else { return nil }
        let trailing = zoomControlWidth > 0 ? zoomControlWidth + 4 : 0
        return CGRect(x: width - 30 - trailing - controlWidth, y: 4, width: controlWidth, height: 18)
    }

    /// What a press at `point` (the bar's own points, top-left origin) is on a bar `width` wide
    /// whose zoom control is `zoomControlWidth` wide (0: hidden); nil below the bar.
    public static func part(at point: CGPoint, width: CGFloat, zoomControlWidth: CGFloat, machineControlWidth: CGFloat = 0) -> Part? {
        guard point.y >= 0, point.y < height, point.x >= 0, point.x < width else { return nil }
        if closeFrame(width: width).contains(point) { return .close }
        if zoomControlFrame(width: width, controlWidth: zoomControlWidth)?.contains(point) == true { return .zoomControl }
        if machineControlFrame(width: width, zoomControlWidth: zoomControlWidth, controlWidth: machineControlWidth)?.contains(point) == true { return .drawingMachine }
        return .handle
    }
}
