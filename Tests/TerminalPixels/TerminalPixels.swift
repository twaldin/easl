import AppKit
import CanvasCore
import GhosttyTerminal

@testable import CanvasApp

@MainActor
private final class GridProbe: NSObject, TerminalSurfaceGridResizeDelegate, TerminalSurfaceLifecycleDelegate {
    let target: any TerminalSurfaceViewDelegate
    var grid: TerminalGridMetrics?

    init(_ target: any TerminalSurfaceViewDelegate) { self.target = target }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        if size.cellHeightPixels > 0 { grid = size }
        (target as? any TerminalSurfaceGridResizeDelegate)?.terminalDidResize(size)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        (target as? any TerminalSurfaceLifecycleDelegate)?.terminalDidAttachSurface(surface)
    }

    func terminalDidDetachSurface() {
        (target as? any TerminalSurfaceLifecycleDelegate)?.terminalDidDetachSurface()
    }
}

@main
@MainActor
private enum TerminalPixels {
    private static var failures = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            failures += 1
        }
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!)
        let board = Board(id: "pixel-regression", root: home)
        let object = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 198.625, y: 36.25, w: 560, h: 400))
        let tile = TerminalTile(object: object, board: board)
        let metrics = GridProbe(tile.terminal.delegate!)
        tile.terminal.delegate = metrics
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        tile.terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let frame = TileFrameView(object: object, content: tile, frame: object.frame.rect)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 1
        let document = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: 2000, height: 1600))
        scroll.documentView = document
        window.contentView!.addSubview(scroll)
        document.addSubview(frame)
        window.orderFrontRegardless()
        defer {
            tile.discard()
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        let originalSize = tile.terminal.frame.size
        let originalFrame = frame.frame
        frame.place(NSRect(x: originalFrame.minX, y: originalFrame.minY, width: 560.2, height: 400.2), zoom: 1)
        require(tile.terminal.frame.size == tile.bounds.size, "autoresizing rounded the terminal body size")
        frame.place(originalFrame, zoom: 1)
        for zoom in [CGFloat(1), 0.73, 0.5, 1] {
            scroll.magnification = zoom
            scroll.contentView.scroll(to: NSPoint(x: 93.375, y: 17.625))
            tile.alignToPixels()
            window.displayIfNeeded()
            let shown = tile.terminal.convert(NSPoint.zero, to: nil)
            let scale = window.backingScaleFactor
            print("zoom=\(zoom) tile=\(tile.convert(NSPoint.zero, to: nil)) terminal=\(tile.terminal.frame) shown=\(shown) layer=\(String(describing: tile.terminal.layer?.frame)) scale=\(scale)")
            require(abs(shown.x * scale - (shown.x * scale).rounded()) < 0.00001, "surface x is between window pixels")
            require(abs(shown.y * scale - (shown.y * scale).rounded()) < 0.00001, "surface y is between window pixels")
            require(frame.frame == originalFrame, "alignment changed the tile frame")
            require(tile.terminal.frame.size == originalSize, "alignment resized the terminal")
            let underline = tile.subviews.compactMap { $0 as? TerminalLinkUnderline }.first!
            require(underline.frame == tile.terminal.frame, "the underline does not follow the terminal")
        }
        guard let grid = metrics.grid else { fatalError("Ghostty did not report its grid") }
        require(grid.rows >= 12, "the test needs twelve terminal rows")
        session.receive("\u{1b}[2J\u{1b}[H" + (0..<Int(grid.rows)).map { "ROW_\($0)" }.joined(separator: "\r\n"))
        session.waitForPendingOutput()
        let style = TerminalConfig.shared.style(for: tile.effectiveAppearance)
        let cellHeight = CGFloat(grid.cellHeightPixels) / window.backingScaleFactor
        let terminalPoint = NSPoint(x: style.padding.width + 1, y: tile.terminal.bounds.height - style.padding.height - 9 * cellHeight + 0.1)
        tile.terminal.setFrameOrigin(NSPoint(x: 0.5, y: -0.5))
        let target = await tile.resolveMention(at: tile.convert(terminalPoint, from: tile.terminal))
        let expected = "  ROW_0\n  ROW_1\n  ROW_2\n  ROW_3\n  ROW_4\n  ROW_5\n  ROW_6\n  ROW_7\n> ROW_8\n  ROW_9\n  ROW_10\n  ROW_11"
        require(target == .terminal(object: object.id, text: expected, part: .rows), "a click just above row 9 mentioned the wrong rows: \(String(describing: target))")
        if failures > 0 { exit(1) }
        print("PASS flipped and magnified window geometry, unchanged tile frame and terminal view size, underline alignment, and row-boundary mention")
    }
}
