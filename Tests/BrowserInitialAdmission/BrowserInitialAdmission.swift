import AppKit
import WebKit
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

    static func main() {
        let app = CanvasApplication.shared
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    private static func run() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: home).appendingPathComponent("board", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("remote-wheel") {
            try await remoteWheel(root: root)
            return
        }
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
        Metrics.shared.reset()
        let object = board.create(type: .browser, props: .object(["url": .string("about:blank")]),
                                  frame: Frame(x: 6000, y: 30, w: 600, h: 300))
        guard let tile = canvas.tiles[object.id] else { fatalError("Browser creation produced no tile") }
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

    private struct WheelFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WheelFailure(description: message) }
    }

    private static func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(condition(), message)
    }

    private enum WheelHostMode: CaseIterable {
        case absent, noFeedback, current
    }

    private struct WheelPeer: SurfacePeer {
        let socket: SocketPeer
        let mode: WheelHostMode
        var owner: SurfaceOwner { socket.owner }
        var isOpen: Bool { socket.isOpen }
        func tile(_ id: ObjectID) throws -> (board: BoardID, tile: BrowserTile) { try socket.tile(id) }
        func hears(_ event: String, on board: BoardID) -> Bool {
            (event != "surface.scrollUnhandled" || mode == .current) && socket.hears(event, on: board)
        }
    }

    @MainActor
    private final class WheelFixture {
        struct Wheel {
            let stream: String
            let gesture: Int?
        }
        let mode: WheelHostMode
        let registry: BoardRegistry
        let board: Board
        let router: ApiRouter
        let hostCanvas: CanvasView
        let hostWindow: NSWindow
        let path: String
        var server: SocketServer!
        var mirror: BoardMirror?
        var controller: CanvasWindowController?
        var viewerWindow: CanvasWindow?
        var streams: [(id: String, connection: SocketServer.Connection)] = []
        var wheels: [Wheel] = []
        var errors: [String] = []
        var advertised: [Bool?] = []
        var acknowledgements = 0

        init(root: URL, mode: WheelHostMode) async throws {
            self.mode = mode
            let directory = root.appendingPathComponent("wheel-\(mode)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("s").path
            registry = BoardRegistry(store: BoardStore(directory: directory.appendingPathComponent("boards")))
            board = try await registry.open(root: directory)
            router = ApiRouter(registry: registry)
            hostCanvas = CanvasView(board: board, viewport: nil)
            hostWindow = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 900, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            hostWindow.isReleasedWhenClosed = false
            hostCanvas.frame = hostWindow.contentView!.bounds
            hostWindow.contentView!.addSubview(hostCanvas)
            board.onEvent = { [weak hostCanvas] in hostCanvas?.apply($0) }
            hostWindow.orderFrontRegardless()
            hostCanvas.show(Viewport(rect: Frame(x: -100, y: -100, w: 900, h: 700), zoom: 1))
            router.surface = { [weak self] request, connection in
                guard let self else { throw ApiRouter.Failure("unavailable", "fixture closed") }
                let socket = SocketPeer(connection: connection, registry: self.registry) { [weak self] _, id in
                    self?.hostCanvas.tiles[id]?.content as? BrowserTile
                }
                let result = try await BrowserSurfaceHost.shared.handle(request, from: WheelPeer(socket: socket, mode: self.mode))
                if case .stream = request {
                    try BrowserInitialAdmission.expect(result["scrollGestures"]?.bool == (self.mode == .current),
                               "host must advertise gestures only to a peer subscribed to feedback on its board")
                    guard let stream = result["stream"]?.string else {
                        throw WheelFailure(description: "real host returned no stream")
                    }
                    self.streams.append((stream, connection))
                    if self.mode == .absent, case .object(var fields) = result {
                        fields.removeValue(forKey: "scrollGestures")
                        self.advertised.append(nil)
                        return .object(fields)
                    }
                    self.advertised.append(result["scrollGestures"]?.bool)
                }
                return result
            }
            server = SocketServer(path: path) { [weak self] request, connection in
                await self?.handle(request, connection)
            }
            try server.start()
        }

        func handle(_ request: JSONValue, _ connection: SocketServer.Connection) async -> JSONValue? {
            let method = request["method"]?.string ?? ""
            let events = request["params"]?["events"]?.array ?? []
            if mode != .current, method == "surface.input",
               events.contains(where: { $0["gesture"] != nil }) {
                errors.append("legacy receiver rejected unknown gesture key")
                return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                "error": .object(["code": .string("invalid_params"),
                                                  "message": .string("unknown scroll key gesture")])])
            }
            let reply = await router.handle(request, connection: connection)
            if method.hasPrefix("surface."), reply?["ok"]?.bool == false {
                errors.append("\(method): \(String(describing: reply?["error"]))")
            }
            if reply?["ok"]?.bool == true {
                if method == "surface.ack" { acknowledgements += 1 }
                if method == "surface.input", let stream = request["params"]?["stream"]?.string {
                    for event in events where event["kind"]?.string == "scroll" {
                        wheels.append(Wheel(stream: stream, gesture: event["gesture"]?.int))
                    }
                }
            }
            return reply
        }

        func feedback(stream: String, gesture: Int) throws {
            guard let connection = streams.last?.connection else {
                throw WheelFailure(description: "no live viewer socket for feedback")
            }
            let line = try EventLine("surface.scrollUnhandled", board: board.id,
                                     SurfaceScrollUnhandled.data(stream: stream, gesture: gesture))
            try BrowserInitialAdmission.expect(connection.send(encoded: line.data), "feedback must cross the viewer's real unix socket")
        }

        func feedbackBarrier(in tile: RemoteBrowserTile) async throws {
            guard let stream = streams.last else { throw WheelFailure(description: "no current viewer stream") }
            let marker = "wheel-barrier-\(UUID().uuidString)"
            let line = try EventLine("surface.notice", board: board.id,
                                     SurfaceEvent.notice(stream: stream.id, kind: .download, name: marker, state: "finished"))
            try BrowserInitialAdmission.expect(stream.connection.send(encoded: line.data), "ordered feedback barrier must cross the viewer socket")
            try await BrowserInitialAdmission.until("viewer must consume the socket event following stale feedback") {
                tile.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(marker) }
            }
        }

        func close() {
            controller?.board.onEvent = nil
            controller?.discard()
            viewerWindow?.delegate = nil
            viewerWindow?.close()
            mirror?.close()
            board.onEvent = nil
            hostCanvas.discard()
            hostWindow.close()
            server.stop()
        }
    }

    private static func wheel(_ point: NSPoint, phase: Int64, in window: CanvasWindow) throws {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: phase == 4 ? 0 : -24, wheel2: 0, wheel3: 0),
              let field = CGEventField(rawValue: 99), let screen = NSScreen.screens.first else {
            throw WheelFailure(description: "native wheel construction requires a logged-in macOS screen")
        }
        cg.location = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        cg.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(field, value: phase)
        guard let event = NSEvent(cgEvent: cg) else { throw WheelFailure(description: "no native wheel event") }
        event.setValue(window, forKey: "_window")
        event.setValue(NSNumber(value: window.windowNumber), forKey: "_windowNumber")
        try expect(event.window === window && abs(event.locationInWindow.x - point.x) < 1
                   && abs(event.locationInWindow.y - point.y) < 1 && event.hasPreciseScrollingDeltas,
                   "native wheel must target the owned viewer window at its page")
        let expected: NSEvent.Phase = phase == 1 ? .began : phase == 4 ? .ended : .changed
        try expect(event.phase == expected, "native wheel phase must survive event construction")
        window.sendEvent(event)
    }

    private static func remoteWheel(root: URL) async throws {
        for mode in WheelHostMode.allCases {
            let fixture = try await WheelFixture(root: root, mode: mode)
            defer { fixture.close() }
            let page = root.appendingPathComponent("wheel-\(mode)/page.html")
            try """
            <!doctype html><meta charset="utf-8"><title>wheel-ready</title>
            <style>body{margin:0;height:20000px;background:linear-gradient(white,blue)}</style>
            <body>
            <script>
            let count = 0;
            window.scrollTo(0, 1000);
            document.title = 'wheel-ready-y-' + Math.round(scrollY);
            addEventListener('wheel', event => {
              event.preventDefault();
              window.scrollBy(0, event.deltaY);
              document.title = 'wheel-' + (++count) + '-y-' + Math.round(scrollY);
            }, {passive:false});
            </script>
            """.write(to: page, atomically: true, encoding: .utf8)
            let object = fixture.board.create(type: .browser, props: .object(["url": .string(page.absoluteString)]),
                                              frame: Frame(x: 30, y: 30, w: 600, h: 500))
            guard let hostTile = fixture.hostCanvas.tiles[object.id]?.content as? BrowserTile else {
                throw WheelFailure(description: "host must contain a real BrowserTile")
            }
            await hostTile.markDriven()
            try await until("host page must load its native wheel handler at scroll position 1000") {
                hostTile.webView?.isLoading == false && hostTile.webView?.title == "wheel-ready-y-1000"
            }
            let host = RemoteHost(name: "wheel-fixture", sshTarget: "wheel-fixture.invalid",
                                  socketPath: fixture.path, tmpdir: root.path, easlBin: "easl", server: .app)
            let mirror = BoardMirror(hostName: host.name, board: fixture.board.id,
                                     connection: EaslConnection(.unixSocket(fixture.path)),
                                     diagrams: EaslConnection(.unixSocket(fixture.path)))
            fixture.mirror = mirror
            let board = try await mirror.load()
            let window = CanvasWindow(contentRect: NSRect(x: 50, y: 50, width: 1000, height: 750),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            fixture.viewerWindow = window
            let controller = CanvasWindowController(window: window, board: board, registry: fixture.registry,
                                                    viewport: nil, composerState: ComposerState(),
                                                    remote: RemoteSource(host: host, mirror: mirror))
            fixture.controller = controller
            controller.isBoardOpen = true
            board.onEvent = { [weak controller] in controller?.apply($0) }
            window.orderFrontRegardless()
            window.layoutIfNeeded()
            let canvas = controller.canvas
            canvas.hasHorizontalScroller = false
            canvas.hasVerticalScroller = false
            canvas.show(Viewport(rect: Frame(x: -100, y: -100, w: 1000, h: 750), zoom: 1))
            guard let tile = canvas.tiles[object.id]?.content as? RemoteBrowserTile else {
                throw WheelFailure(description: "viewer must contain the actual RemoteBrowserTile")
            }
            try await until("viewer must open and acknowledge the real host stream") {
                tile.hasOpenStream && fixture.acknowledgements > 0
            }
            let point = tile.convert(NSPoint(x: 150, y: tile.headerHeight + 100), to: nil)
            let hit = window.contentView?.hitTest(window.contentView?.superview?.convert(point, from: nil) ?? point)
            try expect(hit === tile || hit?.isDescendant(of: tile) == true, "wheel must hit the remote page, not board chrome")
            canvas.setSelection([object.id], cause: .boardGesture)
            try expect(window.makeFirstResponder(canvas.document) && canvas.selection == [object.id],
                       "fixture must explicitly select the browser while the board owns keyboard input")
            let selection = canvas.selection
            let pose = canvas.viewport
            let responder = window.firstResponder
            try wheel(point, phase: 1, in: window)
            try await until("first native wheel must reach the real host without waiting for feedback") {
                !fixture.wheels.isEmpty && hostTile.webView?.title?.hasPrefix("wheel-1-y-") == true
            }
            try expect(hostTile.webView?.title != "wheel-1-y-1000", "usable legacy wheel must change the host page's scroll position")
            try expect(canvas.viewport == pose, "a page-consumed wheel must not pan the viewer board")
            if mode != .current {
                try expect(fixture.wheels.allSatisfy { $0.gesture == nil }, "legacy wheel batches must omit the unknown gesture field")
                try expect(mode == .absent ? fixture.advertised.last! == nil : fixture.advertised.last! == false,
                           "legacy negotiation must exercise both missing and false advertisements")
                try wheel(point, phase: 2, in: window)
                try await until("a legacy stream without feedback must keep accepting native wheel input") {
                    fixture.wheels.count >= 2 && hostTile.webView?.title?.hasPrefix("wheel-2-y-") == true
                }
                try await Task.sleep(for: .milliseconds(300))
                try expect(canvas.viewport == pose && tile.hasOpenStream,
                           "absent feedback must neither stall input nor trigger board fallback")
            } else {
                guard let first = fixture.wheels.first, let oldGesture = first.gesture else {
                    throw WheelFailure(description: "advertised host must receive a numbered page gesture")
                }
                try wheel(point, phase: 4, in: window)
                try wheel(point, phase: 1, in: window)
                try await until("a new native gesture must get a new number") {
                    fixture.wheels.last?.gesture != nil && fixture.wheels.last?.gesture != oldGesture
                }
                let current = fixture.wheels.last!
                try fixture.feedback(stream: first.stream, gesture: oldGesture)
                try await fixture.feedbackBarrier(in: tile)
                try expect(canvas.viewport == pose, "a stale gesture reply must not pan the viewer board")
                tile.setLive(false)
                tile.setLive(true)
                try await until("restarting the viewer must open a new real host stream") {
                    tile.hasOpenStream && fixture.streams.last?.id != current.stream
                }
                try wheel(point, phase: 4, in: window)
                try wheel(point, phase: 1, in: window)
                try await until("the new stream must accept a native numbered wheel") {
                    fixture.wheels.last?.stream == fixture.streams.last?.id && fixture.wheels.last?.gesture != nil
                }
                let fresh = fixture.wheels.last!
                try fixture.feedback(stream: current.stream, gesture: fresh.gesture!)
                try await fixture.feedbackBarrier(in: tile)
                try expect(canvas.viewport == pose, "a reply from the previous stream epoch must not pan the viewer board")
                try fixture.feedback(stream: fresh.stream, gesture: fresh.gesture!)
                try await until("matching current unhandled feedback must produce viewer board fallback") {
                    canvas.viewport != pose
                }
            }
            try expect(fixture.errors.isEmpty, "real surface transport must have no protocol errors: \(fixture.errors)")
            try expect(canvas.selection == selection && window.firstResponder === responder && canvas.focusedTile == nil,
                       "wheel negotiation and fallback must preserve selection and keyboard ownership")
            print("PASS remote-wheel \(mode): real host page input, negotiated wire contract, and viewer board ownership")
        }
    }
}
