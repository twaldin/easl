import AppKit
import CanvasCore
import WebKit

@testable import CanvasApp

@MainActor
private final class Probe: NSObject, WKScriptMessageHandler {
    var events: [String] = []
    var onEntered: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let event = message.body as? String {
            events.append(event)
            print("probe=\(event)")
            if event == "entered" { onEntered?() }
        }
    }
}

@MainActor
private enum BrowserWait {
    private static var failures = 0

    private static func require(_ value: Bool, _ message: String) {
        if !value {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            failures += 1
        }
    }

    private struct Reply {
        let code: String
        let elapsed: Duration
    }

    private static func bounded(_ browser: BrowserTile, command: CmuxBrowserCommand, timeout: Int) async -> Reply {
        let start = ContinuousClock.now
        return await withCheckedContinuation { done in
            var replied = false
            let finish: @MainActor (String) -> Void = { code in
                guard !replied else { return }
                replied = true
                done.resume(returning: Reply(code: code, elapsed: start.duration(to: .now)))
            }
            Task { @MainActor in
                do {
                    _ = try await browser.perform(command, driver: nil)
                    finish("success")
                } catch let error as CmuxError {
                    finish(error.code)
                } catch {
                    finish(String(describing: error))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeout) / 1000 + 0.5) {
                MainActor.assumeIsolated { finish("no_reply") }
            }
        }
    }

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"],
              let origin = ProcessInfo.processInfo.environment["BROWSER_WAIT_ORIGIN"] else {
            fatalError("run.py must supply a disposable home and local fixture origin")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let armer = URLSession(configuration: .ephemeral)
        defer { armer.invalidateAndCancel() }
        let root = URL(fileURLWithPath: home).appendingPathComponent("board")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "browser-wait", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        window.orderFront(nil)
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }

        for present in [true, false] {
            let name = present ? "present" : "absent"
            let object = board.create(type: .browser, props: .object(["url": .string(origin + "/" + name)]),
                                      frame: Frame(x: 0, y: 0, w: 850, h: 550))
            guard let browser = canvas.tiles[object.id]?.content as? BrowserTile else {
                fatalError("the canvas must create a real browser tile")
            }
            _ = try await browser.perform(.wait(.loadState(.complete), timeoutMs: 5000), driver: nil)
            let probe = Probe()
            probe.onEntered = {
                armer.dataTask(with: URL(string: origin + "/armed/" + name)!).resume()
            }
            let webView = browser.ensureWebView()
            webView.configuration.userContentController.add(probe, contentWorld: BrowserScripts.world, name: "waitProbe")
            _ = try await webView.callAsyncJavaScript("""
                const post = event => window.webkit.messageHandlers.waitProbe.postMessage(event);
                const waitFor = window.__canvasCmux.waitFor;
                window.__canvasCmux.waitFor = (selector, timeout) => {
                    post('entered');
                    return waitFor(selector, timeout).finally(() => post('settled'));
                };
                addEventListener('pagehide', () => post('pagehide'), { once: true });
                """, arguments: [:], in: nil, contentWorld: BrowserScripts.world)
            _ = try await browser.perform(.fill(selector: "#username", text: "dummy@example.invalid"), driver: nil)
            _ = try await browser.perform(.fill(selector: "#password", text: "dummy-only"), driver: nil)
            _ = try await browser.perform(.element(.click, selector: "#signin"), driver: nil)
            let reply = await bounded(browser, command: .wait(.selector("#authenticated"), timeoutMs: 2000), timeout: 2000)
            print("case=\(name) code=\(reply.code) elapsed=\(reply.elapsed) events=\(probe.events)")
            require(probe.events.contains("entered"), "\(name): the selector wait entered the old document")
            require(probe.events.contains("pagehide"), "\(name): navigation tore down the waiting document")
            require(reply.code == (present ? "success" : "timeout"), "\(name): wait answers with the destination condition or timeout, got \(reply.code)")
            require(reply.elapsed < .milliseconds(present ? 1500 : 2500), "\(name): wait meets its own deadline")
            if !present { require(reply.elapsed >= .milliseconds(1900), "a missing selector must not time out early") }
            let value = try await browser.perform(.eval(script: "({url: location.href, authenticated: !!document.querySelector('#authenticated')})"), driver: nil)
            require(value["value"]?["url"]?.string == origin + "/account/" + name, "the destination loaded")
            require(value["value"]?["authenticated"]?.bool == present, "the destination has the requested selector only in the positive case")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "waitProbe", contentWorld: BrowserScripts.world)
            try board.delete(object.id)
        }
        let object = board.create(type: .browser, props: .object(["url": .string(origin + "/account/present")]),
                                  frame: Frame(x: 0, y: 0, w: 850, h: 550))
        guard let browser = canvas.tiles[object.id]?.content as? BrowserTile else { fatalError("browser tile missing") }
        _ = try await browser.perform(.wait(.loadState(.complete), timeoutMs: 5000), driver: nil)
        for (name, command, expected) in [
            ("zero", CmuxBrowserCommand.wait(.selector("#authenticated"), timeoutMs: 0), "success"),
            ("invalid", .wait(.selector("["), timeoutMs: 2000), "invalid_params"),
            ("missing-url", .wait(.urlContains("never-matches"), timeoutMs: 200), "timeout")
        ] {
            let reply = await bounded(browser, command: command, timeout: 2000)
            print("case=\(name) code=\(reply.code) elapsed=\(reply.elapsed)")
            require(reply.code == expected, "\(name): expected \(expected), got \(reply.code)")
            require(reply.elapsed < .milliseconds(1500), "\(name): prompt answer")
        }
        for condition in [CmuxWaitCondition.urlContains("/account/present"), .loadState(.interactive), .loadState(.complete)] {
            _ = try await browser.perform(.navigate(url: origin + "/account/present"), driver: nil)
            let reply = await bounded(browser, command: .wait(condition, timeoutMs: 2000), timeout: 2000)
            print("case=navigation-\(condition) code=\(reply.code) elapsed=\(reply.elapsed)")
            require(reply.code == "success" && reply.elapsed < .milliseconds(1500), "URL and load waits find the destination")
        }
        let interrupted = await bounded(browser, command: .eval(script: "new Promise(() => { setTimeout(() => location.href = '/account/present', 20); })"), timeout: 2000)
        print("case=eval-navigation code=\(interrupted.code) elapsed=\(interrupted.elapsed)")
        require(interrupted.code == "js_error" && interrupted.elapsed < .milliseconds(1500), "navigation answers an abandoned eval without replaying it")
        _ = try await browser.perform(.wait(.loadState(.complete), timeoutMs: 5000), driver: nil)
        let unresolved = await bounded(browser, command: .eval(script: "window.browserWaitPromise = new Promise(() => {})"), timeout: 30000)
        print("case=eval-unresolved code=\(unresolved.code) elapsed=\(unresolved.elapsed)")
        require(unresolved.code == "timeout", "a never-resolving eval gets a native timeout")
        require(unresolved.elapsed >= .milliseconds(29900) && unresolved.elapsed < .milliseconds(30500), "the JavaScript deadline is bounded without an early timeout")
        let value = try await browser.perform(.eval(script: "window.browserWaitPromise = null; 42"), driver: nil)
        require(value["value"] == .number(42), "a later call gets its own result after an abandoned promise")
        try board.delete(object.id)
        if failures != 0 { exit(1) }
        print("PASS POST/303 selector wait survives navigation and times out when absent")
    }
}

@MainActor
@_cdecl("EaslBrowserWaitMain")
func easlBrowserWaitMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await BrowserWait.main()
            app.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
    app.run()
    return 0
}
