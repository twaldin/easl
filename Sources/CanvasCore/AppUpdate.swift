import CryptoKit
import Foundation
import Security

/// easl's in-app updater (easl › Check for Updates…, the titlebar Update button; docs/design.md
/// "Updates"): the release `latest.json` offers, whether it's newer than the running app, the
/// update's phases, the checks on what was downloaded and the copy that gets installed, and the
/// helper script that swaps the app once it has quit. The app does the networking, the helper's
/// launch and the windows (`Sources/CanvasApp/Updater.swift`).
public enum AppUpdate {
    /// The release on offer, published beside the installer's pins by canvas-site
    /// (`src/pages/latest.json.ts`, from `RELEASE` in `src/brand/brand.ts`).
    public static let defaultSource = URL(string: "https://easl.sh/latest.json")!
    /// The first automatic check, this long after launch.
    public static let firstCheck: TimeInterval = 60
    /// Automatic checks after the first, while easl runs.
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The bundle a release zip holds.
    public static let appName = "easl.app"
    /// The verified copy beside the installed app, `<prefix><version>.app`, that the helper
    /// renames into its place.
    static let incomingPrefix = ".easl-update-"
    /// The installed app, renamed aside by the helper, `<prefix><version>.app`.
    static let backupPrefix = ".easl-previous-"

    /// Where to read `latest.json`: `override` (`EASL_UPDATE_URL`, for testing against a local
    /// server) when set, else `defaultSource`. Nil when the override isn't an http(s) URL.
    public static func source(override: String?) -> URL? {
        guard let override, !override.isEmpty else { return defaultSource }
        guard let url = URL(string: override), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    /// Checks a downloaded zip against `latest.json` before anything unpacks it: its size, then
    /// its SHA-256. Blocking.
    public static func checkDownload(_ file: URL, against release: LatestRelease) throws {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? -1
        guard size == release.size else { throw DownloadProblem.size(expected: release.size, got: size) }
        let sum = try sha256(of: file)
        guard sum == release.sha256 else { throw DownloadProblem.checksum(expected: release.sha256, got: sum) }
    }

    /// A file's SHA-256 in lowercase hex, read 1 MiB at a time. Blocking.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What's wrong with a downloaded zip (`checkDownload`).
    public enum DownloadProblem: Error, Equatable, CustomStringConvertible {
        case size(expected: Int, got: Int)
        case checksum(expected: String, got: String)

        public var description: String {
            switch self {
            case let .size(expected, got): "the download is \(got) bytes, not the \(expected) latest.json gives"
            case let .checksum(expected, got): "the download's SHA-256 is \(got), not the \(expected) latest.json gives"
            }
        }
    }

    /// Why the new app isn't installed. Each stops the update before easl quits, with nothing
    /// replaced.
    public enum InstallProblem: Error, Equatable, CustomStringConvertible {
        /// The update's folder wouldn't be a direct child of `updates/` (symlinks resolved).
        case outsideUpdates(String)
        /// Nothing at the path: the zip has no `easl.app`.
        case noApp(String)
        /// The path is a symlink or a file, not an app bundle's folder.
        case notABundle(String)
        case unpack(String)
        case signature(String)
        /// The new app's Team ID isn't the running app's (nil: signed ad hoc).
        case team(expected: String?, got: String?)
        case gatekeeper(String)
        case version(expected: String, got: String?)
        /// Copying the verified app beside the installed one failed.
        case copy(String)
        case quarantine(String)
        /// Another easl process runs from the bundle the update would replace (its path).
        case otherInstance(String)

        public var description: String {
            switch self {
            case let .outsideUpdates(path): "the update's folder would be outside easl's updates folder (\(path))"
            case let .noApp(path): "there's no \(AppUpdate.appName) at \(path)"
            case let .notABundle(path): "\(path) is a symlink or a file, not an app"
            case let .unpack(detail): "couldn't unpack the zip: \(detail)"
            case let .signature(detail): "the new app's signature doesn't verify: \(detail)"
            case .team(nil, let got?): "this easl isn't signed with a Developer ID (a build from source?), so it can't take an app signed by team \(got)"
            case .team(let expected?, nil): "the new app isn't signed by easl's team (\(expected))"
            case let .team(expected, got): "the new app is signed by team \(got ?? "none"), not easl's (\(expected ?? "none"))"
            case let .gatekeeper(detail): "Gatekeeper doesn't accept the new app: \(detail)"
            case let .version(expected, got): "the zip holds easl \(got ?? "of no version"), not \(expected)"
            case let .copy(detail): "couldn't copy the new app beside this one: \(detail)"
            case let .quarantine(detail): "couldn't clear the new app's quarantine flag: \(detail)"
            case let .otherInstance(path): "quit the other easl running from \(path) first"
            }
        }
    }

    /// An app bundle's `CFBundleShortVersionString`, read from its Info.plist (never `Bundle`'s
    /// cache). Blocking.
    public static func bundleVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// One update's files, in `<updates>/<version>/` (the app's support directory's `updates`;
    /// never `/tmp`), and the two hidden names beside the installed app the helper renames
    /// between, unique to this update (`transaction`): two instances on other homes running one
    /// bundle never share them. Deleted at the next launch, except a bundle easl runs from.
    public struct Staging: Equatable, Sendable {
        public let updates: URL
        public let directory: URL
        public let version: String
        /// A UUID naming this update's hidden copies.
        public let transaction: String

        /// Refuses a `version` that isn't one plain path component, so `directory` names a child
        /// of `updates` (a version `AppVersion` reads always is one).
        public init(updates: URL, version: String, transaction: UUID = UUID()) throws {
            guard !version.isEmpty, version != ".", version != "..", !version.contains("/"), !version.contains("\0") else {
                throw InstallProblem.outsideUpdates(updates.appendingPathComponent(version).path)
            }
            self.updates = updates
            self.version = version
            self.transaction = transaction.uuidString.lowercased()
            directory = updates.appendingPathComponent(version, isDirectory: true)
        }

        /// The downloaded zip.
        public var zip: URL { directory.appendingPathComponent("easl-\(version).zip") }
        /// Where `ditto -x -k` unpacks it.
        public var unpacked: URL { directory.appendingPathComponent("unpacked", isDirectory: true) }
        /// The new app as unpacked, verified before it's copied beside the installed one.
        public var app: URL { unpacked.appendingPathComponent(AppUpdate.appName, isDirectory: true) }
        /// Where the helper moves the replaced app once the new one is in place.
        public var previous: URL { directory.appendingPathComponent("previous.app", isDirectory: true) }
        /// The helper's outcome (`Outcome`), which the next launch reports.
        public var result: URL { directory.appendingPathComponent("result") }
        /// The helper's output.
        public var log: URL { directory.appendingPathComponent("helper.log") }

        /// The verified copy of the new app beside `installed`, on its volume, so the helper only
        /// ever renames: `.easl-update-<version>-<transaction>.app`.
        public func incoming(beside installed: URL) -> URL {
            installed.deletingLastPathComponent().appendingPathComponent("\(AppUpdate.incomingPrefix)\(version)-\(transaction).app", isDirectory: true)
        }

        /// Where the helper renames `installed` while the new app takes its name:
        /// `.easl-previous-<version>-<transaction>.app`.
        public func backup(beside installed: URL) -> URL {
            installed.deletingLastPathComponent().appendingPathComponent("\(AppUpdate.backupPrefix)\(version)-\(transaction).app", isDirectory: true)
        }

        /// Empties the folder for a new download. Before deleting or creating anything it checks
        /// that the folder, symlinks resolved, is a direct child of `updates`, and again once
        /// it's made. Blocking: call it off the main thread.
        public func prepare() throws {
            let files = FileManager.default
            try files.createDirectory(at: updates, withIntermediateDirectories: true)
            try requireInside()
            if AppUpdate.exists(directory) { try files.removeItem(at: directory) }
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            try requireInside()
        }

        private func requireInside() throws {
            guard let root = AppUpdate.realPath(updates) else { throw InstallProblem.outsideUpdates(directory.path) }
            guard AppUpdate.exists(directory) else { return }
            guard let real = AppUpdate.realPath(directory), (real as NSString).deletingLastPathComponent == root,
                  (real as NSString).lastPathComponent == version else {
                throw InstallProblem.outsideUpdates(directory.path)
            }
        }
    }

    /// A hidden copy an update leaves beside the installed app when it stops partway
    /// (`.easl-update-<version>-<uuid>.app`, `.easl-previous-<version>-<uuid>.app`).
    public static func isLeftover(_ name: String) -> Bool {
        for prefix in [incomingPrefix, backupPrefix] where name.hasPrefix(prefix) && name.hasSuffix(".app") {
            let rest = name.dropFirst(prefix.count).dropLast(4)
            guard rest.count > 37, UUID(uuidString: String(rest.suffix(36))) != nil, rest.dropLast(36).last == "-" else { return false }
            return AppVersion(String(rest.dropLast(37))) != nil
        }
        return false
    }

    /// How old a leftover must be before a launch deletes it: an update renames its copies within
    /// seconds, so one this old belongs to no update still running (another home's instance of
    /// the same bundle may be mid-update).
    public static let leftoverAge: TimeInterval = 60 * 60

    /// The leftovers in the installed app's folder a launch deletes: older than `leftoverAge`,
    /// and never `running`, the name of the bundle easl runs from.
    public static func staleLeftovers(_ files: [Housekeeping.File], running: String, now: Date) -> [String] {
        files.filter { isLeftover($0.name) && $0.name != running && now.timeIntervalSince($0.modified) >= leftoverAge }.map(\.name)
    }

    /// An easl process: its pid and the bundle it runs from.
    public struct RunningInstance: Equatable, Sendable {
        public var pid: Int32
        public var bundle: URL?

        public init(pid: Int32, bundle: URL?) {
            self.pid = pid
            self.bundle = bundle
        }
    }

    /// Another process than `me` running from `bundle` (paths compared with symlinks resolved):
    /// replacing the bundle under it would pull it from a running instance on another home.
    /// Blocking (resolves paths).
    public static func otherInstance(sharing bundle: URL, among instances: [RunningInstance], except me: Int32) -> RunningInstance? {
        func canonical(_ url: URL) -> String { realPath(url) ?? url.standardizedFileURL.path }
        let ours = canonical(bundle)
        return instances.first { $0.pid != me && $0.bundle.map(canonical) == ours }
    }

    /// What the helper did, from its `result` file.
    public enum Outcome: Equatable, Sendable {
        /// The new version is in place.
        case installed
        /// Nothing was replaced; what stopped it.
        case unchanged(String)
        /// The new version couldn't be renamed into place, so the old one was renamed back; why.
        case restored(String)
        /// Neither rename worked: the old app is at this path, and that's what was opened.
        case stranded(String)

        public init?(result text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "installed" {
                self = .installed
                return
            }
            for (prefix, outcome) in [("unchanged: ", Outcome.unchanged), ("restored: ", Outcome.restored), ("stranded: ", Outcome.stranded)]
            where text.hasPrefix(prefix) {
                self = outcome(String(text.dropFirst(prefix.count)))
                return
            }
            return nil
        }

        /// What the user is told about an update that didn't install; nil when it did.
        public var failure: String? {
            switch self {
            case .installed: nil
            case let .unchanged(detail): "nothing was replaced (\(detail))"
            case let .restored(detail): "the new version couldn't be moved into place (\(detail)), so the old version was put back"
            case let .stranded(path): "the new version couldn't be moved into place and the old version couldn't be put back: easl is at \(path); rename it to \(AppUpdate.appName)"
            }
        }
    }

    // MARK: verifying

    /// Everything before easl quits: checks the zip against `latest.json`, unpacks it, verifies
    /// the app it holds, copies that app beside `installed` (`Staging.incoming`, on the installed
    /// app's volume) and verifies the copy, which is what the helper installs. `team` is the
    /// running app's Team ID; `gatekeeper` false skips `spctl` (a development instance updating
    /// ad hoc to ad hoc). On any failure nothing beside `installed` is left. Returns the copy.
    public static func prepareInstall(_ staging: Staging, release: LatestRelease, replacing installed: URL, team: String?, gatekeeper: Bool) async throws -> URL {
        let zip = staging.zip, staged = staging.app
        try await blocking { try checkDownload(zip, against: release) }
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.unpacked.path], or: InstallProblem.unpack)
        try await verify(staged, release: release, team: team, gatekeeper: gatekeeper)
        // ditto gives a quarantined zip's flag to everything it unpacks.
        if try await blocking({ isQuarantined(zip) || isQuarantined(staged) }) { try await clearQuarantine(staged) }
        let incoming = staging.incoming(beside: installed)
        do {
            try await run("/usr/bin/ditto", [staged.path, incoming.path], or: InstallProblem.copy)
            // ditto keeps the release's dates; a launch deletes only leftovers an hour old.
            try await blocking { try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: incoming.path) }
            try await verify(incoming, release: release, team: team, gatekeeper: gatekeeper)
            if try await blocking({ isQuarantined(incoming) }) { try await clearQuarantine(incoming) }
        } catch {
            try? await blocking { if exists(incoming) { try FileManager.default.removeItem(at: incoming) } }
            throw error
        }
        return incoming
    }

    /// The new app is a real folder (not a symlink to one), its signature verifies
    /// (`codesign --verify --deep --strict`), its Team ID is `team`, Gatekeeper accepts it
    /// (`spctl --assess --type execute`, when `gatekeeper`) and its Info.plist version is
    /// exactly `latest.json`'s.
    public static func verify(_ app: URL, release: LatestRelease, team: String?, gatekeeper: Bool) async throws {
        try await blocking { try requireBundle(app) }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], or: InstallProblem.signature)
        let theirs = try await blocking { teamID(of: app) }
        guard theirs == team else { throw InstallProblem.team(expected: team, got: theirs) }
        if gatekeeper {
            try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], or: InstallProblem.gatekeeper)
        }
        let version = try await blocking { bundleVersion(of: app) }
        guard version == release.version.description else { throw InstallProblem.version(expected: release.version.description, got: version) }
    }

    /// `app` itself (not what a symlink there points to) is a folder.
    static func requireBundle(_ app: URL) throws {
        var info = stat()
        guard lstat(app.path, &info) == 0 else { throw InstallProblem.noApp(app.path) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw InstallProblem.notABundle(app.path) }
    }

    /// The Team ID `app` is signed with; nil when it's signed ad hoc or not at all. Blocking.
    public static func teamID(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return teamID(of: code)
    }

    /// This process's Team ID; nil when it's signed ad hoc (a build from source). Blocking.
    public static func runningTeamID() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code else { return nil }
        return teamID(of: code)
    }

    private static func teamID(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func isQuarantined(_ file: URL) -> Bool {
        getxattr(file.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Only after Gatekeeper has accepted the app: a pending first-launch prompt would block the
    /// relaunch (issue #60).
    private static func clearQuarantine(_ app: URL) async throws {
        try await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], or: InstallProblem.quarantine)
    }

    private static func run(_ executable: String, _ arguments: [String], or problem: (String) -> InstallProblem) async throws {
        let result = try await RemoteHost.run(executable, arguments, timeout: 120)
        guard result.status != 0 else { return }
        throw problem(RemoteHost.lastLine(result.errors) ?? RemoteHost.lastLine(result.output) ?? "exit status \(result.status)")
    }

    /// File work off the cooperative pool (docs/design.md, Performance).
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await offPool { Result { try work() } }.get()
    }

    /// Whether anything, a dangling symlink included, is at `url`.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: the helper

    /// The detached helper's `/bin/sh` script. It waits for `pid` (the app) to exit, then only
    /// renames within `app`'s folder: `app` to `staging.backup(beside:)` and
    /// `staging.incoming(beside:)` (the verified copy) to `app`; if the second rename fails, the
    /// backup goes straight back. A rename never copies, so a failure leaves each bundle whole;
    /// `mv` would move into a folder already at the destination, so each destination must be
    /// free first. After a success the backup goes to `staging.previous` (a failure there is
    /// harmless: the next launch deletes it). It writes the outcome to `staging.result`
    /// (`Outcome`) and runs `relaunch`, a shell command that opens `"$app"`: the new version, or
    /// the old one. `relaunch` is `relaunchCommand` in the app; tests pass their own.
    public static func helperScript(pid: Int32, app: URL, staging: Staging, relaunch: String) -> String {
        let q = RemoteHost.quote
        return """
        pid=\(pid)
        app=\(q(app.path))
        new=\(q(staging.incoming(beside: app).path))
        backup=\(q(staging.backup(beside: app).path))
        previous=\(q(staging.previous.path))
        result=\(q(staging.result.path))
        vacant() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
        while kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        if ! vacant "$backup"; then
          printf 'unchanged: %s is in the way\\n' "$backup" > "$result"
        elif ! err=$(/bin/mv "$app" "$backup" 2>&1); then
          printf 'unchanged: %s\\n' "$err" > "$result"
        # Dated now (a rename keeps the app's date): a launch deletes only leftovers an hour old.
        elif /usr/bin/touch "$backup"; vacant "$app" && err=$(/bin/mv "$new" "$app" 2>&1); then
          echo installed > "$result"
          /bin/mv "$backup" "$previous" || echo "easl: $backup stays until the next launch"
        elif vacant "$app" && /bin/mv "$backup" "$app"; then
          printf 'restored: %s\\n' "${err:-something else took $app}" > "$result"
        else
          printf 'stranded: %s\\n' "$backup" > "$result"
          app=$backup
        fi
        \(relaunch)

        """
    }

    /// How the helper opens easl again: registers the bundle at `"$app"` with LaunchServices
    /// (it caches Info.plist) and opens a new instance of it with `environment` (the old
    /// bundle's `LSEnvironment` and `EASL_HOME`, so an instance on its own home comes back on
    /// it). Never `open -g`: a Gatekeeper prompt for a background launch waits on a Space nobody
    /// sees and blocks every exec of the path (issue #60).
    public static func relaunchCommand(environment: [String: String]) -> String {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let env = environment.sorted { $0.key < $1.key }.map { " --env " + RemoteHost.quote("\($0.key)=\($0.value)") }.joined()
        return "\(lsregister) -f \"$app\" >/dev/null 2>&1\n/usr/bin/open -n\(env) \"$app\""
    }
}

/// A release version: `major[.minor[.patch…]]`, an optional pre-release (`-rc.1`) and build
/// metadata (`+build.7`, ignored in comparisons), each a dot-separated list of `[0-9A-Za-z-]`
/// identifiers as semantic versioning allows, so the text is always one plain path component.
/// Compared as semantic versions: numbers numerically (0.2.10 is newer than 0.2.9; missing
/// numbers are 0, so 0.3 is 0.3.0) and a pre-release before its release.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let prerelease: [String]
    /// The text it was read from.
    public let description: String

    public init?(_ text: String) {
        var core = Substring(text)
        if let plus = core.firstIndex(of: "+") {
            guard core[core.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false).allSatisfy(Self.isIdentifier) else { return nil }
            core = core[..<plus]
        }
        var prerelease: [String] = []
        if let dash = core.firstIndex(of: "-") {
            let identifiers = core[core.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy(Self.isIdentifier) else { return nil }
            prerelease = identifiers.map(String.init)
            core = core[..<dash]
        }
        var numbers: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers
        self.prerelease = prerelease
        description = text
    }

    /// A pre-release or build identifier: one or more of `[0-9A-Za-z-]`.
    private static func isIdentifier(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> ComparisonResult {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        // A release is newer than its pre-releases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r ? .orderedAscending : .orderedDescending
            // Numeric identifiers sort before alphanumeric ones.
            case (_?, nil): return .orderedAscending
            case (nil, _?): return .orderedDescending
            case (nil, nil): return left < right ? .orderedAscending : .orderedDescending
            }
        }
        if lhs.prerelease.count == rhs.prerelease.count { return .orderedSame }
        return lhs.prerelease.count < rhs.prerelease.count ? .orderedAscending : .orderedDescending
    }
}

/// The release `latest.json` offers: `{"version", "url", "sha256", "size", "notes"}` (canvas-site
/// `src/pages/latest.json.ts`). `url` is the release zip and `size` its bytes; `notes` is the
/// release page.
public struct LatestRelease: Equatable, Sendable {
    public var version: AppVersion
    public var url: URL
    /// Lowercase hex.
    public var sha256: String
    public var size: Int
    public var notes: URL

    public init(version: AppVersion, url: URL, sha256: String, size: Int, notes: URL) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.notes = notes
    }

    /// Whether it's a newer version than `running`, the app's `CFBundleShortVersionString`.
    public func isNewer(than running: AppVersion) -> Bool { version > running }

    /// What's wrong with a `latest.json`, by field.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notJSON
        case missing(String)
        case wrongType(String)
        /// The field's value breaks its rule (`rules`).
        case invalid(String)

        private static let rules = [
            "version": "isn't a version (like 0.2.3)", "url": "isn't an https address", "sha256": "isn't 64 hex digits",
            "size": "isn't a positive whole number of bytes", "notes": "isn't a web address",
        ]

        public var description: String {
            switch self {
            case .notJSON: "latest.json isn't a JSON object"
            case let .missing(field): "latest.json has no \(field)"
            case let .wrongType(field): "latest.json's \(field) has the wrong type"
            case let .invalid(field): "latest.json's \(field) \(Self.rules[field] ?? "isn't valid")"
            }
        }
    }

    /// Reads `latest.json`. Every field is required. `version` is a semantic version, `url` https
    /// (http only to this Mac, for a test server: `EASL_UPDATE_URL`), `sha256` 64 hex digits,
    /// `size` a positive whole number of bytes, `notes` a web address; fields it doesn't know are
    /// ignored.
    public static func decode(_ data: Data) throws -> LatestRelease {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.dataCorrupted(context) {
            guard let field = context.codingPath.first?.stringValue else { throw Problem.notJSON }
            throw Problem.wrongType(field)
        } catch {
            throw Problem.notJSON
        }
        guard let versionText = raw.version else { throw Problem.missing("version") }
        guard let version = AppVersion(versionText) else { throw Problem.invalid("version") }
        guard let urlText = raw.url else { throw Problem.missing("url") }
        guard let url = download(urlText) else { throw Problem.invalid("url") }
        guard let sha = raw.sha256 else { throw Problem.missing("sha256") }
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw Problem.invalid("sha256") }
        guard let bytes = raw.size else { throw Problem.missing("size") }
        // Any JSON number decodes (JSONDecoder names no field when 1.5 won't fit an Int).
        guard bytes > 0, bytes == bytes.rounded(), bytes < 1e15 else { throw Problem.invalid("size") }
        guard let notesText = raw.notes else { throw Problem.missing("notes") }
        guard let notes = URL(string: notesText), ["http", "https"].contains(notes.scheme?.lowercased() ?? ""), notes.host != nil else {
            throw Problem.invalid("notes")
        }
        return LatestRelease(version: version, url: url, sha256: sha.lowercased(), size: Int(bytes), notes: notes)
    }

    /// The zip's address: https, or http only to this Mac.
    private static func download(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        let host = url.host?.lowercased() ?? ""
        if scheme == "https", !host.isEmpty { return url }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) { return url }
        return nil
    }

    private struct Raw: Decodable {
        var version: String?
        var url: String?
        var sha256: String?
        var size: Double?
        var notes: String?
    }
}

/// Where an update is: idle → checking → available → downloading → verifying → ready →
/// installing, or failed with the reason. Each phase past checking carries the release on offer,
/// and so does a failure after one (the Update button stays, to try again).
public enum UpdatePhase: Equatable, Sendable {
    case idle
    /// `offered`: what an earlier check found, still offered while this one runs.
    case checking(offered: LatestRelease?)
    case available(LatestRelease)
    case downloading(LatestRelease)
    /// `AppUpdate.prepareInstall`: the zip's size and SHA-256, unpacking it, the new app's
    /// signature, Team ID, Gatekeeper's verdict and version, then the same for its copy beside
    /// the installed app.
    case verifying(LatestRelease)
    /// Verified and staged: next the helper starts and easl quits.
    case ready(LatestRelease)
    /// The helper is waiting for easl to quit.
    case installing(LatestRelease)
    case failed(String, offered: LatestRelease?)

    public enum Event: Equatable, Sendable {
        /// A check starts (automatic or easl › Check for Updates…).
        case check
        /// The check found a newer release.
        case found(LatestRelease)
        /// The check found nothing newer.
        case upToDate
        /// The user chose Update.
        case download
        case downloaded
        case verified
        case install
        case fail(String)
    }

    /// The phase after `event`, or nil when `event` can't happen now (a check while
    /// downloading, Update with nothing on offer).
    public func after(_ event: Event) -> UpdatePhase? {
        switch (self, event) {
        case (.idle, .check): .checking(offered: nil)
        case let (.available(release), .check): .checking(offered: release)
        case let (.failed(_, offered), .check): .checking(offered: offered)
        case let (.checking, .found(release)): .available(release)
        case (.checking, .upToDate): .idle
        // Update while a check runs takes what's on offer; the check's answer then comes too late.
        case let (.available(release), .download), let (.failed(_, release?), .download), let (.checking(release?), .download):
            .downloading(release)
        case let (.downloading(release), .downloaded): .verifying(release)
        case let (.verifying(release), .verified): .ready(release)
        case let (.ready(release), .install): .installing(release)
        case let (.checking(offered), .fail(reason)): .failed(reason, offered: offered)
        case let (.downloading(release), .fail(reason)), let (.verifying(release), .fail(reason)),
             let (.ready(release), .fail(reason)), let (.installing(release), .fail(reason)):
            .failed(reason, offered: release)
        default: nil
        }
    }

    /// The release the Update button offers.
    public var offered: LatestRelease? {
        switch self {
        case .idle: nil
        case let .checking(offered), let .failed(_, offered): offered
        case let .available(release), let .downloading(release), let .verifying(release), let .ready(release), let .installing(release): release
        }
    }

    /// Downloading, verifying, or about to quit: the update is under way.
    public var isUpdating: Bool {
        switch self {
        case .downloading, .verifying, .ready, .installing: true
        case .idle, .checking, .available, .failed: false
        }
    }
}
