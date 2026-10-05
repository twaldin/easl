import AppKit
import CanvasCore

/// The chrome text scale (View › Increase/Decrease/Reset Chrome Text Size): how big the app's own
/// text draws, which is the tray, tile title bars and what they say (title, author mark, a
/// terminal's command status, the content zoom control). Content zoom is separate, and a tile's
/// geometry, title bar height included, is the board's and never changes with it
/// (`ChromeTextScale`). One setting for the app, kept in the home's `ui-settings.json`.
@MainActor
enum ChromeText {
    /// Posted when the scale changes; chrome re-applies its fonts and lays out again.
    static let didChange = Notification.Name("net.waldin.easl.chromeTextScale")

    private static let store = ChromeTextScale.Store(url: AppPaths.uiSettings)
    private(set) static var scale = store.load()

    /// `base` points at the current scale.
    static func size(_ base: CGFloat) -> CGFloat { base * CGFloat(scale) }

    /// A length of chrome that holds text (a bar, a chip) at the current scale, whole points.
    static func scaled(_ points: CGFloat) -> CGFloat { size(points).rounded() }

    /// `base` with its point size scaled; `scale` overrides the current setting (1: drawn as
    /// `view.render` draws it, the same for every client).
    static func font(_ base: NSFont, scale: Double? = nil) -> NSFont {
        let factor = CGFloat(scale ?? self.scale)
        return factor == 1 ? base : NSFont(descriptor: base.fontDescriptor, size: base.pointSize * factor) ?? base
    }

    static func canStep(bigger: Bool) -> Bool { ChromeTextScale.step(from: scale, bigger: bigger) != nil }

    static func step(bigger: Bool) {
        guard let next = ChromeTextScale.step(from: scale, bigger: bigger) else { return }
        set(next)
    }

    static func reset() { set(ChromeTextScale.normal) }

    /// The percentage the View menu names, e.g. "115%".
    static var percent: String { "\(Int((scale * 100).rounded()))%" }

    private static func set(_ value: Double) {
        guard value != scale else { return }
        scale = value
        try? store.save(value)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
