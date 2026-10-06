import AppKit

/// Links that leave easl: a web link ⌥-clicked anywhere on the board goes to the default browser,
/// another app's link (`mailto:`, `zoommtg:`) to that app. app.log names the app macOS chose.
/// `EASL_DEV_EXTERNAL_OPEN=log` in a development instance (with `EASL_DEV_INPUT=1`, which
/// `scripts/dev.sh` sets) logs the hand-off and opens nothing, so a test never leaves a window
/// in the user's browser.
@MainActor
enum ExternalOpen {
    private static let logOnly = DevInput.enabled && ProcessInfo.processInfo.environment["EASL_DEV_EXTERNAL_OPEN"] == "log"

    /// `naming: false` keeps the URL out of app.log: a remote board's terminal link is the host's
    /// text (client mode), which nothing on this Mac keeps.
    static func open(_ url: URL, because reason: String, naming: Bool = true) {
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)?.lastPathComponent ?? "no app"
        NSLog("easl: %@: %@ → %@", reason, naming ? url.absoluteString : "(not logged)", app)
        if logOnly { return }
        NSWorkspace.shared.open(url)
    }
}
