import AppKit
import CanvasCore

@testable import CanvasApp

@main
@MainActor
private enum BrowserInitialAdmission {
    private static var failures = 0
    private static let initial = Viewport(
        rect: Frame(x: -5045.000000345375, y: -2260.000000355707,
                    w: 10089.9999999633, h: 4849.999999982363), zoom: 0.1)

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            failures += 1
        }
    }

    private static func calls(_ kind: String) -> Int {
        Metrics.shared.snapshot()["counters"]?["card.call.\(kind)"]?["total"]?["n"]?.int ?? 0
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
        try await exercise(root: root, remote: nil, kind: "BrowserTile")
        let host = RemoteHost(name: "admission-regression", sshTarget: "admission-regression.invalid",
                              socketPath: root.appendingPathComponent("absent.sock").path,
                              tmpdir: root.path, easlBin: "easl")
        let absent = EaslConnection(.unixSocket(host.socketPath))
        let mirror = BoardMirror(hostName: host.name, board: "admission-remote",
                                 connection: absent, diagrams: EaslConnection(.unixSocket(host.socketPath)))
        try await exercise(root: root, remote: RemoteSource(host: host, mirror: mirror), kind: "RemoteBrowserTile")
        if failures > 0 { exit(1) }
        print("PASS initial local and remote browser preview admission, 600-point margin, and driven page preservation")
    }

    private static func exercise(root: URL, remote: RemoteSource?, kind: String) async throws {
        let board = Board(id: "admission-\(kind)", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: remote)
        canvas.hasHorizontalScroller = false
        canvas.hasVerticalScroller = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1009, height: 485),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }
        window.orderFrontRegardless()
        canvas.show(initial)
        try await Task.sleep(for: .milliseconds(250))
        require(board.objects.isEmpty, "\(kind) starts on an empty board")
        require(abs(canvas.viewport.zoom - 0.1) < 0.00001, "\(kind) starts at low zoom")
        require(abs(canvas.viewport.rect.x - initial.rect.x) < 1, "\(kind) starts at the reported viewport origin")
        require(abs(canvas.viewport.rect.y - initial.rect.y) < 1, "\(kind) starts at the reported viewport y")
        require(abs(canvas.viewport.rect.w - initial.rect.w) < 1 && abs(canvas.viewport.rect.h - initial.rect.h) < 1,
                "\(kind) starts with the reported viewport dimensions")
        Metrics.shared.reset()
        let object = board.create(type: .browser, props: .object(["url": .string("about:blank")]),
                                  frame: Frame(x: 6000, y: 30, w: 600, h: 300))
        guard let tile = canvas.tiles[object.id] else { fatalError("Browser creation produced no tile") }
        require(String(describing: type(of: tile.content)) == kind, "\(kind) exercises the requested browser variant")
        try await Task.sleep(for: .milliseconds(350))
        require(calls(kind) == 0, "\(kind) must not request its initial preview outside the 600-point margin")
        let browserRect = CanvasView.docRect(object.frame)
        require(!browserRect.intersects(canvas.documentVisibleRect.insetBy(dx: -600, dy: -600)),
                "\(kind) fixture must actually start beyond proximity")
        var near = canvas.viewport
        near.rect.x = 6000 - near.rect.w - 601
        canvas.show(near)
        try await Task.sleep(for: .milliseconds(200))
        require(calls(kind) == 0, "\(kind) must remain deferred 601 points beyond the viewport")
        near.rect.x += 2
        canvas.show(near)
        try await Task.sleep(for: .milliseconds(350))
        require(calls(kind) > 0, "\(kind) must draw its initial preview 599 points beyond the viewport")
        if let browser = tile.content as? BrowserTile {
            _ = try await browser.perform(.eval(script: "window.admissionToken = 'kept'; window.admissionToken"), driver: nil)
            let page = browser.webView
            canvas.show(initial)
            try await Task.sleep(for: .milliseconds(200))
            let result = try await browser.perform(.eval(script: "window.admissionToken"), driver: nil)
            require(result["value"]?.string == "kept", "An agent can drive a cold offscreen browser without losing page state")
            require(browser.webView === page, "Panning away must preserve the running driven browser session")
        }
    }
}
