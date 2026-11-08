import AppKit
import WebKit
import ImageIO
import CanvasCore
@testable import CanvasApp

@MainActor
private enum BrowserCapture {
    struct Failure: Error { let message: String }
    static func need(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    @MainActor final class Busy {
        var turns = RunLoopTurns(at: ProcessInfo.processInfo.systemUptime, reset: ProcessInfo.processInfo.systemUptime)
        var maximum = 0.0
        var observers: [CFRunLoopObserver] = []
        init() {
            for (activities, order, sleeping) in [
                (CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeTimers.rawValue, CFIndex.min, false),
                (CFRunLoopActivity.beforeWaiting.rawValue, CFIndex.max, true)
            ] {
                let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, order) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let ms = self.turns.activity(sleeping: sleeping, at: ProcessInfo.processInfo.systemUptime).turn {
                            self.maximum = max(self.maximum, ms)
                        }
                    }
                }!
                observers.append(observer)
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
        }
        func stop() {
            for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }
    }

    static func main() {
        let app = CanvasApplication.shared
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let width = Double(arguments[2])!, height = Double(arguments[3])!
        let count = Int(arguments[4])!, format = SurfaceFormat(rawValue: arguments[5])!
        let limit = Double(arguments[6])!
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!)
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let directory = home.appendingPathComponent("board")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = BoardRegistry(store: BoardStore(directory: home.appendingPathComponent("boards")))
        let board = try await registry.open(root: directory)
        let canvas = CanvasView(board: board, viewport: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 100, height: height + 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        window.orderFrontRegardless()
        canvas.show(Viewport(rect: Frame(x: -20, y: -20, w: width + 100, h: height + 160), zoom: 1))
        let object = board.create(type: .browser, props: .object(["url": .string("about:blank")]),
                                  frame: Frame(x: 0, y: 0, w: width, h: height + TileFrameView.titleHeight + BrowserTile.chromeHeight))
        guard let tile = canvas.tiles[object.id]?.content as? BrowserTile else { throw Failure(message: "no browser tile") }
        await tile.markDriven()
        guard let web = tile.webView else { throw Failure(message: "no web view") }
        let page = """
        <!doctype html><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:rgb(240,20,20)}
        #pictures{position:absolute;top:15%;height:70%;width:100%;display:grid;grid-template-columns:repeat(12,1fr)}
        img{width:100%;height:100%;min-height:0;object-fit:fill}</style><div id=pictures></div><script>
        let c=document.createElement('canvas');c.width=512;c.height=512;
        let x=c.getContext('2d'),p=x.createImageData(512,512),s=12345;
        for(let i=0;i<p.data.length;i+=4){s=(Math.imul(s,1664525)+1013904223)>>>0;
        p.data[i]=s&255;p.data[i+1]=(s>>>8)&255;p.data[i+2]=(s>>>16)&255;p.data[i+3]=255}x.putImageData(p,0,0);
        let src=c.toDataURL('image/png');window.ready=false;
        Promise.all(Array.from({length:96},()=>{let i=new Image;i.src=src;document.querySelector('#pictures').append(i);return i.decode()})).then(()=>window.ready=true);
        window.paint=n=>{document.body.style.background=n%2?'rgb(20,20,240)':'rgb(240,20,20)';return n};
        </script>
        """
        web.loadHTMLString(page, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            let ready = try? await web.evaluateJavaScript("window.ready === true")
            if ready as? Bool == true { break }
            try need(ContinuousClock.now < deadline, "page images did not load")
            try await Task.sleep(for: .milliseconds(20))
        }
        try need(abs(web.bounds.width - width) < 1 && abs(web.bounds.height - height) < 1, "page viewport changed")
        let router = ApiRouter(registry: registry)
        router.surface = { request, connection in
            try await BrowserSurfaceHost.shared.handle(request, from: SocketPeer(connection: connection, registry: registry) { _, id in
                id == object.id ? tile : nil
            })
        }
        let socket = home.appendingPathComponent("capture.sock").path
        let server = SocketServer(path: socket) { request, connection in await router.handle(request, connection: connection) }
        try server.start()
        let client = EaslConnection(.unixSocket(socket))
        defer {
            client.close(); server.stop(); board.onEvent = nil; canvas.discard(); window.close()
        }
        let events = client.events()
        client.subscribe(board: board.id, events: ["surface.frame"])
        while client.state != .online {
            try need(ContinuousClock.now < deadline, "socket did not become online")
            try await Task.sleep(for: .milliseconds(20))
        }
        var iterator = events.makeAsyncIterator()
        let opened = try await client.request("surface.stream", .object([
            "id": .string(object.id), "scale": .number(2), "format": .string(format.rawValue)]))
        guard let stream = opened["stream"]?.string else { throw Failure(message: "no stream id") }
        let scale = opened["scale"]?.number ?? 0
        try need(abs(scale - min(2, sqrt(4_000_000 / (width * height)))) < 0.000001, "stream did not use fitted 4MP scale")
        Metrics.shared.monitorMainThread()
        Metrics.shared.reset()
        let busy = Busy()
        var records: [JSONValue] = []
        var lastSeq = 0
        var receivedCount = 0
        _ = try await client.request("surface.ack", .object(["stream": .string(stream), "frame": .number(0)]))
        for phase in 0..<count {
            _ = try await client.request("surface.input", .object([
                "stream": .string(stream), "events": .array([.object([
                    "seq": .number(Double(phase + 1)), "kind": .string("focus"), "on": .bool(true)
                ])])
            ]))
            let frameDeadline = ContinuousClock.now + .seconds(30)
            let frameTimeout = Task {
                try? await Task.sleep(until: frameDeadline, clock: .continuous)
                if !Task.isCancelled { client.close() }
            }
            defer { frameTimeout.cancel() }
            var matched = false
            while !matched {
                guard let event = await iterator.next() else {
                    throw Failure(message: "no fresh frame for phase \(phase)")
                }
                guard event.name == "surface.frame" else { continue }
                let frame = event.data
                guard let seq = frame["seq"]?.int, let w = frame["width"]?.int, let h = frame["height"]?.int,
                      let encoded = frame["data"]?.string else {
                    throw Failure(message: "malformed frame")
                }
                try need(seq > lastSeq && frame["stream"]?.string == stream, "stale or foreign frame")
                lastSeq = seq
                receivedCount += 1
                try need(frame["format"]?.string == format.rawValue && w > 0 && h > 0 && w * h <= 4_000_000,
                         "invalid format or pixel budget")
                try need(frame["size"]?["w"]?.number == width && frame["size"]?["h"]?.number == height
                         && frame["scale"]?.number == scale, "frame changed viewport or scale")
                matched = try await Task.detached {
                    guard let data = Data(base64Encoded: encoded) else { throw Failure(message: "invalid base64 image") }
                    let image = try SurfaceImageDecoder.decode(data, format: format, width: w, height: h,
                        canvas: CGSize(width: w, height: h), video: SurfaceVideoDecoder(), refinement: false)
                    var rgba = Data(count: w * h * 4)
                    let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
                        guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
                    }
                    guard ok else { throw Failure(message: "cannot decode RGBA") }
                    let pixelsMatch = rgba.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        var matching = 0, varied = 0
                        for i in stride(from: 0, to: bytes.count, by: 4) {
                            let r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2])
                            if g < 60 && (phase % 2 == 0 ? r > 200 && b < 60 : b > 200 && r < 60) { matching += 1 }
                            if g > 70 && g < 190 { varied += 1 }
                        }
                        return matching > w * h / 10 && varied > w * h / 10
                    }
                    let matches = pixelsMatch && (frame["input"]?.int ?? 0) >= phase + 1
                    if matches {
                        try data.write(to: output.appendingPathComponent("phase-\(phase).\(format.rawValue)"))
                        try rgba.write(to: output.appendingPathComponent("phase-\(phase).rgba"))
                    }
                    return matches
                }.value
                if matched {
                    records.append(.object(["phase": .number(Double(phase)), "seq": .number(Double(seq)),
                        "width": .number(Double(w)), "height": .number(Double(h)), "input": frame["input"] ?? .null]))
                    if phase + 1 < count { _ = try await web.evaluateJavaScript("window.paint(\(phase + 1))") }
                }
                if !matched || phase + 1 < count {
                    _ = try await client.request("surface.ack", .object(["stream": .string(stream), "frame": .number(Double(seq))]))
                }
                try need(ContinuousClock.now < frameDeadline, "phase \(phase) exceeded its frame deadline")
            }
        }
        _ = try await client.request("surface.stop", .object(["stream": .string(stream)]))
        await MainTurns.next()
        busy.stop()
        let colorSpace = window.screen?.colorSpace?.localizedName
        let result: JSONValue = .object(["frames": .array(records), "receivedFrames": .number(Double(receivedCount)),
            "backingScale": .number(window.backingScaleFactor), "colorSpace": colorSpace.map(JSONValue.string) ?? .null,
            "viewport": SurfaceEvent.size(web.bounds.size), "scale": .number(scale), "format": .string(format.rawValue),
            "metrics": Metrics.shared.snapshot(), "maxMainMs": .number(busy.maximum),
            "maxMainLimitMs": limit > 0 ? .number(limit) : .null, "assertsTiming": .bool(limit > 0)])
        let json = try JSONEncoder().encode(result)
        try json.write(to: output.appendingPathComponent("results.json"))
        print(String(decoding: json, as: UTF8.self))
        if limit > 0 { try need(busy.maximum <= limit, "main busy stretch exceeded supplied threshold") }
    }
}

@MainActor
@_cdecl("EaslBrowserCaptureRegressionMain")
func easlBrowserCaptureRegressionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    BrowserCapture.main()
    return 0
}
