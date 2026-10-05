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

    private struct State: Codable {
        var scale: Double
    }

    /// The setting's file in an easl home (`ui-settings.json`).
    public struct Store: Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        /// The saved level; 100% when there is none or the file is unreadable.
        public func load() -> Double {
            guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(State.self, from: data) else { return normal }
            return level(nearest: state.scale)
        }

        public func save(_ scale: Double) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(State(scale: scale)).write(to: url, options: .atomic)
        }
    }
}
