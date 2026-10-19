import AppKit
import CanvasCore

@testable import CanvasApp

@main
@MainActor
private enum SceneStacking {
    private static var failures = 0
    private static let region = Frame(x: 0, y: 0, w: 320, h: 280)
    private static let sample = NSPoint(x: 160, y: 140)

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            failures += 1
        }
    }

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: home).appendingPathComponent("board", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFixture(to: root.appendingPathComponent("cyan.png"))
        let board = Board(id: "scene-stacking-regression", root: root)
        let canvas = CanvasView(board: board)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let container = window.contentView!
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        let drawing = ShapeLayer.install(on: canvas, toolbarIn: container)
        board.onEvent = { event in
            canvas.apply(event)
            drawing.apply(event)
        }
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }
        let image = board.create(type: .image, props: .object(["path": .string("cyan.png")]),
                                 frame: Frame(x: 40, y: 40, w: 240, h: 200))
        let shape = board.create(type: .shape,
                                 props: ShapeSpec(kind: .rect, color: "#ff0000", fill: .solid).props,
                                 frame: Frame(x: 80, y: 90, w: 160, h: 100))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        canvas.contentView.scroll(to: CanvasView.docRect(region).origin)
        canvas.reflectScrolledClipView(canvas.contentView)
        window.displayIfNeeded()

        canvas.setSelection([shape.id])
        canvas.bringToFront()
        canvas.setSelection([])
        try await check(canvas, image: image.id, shape: shape.id, shapeInFront: true, label: "shape bringToFront")

        canvas.setSelection([shape.id])
        canvas.sendToBack()
        canvas.setSelection([])
        try await check(canvas, image: image.id, shape: shape.id, shapeInFront: false, label: "shape sendToBack")

        canvas.setSelection([image.id])
        canvas.sendToBack()
        canvas.setSelection([])
        try await check(canvas, image: image.id, shape: shape.id, shapeInFront: true, label: "tile sendToBack reverse control")

        canvas.setSelection([image.id])
        canvas.bringToFront()
        canvas.setSelection([])
        try await check(canvas, image: image.id, shape: shape.id, shapeInFront: false, label: "tile bringToFront reverse control")

        _ = try board.update(shape.id, props: .object(["fill": .null]))
        canvas.setSelection([shape.id])
        canvas.bringToFront()
        canvas.setSelection([])
        let unfilled = try await render(canvas)
        require(unfilled.objects.map(\.id) == [image.id, shape.id], "unfilled front shape must remain last in rendered bottom-to-top order")
        requireCyan(try pixel(unfilled), "unfilled shape interior must show the cyan tile")
        checkHit(canvas, image: image.id, shape: nil, label: "unfilled shape interior pass-through")
        let edge = NSPoint(x: 80, y: 140)
        require(canvas.shape(atWindowPoint: windowPoint(edge, in: canvas)) == shape.id,
                "unfilled shape stroke must still hit the front shape")
        try board.delete(shape.id)
        let drawings: [(name: String, type: ObjectType, props: JSONValue)] = [
            ("arrow", .arrow, ArrowSpec(from: .point(CGPoint(x: 80, y: 140)), to: .point(CGPoint(x: 240, y: 140)), color: "#ff0000").props),
            ("ink", .shape, ShapeSpec(kind: .ink, points: [InkPoint(x: 0, y: 0), InkPoint(x: 80, y: 0), InkPoint(x: 160, y: 0)], color: "#ff0000").props),
        ]
        for fixture in drawings {
            let drawing = board.create(type: fixture.type, props: fixture.props, frame: Frame(x: 80, y: 140, w: 160, h: 1))
            canvas.setSelection([drawing.id])
            canvas.bringToFront()
            canvas.setSelection([])
            let front = try await render(canvas)
            require(front.objects.map(\.id) == [image.id, drawing.id], "\(fixture.name) must render above the tile")
            require(canvas.visibleObjects(pixelsPerPoint: 1).map(\.id) == [image.id, drawing.id], "\(fixture.name) front snapshot order must match")
            checkHit(canvas, image: image.id, shape: drawing.id, label: "\(fixture.name) front")
            canvas.setSelection([drawing.id])
            canvas.sendToBack()
            canvas.setSelection([])
            let back = try await render(canvas)
            require(back.objects.map(\.id) == [drawing.id, image.id], "\(fixture.name) must render below the tile")
            require(canvas.visibleObjects(pixelsPerPoint: 1).map(\.id) == [drawing.id, image.id], "\(fixture.name) back snapshot order must match")
            requireCyan(try pixel(back), "\(fixture.name) must not cover the foreground tile")
            checkHit(canvas, image: image.id, shape: nil, label: "\(fixture.name) back")
            try board.delete(drawing.id)
        }

        if failures > 0 { exit(1) }
        print("PASS mixed shape/tile render pixels, bottom-to-top order, native hit testing, reverse stacking commands, and unfilled interior pass-through")
        print("PASS snapshot stacking metadata and arrow/ink front/back transitions")
    }

    private static func writeFixture(to url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 174,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("Cannot allocate cyan fixture")
        }
        guard let bytes = rep.bitmapData else { fatalError("Cannot access fixture pixels") }
        for y in 0..<174 {
            for x in 0..<240 {
                let offset = y * rep.bytesPerRow + x * 4
                bytes[offset] = 0
                bytes[offset + 1] = 255
                bytes[offset + 2] = 255
                bytes[offset + 3] = 255
            }
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode cyan fixture")
        }
        try data.write(to: url)
    }

    private static func render(_ canvas: CanvasView) async throws -> RenderOutput {
        try await canvas.render(RenderRequest(target: .rect(region), scale: 1, chrome: false), format: .png)
    }

    private static func pixel(_ output: RenderOutput) throws -> NSColor {
        guard let bitmap = NSBitmapImageRep(data: output.image),
              let color = bitmap.colorAt(x: Int(sample.x), y: Int(sample.y))?.usingColorSpace(.sRGB) else {
            throw NSError(domain: "SceneStacking", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot decode rendered sample pixel"])
        }
        return color
    }

    private static func requireCyan(_ color: NSColor, _ label: String) {
        require(color.redComponent < 0.05 && color.greenComponent > 0.95 && color.blueComponent > 0.95,
                "\(label), got \(color)")
    }

    private static func check(_ canvas: CanvasView, image: ObjectID, shape: ObjectID,
                              shapeInFront: Bool, label: String) async throws {
        let output = try await render(canvas)
        let expected = shapeInFront ? [image, shape] : [shape, image]
        require(output.objects.map(\.id) == expected,
                "\(label) rendered bottom-to-top order must be \(expected), got \(output.objects.map(\.id))")
        require(canvas.visibleObjects(pixelsPerPoint: 1).map(\.id) == expected,
                "\(label) snapshot metadata must report the same bottom-to-top order")
        require(output.objects.first(where: { $0.id == image })?.state == .rendered,
                "\(label) must render the real image tile, not a placeholder")
        let color = try pixel(output)
        if shapeInFront {
            let otherChannels = max(color.greenComponent, color.blueComponent)
            require(color.redComponent > 2 * otherChannels,
                    "\(label) must show the red shape over the cyan tile, got \(color)")
        } else {
            requireCyan(color, "\(label) must show cyan, not an occluding red shape")
        }
        checkHit(canvas, image: image, shape: shapeInFront ? shape : nil, label: label)
    }

    private static func windowPoint(_ point: NSPoint, in canvas: CanvasView) -> NSPoint {
        canvas.document.convert(NSPoint(x: point.x + CanvasDocumentView.origin.x,
                                       y: point.y + CanvasDocumentView.origin.y), to: nil)
    }

    private static func checkHit(_ canvas: CanvasView, image: ObjectID, shape: ObjectID?, label: String) {
        canvas.window?.displayIfNeeded()
        let point = windowPoint(sample, in: canvas)
        require(canvas.shape(atWindowPoint: point) == shape,
                "\(label) shape lookup must respect tile occlusion, expected \(String(describing: shape))")
        guard let tile = canvas.tiles[image], let parent = canvas.document.superview else {
            require(false, "\(label) must have a real image tile in an attached document")
            return
        }
        var hit = canvas.document.hitTest(parent.convert(point, from: nil))
        require(hit != nil, "\(label) native NSView hit testing must resolve an actual view")
        var hitTile = false
        while let view = hit {
            if view === tile { hitTile = true; break }
            hit = view.superview
        }
        require(hitTile == (shape == nil),
                "\(label) native NSView hit testing must \(shape == nil ? "resolve the tile" : "resolve the front shape, not the tile")")
    }
}
