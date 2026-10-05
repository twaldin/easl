import AppKit
import CanvasCore

/// View › Performance HUD: `app.metrics` at a glance in a small floating panel, redrawn once a
/// second while it shows (and only then: hidden, it costs nothing). The process is sampled every
/// second while it shows (`Metrics.sampleFast`).
@MainActor
final class MetricsHUD {
    static let shared = MetricsHUD()

    private var panel: NSPanel?
    private var text: NSTextField?
    private var timer: Timer?

    var isShown: Bool { panel?.isVisible == true }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSApp.windows.first(where: { $0.isVisible && $0 !== panel })?.screen ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - 16))
        }
        panel.orderFrontRegardless()
        Metrics.shared.sampleFast(true)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MetricsHUD.shared.refresh() }
        }
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        Metrics.shared.sampleFast(false)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 190),
                            styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "easl performance"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let text = NSTextField(wrappingLabelWithString: "")
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .white
        text.frame = panel.contentView!.bounds.insetBy(dx: 10, dy: 8)
        text.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(text)
        self.text = text
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { MetricsHUD.shared.hide() }
        }
        return panel
    }

    private func refresh() {
        text?.stringValue = Self.summary(Metrics.shared.snapshot())
    }

    /// The HUD's lines: the last 60 s.
    static func summary(_ m: JSONValue) -> String {
        func counter(_ name: String, _ window: String = "last60s") -> (n: Int, ms: Double, max: Double, bytes: Int) {
            let t = m["counters"]?[name]?[window]
            return (t?["n"]?.int ?? 0, t?["ms"]?.number ?? 0, t?["maxMs"]?.number ?? 0, t?["bytes"]?.int ?? 0)
        }
        func number(_ value: Double) -> String { String(format: value >= 100 ? "%.0f" : "%.1f", value) }
        let process = m["process"]
        let p60 = process?["windows"]?["last60s"]
        var lines: [String] = []
        let busy = counter("main.busy")
        lines.append("main   busy \(number(busy.ms / 600))%  stretches ≥50 ms \(counter("main.stretch50").n)  ≥250 ms \(counter("main.stretch250").n)  (60 s)")
        if let longest = m["longest"], let ms = longest["ms"]?.number {
            lines.append("       longest \(Int(ms)) ms, \(longest["agoS"]?.int ?? 0) s ago: \(longest["cause"]?.string ?? "")")
        }
        lines.append("cpu    \(number(p60?["cpuPercent"]?.number ?? 0))%  wakeups \(number(p60?["interruptWakeupsPerS"]?.number ?? 0))/s  "
            + "memory \(process?["footprintMB"]?.int ?? 0) MB (peak \(process?["peakFootprintMB"]?.int ?? 0))")
        // Requests by method (`api.in.<method>` counts arrivals, `api.<method>` replies).
        let api = (m["counters"]?.object ?? [:]).keys.filter { $0.hasPrefix("api.in.") }
            .map { ($0.dropFirst("api.in.".count), counter("api.\($0.dropFirst("api.in.".count))")) }.filter { $0.1.n > 0 }.sorted { $0.1.ms > $1.1.ms }
        lines.append("api    " + (api.isEmpty ? "idle" : api.prefix(3).map { "\($0.0) \($0.1.n) requests \(number($0.1.ms)) ms" }.joined(separator: ", ")))
        let route = counter("route.board")
        lines.append("route  board \(route.n)× \(number(route.ms)) ms (max \(number(route.max)))  arrows alone \(counter("route.arrow").n)")
        let save = counter("save.write"), encode = counter("save.encode")
        let events = (m["counters"]?.object ?? [:]).keys.filter { $0.hasPrefix("event.") }.map { counter($0) }
        lines.append("saves  \(save.n) (encode \(number(encode.ms)) ms, \(save.bytes / 1024) KB)  events \(events.reduce(0) { $0 + $1.n }) "
            + "(\(events.reduce(0) { $0 + $1.bytes } / 1024) KB)  writes \(counter("board.write").n)")
        let live = (m["gauges"]?.object ?? [:]).filter { $0.key.hasPrefix("live.") && ($0.value.number ?? 0) > 0 }
            .sorted { $0.key < $1.key }.map { "\($0.key.dropFirst(5).replacingOccurrences(of: "Tile", with: "")) \($0.value.int ?? 0)" }
        lines.append("live   " + (live.isEmpty ? "none" : live.joined(separator: " ")) + "  web views \(m["gauges"]?["html.webviews"]?.int ?? 0)")
        return lines.joined(separator: "\n")
    }
}
