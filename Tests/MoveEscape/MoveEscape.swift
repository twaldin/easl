import AppKit
import CanvasCore

@testable import CanvasApp

@main
@MainActor
private enum MoveEscape {
    private struct Failure: Error { let message: String }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            throw Failure(message: message)
        }
    }

    private static func key(_ code: UInt16, _ characters: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)!
    }

    private static func post(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: false)
        while let queued = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02),
                                           inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"],
              let scenario = CommandLine.arguments.dropFirst().first else {
            fatalError("run.py must provide an isolated home and scenario")
        }
        let root = URL(fileURLWithPath: home).appendingPathComponent(scenario)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "move-escape-\(scenario)", root: root)
        let original = Frame(x: -420, y: 65, w: 500, h: 250)
        let object = board.create(type: .terminal, props: .object([:]), frame: original)
        let canvas = CanvasView(board: board, viewport: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = window.contentView!
        canvas.frame = container.bounds
        container.addSubview(canvas)
        let drawing = ShapeLayer.install(on: canvas, toolbarIn: container)
        board.onEvent = { event in canvas.apply(event); drawing.apply(event) }
        defer {
            board.onEvent = nil
            board.arrowPath = nil
            board.settleArrows = nil
            board.settledRouting = nil
            canvas.discard()
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        canvas.contentView.scroll(to: NSPoint(x: CanvasDocumentView.origin.x - 504.5,
                                              y: CanvasDocumentView.origin.y - 76))
        canvas.reflectScrolledClipView(canvas.contentView)
        window.displayIfNeeded()
        window.makeFirstResponder(canvas.document)
        post(key(46, "m", in: window))
        try require(drawing.tool == .move, "M with canvas focus must activate Move through application dispatch")
        try require(window.firstResponder === canvas.document, "Move must keep canvas keyboard focus")
        let revision = board.revision
        let tile = canvas.tiles[object.id]!
        let initialPreview = tile.frame

        let start = tile.content.convert(NSPoint(x: 50, y: 80), to: nil)
        func mouse(_ type: NSEvent.EventType, _ dx: CGFloat, _ dy: CGFloat) {
            let point = NSPoint(x: start.x + dx, y: start.y - dy)
            post(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        let held = scenario != "responder-idle"
        if held {
            mouse(.leftMouseDown, 0, 0)
            for step in 1...8 {
                mouse(.leftMouseDragged, CGFloat(step) * 50 / 8, CGFloat(step) * 30 / 8)
            }
            try require(tile.frame.origin == NSPoint(x: initialPreview.minX + 50, y: initialPreview.minY + 30),
                        "Held terminal-body drag must show the 50 by 30 preview before Escape")
            try require(board.objects[object.id]?.frame == original && board.revision == revision,
                        "A held drag must not write the board before release")
        }
        let escape = key(53, "\u{1b}", in: window)
        if scenario == "posted-held" {
            post(escape)
        } else {
            window.firstResponder?.keyDown(with: escape)
        }
        try require(drawing.tool == .select, "Escape must return Move to Select via \(scenario)")
        try require(tile.frame == initialPreview, "Escape must restore the visible original frame")
        if held {
            mouse(.leftMouseUp, 50, 30)
            try require(tile.frame == initialPreview, "Release after Escape must not resurrect the preview")
        }
        try require(board.objects[object.id]?.frame == original, "Escape and release must preserve the committed frame")
        try require(board.revision == revision, "Escape and release must leave the board revision unchanged")
        print("PASS \(scenario): Select, original preview and committed frame, unchanged revision")
    }
}

