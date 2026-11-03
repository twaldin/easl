import AppKit
import CanvasCore
import WebKit

@testable import CanvasApp

@MainActor
private enum BrowserColdResponse {
    private static var failures = 0

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func require(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            log("FAIL \(message)")
        }
    }

    private struct Reply {
        let code: String
        let value: JSONValue?
        let elapsed: Double
    }

    @MainActor
    private final class Command {
        let started = ProcessInfo.processInfo.systemUptime
        var reply: Reply?
        var onReply: ((Reply) -> Void)?

        init(_ browser: BrowserTile, _ command: CmuxBrowserCommand, name: String) {
            Task { @MainActor in
                let code: String
                let value: JSONValue?
                do {
                    value = try await browser.perform(command, driver: nil)
                    code = "ok"
                } catch let error as CmuxError {
                    code = error.code
                    value = .string(error.message)
                } catch {
                    code = "unexpected"
                    value = .string(String(describing: error))
                }
                let result = Reply(code: code, value: value,
                                   elapsed: ProcessInfo.processInfo.systemUptime - started)
                reply = result
                log("reply case=\(name) code=\(code) elapsed=\(result.elapsed) value=\(String(describing: value))")
                onReply?(result)
                onReply = nil
            }
        }

        func finish(within seconds: Double) async -> Reply? {
            if let reply { return reply }
            return await withCheckedContinuation { done in
                var finished = false
                let complete: @MainActor (Reply?) -> Void = { value in
                    guard !finished else { return }
                    finished = true
                    done.resume(returning: value)
                }
                onReply = { complete($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    MainActor.assumeIsolated { complete(nil) }
                }
            }
        }
    }

    private static func control(_ session: URLSession, origin: String, path: String) async throws {
        let (_, response) = try await session.data(from: URL(string: origin + path)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "BrowserColdResponse.fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fixture failed: \(path) \(response)"])
        }
    }

    private static func inspect(_ browser: BrowserTile, label: String) async -> String {
        guard let webView = browser.webView else {
            log("document \(label) webView=nil")
            return "no_webview"
        }
        log("native \(label) url=\(webView.url?.absoluteString ?? "nil") loading=\(webView.isLoading)")
        return await withCheckedContinuation { done in
            var finished = false
            let complete: @MainActor (String) -> Void = { value in
                guard !finished else { return }
                finished = true
                log("document \(label) \(value)")
                done.resume(returning: value)
            }
            Task { @MainActor in
                do {
                    let value = try await webView.callAsyncJavaScript("""
                        return JSON.stringify({url: location.href, readyState: document.readyState,
                          title: document.title, clicks: window.coldClicks ?? 0});
                        """, arguments: [:], in: nil, contentWorld: .page)
                    complete(value as? String ?? "unexpected_inspection_value")
                } catch {
                    complete("inspection_error=\(error)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { complete("inspection_safety_cap") }
            }
        }
    }

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"],
              let origin = ProcessInfo.processInfo.environment["BROWSER_COLD_RESPONSE_ORIGIN"] else {
            fatalError("run.py must supply a disposable home and held-response fixture")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        let controlSession = URLSession(configuration: configuration)
        defer { controlSession.invalidateAndCancel() }
        let root = URL(fileURLWithPath: home).appendingPathComponent("board")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "browser-cold-response", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        window.orderFront(nil)
        canvas.show(Viewport(rect: Frame(x: 0, y: 0, w: 900, h: 650), zoom: 1))
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }
        let cases: [(String, CmuxBrowserCommand)] = [
            ("click", .element(.click, selector: "#go")),
            ("eval", .eval(script: "({url: location.href, title: document.title, token: window.coldToken = 'kept'})")),
            ("snapshot", .snapshot(interactive: false, maxDepth: nil)),
            ("timeout", .wait(.selector("html"), timeoutMs: 200))
        ]
        for (name, command) in cases {
            let url = origin + "/page/" + name
            let object = board.create(type: .browser, props: .object(["url": .string(url)]),
                                      frame: Frame(x: 6000, y: 0, w: 850, h: 550))
            guard let browser = canvas.tiles[object.id]?.content as? BrowserTile else {
                fatalError("the canvas must create a real browser tile")
            }
            precondition(browser.webView == nil, "first command must create its own web view")
            log("start case=\(name) webView=nil url=\(url)")
            let pending = Command(browser, command, name: name)
            try await control(controlSession, origin: origin, path: "/arrived/" + name)
            log("held case=\(name) request_arrived=true")
            _ = await inspect(browser, label: "\(name)-held-start")
            if name == "timeout" {
                let reply = await pending.finish(within: 0.6)
                require(reply?.code == "timeout", "short wait must timeout while initial headers remain held, got \(reply?.code ?? "no_reply")")
                require(reply.map { $0.elapsed >= 0.15 && $0.elapsed < 0.45 } ?? false,
                        "short wait's 200ms bound includes initial admission")
            } else {
                try await Task.sleep(for: .milliseconds(900))
                require(pending.reply == nil, "\(name) answered before its initial response was released")
            }
            _ = await inspect(browser, label: "\(name)-held-end")
            log("release case=\(name) early_code=\(pending.reply?.code ?? "pending")")
            try await control(controlSession, origin: origin, path: "/release/" + name)
            let reply = await pending.finish(within: 31)
            require(reply != nil, "\(name) command must not hang")
            if name != "timeout" {
                require(reply?.code == "ok", "\(name) succeeds on its own document, got \(reply?.code ?? "no_reply")")
                require(reply.map { $0.elapsed < 30.5 } ?? false, "\(name) stays inside existing native command bound")
            }
            let settled = Command(browser, .wait(.loadState(.complete), timeoutMs: 2000), name: name + "-settle")
            let settledReply = await settled.finish(within: 2.5)
            require(settledReply?.code == "ok", "\(name) fixture document loads after release")
            let observed = await inspect(browser, label: "\(name)-released")
            if let data = observed.data(using: .utf8),
               let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                require(page["url"] as? String == url, "\(name) observes its own URL")
                require(page["title"] as? String == "Held " + name, "\(name) observes the committed fixture document")
                require(page["clicks"] as? Int == (name == "click" ? 1 : 0), "\(name) has exactly the requested page click count")
            } else {
                require(false, "\(name) must permit raw inspection of the released document")
            }
            if name == "eval" {
                require(reply?.value?["value"]?["url"]?.string == url &&
                        reply?.value?["value"]?["title"]?.string == "Held eval" &&
                        reply?.value?["value"]?["token"]?.string == "kept", "eval's first reply belongs to the committed document")
            }
            if name == "snapshot" {
                require(reply?.value?["page"]?["title"]?.string == "Held snapshot",
                        "snapshot's first reply is not the placeholder")
            }
            try board.delete(object.id)
        }
        if failures != 0 {
            log("FAIL held initial response failures=\(failures)")
            exit(1)
        }
        log("PASS cold click/eval/snapshot wait for their own document; short wait includes initial admission")
    }
}

@MainActor
@_cdecl("EaslBrowserColdResponseMain")
func easlBrowserColdResponseMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await BrowserColdResponse.main()
            app.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
    app.run()
    return 0
}
