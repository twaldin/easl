import Foundation

/// Brings an install of this app under an earlier name here, once: Canvas (0.4, and through 0.2.1:
/// the same locations) or Chalkwork (0.3.0–0.3.3). It moves the support directory (boards,
/// including `pre-repo-migration/` backups and page snapshots, open tabs, Get Started, spooled
/// agent reports), `~/.<slug>` (compositions), the browser profile (cookies, logins, site data)
/// and the user defaults (export folder, lasso setting, window frames). The rules (the upgrade
/// notes in CHANGELOG.md; the markers and the backup in docs/contracts.md, "On-disk locations"):
///
/// - **One source, the newest install.** Canvas 0.4 or later, when its defaults show it ran (its
///   own migration's marker, `LegacyMigration.Chalkwork.v1`, with any value): it took over from
///   Chalkwork, so it is the newest. Otherwise Chalkwork, newer than a Canvas 0.2 it took over from.
///   Otherwise Canvas 0.2. The first of these with a support directory, a `~/.<slug>` or settings
///   is migrated; the other is never merged in or moved, it stays where it is.
/// - **Its data wins.** What already sits at this name's support directory, `~/.<slug>` or in its
///   defaults when no migration put it there (a development build that ran on the default home) is
///   moved first, whole, into the dated backup
///   `~/Library/Application Support/<Name>-stale-<yyyyMMdd'T'HHmmss'Z'>/`, at its path relative to
///   the home (`Library/Application Support/<Name>/`, `.<slug>/`,
///   `Library/Preferences/<bundle id>.plist`). Nothing is deleted.
/// - **The browser profile** (WebKit, HTTPStorages) moves only where this name has none yet.
/// - **Once per earlier name.** Each gets its own marker in this name's defaults
///   (`LegacyMigration.<Name>.v2`), set at the first launch whatever it found: `migrated <time>`,
///   `superseded by <Name>` (an older install left in place) or `none`. A launch with every marker
///   set does nothing, so an earlier app opened again later (recreating its folders) never
///   overwrites what this one owns. No earlier migration's marker (Canvas 0.4's
///   `LegacyMigration.<Name>.v1`, Chalkwork's `LegacyMigration.defaultsMerged`) is copied, and none
///   counts here.
///
/// Image tiles that point into the moved support directory (Snapshot to Image) are re-pointed.
/// Privacy grants (microphone, camera, automation) belong to the old bundle id and can't move:
/// macOS asks again. The app runs it before anything reads `AppPaths` or the defaults, and never
/// for a development home or while an earlier app is running (main.swift).
public struct LegacyMigration {
    /// A name the app ships under: support directory `Application Support/<name>`, `~/.<slug>`,
    /// bundle id and defaults domain `bundle`.
    public struct Name: Equatable, Sendable {
        public let name: String
        public let slug: String
        public let bundle: String

        public init(name: String, slug: String, bundle: String) {
            self.name = name
            self.slug = slug
            self.bundle = bundle
        }

        /// The marker in the current name's defaults saying this earlier name was dealt with.
        public var marker: String { "LegacyMigration.\(name).v2" }
    }

    public static let current = Name(name: "Easl", slug: "easl", bundle: "net.waldin.easl")
    public static let canvas = Name(name: "Canvas", slug: "canvas", bundle: "net.waldin.canvas")
    public static let chalkwork = Name(name: "Chalkwork", slug: "chalkwork", bundle: "net.waldin.chalkwork")
    /// Every name the app shipped under before.
    public static let earlier = [canvas, chalkwork]
    /// Set in Canvas's defaults by Canvas 0.4's own migration, at its first launch: Canvas 0.4 or
    /// later ran, after any Chalkwork.
    public static let canvasTookOverMarker = "LegacyMigration.Chalkwork.v1"
    /// Prefix of every migration's marker, this one's and earlier ones': never copied as a setting.
    static let markerPrefix = "LegacyMigration."

    /// The user's home directory (`~`).
    public let home: URL
    /// The name migrated to: `current`, except in tests.
    public let target: Name

    public init(home: URL, target: Name = current) {
        self.home = home
        self.target = target
    }

    /// The earlier names it migrates from.
    public var sources: [Name] { Self.earlier.filter { $0.bundle != target.bundle } }

    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    public func support(_ name: Name) -> URL { library.appendingPathComponent("Application Support/\(name.name)", isDirectory: true) }
    func dotDirectory(_ name: Name) -> URL { home.appendingPathComponent(".\(name.slug)", isDirectory: true) }
    /// The backup a migration moves stale destination data into, stamped `stamp`.
    public func staleBackup(_ stamp: String) -> URL { library.appendingPathComponent("Application Support/\(target.name)-stale-\(stamp)", isDirectory: true) }

    /// The browser profile, old location → new one.
    func browserMoves(from source: Name) -> [(from: URL, to: URL)] {
        [
            (library.appendingPathComponent("WebKit/\(source.bundle)", isDirectory: true), library.appendingPathComponent("WebKit/\(target.bundle)", isDirectory: true)),
            (library.appendingPathComponent("HTTPStorages/\(source.bundle)", isDirectory: true), library.appendingPathComponent("HTTPStorages/\(target.bundle)", isDirectory: true)),
            (library.appendingPathComponent("HTTPStorages/\(source.bundle).binarycookies"), library.appendingPathComponent("HTTPStorages/\(target.bundle).binarycookies")),
        ]
    }

    /// The sources, newest install first: Canvas when Canvas 0.4 or later ran (it took over from
    /// Chalkwork), else Chalkwork before Canvas 0.2.
    public func newestFirst(defaults: some DefaultsDomains) -> [Name] {
        let canvasTookOver = defaults.persistentDomain(forName: Self.canvas.bundle)?[Self.canvasTookOverMarker] != nil
        let order = canvasTookOver ? [Self.canvas, Self.chalkwork] : [Self.chalkwork, Self.canvas]
        return order.filter(sources.contains)
    }

    /// Earlier names whose marker isn't set yet: the migration has something to decide.
    public func pending(defaults: some DefaultsDomains) -> [Name] {
        let own = defaults.persistentDomain(forName: target.bundle) ?? [:]
        return sources.filter { own[$0.marker] == nil }
    }

    /// Why it mustn't run now: an earlier app among `running`, the bundle ids of the other running
    /// apps, would still be writing the data it moves. Nil: go ahead.
    public func refusal(running: [String]) -> String? {
        guard let app = sources.first(where: { running.contains($0.bundle) }) else { return nil }
        return "\(app.name) is running, so its boards stay with it; quit it and open \(target.name) again to bring them here"
    }

    /// Deals with every pending earlier name (the rules above); returns one line per thing it did
    /// (or failed to do), for the log. Nothing to do: empty.
    @discardableResult
    public func run(defaults: some DefaultsDomains, now: Date = Date()) -> [String] {
        let pending = pending(defaults: defaults)
        guard !pending.isEmpty else { return [] }
        let stamp = Self.stamp(now)
        let decided = defaults.persistentDomain(forName: target.bundle) ?? [:]
        // A previous launch migrated one: every other earlier name is older news.
        var winner = sources.first { (decided[$0.marker] as? String)?.hasPrefix("migrated") == true }
        var log: [String] = []
        var markers: [String: String] = [:]
        for source in newestFirst(defaults: defaults) where pending.contains(source) {
            let present = has(source, defaults: defaults)
            if let winner {
                if present { log.append("left \(source.name)'s data where it is: \(winner.name)'s came here") }
                markers[source.marker] = present ? "superseded by \(winner.name)" : "none"
            } else if present {
                let (lines, done) = migrate(from: source, defaults: defaults, stamp: stamp)
                log += lines
                // Not done (its support directory couldn't move): no marker, so the next launch tries again.
                guard done else { break }
                winner = source
                markers[source.marker] = "migrated \(stamp)"
            } else {
                markers[source.marker] = "none"
            }
        }
        var own = defaults.persistentDomain(forName: target.bundle) ?? [:]
        for (key, value) in markers { own[key] = value }
        defaults.setPersistentDomain(own, forName: target.bundle)
        return log
    }

    /// Whether `name` left anything this migration would bring.
    func has(_ name: Name, defaults: some DefaultsDomains) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: support(name).path) || files.fileExists(atPath: dotDirectory(name).path)
            || !(defaults.persistentDomain(forName: name.bundle) ?? [:]).isEmpty
    }

    /// Clears the destination into the stale backup, then moves `source` here. Not done when the
    /// destination couldn't be cleared or the support directory couldn't move (nothing of
    /// `source`'s moved yet then).
    func migrate(from source: Name, defaults: some DefaultsDomains, stamp: String) -> (log: [String], done: Bool) {
        let files = FileManager.default
        for name in [source, target] {
            let boards = support(name).appendingPathComponent("boards", isDirectory: true)
            guard let walk = files.enumerator(at: boards, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walk where file.pathExtension == "json" && file.lastPathComponent != RepoBoardMigration.reportFile {
                do {
                    _ = try BoardFile.read(file)
                } catch {
                    return (["could not migrate \(source.name)'s data: \(error.localizedDescription)"], false)
                }
            }
        }
        var log: [String] = []
        let backup = staleBackup(stamp)
        // Settings a migration didn't write: everything in the domain but the markers.
        var own = defaults.persistentDomain(forName: target.bundle) ?? [:]
        let stale = own.filter { !$0.key.hasPrefix(Self.markerPrefix) }
        let staleFiles = [support(target), dotDirectory(target)].filter { files.fileExists(atPath: $0.path) }
        if !staleFiles.isEmpty || !stale.isEmpty {
            do {
                for item in staleFiles {
                    let to = backup.appendingPathComponent(String(item.path.dropFirst(home.path.count + 1)), isDirectory: true)
                    try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try files.moveItem(at: item, to: to)
                }
                if !stale.isEmpty {
                    let plist = backup.appendingPathComponent("Library/Preferences/\(target.bundle).plist")
                    try files.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try PropertyListSerialization.data(fromPropertyList: stale, format: .xml, options: 0).write(to: plist)
                    for key in stale.keys { own.removeValue(forKey: key) }
                    defaults.setPersistentDomain(own, forName: target.bundle)
                }
                log.append("moved what was already at \(target.name)'s locations (\(staleFiles.map(\.lastPathComponent).joined(separator: ", "))\(stale.isEmpty ? "" : "\(staleFiles.isEmpty ? "" : ", ")\(stale.count) settings")) to \(backup.path)")
            } catch {
                return (log + ["could not move \(target.name)'s existing data to \(backup.path), so \(source.name)'s stays where it is: \(error.localizedDescription)"], false)
            }
        }
        let from = support(source), to = support(target)
        if files.fileExists(atPath: from.path) {
            do {
                try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: from, to: to)
                log.append("moved \(from.path) to \(to.path)")
                log += repointBoards(from: from)
            } catch {
                return (log + ["could not move \(from.path) to \(to.path): \(error.localizedDescription)"], false)
            }
        }
        for (from, to) in [(from: dotDirectory(source), to: dotDirectory(target))] + browserMoves(from: source) where files.fileExists(atPath: from.path) {
            if files.fileExists(atPath: to.path) {
                log.append("kept \(to.path); \(from.path) stays where it is")
                continue
            }
            do {
                try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: from, to: to)
                log.append("moved \(from.path) to \(to.path)")
            } catch {
                log.append("could not move \(from.path) to \(to.path): \(error.localizedDescription)")
            }
        }
        let settings = (defaults.persistentDomain(forName: source.bundle) ?? [:]).filter { !$0.key.hasPrefix(Self.markerPrefix) }
        if !settings.isEmpty {
            own = defaults.persistentDomain(forName: target.bundle) ?? [:]
            own.merge(settings) { _, theirs in theirs }
            defaults.setPersistentDomain(own, forName: target.bundle)
            log.append("brought \(settings.count) settings from \(source.bundle)")
        }
        return (log, true)
    }

    /// Board files (and their `pre-repo-migration/` backups) name page snapshots by absolute path
    /// inside the support directory: rewrite those under `old` to the moved directory.
    func repointBoards(from old: URL) -> [String] {
        let new = support(target)
        let boards = new.appendingPathComponent("boards", isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: boards, includingPropertiesForKeys: nil) else { return [] }
        // The store writes JSON with escaped slashes; an exported board wouldn't.
        let from = old.path + "/", to = new.path + "/"
        let pairs = [(from, to), (from.replacingOccurrences(of: "/", with: "\\/"), to.replacingOccurrences(of: "/", with: "\\/"))]
        var repointed = 0
        for case let file as URL in walk where file.pathExtension == "json" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let rewritten = pairs.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            guard rewritten != text else { continue }
            do {
                try rewritten.write(to: file, atomically: true, encoding: .utf8)
                repointed += 1
            } catch {
                return ["could not re-point \(file.path): \(error.localizedDescription)"]
            }
        }
        return repointed == 0 ? [] : ["re-pointed \(repointed) board file\(repointed == 1 ? "" : "s") at \(new.path)"]
    }

    /// `now` in UTC as `yyyyMMdd'T'HHmmss'Z'`: sortable, and no colons for Finder to show as slashes.
    static func stamp(_ now: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return format.string(from: now)
    }
}

/// The two `UserDefaults` calls the migration makes, so tests can use a dictionary.
public protocol DefaultsDomains {
    func persistentDomain(forName domainName: String) -> [String: Any]?
    func setPersistentDomain(_ domain: [String: Any], forName domainName: String)
}

extension UserDefaults: DefaultsDomains {}

/// Defaults domains as the plist files in `<home>/Library/Preferences`, read and written directly:
/// for an upgrade rehearsal on a throwaway home (main.swift), since `UserDefaults` (cfprefsd)
/// ignores `HOME` and would read and write the real user's.
public struct PreferenceFiles: DefaultsDomains {
    public let directory: URL

    public init(home: URL) {
        directory = home.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    func file(_ domain: String) -> URL { directory.appendingPathComponent("\(domain).plist") }

    public func persistentDomain(forName domainName: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file(domainName)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    public func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(domainName), options: .atomic)
    }
}
