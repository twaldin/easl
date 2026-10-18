import Darwin
import Foundation
import Testing
import CanvasCore

extension AppUpdate.InstallProblem {
    /// The case's name, so tests match the case and not the reason's wording.
    var kind: String? { Mirror(reflecting: self).children.first?.label }
}

struct AppVersionTests {
    func v(_ text: String) -> AppVersion { AppVersion(text)! }

    @Test func numbersCompareNumericallyNotAsText() {
        #expect(v("0.2.10") > v("0.2.9"))
        #expect(v("0.2.9") < v("0.2.10"))
        #expect(v("0.10.0") > v("0.9.99"))
        #expect(v("1.0.0") > v("0.99.99"))
    }

    @Test func equalVersionsAreNeitherNewerNorOlder() {
        #expect(v("0.2.2") == v("0.2.2"))
        #expect(!(v("0.2.2") < v("0.2.2")) && !(v("0.2.2") > v("0.2.2")))
        #expect(v("0.3") == v("0.3.0"), "missing numbers are 0")
        #expect(v("0.2.2+build.7") == v("0.2.2"), "build metadata is ignored")
        #expect(v("1.0.0-rc.1+exp.sha-5114f85") == v("1.0.0-rc.1"))
    }

    @Test func aPreReleaseComesBeforeItsRelease() {
        #expect(v("1.0.0-rc.1") < v("1.0.0"))
        #expect(v("1.0.0-rc.2") < v("1.0.0-rc.10"))
        #expect(v("1.0.0-alpha") < v("1.0.0-beta"))
        #expect(v("1.0.0-1") < v("1.0.0-alpha"), "numeric identifiers sort first")
        #expect(v("1.0.0-rc") < v("1.0.0-rc.1"))
        #expect(v("1.0.0-rc.1") > v("0.9.9"))
    }

    @Test func anythingElseIsNoVersion() {
        for text in ["", "v0.2.2", "0..2", "0.2.", "0.2.x", "1.0-", "1.0-rc..1", " 0.2.2", "0.2.2 ", "-1.0"] {
            #expect(AppVersion(text) == nil, "\(text.debugDescription)")
        }
        #expect(AppVersion("0.2.2")?.description == "0.2.2")
    }

    @Test func buildMetadataIsOnlyWhatSemverAllows() {
        // The version names the update's folder: nothing in it may step outside.
        for text in ["99+cache/../../boards", "1.0+", "1.0+a..b", "1.0+a/b", "1.0+a b", "1.0+a+b", "1.0-rc/1", "1.0+.."] {
            #expect(AppVersion(text) == nil, "\(text.debugDescription)")
        }
    }
}

struct LatestReleaseTests {
    static let sha = "6b0029f11e0b041c09a063439ae62481d32294cfb4a188ca8a201816616108f2"

    func json(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    var site: [String: Any] {
        ["version": "0.2.2", "url": "https://github.com/twaldin/easl/releases/download/v0.2.2/easl-0.2.2.zip",
         "sha256": Self.sha, "size": 12863471, "notes": "https://github.com/twaldin/easl/releases/tag/v0.2.2"]
    }

    func decode(_ change: (inout [String: Any]) -> Void) throws -> LatestRelease {
        var fields = site
        change(&fields)
        return try LatestRelease.decode(json(fields))
    }

    @Test func decodesWhatTheSitePublishes() throws {
        let release = try decode { $0["sha256"] = Self.sha.uppercased(); $0["published"] = "2026-10-07" }
        #expect(release.version == AppVersion("0.2.2")!)
        #expect(release.url.absoluteString == "https://github.com/twaldin/easl/releases/download/v0.2.2/easl-0.2.2.zip")
        #expect(release.sha256 == Self.sha, "lowercased")
        #expect(release.size == 12863471)
        #expect(release.notes.absoluteString == "https://github.com/twaldin/easl/releases/tag/v0.2.2")
    }

    @Test func somethingOtherThanAnObjectIsNotJSON() {
        #expect(throws: LatestRelease.Problem.notJSON) { try LatestRelease.decode(Data("<html>502</html>".utf8)) }
        #expect(throws: LatestRelease.Problem.notJSON) { try LatestRelease.decode(Data("[]".utf8)) }
        #expect(throws: LatestRelease.Problem.notJSON) { try LatestRelease.decode(Data()) }
    }

    @Test func everyFieldIsRequired() {
        for field in ["version", "url", "sha256", "size", "notes"] {
            #expect(throws: LatestRelease.Problem.missing(field)) { try decode { $0[field] = nil } }
            #expect(throws: LatestRelease.Problem.missing(field)) { try decode { $0[field] = NSNull() } }
        }
    }

    @Test func badValuesAreRefusedWithTheField() {
        #expect(throws: LatestRelease.Problem.wrongType("size")) { try decode { $0["size"] = "12 MB" } }
        #expect(throws: LatestRelease.Problem.wrongType("version")) { try decode { $0["version"] = 3 } }
        for size in [1.5, 0, -3] {
            #expect(throws: LatestRelease.Problem.invalid("size")) { try decode { $0["size"] = size } }
        }
        #expect(throws: LatestRelease.Problem.invalid("version")) { try decode { $0["version"] = "v0.2.3" } }
        #expect(throws: LatestRelease.Problem.invalid("version")) { try decode { $0["version"] = "99+cache/../../boards" } }
        #expect(throws: LatestRelease.Problem.invalid("sha256")) { try decode { $0["sha256"] = "6b0029f1" } }
        #expect(throws: LatestRelease.Problem.invalid("sha256")) { try decode { $0["sha256"] = String(Self.sha.dropLast()) + "g" } }
        #expect(throws: LatestRelease.Problem.invalid("notes")) { try decode { $0["notes"] = "release notes" } }
    }

    @Test func theZipComesOverHTTPSOrFromThisMac() throws {
        for url in ["http://easl.sh/easl.zip", "file:///tmp/easl.zip", "easl.zip", "https:///easl.zip"] {
            #expect(throws: LatestRelease.Problem.invalid("url")) { try decode { $0["url"] = url } }
        }
        #expect(try decode { $0["url"] = "http://127.0.0.1:8765/easl-0.2.3.zip" }.url.port == 8765)
        #expect(try decode { $0["url"] = "http://localhost/easl-0.2.3.zip" }.url.host == "localhost")
    }

    @Test func onlyAHigherVersionIsNewer() throws {
        let release = try decode { $0["version"] = "0.2.10" }
        #expect(release.isNewer(than: AppVersion("0.2.9")!))
        #expect(!release.isNewer(than: AppVersion("0.2.10")!))
        #expect(!release.isNewer(than: AppVersion("0.3.0")!))
    }

    @Test func theSourceIsTheSiteUnlessOverridden() {
        #expect(AppUpdate.source(override: nil) == URL(string: "https://easl.sh/latest.json"))
        #expect(AppUpdate.source(override: "") == AppUpdate.defaultSource)
        #expect(AppUpdate.source(override: "http://127.0.0.1:8765/latest.json") == URL(string: "http://127.0.0.1:8765/latest.json"))
        #expect(AppUpdate.source(override: "latest.json") == nil)
        #expect(AppUpdate.source(override: "file:///tmp/latest.json") == nil)
    }
}

struct UpdateDownloadTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("easl-update-\(UUID().uuidString)", isDirectory: true)

    func zip(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("easl-0.2.3.zip")
        try Data(text.utf8).write(to: file)
        return file
    }

    func release(sha256: String, size: Int) -> LatestRelease {
        LatestRelease(version: AppVersion("0.2.3")!, url: URL(string: "https://example.com/easl-0.2.3.zip")!, sha256: sha256, size: size,
                      notes: URL(string: "https://example.com/notes")!)
    }

    @Test func theZipThatMatchesPasses() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try zip("abc")
        // `printf abc | shasum -a 256`
        let sum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try AppUpdate.sha256(of: file) == sum)
        try AppUpdate.checkDownload(file, against: release(sha256: sum, size: 3))
    }

    @Test func aChecksumMismatchIsRejected() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try zip("abd")
        let pinned = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let got = try AppUpdate.sha256(of: file)
        #expect(throws: AppUpdate.DownloadProblem.checksum(expected: pinned, got: got)) {
            try AppUpdate.checkDownload(file, against: release(sha256: pinned, size: 3))
        }
    }

    @Test func aSizeMismatchIsRejectedBeforeHashing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try zip("abcd")
        #expect(throws: AppUpdate.DownloadProblem.size(expected: 3, got: 4)) {
            try AppUpdate.checkDownload(file, against: release(sha256: String(repeating: "0", count: 64), size: 3))
        }
    }

    @Test func theNewAppsVersionComesFromItsInfoPlist() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("easl.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        #expect(AppUpdate.bundleVersion(of: app) == nil)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.2.3"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(AppUpdate.bundleVersion(of: app) == "0.2.3")
    }
}

struct UpdateStagingTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("easl-staging-\(UUID().uuidString)", isDirectory: true)
    var updates: URL { root.appendingPathComponent("updates", isDirectory: true) }
    var boards: URL { root.appendingPathComponent("boards", isDirectory: true) }

    /// A sibling of `updates` holding the user's data, which no update may touch.
    func sentinel() throws -> URL {
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        let file = boards.appendingPathComponent("brd_1.json")
        try Data("{}".utf8).write(to: file)
        return file
    }

    @Test func aVersionThatIsntOnePlainNameIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try sentinel()
        for version in ["", ".", "..", "99+cache/../../boards", "../boards", "a/b"] {
            let error = #expect(throws: AppUpdate.InstallProblem.self, "\(version.debugDescription)") {
                try AppUpdate.Staging(updates: updates, version: version).prepare()
            }
            #expect(error?.kind == "outsideUpdates")
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFolderThatResolvesOutsideUpdatesIsNeitherDeletedNorMade() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try sentinel()
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: updates.appendingPathComponent("0.2.3").path, withDestinationPath: "../boards")
        let staging = try AppUpdate.Staging(updates: updates, version: "0.2.3")
        let error = #expect(throws: AppUpdate.InstallProblem.self) { try staging.prepare() }
        #expect(error?.kind == "outsideUpdates")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: staging.directory.path)) == "../boards")
    }

    @Test func prepareEmptiesOnlyItsVersionsFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let other = updates.appendingPathComponent("0.2.2/result")
        try files.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("installed\n".utf8).write(to: other)
        let staging = try AppUpdate.Staging(updates: updates, version: "0.2.3")
        try files.createDirectory(at: staging.unpacked, withIntermediateDirectories: true)
        try staging.prepare()
        #expect(try files.contentsOfDirectory(atPath: staging.directory.path).isEmpty)
        #expect(files.fileExists(atPath: other.path))
    }

    @Test func leftoversAreOnlyAnUpdatesHiddenCopies() throws {
        let id = "0f8b5d3a-6a8e-4c2b-9d1e-2b7c4e5f6a7b"
        #expect(AppUpdate.isLeftover(".easl-update-0.2.3-\(id).app"))
        #expect(AppUpdate.isLeftover(".easl-previous-0.2.3-rc.1-\(id).app"))
        let staging = try AppUpdate.Staging(updates: updates, version: "0.2.3")
        let installed = root.appendingPathComponent("Applications/easl.app")
        #expect(AppUpdate.isLeftover(staging.incoming(beside: installed).lastPathComponent))
        #expect(AppUpdate.isLeftover(staging.backup(beside: installed).lastPathComponent))
        for name in ["easl.app", ".easl-update-0.2.3.app", ".easl-update-x-\(id).app", ".easl-update-0.2.3-\(id)", ".easl-previous--\(id).app",
                     ".easl-update-0.2.3-not-a-uuid.app", "Safari.app", ".easl-update-../a-\(id).app"] {
            #expect(!AppUpdate.isLeftover(name), "\(name)")
        }
    }

    @Test func twoUpdatesNeverShareTheirHiddenCopies() throws {
        let installed = root.appendingPathComponent("Applications/easl.app")
        // Two instances on other homes, running one bundle, updating to one version.
        let a = try AppUpdate.Staging(updates: root.appendingPathComponent("a/updates"), version: "0.2.3")
        let b = try AppUpdate.Staging(updates: root.appendingPathComponent("b/updates"), version: "0.2.3")
        #expect(a.incoming(beside: installed) != b.incoming(beside: installed))
        #expect(a.backup(beside: installed) != b.backup(beside: installed))
        #expect(a.incoming(beside: installed).deletingLastPathComponent() == installed.deletingLastPathComponent(), "on the app's volume")
    }

    @Test func aLaunchDeletesOnlyLeftoversAnHourOld() {
        let now = Date(timeIntervalSince1970: 10_000)
        let id = "0f8b5d3a-6a8e-4c2b-9d1e-2b7c4e5f6a7b"
        let old = now.addingTimeInterval(-2 * 60 * 60)
        let fresh = now.addingTimeInterval(-30)
        let files = [
            Housekeeping.File(name: ".easl-update-0.2.3-\(id).app", modified: fresh),
            Housekeeping.File(name: ".easl-previous-0.2.3-\(id).app", modified: old),
            Housekeeping.File(name: ".easl-previous-0.2.2-\(id).app", modified: old),
            Housekeeping.File(name: ".easl-previous-0.2.2-\(id).app.protection", modified: old),
            Housekeeping.File(name: "easl.app", modified: old),
            // An old protection cannot age a fresh bundle; a fresh one protects its old bundle.
            Housekeeping.File(name: ".easl-previous-0.2.4-\(id).app", modified: fresh),
            Housekeeping.File(name: ".easl-previous-0.2.4-\(id).app.protection", modified: old),
            Housekeeping.File(name: ".easl-previous-0.2.5-\(id).app", modified: old),
            Housekeeping.File(name: ".easl-previous-0.2.5-\(id).app.protection", modified: fresh),
            // Repeated protection names must keep the newest date for both the backup and protection.
            Housekeeping.File(name: ".easl-previous-0.2.5-\(id).app.protection", modified: old),
            Housekeeping.File(name: ".easl-previous-0.2.6-\(id).app.protection", modified: old),
            Housekeeping.File(name: ".easl-previous-0.2.7-\(id).app.protection", modified: fresh),
            // An unreadable date is treated as young, never as an absent protection.
            Housekeeping.File(name: ".easl-previous-0.2.8-\(id).app", modified: old),
            Housekeeping.File(name: ".easl-previous-0.2.8-\(id).app.protection", modified: .distantFuture),
            Housekeeping.File(name: ".easl-update-0.2.9-\(id).app", modified: .distantFuture),
            Housekeeping.File(name: ".easl-previous-not-a-transaction.app.protection", modified: old),
            Housekeeping.File(name: ".easl-previous-x-\(id).app.protection", modified: old),
            Housekeeping.File(name: ".easl-previous-0.2.3-not-a-uuid.app.protection", modified: old),
            Housekeeping.File(name: ".easl-update-0.2.3-\(id).app.protection", modified: old),
        ]
        // A fresh copy may be another home's update under way; never remove the running rollback or its protection.
        #expect(AppUpdate.staleLeftovers(files, running: ".easl-previous-0.2.2-\(id).app", now: now) == [
            ".easl-previous-0.2.3-\(id).app",
            ".easl-previous-0.2.4-\(id).app.protection",
            ".easl-previous-0.2.6-\(id).app.protection",
        ])
    }

    @Test func launchCleanupLeavesAnUndeletableLeftoverButRemovesTheOthers() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let now = Date()
        let old = now.addingTimeInterval(-2 * 60 * 60)
        let id = "0f8b5d3a-6a8e-4c2b-9d1e-2b7c4e5f6a7b"
        let protected = root.appendingPathComponent(".easl-previous-0.2.3-\(id).app.protection")
        let removable = root.appendingPathComponent(".easl-update-0.2.3-\(id).app")
        for entry in [protected, removable] {
            try files.createDirectory(at: entry, withIntermediateDirectories: true)
            try files.setAttributes([.modificationDate: old], ofItemAtPath: entry.path)
        }
        try files.setAttributes([.immutable: true], ofItemAtPath: protected.path)
        defer { try? files.setAttributes([.immutable: false], ofItemAtPath: protected.path) }
        #expect(AppUpdate.removeStaleLeftovers(beside: root, running: "easl.app", now: now) == [removable.lastPathComponent])
        #expect(files.fileExists(atPath: protected.path))
        #expect(!files.fileExists(atPath: removable.path))
        #expect(AppUpdate.removeStaleLeftovers(beside: root.appendingPathComponent("absent"), running: "easl.app", now: now).isEmpty)
    }

    @Test func anotherInstanceRunningFromTheSameBundleIsFound() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications/easl.app", isDirectory: true)
        let other = root.appendingPathComponent("elsewhere/easl.app", isDirectory: true)
        let link = root.appendingPathComponent("link.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let me: Int32 = 100
        let sharing = [AppUpdate.RunningInstance(pid: me, bundle: app), AppUpdate.RunningInstance(pid: 7, bundle: nil),
                       AppUpdate.RunningInstance(pid: 42, bundle: link)]
        #expect(AppUpdate.otherInstance(sharing: app, among: sharing, except: me)?.pid == 42, "the same bundle through a symlink")
        let apart = [AppUpdate.RunningInstance(pid: me, bundle: app), AppUpdate.RunningInstance(pid: 42, bundle: other)]
        #expect(AppUpdate.otherInstance(sharing: app, among: apart, except: me) == nil, "another copy elsewhere")
        #expect(AppUpdate.otherInstance(sharing: app, among: [AppUpdate.RunningInstance(pid: me, bundle: app)], except: me) == nil)
    }
}

struct UpdateStagingLeaseTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("easl-lease-\(UUID().uuidString)", isDirectory: true)
    var app: URL { root.appendingPathComponent("easl.app") }

    func incoming(version: String = "0.2.3") throws -> URL {
        try AppUpdate.Staging(updates: root.appendingPathComponent("updates"), version: version).incoming(beside: app)
    }

    func age(_ urls: [URL], now: Date) throws {
        for url in urls {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * AppUpdate.leftoverAge)], ofItemAtPath: url.path)
        }
    }

    @Test func anotherHomesStartupKeepsAReadyCopyForAsLongAsItsLeaseIsHeld() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let ready = try incoming()
        let leaseURL = URL(fileURLWithPath: ready.path + ".lease")
        var lease: AppUpdate.StagingLease? = try AppUpdate.StagingLease(incoming: ready)
        #expect(lease?.descriptor != nil, "ownership begins before the incoming copy exists")
        try TestBundle.make(ready, version: "0.2.3", executable: Data("ready".utf8))
        let original = try TestBundle.snapshot(ready)
        let orphan = try incoming(version: "0.2.4")
        try TestBundle.make(orphan, version: "0.2.4")
        let now = Date()
        try age([ready, leaseURL, orphan], now: now)
        let muchLater = now.addingTimeInterval(365 * 24 * 60 * 60)
        #expect(AppUpdate.removeStaleLeftovers(beside: root, running: "easl.app", now: muchLater) == [orphan.lastPathComponent])
        #expect(try TestBundle.snapshot(ready) == original)
        #expect(files.fileExists(atPath: leaseURL.path))
        withExtendedLifetime(lease) {}
        lease = nil
        #expect(files.fileExists(atPath: leaseURL.path), "deinit closes ownership without unlinking an inherited lease")
        #expect(Set(AppUpdate.removeStaleLeftovers(beside: root, running: "easl.app", now: muchLater))
                == Set([ready.lastPathComponent, leaseURL.lastPathComponent]))
        #expect(!files.fileExists(atPath: ready.path))
        #expect(!files.fileExists(atPath: leaseURL.path))
        #expect(AppUpdate.removeStaleLeftovers(beside: root, running: "easl.app", now: muchLater).isEmpty)
    }

    @Test func orphanLeaseCleanupDoesNotAgeAYoungBundleOrKeepAnAbsentOneForever() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let young = try incoming()
        try TestBundle.make(young, version: "0.2.3")
        let youngLease = URL(fileURLWithPath: young.path + ".lease")
        let absent = try incoming(version: "0.2.4")
        let absentLease = URL(fileURLWithPath: absent.path + ".lease")
        try Data().write(to: youngLease)
        try Data().write(to: absentLease)
        let now = Date()
        try age([youngLease, absentLease], now: now)
        #expect(Set(AppUpdate.removeStaleLeftovers(beside: root, running: "easl.app", now: now))
                == Set([youngLease.lastPathComponent, absentLease.lastPathComponent]))
        #expect(AppUpdate.bundleVersion(of: young) == "0.2.3")
        #expect(!files.fileExists(atPath: youngLease.path))
        #expect(!files.fileExists(atPath: absentLease.path))
        #expect(!files.fileExists(atPath: absent.path))
    }

    @Test func uninspectableLeasesPreserveTheirCopiesWithoutBlockingOtherCleanup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let linked = try incoming()
        let directory = try incoming(version: "0.2.4")
        let orphan = try incoming(version: "0.2.5")
        for url in [linked, directory, orphan] { try TestBundle.make(url, version: "0.2.3") }
        let sentinel = root.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        let linkLease = URL(fileURLWithPath: linked.path + ".lease")
        let directoryLease = URL(fileURLWithPath: directory.path + ".lease")
        try files.createSymbolicLink(at: linkLease, withDestinationURL: sentinel)
        try files.createDirectory(at: directoryLease, withIntermediateDirectories: false)
        let now = Date()
        try age([linked, directory, orphan, sentinel, directoryLease], now: now)
        #expect(AppUpdate.removeStaleLeftovers(beside: root, running: "easl.app", now: now) == [orphan.lastPathComponent])
        #expect(AppUpdate.bundleVersion(of: linked) == "0.2.3")
        #expect(AppUpdate.bundleVersion(of: directory) == "0.2.3")
        #expect(try files.destinationOfSymbolicLink(atPath: linkLease.path) == sentinel.path)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(files.fileExists(atPath: directoryLease.path))
    }

    @Test func discardReleasesOnlyItsOwnExclusivelyCreatedLease() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = try incoming()
        let path = copy.path + ".lease"
        let first = try AppUpdate.StagingLease(incoming: copy)
        #expect(throws: POSIXError.self) { try AppUpdate.StagingLease(incoming: copy) }
        try first.discard()
        #expect(first.descriptor == -1)
        #expect(!files.fileExists(atPath: path))
        try first.discard()
        let second = try AppUpdate.StagingLease(incoming: copy)
        try files.removeItem(atPath: path)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: POSIXError(.ESTALE)) { try second.discard() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "replacement")
        try files.removeItem(atPath: path)
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try files.createSymbolicLink(atPath: path, withDestinationPath: sentinel.path)
        #expect(throws: POSIXError.self) { try AppUpdate.StagingLease(incoming: copy) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(try files.destinationOfSymbolicLink(atPath: path) == sentinel.path)
    }

    @Test func anInheritedHelperDescriptorKeepsTheLeaseAfterItsOriginalOwnerExits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try incoming()
        try TestBundle.make(copy, version: "0.2.3")
        let leaseURL = URL(fileURLWithPath: copy.path + ".lease")
        let pidFile = root.appendingPathComponent("helper-pid")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let observed = try await offPool {
            Result {
                let owner = Process()
                owner.executableURL = executable
                owner.arguments = ["--update-lease-owner", copy.path, pidFile.path]
                owner.standardOutput = FileHandle.nullDevice
                owner.standardError = FileHandle.nullDevice
                try owner.run()
                owner.waitUntilExit()
                let child = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
                var helperToStop = child
                defer { if helperToStop > 0 { kill(helperToStop, SIGKILL) } }
                let now = Date().addingTimeInterval(365 * 24 * 60 * 60)
                let held = AppUpdate.removeStaleLeftovers(beside: copy.deletingLastPathComponent(), running: "easl.app", now: now)
                let survived = AppUpdate.bundleVersion(of: copy)
                let leaseSurvived = FileManager.default.fileExists(atPath: leaseURL.path)
                let killed = kill(child, SIGKILL)
                if killed == 0 { helperToStop = 0 }
                var removed: Set<String> = []
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline && removed.count < 2 {
                    removed.formUnion(AppUpdate.removeStaleLeftovers(beside: copy.deletingLastPathComponent(), running: "easl.app", now: now))
                    if removed.count < 2 { usleep(10_000) }
                }
                return (status: owner.terminationStatus, held: held, survived: survived, leaseSurvived: leaseSurvived, killed: killed, removed: removed)
            }
        }.get()
        #expect(observed.status == 0)
        #expect(observed.held.isEmpty)
        #expect(observed.survived == "0.2.3")
        #expect(observed.leaseSurvived)
        #expect(observed.killed == 0)
        #expect(observed.removed == Set([copy.lastPathComponent, leaseURL.lastPathComponent]))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(!FileManager.default.fileExists(atPath: leaseURL.path))
    }
}

/// Bundles on disk for the install tests: an app folder with an Info.plist and an executable.
enum TestBundle {
    static func make(_ app: URL, version: String, executable: Data? = nil) throws {
        let files = FileManager.default
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "net.waldin.easl.test", "CFBundleExecutable": "Easl", "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let executable {
            try executable.write(to: macOS.appendingPathComponent("Easl"))
        } else {
            try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Easl"))
        }
    }

    /// Signs ad hoc, as a development build is.
    static func sign(_ app: URL) async throws {
        let result = try await RemoteHost.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], timeout: 60)
        #expect(result.status == 0, "\(result.errors)")
    }

    /// Every file under `folder`, by relative path, with its bytes.
    static func snapshot(_ folder: URL) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            var isFolder: ObjCBool = false
            let url = folder.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue {
                contents[path] = try Data(contentsOf: url)
            }
        }
        return contents
    }
}

extension TestBundle {
    /// Models a bundle that can be renamed through its writable parent, but whose timestamps
    /// cannot be changed. The ACL belongs only to this owned fixture; no privilege escalation.
    static func denyTimestampChanges(_ app: URL) async throws {
        let denied = try await RemoteHost.run("/bin/chmod", ["+a", "user:\(NSUserName()) deny writeattr", app.path], timeout: 10)
        try #require(denied.status == 0, "\(denied.errors)")
        let touch = try await RemoteHost.run("/usr/bin/touch", [app.path], timeout: 10)
        #expect(touch.status != 0, "the fixture must refuse the native helper's old timestamp write")
    }

    /// Runs the helper for a process that has already exited, relaunching by writing `"$app"`
    /// to `relaunched`; its outcome.
    static func runHelper(app: URL, staging: AppUpdate.Staging, relaunched: URL, beforeSwap: String = "", afterSwap: String = "",
                          swapExitsAfterExchange: Bool = false, expectedStatus: Int32 = 0) async throws -> AppUpdate.Outcome? {
        try FileManager.default.createDirectory(at: staging.directory, withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let status = await offPool { () -> Int32 in
            let exited = Process()
            exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            guard (try? exited.run()) != nil else { return -1 }
            exited.waitUntilExit()
            let script = AppUpdate.helperScript(pid: exited.processIdentifier, app: app, staging: staging,
                                                relaunch: "kill -TERM $$; kill -INT $$; kill -HUP $$; printf %s \"$app\" > \(RemoteHost.quote(relaunched.path))",
                                                swapExecutable: executable, beforeSwap: beforeSwap, afterSwap: afterSwap)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", script]
            if swapExitsAfterExchange {
                var environment = ProcessInfo.processInfo.environment
                environment["EASL_TEST_EXIT_AFTER_UPDATE_SWAP"] = "1"
                helper.environment = environment
            }
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            guard (try? helper.run()) != nil else { return -1 }
            helper.waitUntilExit()
            return helper.terminationStatus
        }
        #expect(status == expectedStatus)
        return (try? String(contentsOf: staging.result, encoding: .utf8)).flatMap(AppUpdate.Outcome.init(result:))
    }
}

struct UpdateHelperTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("easl-helper-\(UUID().uuidString)", isDirectory: true)
    var applications: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    var app: URL { applications.appendingPathComponent("easl.app", isDirectory: true) }
    let staging: AppUpdate.Staging

    init() throws {
        staging = try AppUpdate.Staging(updates: root.appendingPathComponent("updates", isDirectory: true), version: "0.2.3")
    }
    var relaunched: URL { root.appendingPathComponent("relaunched") }

    func runHelper() async throws -> AppUpdate.Outcome? {
        try await TestBundle.runHelper(app: app, staging: staging, relaunched: relaunched)
    }

    @Test func theHelperRenamesTheNewAppInAndLeavesNoHiddenCopy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        // The installed bundle's metadata is not writable, though its parent permits renames.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)], ofItemAtPath: app.path)
        let oldDate = try FileManager.default.attributesOfItem(atPath: app.path)[.modificationDate] as? Date
        try await TestBundle.denyTimestampChanges(app)
        try TestBundle.make(staging.incoming(beside: app), version: "0.2.3", executable: Data("new".utf8))
        #expect(try await runHelper() == .installed)
        #expect(AppUpdate.bundleVersion(of: app) == "0.2.3")
        #expect(AppUpdate.bundleVersion(of: staging.previous) == "0.2.2")
        let backupDate = try FileManager.default.attributesOfItem(atPath: staging.previous.path)[.modificationDate] as? Date
        #expect(backupDate == oldDate, "replacement must not need to change the installed bundle's timestamp")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["easl.app"])
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
    }

    @Test func aSwapChildThatExitsAbnormallyAfterExchangeStillReportsInstalled() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        let incoming = staging.incoming(beside: app)
        try TestBundle.make(incoming, version: "0.2.3", executable: Data("new".utf8))
        let old = try TestBundle.snapshot(app)
        let new = try TestBundle.snapshot(incoming)
        let lease = try AppUpdate.StagingLease(incoming: incoming)
        let leaseURL = URL(fileURLWithPath: incoming.path + ".lease")
        #expect(try await TestBundle.runHelper(app: app, staging: staging, relaunched: relaunched, swapExitsAfterExchange: true) == .installed)
        #expect(try TestBundle.snapshot(app) == new)
        #expect(try TestBundle.snapshot(staging.previous) == old)
        #expect(!FileManager.default.fileExists(atPath: leaseURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["easl.app"])
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
        withExtendedLifetime(lease) {}
    }

    @Test func anAbnormalSwapChildKeepsTheOriginalProtectedWhenArchivingFails() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)], ofItemAtPath: app.path)
        let old = try TestBundle.snapshot(app)
        let incoming = staging.incoming(beside: app)
        try TestBundle.make(incoming, version: "0.2.3", executable: Data("new".utf8))
        let new = try TestBundle.snapshot(incoming)
        try files.createDirectory(at: staging.directory, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: staging.previous)
        let lease = try AppUpdate.StagingLease(incoming: incoming)
        #expect(try await TestBundle.runHelper(app: app, staging: staging, relaunched: relaunched, swapExitsAfterExchange: true) == .installed)
        #expect(try TestBundle.snapshot(app) == new)
        #expect(try TestBundle.snapshot(staging.backup(beside: app)) == old)
        #expect(files.fileExists(atPath: staging.protection(beside: app).path))
        #expect(!files.fileExists(atPath: incoming.path + ".lease"))
        #expect(AppUpdate.removeStaleLeftovers(beside: applications, running: app.lastPathComponent).isEmpty)
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
        withExtendedLifetime(lease) {}
    }

    @Test func aFailedSwapLeavesTheOriginalByteForByte() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        let original = try TestBundle.snapshot(app)
        let incoming = staging.incoming(beside: app)
        try TestBundle.make(incoming, version: "0.2.3")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: incoming.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: incoming.path) }
        guard case .unchanged? = try await runHelper() else {
            Issue.record("expected failed atomic exchange to leave installed app unchanged")
            return
        }
        #expect(try TestBundle.snapshot(app) == original)
        #expect(AppUpdate.bundleVersion(of: incoming) == "0.2.3")
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
    }

    @Test func atomicPrimitiveExchangesBothCompleteBundles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        let incoming = staging.incoming(beside: app)
        try TestBundle.make(incoming, version: "0.2.3", executable: Data("new".utf8))
        let old = try TestBundle.snapshot(app)
        let new = try TestBundle.snapshot(incoming)
        try AppUpdate.swapBundles(installed: app, incoming: incoming)
        #expect(try TestBundle.snapshot(app) == new)
        #expect(try TestBundle.snapshot(incoming) == old)
    }

    @Test func atomicPrimitiveFailureChangesNeitherBundle() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        let original = try TestBundle.snapshot(app)
        #expect(throws: (any Error).self) {
            try AppUpdate.swapBundles(installed: app, incoming: staging.incoming(beside: app))
        }
        #expect(try TestBundle.snapshot(app) == original)
    }

    @Test func aBackupInTheWayReplacesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        let original = try TestBundle.snapshot(app)
        try TestBundle.make(staging.incoming(beside: app), version: "0.2.3")
        try FileManager.default.createDirectory(at: staging.backup(beside: app), withIntermediateDirectories: true)
        let outcome = try await runHelper()
        guard case .unchanged? = outcome else {
            Issue.record("expected nothing replaced, got \(String(describing: outcome))")
            return
        }
        #expect(try TestBundle.snapshot(app) == original)
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
        #expect(!FileManager.default.fileExists(atPath: staging.protection(beside: app).path))
    }

    @Test func aProtectionInTheWayReplacesNothingAndIsNotReused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        let original = try TestBundle.snapshot(app)
        try TestBundle.make(staging.incoming(beside: app), version: "0.2.3")
        let protection = staging.protection(beside: app)
        try files.createDirectory(at: protection, withIntermediateDirectories: false)
        let sentinel = protection.appendingPathComponent("not-ours")
        try Data("keep".utf8).write(to: sentinel)
        let outcome = try await runHelper()
        guard case .unchanged? = outcome else {
            Issue.record("expected nothing replaced, got \(String(describing: outcome))")
            return
        }
        #expect(try TestBundle.snapshot(app) == original)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(!files.fileExists(atPath: staging.backup(beside: app).path))
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
    }

    @Test func aFailedExchangeLeavesTheInstalledBundleWholeAndRemovesItsProtection() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        let original = try TestBundle.snapshot(app)
        try TestBundle.make(staging.incoming(beside: app), version: "0.2.3")
        try files.setAttributes([.immutable: true], ofItemAtPath: app.path)
        defer { try? files.setAttributes([.immutable: false], ofItemAtPath: app.path) }
        let outcome = try await runHelper()
        guard case .unchanged? = outcome else {
            Issue.record("expected nothing replaced, got \(String(describing: outcome))")
            return
        }
        #expect(try TestBundle.snapshot(app) == original)
        #expect(!files.fileExists(atPath: staging.backup(beside: app).path))
        #expect(!files.fileExists(atPath: staging.protection(beside: app).path))
        #expect(AppUpdate.bundleVersion(of: staging.incoming(beside: app)) == "0.2.3")
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
    }


    @Test func anInstalledUpdateKeepsRollbackProtectionIfMovingItToStagingFails() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)], ofItemAtPath: app.path)
        let original = try TestBundle.snapshot(app)
        try await TestBundle.denyTimestampChanges(app)
        try TestBundle.make(staging.incoming(beside: app), version: "0.2.3")
        // A file at the archive destination refuses moving a directory there.
        let outcome = try await TestBundle.runHelper(app: app, staging: staging, relaunched: relaunched,
                                                     afterSwap: "printf blocked > \"$previous\"")
        let backup = staging.backup(beside: app)
        let protection = staging.protection(beside: app)
        #expect(outcome == .installed)
        #expect(AppUpdate.bundleVersion(of: app) == "0.2.3")
        #expect(try TestBundle.snapshot(backup) == original)
        #expect(try String(contentsOf: staging.previous, encoding: .utf8) == "blocked")
        #expect(AppUpdate.removeStaleLeftovers(beside: applications, running: app.lastPathComponent).isEmpty)
        #expect(files.fileExists(atPath: protection.path))
        let expired = Date().addingTimeInterval(AppUpdate.leftoverAge + 1)
        #expect(Set(AppUpdate.removeStaleLeftovers(beside: applications, running: app.lastPathComponent, now: expired))
                == Set([backup.lastPathComponent, protection.lastPathComponent]))
        #expect(try files.contentsOfDirectory(atPath: applications.path) == ["easl.app"])
    }

    @Test func interruptionOnEitherSideOfSwapKeepsCanonicalBundleUsable() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for after in [false, true] {
            let area = root.appendingPathComponent(after ? "after" : "before")
            let installed = area.appendingPathComponent("easl.app")
            let attempt = try AppUpdate.Staging(updates: area.appendingPathComponent("updates"), version: "0.2.3")
            let relaunched = area.appendingPathComponent("relaunched")
            try TestBundle.make(installed, version: "0.2.2", executable: Data("old".utf8))
            try TestBundle.make(attempt.incoming(beside: installed), version: "0.2.3", executable: Data("new".utf8))
            let result = try await TestBundle.runHelper(app: installed, staging: attempt, relaunched: relaunched,
                                                      beforeSwap: after ? "" : "kill -TERM $$",
                                                      afterSwap: after ? "kill -TERM $$" : "", expectedStatus: 1)
            #expect(result == (after ? .installed : .unchanged("helper interrupted")))
            #expect(AppUpdate.bundleVersion(of: installed) == (after ? "0.2.3" : "0.2.2"))
            #expect(try String(contentsOf: relaunched, encoding: .utf8) == installed.path)
        }
    }

    @Test func uncatchableInterruptionNeverRemovesCanonicalBundle() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for after in [false, true] {
            let area = root.appendingPathComponent(after ? "after" : "before")
            let installed = area.appendingPathComponent("easl.app")
            let attempt = try AppUpdate.Staging(updates: area.appendingPathComponent("updates"), version: "0.2.3")
            try TestBundle.make(installed, version: "0.2.2", executable: Data("old".utf8))
            let incoming = attempt.incoming(beside: installed)
            try TestBundle.make(incoming, version: "0.2.3", executable: Data("new".utf8))
            let old = try TestBundle.snapshot(installed)
            let new = try TestBundle.snapshot(incoming)
            let result = try await TestBundle.runHelper(app: installed, staging: attempt, relaunched: area.appendingPathComponent("relaunched"),
                                                      beforeSwap: after ? "" : "kill -KILL $$",
                                                      afterSwap: after ? "kill -KILL $$" : "", expectedStatus: 9)
            #expect(result == nil)
            #expect(try TestBundle.snapshot(installed) == (after ? new : old))
            #expect(try TestBundle.snapshot(incoming) == (after ? old : new))
        }
    }

    @Test func theResultFileSaysWhatHappened() {
        #expect(AppUpdate.Outcome(result: "installed\n") == .installed)
        #expect(AppUpdate.Outcome(result: "unchanged: x\n") == .unchanged("x"))
        #expect(AppUpdate.Outcome(result: "restored: x\n") == .restored("x"))
        #expect(AppUpdate.Outcome(result: "stranded: /Applications/.easl-previous-0.2.3.app\n") == .stranded("/Applications/.easl-previous-0.2.3.app"))
        #expect(AppUpdate.Outcome(result: "") == nil)
        #expect(AppUpdate.Outcome.installed.failure == nil)
        #expect(AppUpdate.Outcome.restored("x").failure != nil)
    }
}

/// `AppUpdate.prepareInstall` on real zips, signed ad hoc as a development instance's update is
/// (no Team ID, no Gatekeeper).
struct UpdateInstallTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("easl-install-\(UUID().uuidString)", isDirectory: true)
    var applications: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    var installed: URL { applications.appendingPathComponent("easl.app", isDirectory: true) }

    /// Zips `source` into a fresh staging folder; the release pins the zip's size and SHA-256.
    func stage(_ source: URL, keepParent: Bool) async throws -> (AppUpdate.Staging, LatestRelease) {
        let staging = try AppUpdate.Staging(updates: root.appendingPathComponent("updates", isDirectory: true), version: "0.2.3")
        try staging.prepare()
        let zipped = try await RemoteHost.run("/usr/bin/ditto", ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [source.path, staging.zip.path], timeout: 60)
        #expect(zipped.status == 0, "\(zipped.errors)")
        let size = try FileManager.default.attributesOfItem(atPath: staging.zip.path)[.size] as? Int ?? 0
        let release = LatestRelease(version: AppVersion("0.2.3")!, url: URL(string: "https://example.com/easl-0.2.3.zip")!,
                                    sha256: try AppUpdate.sha256(of: staging.zip), size: size, notes: URL(string: "https://example.com/notes")!)
        return (staging, release)
    }

    @Test func aZipWhoseAppIsASymlinkIsRefusedBeforeAnythingMoves() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(installed, version: "0.2.2", executable: Data("old".utf8))
        let original = try TestBundle.snapshot(installed)
        // A valid app beside an `easl.app` that only points to it.
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try TestBundle.make(payload.appendingPathComponent("payload.app"), version: "0.2.3")
        try await TestBundle.sign(payload.appendingPathComponent("payload.app"))
        try FileManager.default.createSymbolicLink(atPath: payload.appendingPathComponent("easl.app").path, withDestinationPath: "payload.app")
        let (staging, release) = try await stage(payload, keepParent: false)

        let error = await #expect(throws: AppUpdate.InstallProblem.self) {
            try await AppUpdate.prepareInstall(staging, release: release, replacing: installed, team: nil, gatekeeper: false)
        }
        #expect(error?.kind == "notABundle")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: staging.app.path)) == "payload.app", "unpacked as a symlink")
        #expect(try TestBundle.snapshot(installed) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["easl.app"])
    }

    @Test func theVerifiedCopyBesideTheAppIsWhatTheHelperInstalls() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(installed, version: "0.2.2", executable: Data("old".utf8))
        let new = root.appendingPathComponent("new/easl.app", isDirectory: true)
        try TestBundle.make(new, version: "0.2.3")
        try await TestBundle.sign(new)
        // The release's own date, long past: only prepareInstall's refresh makes the copy fresh.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)], ofItemAtPath: new.path)
        let (staging, release) = try await stage(new, keepParent: true)

        let incoming = try await AppUpdate.prepareInstall(staging, release: release, replacing: installed, team: nil, gatekeeper: false)
        #expect(incoming == staging.incoming(beside: installed))
        let copied = try FileManager.default.attributesOfItem(atPath: incoming.path)[.modificationDate] as? Date
        #expect(copied.map { -$0.timeIntervalSinceNow < AppUpdate.leftoverAge } == true, "dated now, not the release's date")
        #expect(AppUpdate.bundleVersion(of: incoming) == "0.2.3")
        #expect(AppUpdate.bundleVersion(of: installed) == "0.2.2", "nothing replaced before easl quits")
        #expect(try TestBundle.snapshot(incoming) == TestBundle.snapshot(new))

        let relaunched = root.appendingPathComponent("relaunched")
        #expect(try await TestBundle.runHelper(app: installed, staging: staging, relaunched: relaunched) == .installed)
        #expect(try TestBundle.snapshot(installed) == TestBundle.snapshot(new))
        #expect(AppUpdate.bundleVersion(of: staging.previous) == "0.2.2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["easl.app"])
    }

    @Test func aVersionOtherThanLatestJSONsIsRefusedAndLeavesNoCopy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(installed, version: "0.2.2", executable: Data("old".utf8))
        let new = root.appendingPathComponent("new/easl.app", isDirectory: true)
        try TestBundle.make(new, version: "0.2.4")
        try await TestBundle.sign(new)
        let (staging, release) = try await stage(new, keepParent: true)

        let error = await #expect(throws: AppUpdate.InstallProblem.self) {
            try await AppUpdate.prepareInstall(staging, release: release, replacing: installed, team: nil, gatekeeper: false)
        }
        #expect(error?.kind == "version")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["easl.app"])
    }

    @Test func anAppFromAnotherTeamIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(installed, version: "0.2.2", executable: Data("old".utf8))
        let new = root.appendingPathComponent("new/easl.app", isDirectory: true)
        try TestBundle.make(new, version: "0.2.3")
        try await TestBundle.sign(new)
        let (staging, release) = try await stage(new, keepParent: true)

        let error = await #expect(throws: AppUpdate.InstallProblem.self) {
            try await AppUpdate.prepareInstall(staging, release: release, replacing: installed, team: "RPJT9J47TS", gatekeeper: false)
        }
        #expect(error?.kind == "team")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["easl.app"])
    }

    @Test func anUnsignedAppIsRefusedWithoutChangingTheRunningVersion() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(installed, version: "0.2.2", executable: Data("old".utf8))
        let original = try TestBundle.snapshot(installed)
        let new = root.appendingPathComponent("new/easl.app", isDirectory: true)
        try TestBundle.make(new, version: "0.2.3")
        let (staging, release) = try await stage(new, keepParent: true)
        let error = await #expect(throws: AppUpdate.InstallProblem.self) {
            try await AppUpdate.prepareInstall(staging, release: release, replacing: installed, team: nil, gatekeeper: false)
        }
        #expect(error?.kind == "signature")
        #expect(try TestBundle.snapshot(installed) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["easl.app"])
    }

    @Test func tamperingWithTheStagedCopyIsRefusedBeforeInstallation() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(installed, version: "0.2.2", executable: Data("old".utf8))
        let original = try TestBundle.snapshot(installed)
        let new = root.appendingPathComponent("new/easl.app", isDirectory: true)
        try TestBundle.make(new, version: "0.2.3")
        try await TestBundle.sign(new)
        let (staging, release) = try await stage(new, keepParent: true)
        let incoming = try await AppUpdate.prepareInstall(staging, release: release, replacing: installed, team: nil, gatekeeper: false)
        try Data("tampered".utf8).write(to: incoming.appendingPathComponent("Contents/MacOS/Easl"))
        let error = await #expect(throws: AppUpdate.InstallProblem.self) {
            try await AppUpdate.verify(incoming, release: release, team: nil, gatekeeper: false)
        }
        #expect(error?.kind == "signature")
        #expect(try TestBundle.snapshot(installed) == original)
        #expect(AppUpdate.bundleVersion(of: installed) == "0.2.2")
    }
}

struct UpdatePhaseTests {
    let release = LatestRelease(version: AppVersion("0.2.3")!, url: URL(string: "https://example.com/easl-0.2.3.zip")!,
                                sha256: String(repeating: "a", count: 64), size: 1, notes: URL(string: "https://example.com/notes")!)

    @Test func anUpdateRunsFromCheckToInstall() {
        var phase = UpdatePhase.idle
        let steps: [(UpdatePhase.Event, UpdatePhase)] = [
            (.check, .checking(offered: nil)), (.found(release), .available(release)), (.download, .downloading(release)),
            (.downloaded, .verifying(release)), (.verified, .ready(release)), (.install, .installing(release)),
        ]
        for (event, expected) in steps {
            guard let next = phase.after(event) else {
                Issue.record("\(event) from \(phase) was refused")
                return
            }
            #expect(next == expected)
            phase = next
        }
        #expect(phase.offered == release && phase.isUpdating)
    }

    @Test func aCheckWithNothingNewerGoesBackToIdle() {
        #expect(UpdatePhase.idle.after(.check)?.after(.upToDate) == .idle)
        #expect(UpdatePhase.idle.offered == nil && !UpdatePhase.idle.isUpdating)
    }

    @Test func aFailureKeepsTheOfferSoUpdateCanBeTriedAgain() {
        for phase in [UpdatePhase.downloading(release), .verifying(release), .ready(release), .installing(release)] {
            #expect(phase.after(.fail("no network")) == .failed("no network", offered: release))
        }
        let failed = UpdatePhase.failed("checksum mismatch", offered: release)
        #expect(failed.offered == release && !failed.isUpdating)
        #expect(failed.after(.download) == .downloading(release))
        #expect(failed.after(.check) == .checking(offered: release))
    }

    @Test func aCheckKeepsOfferingWhatTheLastOneFound() {
        let checking = UpdatePhase.available(release).after(.check)
        #expect(checking == .checking(offered: release) && checking?.offered == release)
        #expect(checking?.after(.fail("offline")) == .failed("offline", offered: release))
        #expect(checking?.after(.download) == .downloading(release), "Update while a check runs takes what's on offer")
        #expect(UpdatePhase.checking(offered: nil).after(.download) == nil)
        #expect(UpdatePhase.downloading(release).after(.found(release)) == nil, "a check's answer after Update is too late")
        #expect(UpdatePhase.idle.after(.check)?.after(.fail("offline")) == .failed("offline", offered: nil))
    }

    @Test func eventsThatCantHappenNowAreRefused() {
        #expect(UpdatePhase.idle.after(.download) == nil, "nothing on offer")
        #expect(UpdatePhase.failed("offline", offered: nil).after(.download) == nil)
        #expect(UpdatePhase.idle.after(.fail("x")) == nil)
        #expect(UpdatePhase.available(release).after(.install) == nil, "not downloaded or verified")
        #expect(UpdatePhase.verifying(release).after(.install) == nil, "not verified yet")
        #expect(UpdatePhase.checking(offered: nil).after(.check) == nil, "one check at a time")
        for busy in [UpdatePhase.downloading(release), .verifying(release), .ready(release), .installing(release)] {
            #expect(busy.after(.check) == nil, "no check while updating")
            #expect(busy.after(.download) == nil)
        }
    }
}

struct AutomaticUpdatePolicyTests {
    let release = LatestRelease(version: AppVersion("0.2.10")!, url: URL(string: "https://example.com/easl.zip")!,
                                sha256: String(repeating: "a", count: 64), size: 1, notes: URL(string: "https://example.com/notes")!)

    @Test func stagingDoesNotWaitForIdle() {
        #expect(AppUpdate.automaticAction(phase: .available(release), running: AppVersion("0.2.9")!,
                                         enabled: true, idleSeconds: 0) == .stage)
        #expect(AppUpdate.automaticAction(phase: .ready(release), running: AppVersion("0.2.9")!,
                                         enabled: true, idleSeconds: 0) == .none)
    }

    @Test func installationRequiresTenFullMinutesWithoutInput() {
        for seconds: TimeInterval in [0, 60, 599, 599.999, -.infinity, .infinity, .nan] {
            #expect(AppUpdate.automaticAction(phase: .ready(release), running: AppVersion("0.2.9")!,
                                             enabled: true, idleSeconds: seconds) == .none)
        }
        for seconds: TimeInterval in [600, 601, 3600] {
            #expect(AppUpdate.automaticAction(phase: .ready(release), running: AppVersion("0.2.9")!,
                                             enabled: true, idleSeconds: seconds) == .install)
        }
    }

    @Test func turningAutomaticUpdatesOffAlsoBlocksAnAlreadyVerifiedUpdate() {
        for phase in [UpdatePhase.available(release), .ready(release)] {
            #expect(AppUpdate.automaticAction(phase: phase, running: AppVersion("0.2.9")!,
                                             enabled: false, idleSeconds: 3600) == .none)
        }
        #expect(AppUpdate.automaticAction(phase: .ready(release), running: AppVersion("0.2.9")!,
                                         enabled: true, idleSeconds: 3600) == .install)
    }

    @Test func onlyANewerVersionCanBeStagedOrInstalled() {
        for phase in [UpdatePhase.available(release), .ready(release)] {
            for running in ["0.2.10", "0.2.10+build.8", "0.2.11", "1.0.0"] {
                #expect(AppUpdate.automaticAction(phase: phase, running: AppVersion(running)!,
                                                 enabled: true, idleSeconds: 600) == .none)
            }
        }
        #expect(AppUpdate.automaticAction(phase: .available(release), running: AppVersion("0.2.10-rc.1")!,
                                         enabled: true, idleSeconds: 600) == .stage)
        for running in ["0.2.7", "0.2.8"] {
            #expect(AppUpdate.automaticAction(phase: .available(release), running: AppVersion(running)!,
                                             enabled: true, idleSeconds: 0) == .stage)
        }
    }

    @Test func aRejectedArtifactDoesNotRetryOnEveryIdleSampleOrCheck() {
        #expect(AppUpdate.automaticAction(phase: .available(release), running: AppVersion("0.2.9")!,
                                         enabled: true, idleSeconds: 600, rejectedSHA256: release.sha256) == .none)
        #expect(AppUpdate.automaticAction(phase: .failed("bad signature", offered: release), running: AppVersion("0.2.9")!,
                                         enabled: true, idleSeconds: 600) == .none)
        #expect(AppUpdate.automaticAction(phase: .available(release), running: AppVersion("0.2.9")!,
                                         enabled: true, idleSeconds: 600, rejectedSHA256: String(repeating: "b", count: 64)) == .stage)
    }

    @Test func onlyVerifiedStagingCanBeInstalled() {
        for phase in [UpdatePhase.downloading(release), .verifying(release), .installing(release), .checking(offered: release)] {
            #expect(AppUpdate.automaticAction(phase: phase, running: AppVersion("0.2.9")!,
                                             enabled: true, idleSeconds: 600) == .none)
        }
        #expect(UpdatePhase.ready(release).installPending)
        #expect(UpdatePhase.ready(release).after(.install) == .installing(release))
        #expect(!UpdatePhase.available(release).installPending)
    }
}
