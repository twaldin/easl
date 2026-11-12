import AppKit
import GhosttyTerminal

@MainActor
private final class FrameView: AppTerminalView {
    var deliveredFrames = 0
    override func surfaceDidDraw() { deliveredFrames += 1 }
}

@MainActor
private final class Mailbox: TerminalSurfaceTitleDelegate, TerminalSurfacePwdDelegate,
    TerminalSurfaceBellDelegate, TerminalSurfaceCloseDelegate, TerminalSurfaceGridResizeDelegate {
    var title = ""
    var cwd = ""
    var rang = false
    var closed = false
    var grid: TerminalGridMetrics?
    var ioViewport: InMemoryTerminalViewport?
    func terminalDidChangeTitle(_ title: String) { self.title = title }
    func terminalDidChangeWorkingDirectory(_ path: String) { cwd = path }
    func terminalDidRingBell() { rang = true }
    func terminalDidClose(processAlive: Bool) { closed = true }
    func terminalDidResize(_ size: TerminalGridMetrics) { grid = size }
}

@main
@MainActor
private enum TerminalWakeup {
    struct Failure: Error { let message: String }
    static let escape = "\u{1b}"
    static var evidence: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["TERMINAL_WAKEUP_EVIDENCE"]!)
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func eventually(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            try check(ContinuousClock.now < deadline, "timeout: \(label)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func paint(_ session: InMemoryTerminalSession, color: String?, marker: String) {
        let background = color.map { "48;2;\($0)" } ?? "49"
        session.receive("\(escape)[?25l\(escape)[0;97;\(background)m\(escape)[2J\(escape)[H\(marker)")
    }

    static func session(_ mailbox: Mailbox) -> InMemoryTerminalSession {
        InMemoryTerminalSession(write: { _ in }, resize: { viewport in
            Task { @MainActor in mailbox.ioViewport = viewport }
        })
    }

    static func sized(_ view: FrameView, _ mailbox: Mailbox) async throws {
        let scale = view.window!.backingScaleFactor
        let width = UInt32(view.bounds.width * scale)
        let height = UInt32(view.bounds.height * scale)
        try await eventually("IO viewport \(width)x\(height)") {
            mailbox.ioViewport?.widthPixels == width && mailbox.ioViewport?.heightPixels == height
        }
    }

    static func capture(_ phase: String, window: NSWindow, active: FrameView,
                        marker: String, color: [Int], width: CGFloat = 600, exitText: Bool = false,
                        cursor: CGPoint? = nil, cursorColor: [Int] = []) async throws {
        var request: [String: Any] = ["phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
            "window": window.windowNumber, "marker": marker, "color": color,
            "activeWidth": width, "width": 1040, "height": 480,
            "deliveredFrames": active.deliveredFrames]
        request["exitText"] = exitText
        if let cursor {
            request["cursorPoint"] = [cursor.x, cursor.y]
            request["cursorColor"] = cursorColor
        }
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            .write(to: evidence.appendingPathComponent("\(phase).ready.json"), options: .atomic)
        try await eventually("native pixels \(phase)") {
            FileManager.default.fileExists(atPath: evidence.appendingPathComponent("\(phase).captured").path)
        }
    }

    static func run() async throws {
        let app = NSApplication.shared
        let controller = TerminalController(configuration: TerminalConfiguration {
            $0.withBackground("101010")
            $0.withForeground("ffffff")
            $0.withCursorStyleBlink(false)
            $0.withWindowPaddingX(0)
            $0.withWindowPaddingY(0)
            $0.withCustom("bell-features", "no-audio")
        }, theme: TerminalTheme())
        try check(controller.lastConfigurationIssue == nil, "invalid native test configuration")
        let mailbox = Mailbox(), quietMailbox = Mailbox()
        let session = Self.session(mailbox)
        let quietSession = Self.session(quietMailbox)
        let active = FrameView(frame: NSRect(x: 0, y: 0, width: 600, height: 480))
        let quiet = FrameView(frame: NSRect(x: 640, y: 0, width: 400, height: 480))
        active.delegate = mailbox
        active.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        quiet.configuration = TerminalSurfaceOptions(backend: .inMemory(quietSession))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1040, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(active)
        window.contentView!.addSubview(quiet)
        active.controller = controller
        quiet.controller = controller
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer {
            active.controller = nil
            quiet.controller = nil
            window.close()
        }
        try await eventually("two real surfaces") { active.surface != nil && quiet.surface != nil && mailbox.grid != nil }
        try await sized(active, mailbox)
        try await sized(quiet, quietMailbox)
        paint(quietSession, color: "20;40;180", marker: "QUIET_SIBLING")
        paint(session, color: "180;20;20", marker: "INITIAL_RED")
        try await eventually("initial marker") { session.readViewportText()?.contains("INITIAL_RED") == true }
        try await capture("01-initial", window: window, active: active, marker: "INITIAL_RED", color: [180, 20, 20])

        // No lifecycle/config/layout stimulus after this idle interval: output alone must deliver a frame.
        try await Task.sleep(for: .seconds(1))
        let beforeOutput = active.deliveredFrames
        paint(session, color: "20;180;40", marker: "ASYNC_GREEN")
        try await eventually("normal output marker and delivered frame") {
            active.deliveredFrames > beforeOutput && session.readViewportText()?.contains("ASYNC_GREEN") == true
        }
        try await capture("02-async", window: window, active: active, marker: "ASYNC_GREEN", color: [20, 180, 40])
        try check(quietSession.readViewportText()?.contains("QUIET_SIBLING") == true, "output changed quiet sibling")

        active.setSurfaceVisible(false)
        active.isHidden = true
        quiet.setSurfaceVisible(false)
        quiet.isHidden = true
        // The native mailbox has 64 slots. Distinct OSC titles force substantially more than one mailboxful.
        session.receive((0..<256).map { "\(escape)]2;HIDDEN_\($0)\u{7}" }.joined()
            + "\(escape)]7;file://localhost/tmp/easl-wakeup-hidden\u{7}\u{7}"
            + "\(escape)]2;HIDDEN_MAILBOX_COMPLETE\u{7}")
        paint(session, color: "180;120;20", marker: "HIDDEN_AMBER")
        try await eventually("hidden title/cwd/bell mailbox progress beyond capacity") {
            mailbox.title == "HIDDEN_MAILBOX_COMPLETE" && mailbox.cwd == "/tmp/easl-wakeup-hidden" && mailbox.rang
        }
        try await eventually("hidden output tail") { session.readViewportText()?.contains("HIDDEN_AMBER") == true }
        let beforeReveal = active.deliveredFrames
        active.isHidden = false
        active.setSurfaceVisible(true)
        quiet.isHidden = false
        quiet.setSurfaceVisible(true)
        try await eventually("reveal frame") { active.deliveredFrames > beforeReveal }
        try await capture("03-reveal", window: window, active: active, marker: "HIDDEN_AMBER", color: [180, 120, 20])

        paint(session, color: nil, marker: "CONFIG_PURPLE")
        try await eventually("default background marker") { session.readViewportText()?.contains("CONFIG_PURPLE") == true }
        try check(controller.setTerminalConfiguration(TerminalConfiguration {
            $0.withBackground("7820b4")
            $0.withCursorStyle(.block)
            $0.withCursorStyleBlink(false)
            $0.withCursorColor("ff0000")
            $0.withWindowPaddingX(0)
            $0.withWindowPaddingY(0)
        }), "config rejected")
        try await capture("04-config", window: window, active: active, marker: "CONFIG_PURPLE", color: [120, 32, 180])

        let oldColumns = mailbox.grid!.columns
        let beforeWrap = active.deliveredFrames
        session.receive("\(escape)[2J\(escape)[H" + String(repeating: " ", count: Int(oldColumns) - 2) + "WRAP_FRESH")
        try await eventually("pre-resize native frame") { active.deliveredFrames > beforeWrap }
        active.setFrameSize(NSSize(width: 520, height: 480))
        try await sized(active, mailbox)
        try await eventually("layout grid freshness") { mailbox.grid!.columns < oldColumns }
        try await capture("05-layout", window: window, active: active, marker: "WRAP_FRESH", color: [120, 32, 180], width: 520)

        paint(session, color: nil, marker: "")
        session.receive("\(escape)[3;1HFOCUS_CURSOR\(escape)[H\(escape)[?25h")
        let cursor = CGPoint(x: active.bounds.width / CGFloat(mailbox.grid!.columns) / 2,
                             y: active.bounds.height / CGFloat(mailbox.grid!.rows) / 2)
        try check(window.makeFirstResponder(active), "active focus rejected")
        try await capture("05a-focus-filled", window: window, active: active, marker: "FOCUS_CURSOR",
                          color: [120, 32, 180], width: 520, cursor: cursor, cursorColor: [255, 0, 0])
        try check(window.makeFirstResponder(quiet), "quiet focus rejected")
        try await capture("05b-focus-hollow", window: window, active: active, marker: "FOCUS_CURSOR",
                          color: [120, 32, 180], width: 520, cursor: cursor, cursorColor: [120, 32, 180])

        window.orderOut(nil)
        active.setSurfaceVisible(false)
        quiet.setSurfaceVisible(false)
        paint(session, color: "160;20;120", marker: "EXPOSED_MAGENTA")
        try await eventually("unexposed output tail") { session.readViewportText()?.contains("EXPOSED_MAGENTA") == true }
        window.makeKeyAndOrderFront(nil)
        active.setSurfaceVisible(true)
        quiet.setSurfaceVisible(true)
        try check(window.makeFirstResponder(active), "exposed focus rejected")
        try await capture("06-exposure", window: window, active: active, marker: "EXPOSED_MAGENTA", color: [160, 20, 120], width: 520)

        active.setSurfaceVisible(false)
        active.isHidden = true
        quiet.setSurfaceVisible(false)
        quiet.isHidden = true
        session.finish(exitCode: 0, runtimeMilliseconds: 1000)
        try await eventually("attached hidden child exit") { mailbox.closed && active.surface?.isProcessRunning == false }
        active.controller = nil
        try check(active.surface == nil && session.readViewportText() == nil, "teardown retained session surface")
        let replacement = Self.session(mailbox)
        mailbox.ioViewport = nil
        active.configuration = TerminalSurfaceOptions(backend: .inMemory(replacement))
        paint(replacement, color: "20;160;180", marker: "REATTACHED_CYAN")
        active.isHidden = false
        active.setSurfaceVisible(true)
        quiet.isHidden = false
        quiet.setSurfaceVisible(true)
        let beforeReattach = active.deliveredFrames
        active.controller = controller
        try await eventually("reattached buffered output and frame") {
            active.deliveredFrames > beforeReattach && replacement.readViewportText()?.contains("REATTACHED_CYAN") == true
        }
        try await sized(active, mailbox)
        paint(replacement, color: "20;160;180", marker: "REATTACHED_CYAN")
        try await capture("07-reattach", window: window, active: active, marker: "REATTACHED_CYAN", color: [20, 160, 180], width: 520)
        try check(quietSession.readViewportText()?.contains("QUIET_SIBLING") == true, "lifecycle work changed quiet sibling")
        paint(replacement, color: nil, marker: "VISIBLE_EXIT")
        try await eventually("pre-exit marker") { replacement.readViewportText()?.contains("VISIBLE_EXIT") == true }
        try check(window.makeFirstResponder(quiet), "exit control focus rejected")
        try await Task.sleep(for: .seconds(1))
        replacement.finish(exitCode: 3, runtimeMilliseconds: 0)
        try await eventually("unfocused exit text") {
            replacement.readViewportText()?.contains("Press any key to close the window.") == true
        }
        try await capture("08-visible-exit", window: window, active: active,
                          marker: "Press any key to close the window.", color: [120, 32, 180], width: 520, exitText: true)
        let normalExit = Self.session(mailbox)
        mailbox.ioViewport = nil
        active.configuration = TerminalSurfaceOptions(backend: .inMemory(normalExit))
        try await sized(active, mailbox)
        paint(normalExit, color: nil, marker: "NORMAL_EXIT")
        try await eventually("normal exit control") { normalExit.readViewportText()?.contains("NORMAL_EXIT") == true }
        try await Task.sleep(for: .seconds(1))
        mailbox.closed = false
        normalExit.finish(exitCode: 0, runtimeMilliseconds: 1000)
        try await eventually("normal unfocused exit text") {
            mailbox.closed && normalExit.readViewportText()?.contains("Process exited. Press any key to close the terminal.") == true
        }
        try await capture("09-normal-exit", window: window, active: active,
                          marker: "Process exited. Press any key to close the terminal.", color: [120, 32, 180], width: 520)
        try Data("PASS native output, hidden mailbox/backpressure/exit, reveal, config, wrapped layout, filled/hollow focus, exposure, reattach, frame delivery and captured pixels\n".utf8)
            .write(to: evidence.appendingPathComponent("result.txt"), options: .atomic)
    }

    static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }
}
