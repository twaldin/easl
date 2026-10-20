import Foundation
import Testing
import CanvasCore

/// An install under an earlier name (Canvas 0.4 or 0.2, Chalkwork 0.3) arrives whole, once
/// (LegacyMigration), on a temporary home, at a name the app never had (the stand-in `fresh`).
struct LegacyMigrationTests {
    final class Domains: DefaultsDomains {
        var domains: [String: [String: Any]] = [:]
        func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }
        func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { domains[domainName] = domain }
    }

    static let canvas = LegacyMigration.canvas
    static let chalkwork = LegacyMigration.chalkwork
    /// A name the app never had, whatever this build is called.
    static let fresh = LegacyMigration.Name(name: "Freshname", slug: "freshname", bundle: "net.waldin.freshname")
    static let now = Date(timeIntervalSince1970: 1_791_039_600)  // 2026-10-03 15:00:00 UTC
    static let stamp = "20261003T150000Z"
    /// What Canvas 0.4's own migration leaves in Canvas's defaults at its first launch.
    static var canvas04: [String: Any] { ["LegacyMigration.Chalkwork.v1": "migrated 20261002T180000Z"] }

    let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)", isDirectory: true)
    var migration: LegacyMigration { LegacyMigration(home: home, target: Self.fresh) }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }
    func url(_ path: String) -> URL { home.appendingPathComponent(path) }

    /// Every file under `dir`, relative path → contents.
    func tree(_ dir: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: dir.path) {
            var isDirectory: ObjCBool = false
            let url = dir.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[path] = try read(url)
        }
        return files
    }

    /// An install of `name` as its app leaves it: a board whose snapshot image tile names its PNG
    /// by absolute path (escaped slashes, as the store writes them), a pre-repo-migration backup,
    /// open tabs, a spooled report, a composition, the browser profile. `tag` marks every file.
    /// Returns the board JSON as written.
    @discardableResult
    func install(_ name: LegacyMigration.Name, tag: String) throws -> String {
        let support = migration.support(name)
        let snapshot = support.appendingPathComponent("boards/brd_1/snapshots/obj_9-20260928-101010.png").path
        let board = #"{"id":"brd_1","objects":[{"id":"obj_9","props":{"path":"\#(snapshot.replacingOccurrences(of: "/", with: "\\/"))"},"type":"image"}],"root":"\/Users\/me\/src\/\#(tag)"}"#
        try write(board, support.appendingPathComponent("boards/brd_1.json"))
        try write("PNG \(tag)", URL(fileURLWithPath: snapshot))
        try write(#"{"id":"brd_2","objects":[],"root":"\/Users\/me\/src\/\#(tag)\/wt"}"#, support.appendingPathComponent("boards/pre-repo-migration/brd_2.json"))
        try write(#"["/Users/me/src/\#(tag)"]"#, support.appendingPathComponent("open-boards.json"))
        try write("{}", support.appendingPathComponent("agent-reports/obj_1/5-42-\(tag).json"))
        try write("def arrange(canvas): pass  # \(tag)\n", url(".\(name.slug)/compositions/grid.py"))
        try write("cookies \(tag)", url("Library/HTTPStorages/\(name.bundle).binarycookies"))
        try write("site data \(tag)", url("Library/WebKit/\(name.bundle)/WebsiteData/LocalStorage/x.sqlite3"))
        return board
    }

    /// `install(source)` arrived at the new name's locations: every file, the board re-pointed,
    /// nothing left at the source's.
    func expectArrived(_ before: [String: String], board: String, from source: LegacyMigration.Name, tag: String) throws {
        let target = Self.fresh
        let after = try tree(migration.support(target))
        #expect(Set(after.keys) == Set(before.keys), "every file arrives")
        for (path, text) in before where path != "boards/brd_1.json" { #expect(after[path] == text, "\(path) unchanged") }
        let old = migration.support(source).path.replacingOccurrences(of: "/", with: "\\/")
        let new = migration.support(target).path.replacingOccurrences(of: "/", with: "\\/")
        #expect(after["boards/brd_1.json"] == board.replacingOccurrences(of: old, with: new), "the image tile names the moved PNG")
        #expect(try read(url(".\(target.slug)/compositions/grid.py")) == "def arrange(canvas): pass  # \(tag)\n")
        #expect(try read(url("Library/HTTPStorages/\(target.bundle).binarycookies")) == "cookies \(tag)")
        #expect(try read(url("Library/WebKit/\(target.bundle)/WebsiteData/LocalStorage/x.sqlite3")) == "site data \(tag)")
        #expect(!exists("Library/Application Support/\(source.name)"))
        #expect(!exists(".\(source.slug)"))
    }

    func settings(_ defaults: Domains) throws -> [String: Any] { try #require(defaults.domains[Self.fresh.bundle]) }

    @Test(arguments: ["unknown", "newer", "truncated"])
    func unreadableBoardsStayAtTheirOriginalLocation(_ kind: String) throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let from = migration.support(Self.canvas)
        let file = from.appendingPathComponent("boards/brd_future.json")
        let original: String
        switch kind {
        case "unknown":
            original = #"{"format":3,"id":"brd_future","root":"/tmp","revision":7,"objects":[{"type":"hologram"}]}"#
        case "newer":
            original = #"{"format":99,"id":"brd_future","root":"/tmp","revision":7,"objects":[]}"#
        default:
            original = #"{"format":3,"id":"brd_future","objects":["#
        }
        try write(original, file)
        let defaults = Domains()
        defaults.domains[Self.canvas.bundle] = Self.canvas04
        let log = migration.run(defaults: defaults, now: Self.now)
        #expect(try? read(file) == original)
        #expect(!FileManager.default.fileExists(atPath: migration.support(Self.fresh).path))
        #expect(defaults.domains[Self.fresh.bundle]?[Self.canvas.marker] == nil)
        #expect(log.contains { $0.contains(file.path) })
    }

    @Test func aFreshInstallMovesNothingAndRecordsThatOnce() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = Domains()
        #expect(migration.run(defaults: defaults, now: Self.now).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.path), "no folder created")
        #expect(defaults.domains[Self.fresh.bundle] as? [String: String] == ["LegacyMigration.Canvas.v2": "none", "LegacyMigration.Chalkwork.v2": "none"])
        #expect(migration.pending(defaults: defaults).isEmpty)
        // A Canvas installed and used afterwards stays its own.
        try install(Self.canvas, tag: "later")
        #expect(migration.run(defaults: defaults, now: Self.now).isEmpty)
        #expect(exists("Library/Application Support/Canvas/boards/brd_1.json"))
    }

    @Test func aCanvas04InstallArrivesIntactAndTheSecondRunDoesNothing() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let board = try install(Self.canvas, tag: "canvas")
        let before = try tree(migration.support(Self.canvas))
        let defaults = Domains()
        defaults.domains[Self.canvas.bundle] = Self.canvas04.merging(["canvas.lassoSelection": true, "NSWindow Frame Canvas-brd_1": "0 0 800 600"]) { a, _ in a }

        let log = migration.run(defaults: defaults, now: Self.now)

        try expectArrived(before, board: board, from: Self.canvas, tag: "canvas")
        let own = try settings(defaults)
        #expect(own["canvas.lassoSelection"] as? Bool == true)
        #expect(own["NSWindow Frame Canvas-brd_1"] as? String == "0 0 800 600", "window frames come along")
        #expect(own["LegacyMigration.Chalkwork.v1"] == nil, "Canvas 0.4's marker isn't this migration's")
        #expect(own["LegacyMigration.Canvas.v2"] as? String == "migrated \(Self.stamp)")
        #expect(own["LegacyMigration.Chalkwork.v2"] as? String == "none")
        #expect(!exists("Library/Application Support/Freshname-stale-\(Self.stamp)"), "nothing was in the way: \(log)")

        // A second launch: nothing to decide, and a Canvas that ran again since (recreating its
        // folder, changing a setting) doesn't overwrite what the new name now owns.
        try write("{}", migration.support(Self.canvas).appendingPathComponent("open-boards.json"))
        defaults.domains[Self.canvas.bundle]?["canvas.exportDirectory"] = "/tmp"
        let settled = try tree(home)
        #expect(migration.run(defaults: defaults, now: Self.now.addingTimeInterval(60)).isEmpty)
        #expect(try tree(home) == settled)
        #expect(defaults.domains[Self.fresh.bundle]?["canvas.exportDirectory"] == nil)
    }

    @Test func canvas04WinsOverChalkworkLeftovers() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        // Canvas 0.4 took Chalkwork's data; a Chalkwork opened again since left a new tree.
        let board = try install(Self.canvas, tag: "canvas")
        let canvas = try tree(migration.support(Self.canvas))
        try install(Self.chalkwork, tag: "chalkwork leftovers")
        let chalkwork = try tree(migration.support(Self.chalkwork))
        let defaults = Domains()
        defaults.domains[Self.canvas.bundle] = ["LegacyMigration.Chalkwork.v1": "none", "canvas.exportDirectory": "/canvas"]
        defaults.domains[Self.chalkwork.bundle] = ["canvas.exportDirectory": "/chalkwork", "canvas.lassoSelection": true]

        let log = migration.run(defaults: defaults, now: Self.now)

        try expectArrived(canvas, board: board, from: Self.canvas, tag: "canvas")
        #expect(try tree(migration.support(Self.chalkwork)) == chalkwork, "Chalkwork's leftovers stay whole")
        #expect(try read(url("Library/HTTPStorages/net.waldin.chalkwork.binarycookies")) == "cookies chalkwork leftovers")
        let own = try settings(defaults)
        #expect(own["canvas.exportDirectory"] as? String == "/canvas")
        #expect(own["canvas.lassoSelection"] == nil, "nothing of Chalkwork's merged in")
        #expect(own["LegacyMigration.Canvas.v2"] as? String == "migrated \(Self.stamp)")
        #expect(own["LegacyMigration.Chalkwork.v2"] as? String == "superseded by Canvas")
        #expect(log.contains("left Chalkwork's data where it is: Canvas's came here"))
    }

    @Test func aChalkworkInstallArrives() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let board = try install(Self.chalkwork, tag: "chalkwork")
        let before = try tree(migration.support(Self.chalkwork))
        let defaults = Domains()
        // Chalkwork's own marker of its Canvas merge comes with its domain.
        defaults.domains[Self.chalkwork.bundle] = ["canvas.lassoSelection": true, "LegacyMigration.defaultsMerged": true]

        migration.run(defaults: defaults, now: Self.now)

        try expectArrived(before, board: board, from: Self.chalkwork, tag: "chalkwork")
        let own = try settings(defaults)
        #expect(own["canvas.lassoSelection"] as? Bool == true)
        #expect(own["LegacyMigration.defaultsMerged"] == nil, "Chalkwork's marker isn't this migration's")
        #expect(own["LegacyMigration.Chalkwork.v2"] as? String == "migrated \(Self.stamp)")
        #expect(own["LegacyMigration.Canvas.v2"] as? String == "none")
    }

    @Test func chalkworkWinsOverAStaleCanvas02() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        // Canvas 0.2 never ran Canvas 0.4's migration: no marker in its defaults, so Chalkwork,
        // which took over from it, is newer. Canvas comes first in `earlier` and must not fill
        // the destination first.
        try install(Self.canvas, tag: "stale canvas")
        let board = try install(Self.chalkwork, tag: "chalkwork")
        let chalkwork = try tree(migration.support(Self.chalkwork))
        let canvas = try tree(migration.support(Self.canvas))
        let defaults = Domains()
        defaults.domains[Self.canvas.bundle] = ["canvas.exportDirectory": "/old", "canvas.lassoSelection": true]
        defaults.domains[Self.chalkwork.bundle] = ["canvas.lassoSelection": false]

        let log = migration.run(defaults: defaults, now: Self.now)

        try expectArrived(chalkwork, board: board, from: Self.chalkwork, tag: "chalkwork")
        #expect(try tree(migration.support(Self.canvas)) == canvas, "Canvas's install stays whole")
        #expect(try read(url(".canvas/compositions/grid.py")) == "def arrange(canvas): pass  # stale canvas\n")
        #expect(try read(url("Library/HTTPStorages/net.waldin.canvas.binarycookies")) == "cookies stale canvas")
        let own = try settings(defaults)
        #expect(own["canvas.lassoSelection"] as? Bool == false, "Chalkwork's value")
        #expect(own["canvas.exportDirectory"] == nil, "nothing of Canvas's merged in")
        #expect(own["LegacyMigration.Chalkwork.v2"] as? String == "migrated \(Self.stamp)")
        #expect(own["LegacyMigration.Canvas.v2"] as? String == "superseded by Chalkwork")
        #expect(log.contains("left Canvas's data where it is: Chalkwork's came here"))
    }

    @Test func aCanvas02InstallThatNeverRanChalkworkArrives() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let board = try install(Self.canvas, tag: "canvas 0.2")
        let before = try tree(migration.support(Self.canvas))
        // The real files, as the rehearsal reads them (main.swift).
        let defaults = PreferenceFiles(home: home)
        defaults.setPersistentDomain(["canvas.lassoSelection": false], forName: Self.canvas.bundle)

        migration.run(defaults: defaults, now: Self.now)

        try expectArrived(before, board: board, from: Self.canvas, tag: "canvas 0.2")
        let own = try #require(defaults.persistentDomain(forName: Self.fresh.bundle))
        #expect(own["canvas.lassoSelection"] as? Bool == false)
        #expect(own["LegacyMigration.Canvas.v2"] as? String == "migrated \(Self.stamp)")
        #expect(own["LegacyMigration.Chalkwork.v2"] as? String == "none")
    }

    @Test func aPopulatedDestinationIsBackedUpFirst() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        // A development build on the release bundle id wrote settings and a support directory on
        // the default home, without any migration having run.
        try write("[]", migration.support(Self.fresh).appendingPathComponent("open-boards.json"))
        try write("mine", url(".freshname/compositions/own.py"))
        try install(Self.canvas, tag: "canvas")
        let defaults = Domains()
        defaults.domains[Self.fresh.bundle] = ["canvas.lassoSelection": true]
        defaults.domains[Self.canvas.bundle] = Self.canvas04.merging(["canvas.exportDirectory": "/work"]) { a, _ in a }

        migration.run(defaults: defaults, now: Self.now)

        let backup = "Library/Application Support/Freshname-stale-\(Self.stamp)"
        #expect(try read(url("\(backup)/Library/Application Support/Freshname/open-boards.json")) == "[]")
        #expect(try read(url("\(backup)/.freshname/compositions/own.py")) == "mine")
        let backedUp = try PropertyListSerialization.propertyList(from: Data(contentsOf: url("\(backup)/Library/Preferences/net.waldin.freshname.plist")), format: nil) as? [String: Bool]
        #expect(backedUp == ["canvas.lassoSelection": true])
        #expect(try read(migration.support(Self.fresh).appendingPathComponent("open-boards.json")) == #"["/Users/me/src/canvas"]"#)
        let own = try settings(defaults)
        #expect(own["canvas.lassoSelection"] == nil)
        #expect(own["canvas.exportDirectory"] as? String == "/work")
    }

    @Test func eachEarlierNameHasItsOwnMarkerAndOlderMarkersCountForNothing() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try install(Self.chalkwork, tag: "chalkwork")
        // Markers of earlier migrations in this name's domain (copied by hand, say) decide nothing.
        let copied = Domains()
        copied.domains[Self.fresh.bundle] = ["LegacyMigration.defaultsMerged": true, "LegacyMigration.Chalkwork.v1": "migrated 20261002T180000Z", "LegacyMigration.Canvas.v1": "none"]
        #expect(migration.pending(defaults: copied) == [Self.canvas, Self.chalkwork])

        // Canvas decided, Chalkwork not: Chalkwork runs.
        let defaults = Domains()
        defaults.domains[Self.fresh.bundle] = ["LegacyMigration.Canvas.v2": "none"]
        #expect(migration.pending(defaults: defaults) == [Self.chalkwork])
        migration.run(defaults: defaults, now: Self.now)
        #expect(exists("Library/Application Support/Freshname/boards/brd_1.json"))
        #expect(defaults.domains[Self.fresh.bundle]?["LegacyMigration.Chalkwork.v2"] as? String == "migrated \(Self.stamp)")

        // Chalkwork migrated, Canvas undecided: Canvas is superseded, its install left alone,
        // even one that shows Canvas 0.4 ran.
        try FileManager.default.removeItem(at: home)
        try install(Self.canvas, tag: "canvas")
        let canvas = try tree(home)
        let later = Domains()
        later.domains[Self.fresh.bundle] = ["LegacyMigration.Chalkwork.v2": "migrated 20261003T150000Z", "canvas.lassoSelection": true]
        later.domains[Self.canvas.bundle] = Self.canvas04
        migration.run(defaults: later, now: Self.now)
        #expect(try tree(home) == canvas)
        #expect(later.domains[Self.fresh.bundle]?["LegacyMigration.Canvas.v2"] as? String == "superseded by Chalkwork")
        #expect(later.domains[Self.fresh.bundle]?["canvas.lassoSelection"] as? Bool == true, "the new name's own setting stays")
    }

    @Test func refusesWhileAnEarlierAppRuns() {
        #expect(migration.refusal(running: ["com.apple.Safari", "net.waldin.freshname.dev.0123456789"]) == nil)
        #expect(migration.refusal(running: ["net.waldin.canvas"]) == "Canvas is running, so its boards stay with it; quit it and open Freshname again to bring them here")
        #expect(migration.refusal(running: ["net.waldin.chalkwork"])?.hasPrefix("Chalkwork is running") == true)
    }

    @Test func newestFirstFollowsCanvas04sMarker() {
        let defaults = Domains()
        #expect(migration.newestFirst(defaults: defaults) == [Self.chalkwork, Self.canvas])
        defaults.domains[Self.canvas.bundle] = ["canvas.lassoSelection": true]
        #expect(migration.newestFirst(defaults: defaults) == [Self.chalkwork, Self.canvas], "Canvas 0.2's settings alone")
        defaults.domains[Self.canvas.bundle] = ["LegacyMigration.Chalkwork.v1": "none"]
        #expect(migration.newestFirst(defaults: defaults) == [Self.canvas, Self.chalkwork], "any value of Canvas 0.4's marker")
    }

    @Test func thisBuildMigratesFromCanvasAndChalkwork() {
        #expect(Set(LegacyMigration(home: home).sources.map(\.name)) == ["Canvas", "Chalkwork"])
    }
}
