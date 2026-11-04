import AppKit
import CanvasCore

@testable import CanvasApp

@MainActor
private enum BrowserColdCommands {
    private enum Kind: String, CaseIterable {
        case eval, click, wait, expression, snapshot, dblclick, hover, focus, check, uncheck
        case scrollIntoView, type, fill, press, scroll

        var count: Int {
            switch self {
            case .eval, .click, .wait: 20
            default: 1
            }
        }

        var command: CmuxBrowserCommand {
            switch self {
            case .eval: .eval(script: "window.coldToken = 'kept'; ({title: document.title, token: window.coldToken})")
            case .click: .element(.click, selector: "#go")
            case .wait: .wait(.selector("html"), timeoutMs: 2000)
            case .expression: .eval(script: "({title: document.title, token: window.coldToken = 'kept'})")
            case .snapshot: .snapshot(interactive: false, maxDepth: nil)
            case .dblclick: .element(.dblclick, selector: "#go")
            case .hover: .element(.hover, selector: "#go")
            case .focus: .element(.focus, selector: "#field")
            case .check: .element(.check, selector: "#check")
            case .uncheck: .element(.uncheck, selector: "#check")
            case .scrollIntoView: .element(.scrollIntoView, selector: "#bottom")
            case .type: .type(selector: "#field", text: "a")
            case .fill: .fill(selector: "#field", text: "filled")
            case .press: .press(key: "a")
            case .scroll: .scroll(dx: 0, dy: 100)
            }
        }
    }

    private struct Reply {
        let code: String
        let value: JSONValue?
        let message: String?
        let startedUptime: Double
        let endedUptime: Double
    }

    private struct Record: Encodable {
        let kind: String
        let trial: Int
        let code: String
        let result: JSONValue?
        let message: String?
        let startedUptime: Double
        let endedUptime: Double
        let latencyMs: Double
        let initialLoading: Bool
        let settledCode: String
        let observed: JSONValue
        let passed: Bool
    }

    private static let observation = """
        ({title: document.title, token: window.coldToken ?? null,
          clicks: window.coldClicks ?? 0, doubled: window.coldDouble ?? false,
          hovered: document.querySelector('#go')?.dataset.hovered === 'yes',
          active: document.activeElement?.id, field: document.querySelector('#field')?.value,
          checked: document.querySelector('#check')?.checked,
          key: document.documentElement.dataset.key ?? null, scroll: scrollY,
          bottomVisible: (() => { const r = document.querySelector('#bottom')?.getBoundingClientRect();
            return !!r && r.top >= 0 && r.bottom <= innerHeight; })()})
        """

    private static func perform(_ browser: BrowserTile, _ command: CmuxBrowserCommand) async -> Reply {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let value = try await browser.perform(command, driver: nil)
            return Reply(code: "ok", value: value, message: nil, startedUptime: started,
                         endedUptime: ProcessInfo.processInfo.systemUptime)
        } catch let error as CmuxError {
            return Reply(code: error.code, value: nil, message: error.message, startedUptime: started,
                         endedUptime: ProcessInfo.processInfo.systemUptime)
        } catch {
            return Reply(code: "unexpected", value: nil, message: String(describing: error), startedUptime: started,
                         endedUptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    private static func matches(_ kind: Kind, reply: Reply, observed: JSONValue, title: String, url: String) -> Bool {
        guard reply.code == "ok", observed["title"]?.string == title else { return false }
        switch kind {
        case .eval, .expression:
            return reply.value?["value"]?["title"]?.string == title &&
                reply.value?["value"]?["token"]?.string == "kept" && observed["token"]?.string == "kept"
        case .click: return observed["clicks"] == .number(1)
        case .wait: return reply.value?["url"]?.string == url
        case .snapshot: return reply.value?["page"]?["title"]?.string == title
        case .dblclick: return observed["clicks"] == .number(2) && observed["doubled"] == .bool(true)
        case .hover: return observed["hovered"] == .bool(true)
        case .focus: return observed["active"]?.string == "field"
        case .check: return observed["checked"] == .bool(true)
        case .uncheck: return observed["checked"] == .bool(false)
        case .scrollIntoView: return observed["bottomVisible"] == .bool(true)
        case .type: return observed["field"]?.string == "a"
        case .fill: return observed["field"]?.string == "filled"
        case .press: return observed["key"]?.string == "a"
        case .scroll: return observed["scroll"] == .number(100) && reply.value?["scroll_y"] == .number(100)
        }
    }

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"],
              let output = ProcessInfo.processInfo.environment["BROWSER_COLD_OUTPUT"] else {
            fatalError("run.py must supply a disposable home and result directory")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: home).appendingPathComponent("board")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "browser-cold", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: nil)
        canvas.hasHorizontalScroller = false
        canvas.hasVerticalScroller = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        window.orderFront(nil)
        canvas.show(Viewport(rect: Frame(x: 0, y: 0, w: 900, h: 650), zoom: 1))
        try await Task.sleep(for: .milliseconds(250))
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }
        var records: [Record] = []
        for kind in Kind.allCases {
            for trial in 1...kind.count {
                let blank = kind == .eval || kind == .wait
                let title = blank ? "" : "Cold \(kind.rawValue) \(trial)"
                let checked = kind == .uncheck ? "checked" : ""
                let html = """
                    <!doctype html><title>\(title)</title><style>html{scroll-behavior:auto}</style>
                    <script>document.addEventListener('keydown', e => { document.documentElement.dataset.key = e.key; });</script>
                    <button id="go" onclick="window.coldClicks=(window.coldClicks||0)+1"
                      ondblclick="window.coldDouble=true" onmouseover="this.dataset.hovered='yes'">Go</button>
                    <input id="field" value=""><input id="check" type="checkbox" \(checked)>
                    <div style="height:3000px"></div><div id="bottom">Bottom</div>
                    """
                let url = blank ? "about:blank" : "data:text/html;base64," + Data(html.utf8).base64EncodedString()
                let object = board.create(type: .browser, props: .object(["url": .string(url)]),
                                          frame: Frame(x: blank ? 0 : 6000, y: 0, w: 850, h: 550))
                guard let browser = canvas.tiles[object.id]?.content as? BrowserTile else { fatalError("cold browser missing") }
                if blank {
                    browser.setLive(false)
                    browser.setLive(true)
                    precondition(browser.webView?.isLoading == true, "the first command must overlap initial page admission")
                } else {
                    precondition(browser.webView == nil, "offscreen commands must create their own cold page")
                }
                let initialLoading = browser.webView?.isLoading == true
                let reply = await perform(browser, kind.command)
                let settled = await perform(browser, .wait(.loadState(.complete), timeoutMs: 2000))
                let script = blank ? "({title: document.title, token: window.coldToken ?? null, tag: document.documentElement.tagName.toLowerCase()})" : observation
                let observedReply = await perform(browser, .eval(script: script))
                let observed = observedReply.value?["value"] ?? .null
                let record = Record(kind: kind.rawValue, trial: trial, code: reply.code, result: reply.value,
                                    message: reply.message, startedUptime: reply.startedUptime, endedUptime: reply.endedUptime,
                                    latencyMs: (reply.endedUptime - reply.startedUptime) * 1000, initialLoading: initialLoading,
                                    settledCode: settled.code, observed: observed,
                                    passed: settled.code == "ok" && reply.endedUptime - reply.startedUptime < 3 &&
                                        matches(kind, reply: reply, observed: observed, title: title, url: url))
                records.append(record)
                FileHandle.standardOutput.write(try JSONEncoder().encode(record))
                FileHandle.standardOutput.write(Data("\n".utf8))
                try JSONEncoder().encode(records).write(to: URL(fileURLWithPath: output).appendingPathComponent("results.json"), options: .atomic)
                try board.delete(object.id)
            }
        }
        for kind in Kind.allCases {
            let rows = records.filter { $0.kind == kind.rawValue }
            print("kind=\(kind.rawValue) trials=\(rows.count) passed=\(rows.filter(\.passed).count) js_error=\(rows.filter { $0.code == "js_error" }.count)")
        }
        if records.contains(where: { !$0.passed }) { exit(1) }
        print("PASS cold first-command results and effects without false navigation errors")
    }
}

@MainActor
@_cdecl("EaslBrowserColdCommandsMain")
func easlBrowserColdCommandsMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await BrowserColdCommands.main()
            app.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
    app.run()
    return 0
}
