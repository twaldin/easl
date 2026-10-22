import AppKit

@testable import CanvasApp

@main
@MainActor
private enum ApplicationIcon {
    private static let points = NSSize(width: 16, height: 16)

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    private static func bitmap(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        rep.size = points
        return rep
    }

    private static func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.imageInterpolation = .none
        body()
    }

    private static func icon(_ one: NSColor, _ two: NSColor) -> NSImage {
        let image = NSImage(size: points)
        for (pixels, color) in [(16, one), (32, two)] {
            let rep = bitmap(pixels: pixels)
            draw(into: rep) {
                color.setFill()
                NSRect(origin: .zero, size: points).fill()
            }
            image.addRepresentation(rep)
        }
        return image
    }

    private static func pixels(_ image: NSImage, scale: Int) -> [UInt8] {
        let rep = bitmap(pixels: 16 * scale)
        draw(into: rep) {
            image.draw(in: NSRect(origin: .zero, size: points), from: .zero, operation: .copy, fraction: 1)
        }
        return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    private static func check(_ image: NSImage, one: NSColor, two: NSColor, stage: String) {
        for (scale, color) in [(1, one), (2, two)] {
            let actual = pixels(image, scale: scale)
            let expected = pixels(icon(color, color), scale: scale)
            require(actual == expected, "\(stage) lost the \(scale)x icon artwork")
        }
    }

    static func main() {
        let app = CanvasApplication.shared
        require(app is CanvasApplication, "native icon test needs CanvasApplication")
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        let original = pixels(app.applicationIconImage, scale: 1)
        defer { app.applicationIconImage = nil }

        app.applicationIconImage = icon(.red, .blue)
        check(app.applicationIconImage, one: .red, two: .blue, stage: "initial icon")
        app.applicationIconImage = icon(.green, .yellow)
        check(app.applicationIconImage, one: .green, two: .yellow, stage: "replacement icon")
        app.applicationIconImage = nil
        require(pixels(app.applicationIconImage, scale: 1) == original, "reset kept the custom icon instead of the bundle icon")
        print("APPLICATION_ICON_COMPLETE")
    }
}
