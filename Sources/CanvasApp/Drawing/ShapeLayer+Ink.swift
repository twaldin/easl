import AppKit
import CanvasCore

/// The default ink ("black") resolved against what it's drawn over (`InkContrast`): the tiles
/// under a drawing, each by what its content shows (`TileContent.surfaceLuminance`: a web page's
/// background, an image, a terminal's theme), else the canvas. The screen, Copy as Image, and
/// `view.render` resolve it the same way.
extension ShapeLayer {
    /// The ink for a drawing of the default color over `rect` (document coordinates);
    /// `excluded`: the tiles a render leaves out (`RenderExclusion`), which then aren't under it.
    func defaultInk(over rect: NSRect, below drawing: CanvasObject? = nil, excluding excluded: RenderExclusion = RenderExclusion()) -> InkContrast.Ink {
        let appearance = effectiveAppearance
        let canvasLuminance = Self.canvasLuminance(appearance)
        let tiles = canvas.tiles.values.filter { $0.frame.intersects(rect) }
        let surfaces = tiles.compactMap { tile -> (z: Double, id: ObjectID, surface: InkContrast.Surface)? in
            guard let object = canvas.board.objects[tile.objectID], !excluded.hides(object) else { return nil }
            if let drawing, (object.z, object.id) >= (drawing.z, drawing.id) { return nil }
            let luminance = tile.content.surfaceLuminance ?? DrawingStyle.luminance(.textBackgroundColor, in: appearance) ?? canvasLuminance
            return (tile.z, tile.objectID, InkContrast.Surface(rect: tile.frame, luminance: luminance))
        }
        return InkContrast.ink(for: rect, over: surfaces.sorted { ($0.z, $0.id) < ($1.z, $1.id) }.map(\.surface), canvas: canvasLuminance)
    }

    /// The ink an item draws in: its default ink resolved, or nil for an explicit color.
    func ink(for item: DrawnItem, excluding excluded: RenderExclusion = RenderExclusion()) -> InkContrast.Ink? {
        item.usesDefaultInk ? defaultInk(over: item.frame.isEmpty ? item.bounds : item.frame, below: item.object, excluding: excluded) : nil
    }

    /// A color being drawn with right now (a gesture, the text editor) over `rect`.
    func inkColor(_ name: String?, over rect: NSRect) -> NSColor {
        DrawingStyle.isDefaultInk(name) ? DrawingStyle.color(defaultInk(over: rect)) : DrawingStyle.color(name)
    }

    private static func canvasLuminance(_ appearance: NSAppearance) -> Double {
        DrawingStyle.luminance(.underPageBackgroundColor, in: appearance) ?? 0
    }

    /// Something under drawings changed how it looks (a page loaded, a tile moved): the
    /// default-ink drawings over `rect` redraw.
    func surfaceChanged(_ rect: NSRect) {
        for item in items.values where item.usesDefaultInk && item.bounds.intersects(rect) { invalidate(item) }
    }

    /// A tile appeared, moved, restacked, or went: what is under the drawings over it changed.
    func tileMoved(_ event: BoardEvent) {
        switch event {
        case .objectCreated(let object), .objectUpdated(let object):
            guard TileFactory.hasTile(object.type) else { return }
            let before = surfaceFrames.updateValue((object.frame, object.z), forKey: object.id)
            guard before?.frame != object.frame || before?.z != object.z else { return }
            surfaceChanged(Self.docRect(object.frame))
            if let before { surfaceChanged(Self.docRect(before.frame)) }
        case .objectDeleted(let id):
            if let before = surfaceFrames.removeValue(forKey: id) { surfaceChanged(Self.docRect(before.frame)) }
        default:
            break
        }
    }
}

extension Notification.Name {
    /// A tile's content changed how its surface looks to drawings over it
    /// (`TileContent.surfaceLuminance`); the object is the content view.
    static let tileSurfaceChanged = Notification.Name("canvas.tileSurfaceChanged")
}
