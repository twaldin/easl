import CryptoKit
import Foundation

/// easl's in-app updater (easl › Check for Updates…, the titlebar Update button; docs/design.md
/// "Updates"): the release `latest.json` offers, whether it's newer than the running app, the
/// update's phases, the checks on what was downloaded, and the helper script that swaps the app
/// once it has quit. The app does the networking, the subprocesses and the windows
/// (`Sources/CanvasApp/Updater.swift`).
public enum AppUpdate {
    /// The release on offer, published beside the installer's pins by canvas-site
    /// (`src/pages/latest.json.ts`, from `RELEASE` in `src/brand/brand.ts`).
    public static let defaultSource = URL(string: "https://easl.sh/latest.json")!
    /// The first automatic check, this long after launch.
    public static let firstCheck: TimeInterval = 60
    /// Automatic checks after the first, while easl runs.
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The bundle a release zip holds, and the name the helper's moves keep.
    public static let appName = "easl.app"

    /// Where to read `latest.json`: `override` (`EASL_UPDATE_URL`, for testing against a local
    /// server) when set, else `defaultSource`. Nil when the override isn't an http(s) URL.
    public static func source(override: String?) -> URL? {
        guard let override, !override.isEmpty else { return defaultSource }
        guard let url = URL(string: override), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    /// Checks a downloaded zip against `latest.json` before anything unpacks it: its size, then
    /// its SHA-256.
    public static func checkDownload(_ file: URL, against release: LatestRelease) throws {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? -1
        guard size == release.size else { throw DownloadProblem.size(expected: release.size, got: size) }
        let sum = try sha256(of: file)
        guard sum == release.sha256 else { throw DownloadProblem.checksum(expected: release.sha256, got: sum) }
    }

    /// A file's SHA-256 in lowercase hex, read 1 MiB at a time.
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

    /// An app bundle's `CFBundleShortVersionString`, read from its Info.plist (never `Bundle`'s
    /// cache).
    public static func bundleVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// One update's files, in `<updates>/<version>/` (the app's support directory's `updates`;
    /// never `/tmp`). Deleted at the next launch, except a bundle easl runs from.
    public struct Staging: Equatable, Sendable {
        public let directory: URL
        public let version: String

        public init(updates: URL, version: String) {
            self.version = version
            directory = updates.appendingPathComponent(version, isDirectory: true)
        }

        /// The downloaded zip.
        public var zip: URL { directory.appendingPathComponent("easl-\(version).zip") }
        /// Where `ditto -x -k` unpacks it.
        public var unpacked: URL { directory.appendingPathComponent("unpacked", isDirectory: true) }
        /// The new app, verified here before the helper moves it into place.
        public var app: URL { unpacked.appendingPathComponent(AppUpdate.appName, isDirectory: true) }
        /// Where the helper moves the app it replaces.
        public var previous: URL { directory.appendingPathComponent("previous.app", isDirectory: true) }
        /// The helper's one-line outcome (`Outcome`), which the next launch reports.
        public var result: URL { directory.appendingPathComponent("result") }
        /// The helper's output.
        public var log: URL { directory.appendingPathComponent("helper.log") }
    }

    /// What the helper did, from its `result` file.
    public enum Outcome: Equatable, Sendable {
        /// The new version is in place.
        case installed
        /// Nothing was replaced, or the old version was put back; the reason, for the user.
        case failed(String)

        public init?(result text: String) {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "installed" {
                self = .installed
            } else if line.hasPrefix("failed: ") {
                self = .failed(String(line.dropFirst(8)))
            } else {
                return nil
            }
        }
    }

    /// The detached helper's `/bin/sh` script. It waits for `pid` (the app) to exit, moves `app`
    /// aside to `staging.previous` and `staging.app` into its place, writes the outcome to
    /// `staging.result` and runs `relaunch`, a shell command that opens `"$app"`: the new
    /// version, or the old one when a move failed (put back in place, or, if even that failed,
    /// where it was moved aside). `relaunch` is `relaunchCommand` in the app; tests pass their own.
    public static func helperScript(pid: Int32, app: URL, staging: Staging, relaunch: String) -> String {
        let q = RemoteHost.quote
        return """
        pid=\(pid)
        app=\(q(app.path))
        new=\(q(staging.app.path))
        previous=\(q(staging.previous.path))
        result=\(q(staging.result.path))
        while kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$previous"
        if ! err=$(/bin/mv "$app" "$previous" 2>&1); then
          printf "failed: couldn't move %s aside (%s); nothing was replaced\\n" "$app" "$err" > "$result"
        elif ! err=$(/bin/mv "$new" "$app" 2>&1); then
          # What a move across volumes left half-copied. mv into a directory that still exists
          # would nest the old app inside it, so that counts as a failed restore.
          /bin/rm -rf "$app"
          if [ ! -e "$app" ] && /bin/mv "$previous" "$app" 2>/dev/null; then
            printf "failed: couldn't move the new version to %s (%s); the old version is back\\n" "$app" "$err" > "$result"
          else
            printf "failed: couldn't move the new version to %s (%s) or put the old one back, which is at %s\\n" "$app" "$err" "$previous" > "$result"
            app=$previous
          fi
        else
          echo installed > "$result"
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
/// metadata (`+…`, ignored), compared as semantic versions: numbers numerically (0.2.10 is
/// newer than 0.2.9; missing numbers are 0, so 0.3 is 0.3.0) and a pre-release before its
/// release.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let prerelease: [String]
    /// The text it was read from.
    public let description: String

    public init?(_ text: String) {
        var core = Substring(text)
        if let plus = core.firstIndex(of: "+") { core = core[..<plus] }
        var prerelease: [String] = []
        if let dash = core.firstIndex(of: "-") {
            prerelease = core[core.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
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

    /// What's wrong with a `latest.json`.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notJSON
        case missing(String)
        case invalid(String, String)

        public var description: String {
            switch self {
            case .notJSON: "latest.json isn't a JSON object"
            case let .missing(field): "latest.json has no \(field)"
            case let .invalid(field, why): "latest.json's \(field) \(why)"
            }
        }
    }

    /// Reads `latest.json`. Every field is required. `url` must be https (http only to this Mac,
    /// for a test server: `EASL_UPDATE_URL`), `sha256` 64 hex digits, `size` a positive whole
    /// number of bytes; fields it doesn't know are ignored.
    public static func decode(_ data: Data) throws -> LatestRelease {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.dataCorrupted(context) {
            guard let field = context.codingPath.first?.stringValue else { throw Problem.notJSON }
            throw Problem.invalid(field, "has the wrong type")
        } catch {
            throw Problem.notJSON
        }
        guard let versionText = raw.version else { throw Problem.missing("version") }
        guard let version = AppVersion(versionText) else { throw Problem.invalid("version", "isn't a version: \(versionText)") }
        guard let urlText = raw.url else { throw Problem.missing("url") }
        let url = try download(urlText)
        guard let sha = raw.sha256 else { throw Problem.missing("sha256") }
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw Problem.invalid("sha256", "isn't 64 hex digits") }
        guard let bytes = raw.size else { throw Problem.missing("size") }
        // Any JSON number decodes (JSONDecoder names no field when 1.5 won't fit an Int).
        guard bytes > 0, bytes == bytes.rounded(), bytes < 1e15 else { throw Problem.invalid("size", "isn't a positive whole number of bytes") }
        let size = Int(bytes)
        guard let notesText = raw.notes else { throw Problem.missing("notes") }
        guard let notes = URL(string: notesText), ["http", "https"].contains(notes.scheme?.lowercased() ?? ""), notes.host != nil else {
            throw Problem.invalid("notes", "isn't a web address: \(notesText)")
        }
        return LatestRelease(version: version, url: url, sha256: sha.lowercased(), size: size, notes: notes)
    }

    private static func download(_ text: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { throw Problem.invalid("url", "isn't a web address: \(text)") }
        let host = url.host?.lowercased() ?? ""
        if scheme == "https", !host.isEmpty { return url }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) { return url }
        throw Problem.invalid("url", "isn't https: \(text)")
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
    /// The zip's size and SHA-256, unpacking it, the new app's signature, Team ID, Gatekeeper's
    /// verdict and version.
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
