import Foundation

/// The Safari web extensions the user added to easl's browser tiles, as `browser-extensions.json`
/// in the easl home records them: where each one lives, whether it runs, and whether the user
/// has seen and accepted what it asks for. WebKit keeps everything else per extension (its
/// storage, the permissions granted) under the browser profile, keyed by `id`.
public struct BrowserExtensionList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Stable across launches: WebKit keys the extension's storage, granted permissions and
        /// page origin by it, so a vault the user unlocked stays theirs after a restart.
        public var id: String
        /// An unpacked folder holding `manifest.json`, or a Safari web extension `.appex`.
        public var path: String
        /// The extension's name as it last loaded, for the menu while it's disabled.
        public var name: String?
        public var enabled: Bool
        /// The user confirmed the permissions sheet. An entry added by hand (or one whose sheet
        /// was dismissed by a quit) asks again when it next loads.
        public var reviewed: Bool
        /// What the user granted (API permissions such as `storage`, and match patterns such as
        /// `<all_urls>`), restored into WebKit at every launch: WebKit doesn't keep grants itself.
        public var permissions: [String]
        public var sites: [String]

        public init(id: String, path: String, enabled: Bool, reviewed: Bool, permissions: [String] = [], sites: [String] = []) {
            self.id = id
            self.path = path
            self.enabled = enabled
            self.reviewed = reviewed
            self.permissions = permissions
            self.sites = sites
        }

        /// Only `path` is required, so an entry written by hand loads (and asks for review).
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            name = try container.decodeIfPresent(String.self, forKey: .name)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            reviewed = try container.decodeIfPresent(Bool.self, forKey: .reviewed) ?? false
            permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
            sites = try container.decodeIfPresent([String].self, forKey: .sites) ?? []
        }
    }

    public var extensions: [Entry]

    public init(extensions: [Entry] = []) {
        self.extensions = extensions
    }

    /// Adds the extension at `path`, or re-enables the one already recorded there (picking the
    /// same app twice never runs two copies). Returns the entry.
    @discardableResult
    public mutating func add(path: String, id: String = UUID().uuidString) -> Entry {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        if let index = extensions.firstIndex(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == standard }) {
            extensions[index].enabled = true
            return extensions[index]
        }
        let entry = Entry(id: id, path: standard, enabled: true, reviewed: false)
        extensions.append(entry)
        return entry
    }

    public mutating func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        change(&extensions[index])
    }

    public mutating func remove(_ id: String) {
        extensions.removeAll { $0.id == id }
    }

    /// The list's file in an easl home; unreadable or absent counts as empty.
    public struct Store: Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        public func load() -> BrowserExtensionList {
            guard let data = try? Data(contentsOf: url) else { return BrowserExtensionList() }
            return (try? JSONDecoder().decode(BrowserExtensionList.self, from: data)) ?? BrowserExtensionList()
        }

        public func save(_ list: BrowserExtensionList) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(list).write(to: url, options: .atomic)
        }
    }
}

/// What the user picked to add as a browser extension, resolved to what WebKit loads: an app
/// (the App Store's Bitwarden.app, 1Password for Safari) carries its Safari web extensions as
/// `.appex` bundles in `Contents/PlugIns`; an `.appex` is one; a folder with `manifest.json` is
/// an unpacked extension (a developer's build).
public enum BrowserExtensionSource: Equatable, Sendable {
    case appExtension(URL)
    case folder(URL)

    public var url: URL {
        switch self {
        case .appExtension(let url), .folder(let url): url
        }
    }

    /// The extension point every Safari web extension's `.appex` declares.
    public static let safariExtensionPoint = "com.apple.Safari.web-extension"

    public struct Failure: Error, Equatable, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// The extensions at `url`; throws with a sentence for the user when there are none.
    public static func resolve(_ url: URL) throws -> [BrowserExtensionSource] {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "app":
            let plugIns = url.appendingPathComponent("Contents/PlugIns", isDirectory: true)
            let bundles = (try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? []
            let found = bundles.filter { $0.pathExtension == "appex" && isSafariExtension($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !found.isEmpty else { throw Failure(message: "\(name) doesn't contain a Safari web extension.") }
            return found.map(BrowserExtensionSource.appExtension)
        case "appex":
            guard isSafariExtension(url) else { throw Failure(message: "\(name) isn't a Safari web extension.") }
            return [.appExtension(url)]
        default:
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
                throw Failure(message: "\(name) isn't a Safari web extension: pick an app that includes one, an .appex, or a folder with a manifest.json.")
            }
            return [.folder(url)]
        }
    }

    private static func isSafariExtension(_ appex: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist")),
              let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String else { return false }
        return point == safariExtensionPoint
    }
}
