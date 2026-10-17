import Foundation

// Per-client UI state: what one Mac's window remembers about a board or about itself. It lives in
// the client's own home (`EASL_HOME`), never in the board file, because a board is shared by every
// client that opens it and each of them looks at it differently.

/// Where a board's view was left: the zoom and the board point at the centre of the view
/// (board coordinates, as `Viewport.rect`), so a window of another size on the next launch still
/// centres on what the user was looking at.
public struct SavedViewport: Codable, Equatable, Sendable {
    public var zoom: Double
    public var x: Double
    public var y: Double

    public init(zoom: Double, x: Double, y: Double) {
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    /// Whether the numbers can be shown (a hand-edited or damaged file may hold anything).
    var isUsable: Bool { zoom.isFinite && zoom > 0 && x.isFinite && y.isFinite }

    /// One board's saved view: `<dir>/<boardId>.json`.
    public struct Store: Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        /// Unreadable or unusable counts as absent: the board opens as a first open does.
        public func load() -> SavedViewport? {
            guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedViewport.self, from: data), saved.isUsable else { return nil }
            return saved
        }

        public func save(_ viewport: SavedViewport) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(viewport).write(to: url, options: .atomic)
        }
    }

    /// A board's record as one open board keeps it: the view it opened at (nil: a first open, or
    /// a file that couldn't be read) and what is on disk now. `record` writes whatever differs
    /// from the disk, so a board that never moved still gets its record at the first close or
    /// quit, and a write that failed is tried again at the next one.
    public struct Recorder: Sendable {
        public let store: Store
        /// What the store held when the board opened, or nil.
        public let opened: SavedViewport?
        /// What the last successful write (or the load) left on disk; nil: nothing readable.
        public private(set) var written: SavedViewport?

        public init(store: Store) {
            self.store = store
            opened = store.load()
            written = opened
        }

        /// Writes `viewport` unless the disk holds it already; false when the write failed.
        @discardableResult
        public mutating func record(_ viewport: SavedViewport) -> Bool {
            guard viewport != written else { return true }
            do {
                try store.save(viewport)
            } catch {
                return false
            }
            written = viewport
            return true
        }
    }
}

/// How much the app's chrome text (the tray, tile title bars and their status text) is scaled,
/// View › Increase/Decrease/Reset Chrome Text Size. Only text and the window chrome that holds it
/// scale: a tile's frame, its title bar's height and the board's geometry are the board's, the
/// same for every client, and content zoom (`ObjectZoom`) is separate.
public enum ChromeTextScale {
    /// 100% is how the app has always drawn it.
    public static let levels: [Double] = [1, 1.15, 1.3, 1.5]
    public static let normal = 1.0

    /// The level nearest `value`; 100% for anything unusable.
    public static func level(nearest value: Double) -> Double {
        guard value.isFinite else { return normal }
        return levels.min { abs($0 - value) < abs($1 - value) } ?? normal
    }

    /// The next level up or down from `scale`; nil at the end of the range.
    public static func step(from scale: Double, bigger: Bool) -> Double? {
        let current = level(nearest: scale)
        guard let index = levels.firstIndex(of: current) else { return nil }
        let next = bigger ? index + 1 : index - 1
        return levels.indices.contains(next) ? levels[next] : nil
    }
}

/// The app's own settings in an easl home (`ui-settings.json`): the chrome text scale and
/// background attach. Each change reads the file again and writes back only its own field, so one
/// setting's write keeps the other's.
public struct UISettings: Equatable, Sendable {
    /// `ChromeTextScale`'s level.
    public var chromeTextScale: Double
    /// Remote easld boards in the reopen list (`RemoteReopen`) stay attached while easl runs, also
    /// with their windows closed (docs/design.md "Client mode"). On unless turned off.
    public var backgroundAttach: Bool

    public init(chromeTextScale: Double = ChromeTextScale.normal, backgroundAttach: Bool = true) {
        self.chromeTextScale = chromeTextScale
        self.backgroundAttach = backgroundAttach
    }

    /// On disk: a missing or damaged field is that setting's default, whatever the others hold.
    private struct File: Codable {
        var scale: Double?
        var backgroundAttach: Bool?

        init(_ settings: UISettings) {
            scale = settings.chromeTextScale
            backgroundAttach = settings.backgroundAttach
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            scale = try? fields.decodeIfPresent(Double.self, forKey: .scale)
            backgroundAttach = try? fields.decodeIfPresent(Bool.self, forKey: .backgroundAttach)
        }
    }

    public struct Store: Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        /// The saved settings; 100% and on where there is none or the file is unreadable.
        public func load() -> UISettings {
            guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return UISettings() }
            return UISettings(chromeTextScale: file.scale.map(ChromeTextScale.level(nearest:)) ?? ChromeTextScale.normal,
                              backgroundAttach: file.backgroundAttach ?? true)
        }

        /// Writes the settings as the file holds them now, with `change` applied.
        public func update(_ change: (inout UISettings) -> Void) throws {
            var settings = load()
            change(&settings)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(settings)).write(to: url, options: .atomic)
        }
    }
}

/// A remote easld board in the reopen list (`remote-boards.json`): one this Mac opened whose tab
/// wasn't closed by hand or with `board.close`. Background attach attaches these again at launch.
/// Only how to reach the board: its host is discovered afresh each time, and nothing the board
/// holds (root, view, composer, drawings, pages) is kept on this Mac.
public struct RemoteReopen: Codable, Hashable, Sendable {
    /// The host as the user knows it (`RemoteHost.name`).
    public var host: String
    public var sshTarget: String
    public var board: BoardID

    public init(host: String, sshTarget: String, board: BoardID) {
        self.host = host
        self.sshTarget = sshTarget
        self.board = board
    }

    /// The reopen list, in the order its boards were opened.
    public struct Store: Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        /// An unreadable file is an empty list. A hand-edited entry ssh would misread, or that names
        /// no board, is left out (`RemoteHost.problem(withHost:)`).
        public func load() -> [RemoteReopen] {
            guard let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([RemoteReopen].self, from: data) else { return [] }
            return entries.filter { RemoteHost.problem(withHost: $0.sshTarget) == nil && ApiRouter.isBoardID($0.board) }
        }

        /// `entry` is in the list: added at the end, or in place of the one for its host and board.
        public func remember(_ entry: RemoteReopen) throws {
            var entries = load()
            if let index = entries.firstIndex(where: { $0.sshTarget == entry.sshTarget && $0.board == entry.board }) {
                guard entries[index] != entry else { return }
                entries[index] = entry
            } else {
                entries.append(entry)
            }
            try save(entries)
        }

        /// No entry for `board` on `sshTarget` is left.
        public func forget(sshTarget: String, board: BoardID) throws {
            let entries = load()
            let kept = entries.filter { $0.sshTarget != sshTarget || $0.board != board }
            guard kept.count != entries.count else { return }
            try save(kept)
        }

        private func save(_ entries: [RemoteReopen]) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        }
    }
}

/// How a remote board's window was closed by hand, taken when the close is asked for: AppKit takes
/// a closing tab out of its group before the window says it closed.
public enum RemoteClose: Equatable, Sendable {
    /// A tab beside others: the user is done with the board, as with `board.close`.
    case tab
    /// The window's only tab.
    case window

    public enum Outcome: Equatable, Sendable {
        /// Out of the reopen list and detached.
        case forget
        /// Still in the reopen list, detached until background attach brings it back.
        case detach
        /// Still in the reopen list and attached, its window closed.
        case retain
    }

    /// Only an easld host takes a viewer as its client: a Mac host answers its own calls.
    public func outcome(backgroundAttach: Bool, server: RemoteHost.Server?) -> Outcome {
        switch self {
        case .tab: .forget
        case .window: backgroundAttach && server == .easld ? .retain : .detach
        }
    }
}
