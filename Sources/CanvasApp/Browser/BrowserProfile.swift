import AppKit
import CanvasCore
import CryptoKit
import WebKit

/// Browser profiles: cookies and logins, local storage and databases, caches. Every browser tile
/// without a `profile` prop shares the default profile, one browser with separate screens. The
/// app keeps WebKit's default store for it whatever its `EASL_HOME` (a developer's everyday
/// instance runs from a development home), so nothing moves for anyone. An instance launched
/// with `EASL_BROWSER_PROFILE=own` (`scripts/dev.sh` sets it for a `EASL_DEV_HOME`: study and
/// slice instances) gets a persistent store named by its home (`identifier`), so it never shares
/// cookies or storage with the user's app or another instance, and keeps its own across restarts.
///
/// A tile's `profile` prop names another profile (a second Google account, a clean session):
/// its own persistent store (`WKWebsiteDataStore(forIdentifier:)`), the same for every tile and
/// board that names it, and in an `own` instance kept apart from the user's app too. HTML tiles
/// never use any of them (their store is non-persistent, `HtmlTile`).
@MainActor
enum BrowserProfile {
    private static let ownStores = ProcessInfo.processInfo.environment["EASL_BROWSER_PROFILE"] == "own"

    static let store: WKWebsiteDataStore = ownStores ? WKWebsiteDataStore(forIdentifier: identifier(home: AppPaths.support)) : .default()

    private static var named: [String: WKWebsiteDataStore] = [:]

    /// The profile a tile's props name: its trimmed `profile`, nil for the default profile.
    static func name(in props: JSONValue) -> String? {
        guard let name = props["profile"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// The store of profile `name`; nil is the default profile (`store`).
    static func store(named name: String?) -> WKWebsiteDataStore {
        guard let name else { return store }
        if let existing = named[name] { return existing }
        let created = WKWebsiteDataStore(forIdentifier: identifier(profile: name, home: ownStores ? AppPaths.support : nil))
        named[name] = created
        return created
    }

    /// The same UUID for the same home directory on every launch (a name-based UUID, RFC 9562
    /// version 5 layout, from SHA-256 of the standardized path), a different one for another.
    nonisolated static func identifier(home: URL) -> UUID {
        nameUUID("net.waldin.canvas.home:" + home.standardizedFileURL.path)
    }

    /// A named profile's store: the same UUID for the same name on every launch; with a `home`
    /// (an `own` instance) one that differs from every other home's and from the user's app.
    nonisolated static func identifier(profile: String, home: URL?) -> UUID {
        nameUUID("net.waldin.easl.profile:" + (home.map { $0.standardizedFileURL.path + "\n" } ?? "") + profile)
    }

    private nonisolated static func nameUUID(_ text: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// What follows WebKit's own user agent: `Version/<Safari's version> Safari/605.1.15`, the
    /// installed Safari's version (the WebKit the tiles run is that Safari's engine), read once.
    /// Sites key features and sign-in flows off the Safari token: without it Google serves a
    /// degraded sign-in, with an old fixed version sniffers treat the engine as older than it
    /// is. Without Safari's bundle (removed, unreadable) the version is the one macOS ships:
    /// Safari 17 on macOS 14, 18 on 15, and the system's own number from macOS 26.
    static let applicationName: String = {
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") ?? URL(fileURLWithPath: "/Applications/Safari.app")
        let installed = Bundle(url: safari)?.infoDictionary?["CFBundleShortVersionString"] as? String
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let shipped = os.majorVersion >= 26 ? "\(os.majorVersion).\(os.minorVersion)" : "\(os.majorVersion + 3).\(os.minorVersion)"
        let version = installed.flatMap { $0.allSatisfy { $0.isNumber || $0 == "." } && !$0.isEmpty ? $0 : nil } ?? shipped
        return "Version/\(version) Safari/605.1.15"
    }()

    /// easl › Clear Browsing Data…: says what goes, in a sheet (an app-modal alert would stall
    /// every socket request until answered), then removes all of it from the default profile and
    /// every named profile `profiles` lists (the ones tiles on the open boards use). Pages open
    /// now keep what they show until they reload. `done` runs once the data is gone.
    static func confirmClear(in window: NSWindow, profiles: Set<String>, done: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Clear browsing data?"
        let others = profiles.isEmpty ? "" : " Also clears the \(profiles.sorted().map { "“\($0)”" }.joined(separator: ", ")) profile\(profiles.count == 1 ? "" : "s")."
        alert.informativeText = "Removes every browser tile's cookies and logins, local storage and databases, and cached files, on every board.\(others) Pages open now keep what they show until they reload."
        // Return and Esc cancel: this signs you out of every site, so it takes a click.
        alert.addButton(withTitle: "Cancel")
        let clear = alert.addButton(withTitle: "Clear")
        clear.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            Task { @MainActor in
                for cleared in [BrowserProfile.store] + profiles.sorted().map(BrowserProfile.store(named:)) {
                    await cleared.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                }
                NSLog("easl: cleared browsing data")
                done()
            }
        }
    }
}
