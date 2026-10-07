import Foundation
import Testing
import CanvasCore

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
        #expect(throws: LatestRelease.Problem.invalid("size", "has the wrong type")) { try decode { $0["size"] = "12 MB" } }
        #expect(throws: LatestRelease.Problem.invalid("size", "isn't a positive whole number of bytes")) { try decode { $0["size"] = 1.5 } }
        #expect(throws: LatestRelease.Problem.invalid("version", "has the wrong type")) { try decode { $0["version"] = 3 } }
        #expect(throws: LatestRelease.Problem.invalid("version", "isn't a version: v0.2.3")) { try decode { $0["version"] = "v0.2.3" } }
        #expect(throws: LatestRelease.Problem.invalid("sha256", "isn't 64 hex digits")) { try decode { $0["sha256"] = "6b0029f1" } }
        #expect(throws: LatestRelease.Problem.invalid("sha256", "isn't 64 hex digits")) { try decode { $0["sha256"] = String(Self.sha.dropLast()) + "g" } }
        #expect(throws: LatestRelease.Problem.invalid("size", "isn't a positive whole number of bytes")) { try decode { $0["size"] = 0 } }
        #expect(throws: LatestRelease.Problem.invalid("size", "isn't a positive whole number of bytes")) { try decode { $0["size"] = -3 } }
        #expect(throws: LatestRelease.Problem.invalid("notes", "isn't a web address: release notes")) { try decode { $0["notes"] = "release notes" } }
    }

    @Test func theZipComesOverHTTPSOrFromThisMac() throws {
        #expect(throws: LatestRelease.Problem.invalid("url", "isn't https: http://easl.sh/easl.zip")) { try decode { $0["url"] = "http://easl.sh/easl.zip" } }
        #expect(throws: LatestRelease.Problem.invalid("url", "isn't https: file:///tmp/easl.zip")) { try decode { $0["url"] = "file:///tmp/easl.zip" } }
        #expect(throws: LatestRelease.Problem.invalid("url", "isn't a web address: easl.zip")) { try decode { $0["url"] = "easl.zip" } }
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

struct UpdateHelperTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("easl-helper-\(UUID().uuidString)", isDirectory: true)
    var app: URL { root.appendingPathComponent("Applications/easl.app", isDirectory: true) }
    var staging: AppUpdate.Staging { AppUpdate.Staging(updates: root.appendingPathComponent("updates", isDirectory: true), version: "0.2.3") }
    var relaunched: URL { root.appendingPathComponent("relaunched") }

    func bundle(_ url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    /// Runs the helper for a process that has already exited, relaunching by writing `"$app"`
    /// to `relaunched`.
    func runHelper() async throws {
        let app = app, staging = staging, relaunched = relaunched
        let status = await offPool { () -> Int32 in
            let exited = Process()
            exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            guard (try? exited.run()) != nil else { return -1 }
            exited.waitUntilExit()
            let script = AppUpdate.helperScript(pid: exited.processIdentifier, app: app, staging: staging,
                                                relaunch: "printf %s \"$app\" > \(RemoteHost.quote(relaunched.path))")
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", script]
            guard (try? helper.run()) != nil else { return -1 }
            helper.waitUntilExit()
            return helper.terminationStatus
        }
        #expect(status == 0)
    }

    @Test func theHelperSwapsTheAppAndRelaunchesTheNewOne() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try bundle(app, version: "0.2.2")
        try bundle(staging.app, version: "0.2.3")
        try await runHelper()
        #expect(AppUpdate.bundleVersion(of: app) == "0.2.3")
        #expect(AppUpdate.bundleVersion(of: staging.previous) == "0.2.2")
        #expect(!FileManager.default.fileExists(atPath: staging.app.path))
        #expect(AppUpdate.Outcome(result: try String(contentsOf: staging.result, encoding: .utf8)) == .installed)
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
    }

    @Test func aFailedMovePutsTheOldAppBackAndRelaunchesIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try bundle(app, version: "0.2.2")
        // No new app staged: the second move fails.
        try FileManager.default.createDirectory(at: staging.directory, withIntermediateDirectories: true)
        try await runHelper()
        #expect(AppUpdate.bundleVersion(of: app) == "0.2.2")
        #expect(!FileManager.default.fileExists(atPath: staging.previous.path))
        let outcome = AppUpdate.Outcome(result: try String(contentsOf: staging.result, encoding: .utf8))
        guard case let .failed(reason)? = outcome else {
            Issue.record("expected a failure, got \(String(describing: outcome))")
            return
        }
        #expect(reason.hasSuffix("the old version is back"), "\(reason)")
        #expect(try String(contentsOf: relaunched, encoding: .utf8) == app.path)
    }

    @Test func theRelaunchOpensANewInstanceWithTheOldEnvironmentNeverInTheBackground() {
        let command = AppUpdate.relaunchCommand(environment: ["EASL_HOME": "/Users/me/dev home", "EASL_NO_ACTIVATE": "1"])
        #expect(command.hasSuffix("/usr/bin/open -n --env 'EASL_HOME=/Users/me/dev home' --env EASL_NO_ACTIVATE=1 \"$app\""))
        #expect(!command.contains(" -g"))
        #expect(AppUpdate.relaunchCommand(environment: [:]).hasSuffix("/usr/bin/open -n \"$app\""))
    }

    @Test func theResultFileSaysWhatHappened() {
        #expect(AppUpdate.Outcome(result: "installed\n") == .installed)
        #expect(AppUpdate.Outcome(result: "failed: couldn't move x aside (denied); nothing was replaced\n") == .failed("couldn't move x aside (denied); nothing was replaced"))
        #expect(AppUpdate.Outcome(result: "") == nil)
    }
}
