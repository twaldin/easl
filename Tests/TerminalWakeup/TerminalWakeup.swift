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

    // The runner acknowledges only a fresh, PID/window-bound native capture with matching pixels.
    static func capture(_ phase: String, window: NSWindow, active: FrameView,
                        marker: String, color: [Int], width: CGFloat = 600, exitText: Bool = false) async throws {
        var request: [String: Any] = ["phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
            "window": window.windowNumber, "marker": marker, "color": color,
            "activeWidth": width, "width": 1040, "height": 480,
            "deliveredFrames": active.deliveredFrames]
        request["exitText"] = exitText
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
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let quietSession = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let mailbox = Mailbox()
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
        try check(controller.setTerminalConfiguration(TerminalConfiguration { $0.withBackground("7820b4") }), "config rejected")
        try await capture("04-config", window: window, active: active, marker: "CONFIG_PURPLE", color: [120, 32, 180])

        let oldColumns = mailbox.grid!.columns
        active.setFrameSize(NSSize(width: 520, height: 480))
        try await eventually("layout grid freshness") { mailbox.grid!.columns < oldColumns }
        try check(window.makeFirstResponder(quiet), "quiet focus rejected")
        try check(window.makeFirstResponder(active), "active focus rejected")
        try await capture("05-layout-focus", window: window, active: active, marker: "CONFIG_PURPLE", color: [120, 32, 180], width: 520)

        window.orderOut(nil)
        paint(session, color: "160;20;120", marker: "EXPOSED_MAGENTA")
        try await eventually("unexposed output tail") { session.readViewportText()?.contains("EXPOSED_MAGENTA") == true }
        window.makeKeyAndOrderFront(nil)
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
        let replacement = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
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
        try Data("PASS native output, hidden mailbox/backpressure/exit, reveal, config, layout/focus, reattach, frame delivery and captured pixels\n".utf8)
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
