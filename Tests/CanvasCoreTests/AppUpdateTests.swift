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
    static func runHelper(app: URL, staging: AppUpdate.Staging, relaunched: URL, afterBackup: String = "") async throws -> AppUpdate.Outcome? {
        try FileManager.default.createDirectory(at: staging.directory, withIntermediateDirectories: true)
        let status = await offPool { () -> Int32 in
            let exited = Process()
            exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            guard (try? exited.run()) != nil else { return -1 }
            exited.waitUntilExit()
            let script = AppUpdate.helperScript(pid: exited.processIdentifier, app: app, staging: staging,
                                                relaunch: "printf %s \"$app\" > \(RemoteHost.quote(relaunched.path))", afterBackup: afterBackup)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", script]
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            guard (try? helper.run()) != nil else { return -1 }
            helper.waitUntilExit()
            return helper.terminationStatus
        }
        #expect(status == 0)
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

    @Test func aFailedSecondRenamePutsTheOriginalBackByteForByte() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try TestBundle.make(app, version: "0.2.2", executable: Data((0..<4096).map { _ in UInt8.random(in: 0...255) }))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)], ofItemAtPath: app.path)
        let oldDate = try FileManager.default.attributesOfItem(atPath: app.path)[.modificationDate] as? Date
        try await TestBundle.denyTimestampChanges(app)
        let original = try TestBundle.snapshot(app)
        let incoming = staging.incoming(beside: app)
        try TestBundle.make(incoming, version: "0.2.3")
        // An immutable folder can't be renamed: the second rename fails.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: incoming.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: incoming.path) }
        let outcome = try await runHelper()
        guard case .restored? = outcome else {
            Issue.record("expected the old app back, got \(String(describing: outcome))")
            return
        }
        #expect(try TestBundle.snapshot(app) == original)
        #expect(try FileManager.default.attributesOfItem(atPath: app.path)[.modificationDate] as? Date == oldDate)
        #expect(!FileManager.default.fileExists(atPath: staging.backup(beside: app).path))
        #expect(!FileManager.default.fileExists(atPath: staging.protection(beside: app).path))
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
    }

    @Test func cleanupAtTheFirstRenameKeepsRollbackThenTheHelperInstalls() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let oldDate = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        try files.setAttributes([.modificationDate: oldDate], ofItemAtPath: app.path)
        try await TestBundle.denyTimestampChanges(app)
        try TestBundle.make(staging.incoming(beside: app), version: "0.2.3")

        // Stop the actual shell at its first rename, clean beside it, then let it finish.
        // Both sides have finite bounds; on any test error the gate is released before unwind.
        let paused = root.appendingPathComponent("paused")
        let resume = root.appendingPathComponent("resume")
        let q = RemoteHost.quote
        let gate = """
        : > \(q(paused.path))
        count=0
        while [ ! -e \(q(resume.path)) ] && [ "$count" -lt 200 ]; do
          /bin/sleep 0.05
          count=$((count + 1))
        done
        [ -e \(q(resume.path)) ] || exit 1
        """
        async let outcome = TestBundle.runHelper(app: app, staging: staging, relaunched: relaunched, afterBackup: gate)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !files.fileExists(atPath: paused.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(files.fileExists(atPath: paused.path), "the helper must reach its real first rename")
            #expect(AppUpdate.removeStaleLeftovers(beside: applications, running: app.lastPathComponent).isEmpty)
            #expect(AppUpdate.bundleVersion(of: staging.backup(beside: app)) == "0.2.2", "cleanup must not take the helper's rollback")
        } catch {
            try? Data().write(to: resume)
            _ = try await outcome
            throw error
        }
        try Data().write(to: resume)
        let installed = try await outcome
        #expect(installed == .installed)
        #expect(AppUpdate.bundleVersion(of: app) == "0.2.3")
        #expect(AppUpdate.bundleVersion(of: staging.previous) == "0.2.2")
        #expect(!files.fileExists(atPath: staging.protection(beside: app).path))
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

    @Test func aFailedFirstRenameLeavesTheInstalledBundleWholeAndRemovesItsProtection() async throws {
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

    @Test func aStrandedRollbackKeepsItsProtectionAndIsNeverCleanedWhileRunning() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try TestBundle.make(app, version: "0.2.2", executable: Data("old".utf8))
        try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)], ofItemAtPath: app.path)
        let original = try TestBundle.snapshot(app)
        try await TestBundle.denyTimestampChanges(app)
        try TestBundle.make(staging.incoming(beside: app), version: "0.2.3")
        let outcome = try await TestBundle.runHelper(app: app, staging: staging, relaunched: relaunched, afterBackup: "/bin/mkdir \"$app\"")
        let backup = staging.backup(beside: app)
        #expect(outcome == .stranded(backup.path))
        #expect(try TestBundle.snapshot(backup) == original)
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == backup.path)
        #expect(AppUpdate.removeStaleLeftovers(beside: applications, running: app.lastPathComponent).isEmpty)
        #expect(files.fileExists(atPath: staging.protection(beside: app).path))
        let expired = Date().addingTimeInterval(AppUpdate.leftoverAge + 1)
        #expect(AppUpdate.removeStaleLeftovers(beside: applications, running: backup.lastPathComponent, now: expired)
                == [staging.incoming(beside: app).lastPathComponent])
        #expect(try TestBundle.snapshot(backup) == original)
        #expect(files.fileExists(atPath: staging.protection(beside: app).path))
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
                                                     afterBackup: "printf blocked > \"$previous\"")
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

    @Test func aUsersRelaunchOpensANewInstanceInFrontWithTheOldEnvironment() {
        let command = AppUpdate.relaunchCommand(environment: ["EASL_HOME": "/Users/me/my home", "EASL_UPDATE_URL": "https://easl.sh/latest.json"])
        #expect(command.hasSuffix("/usr/bin/open -n --env 'EASL_HOME=/Users/me/my home' --env EASL_UPDATE_URL=https://easl.sh/latest.json \"$app\""))
        #expect(!command.contains(" -g"))
        #expect(AppUpdate.relaunchCommand(environment: [:]).hasSuffix("/usr/bin/open -n \"$app\""))
        #expect(!AppUpdate.relaunchCommand(environment: ["EASL_NO_ACTIVATE": "0"]).contains(" -g"))
    }

    @Test func anInstanceThatMayNotActivateComesBackInTheBackground() {
        let command = AppUpdate.relaunchCommand(environment: ["EASL_HOME": "/Users/me/dev home", "EASL_NO_ACTIVATE": "1"])
        #expect(command.hasSuffix("/usr/bin/open -n -g --env 'EASL_HOME=/Users/me/dev home' --env EASL_NO_ACTIVATE=1 \"$app\""))
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
