import AppKit
import CanvasCore

/// One tile's content drawn offscreen for `view.render` (and zoomed-out cards).
struct TileRenderRequest {
    /// The body in points: the object's frame `w × h` (the title bar is the frame view's).
    var size: CGSize
    /// Pixels per point for the bitmap.
    var scale: CGFloat
    /// Draw the whole content (all rows, the full page height, long lines) instead of the frame's window.
    var full: Bool
    /// The window's effective appearance; dynamic colors resolve inside `performAsCurrentDrawingAppearance`.
    var appearance: NSAppearance
}

struct TileRender {
    typealias State = RenderState

    /// `size` in points with its top-left at the body's top-left: `request.size`, or
    /// `max(request.size, contentSize)` when full.
    var image: NSImage?
    /// The content's own extent in points at `request.size.width` (overflow = content − size);
    /// `request.size` when the content has no intrinsic extent.
    var contentSize: CGSize
    /// Never `.rendered` with a blank image: `.placeholder` when the model isn't loaded (the
    /// image, if any, is a stand-in), `.failed` on errors.
    var state: State
    /// Why a placeholder or failure.
    var reason: String?

    static func placeholder(_ request: TileRenderRequest, _ reason: String) -> TileRender {
        TileRender(image: nil, contentSize: request.size, state: .placeholder, reason: reason)
    }
}

extension TileRenderRequest {
    /// Draws into a bitmap of `size` points at the request's scale, flipped (top-left origin),
    /// with the request's appearance current.
    @MainActor
    func image(size: CGSize? = nil, _ draw: (CGRect) -> Void) -> NSImage? {
        let points = size ?? self.size
        let width = max(1, Int((points.width * scale).rounded())), height = max(1, Int((points.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = points
        let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        flipped.cgContext.translateBy(x: 0, y: CGFloat(height))
        flipped.cgContext.scaleBy(x: CGFloat(width) / points.width, y: -CGFloat(height) / points.height)
        appearance.performAsCurrentDrawingAppearance { draw(CGRect(origin: .zero, size: points)) }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: points)
        image.addRepresentation(rep)
        return image
    }

    /// `view`'s own drawing (AppKit views that draw themselves) at the request's scale, in the
    /// view's appearance.
    @MainActor
    func image(of view: NSView) -> NSImage? {
        let points = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int((points.width * scale).rounded())),
                                         pixelsHigh: max(1, Int((points.height * scale).rounded())), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = points
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: points)
        image.addRepresentation(rep)
        return image
    }
}

/// The Swift tile protocol from docs/contracts.md. Implemented by each tile's content view;
/// TileFrameView supplies the shared chrome (title bar, drag, resize, lifecycle badge).
@MainActor
protocol TileContent: NSView {
    /// Live = visible at readable zoom. Not live = release heavy resources and show the card.
    func setLive(_ live: Bool)
    /// The lowest zoom at which the tile shows its live view; below it, its card. Terminals go
    /// lower than the rest: Ghostty's layer just scales with the canvas, so zooming out a little
    /// never swaps a terminal for a redraw in another font, frozen until zooming back in.
    var liveZoom: CGFloat { get }
    /// Offscreen image of the content for `view.render`, independent of liveness, window, Space,
    /// and viewport. Draws from the tile's model, not by capturing live views (which may be
    /// detached, hidden, or drawn outside AppKit), and may await loading; the renderer applies
    /// a deadline and reports a tile that misses it as a placeholder.
    func render(_ request: TileRenderRequest) async -> TileRender
    /// Image for the zoomed-out card, delivered on the main actor. Called before the tile goes
    /// not-live; defaults to `render` at card resolution.
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void)
    /// Calls `ready` once the content, just made live, shows its live view as it will stay (a
    /// web page loaded, laid out, and painted); until then the frame keeps the card over it.
    /// Defaults to at once: views that draw synchronously are ready when shown.
    func whenLiveReady(_ ready: @escaping @MainActor () -> Void)
    /// While `view.snapshot` renders the window with `cacheDisplay`, cover content that renders
    /// outside AppKit's drawing (Metal, WebKit) with an image of it; `false` restores the live view.
    /// Synchronous, so whatever the cover needs from a process is fetched first (`prepareSnapshot`).
    func showSnapshot(_ show: Bool)
    /// Before `showSnapshot(true)`: fetch, off the main actor, what the cover is drawn from.
    func prepareSnapshot() async
    /// What a Hyper-click at `point` (in this view's coordinates) would mention. Called on every
    /// hover move, so it must be cheap; tiles whose content answers asynchronously (web views)
    /// return their latest cached answer and post `.tileMentionHoverChanged` when it changes.
    func mentionTarget(at point: NSPoint) -> MentionTarget?
    /// The mention for an actual Hyper-click, which may take a round trip (e.g. JavaScript).
    func resolveMention(at point: NSPoint) async -> MentionTarget?
    /// What Edit › Mention (⇧⌘M) stages from this tile (`KeyboardMention`): what the user is on
    /// in it. `hasKeyboard` false: the tile is only selected, so only an explicit sub-selection
    /// (selected text, a hunk) counts. Nil: the tile as a whole (or, only selected, the selection).
    func keyboardMention(hasKeyboard: Bool) async -> MentionTarget?
    /// Outline for a target in this view's coordinates, for the hover highlight.
    func outline(for target: MentionTarget) -> NSRect?
    /// A click on the target's tray chip: scroll the content so the mentioned part (a line or
    /// range, a note block) shows, for `outline(for:)` to find and the canvas to flash. Nothing
    /// for content that shows all of itself or can't find it.
    func scrollToMention(_ target: MentionTarget)
    /// The page elements under `rect` (this view's coordinates), for a mention of a shape drawn
    /// over the tile; nil for tiles without a page, and while the page isn't there to ask.
    func pageElements(in rect: NSRect) async -> PageElements?
    /// Height of the controls strip at the top of the content (a browser's address bar, a code
    /// tile's header), which attention bubbles keep off, like the title bar above it.
    var headerHeight: CGFloat { get }
    /// Relative luminance (0 black … 1 white) of what the content shows: a web page's
    /// background, an image, a terminal's theme. Drawings in the default ink over the tile are
    /// drawn to contrast with it (`InkContrast`). Nil when it is the app's own text background
    /// (code, notes, changes); post `.tileSurfaceChanged` when it changes.
    var surfaceLuminance: Double? { get }
    /// Whether clicking into the tile should take keyboard focus.
    var takesKeyboardFocus: Bool { get }
    /// Return on the selected tile while the canvas has the keyboard: the tile takes it
    /// (a terminal, a code tile's rows, a changes tile, a note's editor, a page). Esc in the
    /// tile hands it back (`CanvasView.leaveTile`). False when nothing in it types.
    func enterKeyboard() -> Bool
    /// What VoiceOver reads inside the tile while it is live, as a text area (a code tile's
    /// lines, a terminal's screen), built only when asked; nil when the tile's own views say it
    /// (notes, pages) or it has no text.
    var accessibleText: AccessibleTextElement? { get }
    /// Apply a new revision of the backing object.
    func update(_ object: CanvasObject)
}

extension Notification.Name {
    /// Posted (object: the tile content view) when an async hover answer arrives.
    static let tileMentionHoverChanged = Notification.Name("canvas.tileMentionHoverChanged")
}

extension TileContent {
    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        mentionTarget(at: point)
    }

    func keyboardMention(hasKeyboard: Bool) async -> MentionTarget? { nil }

    func pageElements(in rect: NSRect) async -> PageElements? { nil }

    func scrollToMention(_ target: MentionTarget) {}

    var headerHeight: CGFloat { 0 }

    var surfaceLuminance: Double? { nil }

    func showSnapshot(_ show: Bool) {}

    func prepareSnapshot() async {}

    var liveZoom: CGFloat { CanvasView.liveThreshold }

    func whenLiveReady(_ ready: @escaping @MainActor () -> Void) { ready() }

    var accessibleText: AccessibleTextElement? { nil }

    func enterKeyboard() -> Bool { false }

    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) {
        let request = TileRenderRequest(size: bounds.size, scale: TileFrameView.cardPixelsPerPoint, full: false,
                                        appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        Task { @MainActor in
            // Cards requested together (a batch of new tiles) render one per wake of the main thread.
            await MainTurns.next()
            let render = await self.render(request)
            deliver(render.state == .rendered ? render.image : nil)
        }
    }
}

extension NSImage {
    /// Draws right side up in flipped contexts (every render context is flipped).
    func drawUpright(in rect: NSRect, fraction: CGFloat = 1) {
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}
