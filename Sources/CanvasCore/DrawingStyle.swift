import AppKit
import CoreText

/// Fonts and colors of the hand-drawn layer.
@MainActor
public enum DrawingStyle {
    /// Shantell Sans 1.011 (arrowtype/shantell-sans, the Google Fonts variable TTF), SIL OFL 1.1:
    /// resources/fonts/OFL.txt. Registered for this process only, at launch.
    private static var family: NSFontDescriptor?
    /// The bundled font file, relative to the app's asset root.
    public static let fontAsset = "fonts/ShantellSans-Variable.ttf"

    public static func registerFonts(_ url: URL) {
        guard family == nil else { return }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            NSLog("easl: cannot register \(url.path): \(String(describing: error?.takeRetainedValue()))")
        }
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        family = descriptors?.first.map { $0 as NSFontDescriptor }
    }

    public static func font(size: CGFloat) -> NSFont {
        family.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    static func fontSnapshot() throws -> Data? {
        try family.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    nonisolated public static let textPointSize: CGFloat = 20
    nonisolated public static let labelSize: CGFloat = 18
    nonisolated public static let arrowLabelSize: CGFloat = 15

    /// Named palette (ShapeProps.color). Unknown names fall back to `#rrggbb`, then the default ink.
    public static let palette: [(name: String, color: NSColor)] = [
        ("black", .labelColor), ("grey", .systemGray), ("blue", .systemBlue), ("green", .systemGreen),
        ("orange", .systemOrange), ("red", .systemRed), ("violet", .systemPurple),
    ]

    public static func color(_ name: String?) -> NSColor {
        name.flatMap(explicitColor) ?? .labelColor
    }

    /// A palette name's color or a `#rrggbb` (the `#` optional); nil for a name that is no color.
    private static func explicitColor(_ name: String) -> NSColor? {
        if let named = palette.first(where: { $0.name == name }) { return named.color }
        let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Whether `name` draws in the default ink ("black", no color, or a name that is no color),
    /// which is drawn dark or light by what lies under it (`InkContrast`) rather than following
    /// the window's appearance: "black" in dark mode would otherwise be white on a white page.
    public static func isDefaultInk(_ name: String?) -> Bool {
        guard let name, name != "black" else { return true }
        return explicitColor(name) == nil
    }

    /// The default ink as resolved against its surface.
    public static func color(_ ink: InkContrast.Ink) -> NSColor {
        ink == .dark ? darkInk : lightInk
    }
    private static let darkInk = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private static let lightInk = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)

    /// Relative luminance of a color as `appearance` draws it; nil when it has no RGB form.
    public static func luminance(_ color: NSColor, in appearance: NSAppearance) -> Double? {
        var result: Double?
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            result = InkContrast.luminance(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        }
        return result
    }

    public static func text(_ string: String, size: CGFloat, color: NSColor, alignment: NSTextAlignment = .left) -> NSAttributedString {
        text(string, font: font(size: size), color: color, alignment: alignment)
    }

    nonisolated static func text(_ string: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// Widest an arrow caption lays out before it wraps.
    nonisolated public static let arrowLabelWidth: CGFloat = 240

    /// An arrow's caption (its `label`, else its `relation` in the secondary color) and the size
    /// of the chip it sits on: what the drawing layer draws and `layout.check` places, both
    /// with `DrawingGeometry.labelRect`. Nil when the arrow has no caption.
    public static func arrowLabel(_ spec: ArrowSpec) -> (text: NSAttributedString, size: CGSize)? {
        guard let caption = spec.label ?? spec.relation, !caption.isEmpty else { return nil }
        let color = spec.label == nil ? NSColor.secondaryLabelColor : Self.color(spec.color)
        return arrowLabel(caption, font: font(size: arrowLabelSize), color: color)
    }

    nonisolated static func arrowLabel(_ caption: String, font: NSFont, color: NSColor = .labelColor) -> (text: NSAttributedString, size: CGSize)? {
        guard !caption.isEmpty else { return nil }
        let text = Self.text(caption, font: font, color: color, alignment: .center)
        let size = text.boundingRect(with: NSSize(width: arrowLabelWidth, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
        return (text, CGSize(width: ceil(size.width) + 8, height: ceil(size.height)))
    }
}
