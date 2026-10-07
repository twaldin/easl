import CanvasCore
import Foundation

/// Filesystem locations the app depends on (docs/contracts.md).
enum AppPaths {
    /// `EASL_HOME` relocates sockets and boards so a development build can run beside the
    /// installed app (docs/testing.md).
    static let support: URL = {
        if let home = ProcessInfo.processInfo.environment["EASL_HOME"] { return URL(fileURLWithPath: home, isDirectory: true) }
        return defaultSupport
    }()
    /// No `EASL_HOME`: the user's own instance, on the default support directory.
    static let isDefaultHome = ProcessInfo.processInfo.environment["EASL_HOME"] == nil
    private static let defaultSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Easl", isDirectory: true)
    static let apiSocket = support.appendingPathComponent("easl.sock").path
    static let cmuxSocket = support.appendingPathComponent("cmux.sock").path
    /// Held by the one instance running on this support directory (`InstanceLock`).
    static let instanceLock = support.appendingPathComponent("instance.lock").path
    /// Launching the app with CMUX_SOCKET_PASSWORD makes the cmux socket require it; terminal
    /// tiles get it in their environment. Without it the socket relies on its 0600 mode.
    static let cmuxPassword: String? = ProcessInfo.processInfo.environment["CMUX_SOCKET_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }
    static let boards = support.appendingPathComponent("boards", isDirectory: true)
    /// Lifecycle reports agent integrations spooled while the app was away, replayed as each
    /// board opens (`AgentReportSpool`). Beside the socket: integrations find it from `EASL_SOCKET`.
    static let agentReports = support.appendingPathComponent("agent-reports", isDirectory: true)
    /// Browser pages frozen by Snapshot to Image, kept with the board (beside its
    /// `<boardId>.json`), so they outlive the temp directory and the page changing.
    static func pageSnapshots(of board: BoardID) -> URL {
        boards.appendingPathComponent(board, isDirectory: true).appendingPathComponent("snapshots", isDirectory: true)
    }
    /// The composer's draft, sent prompts and extra targets for one board (`ComposerState`):
    /// this user's, kept beside the boards and never in the board file.
    static func composer(of board: BoardID) -> URL {
        support.appendingPathComponent("composer", isDirectory: true).appendingPathComponent("\(board).json")
    }
    /// Whether Help › Get Started still opens at launch (`GetStarted.Store`).
    static let getStarted = support.appendingPathComponent("get-started.json")
    /// Roots of the boards open as tabs, in tab order, reopened at the next launch.
    static let openBoards = support.appendingPathComponent("open-boards.json")
    /// The hosts File › Open Remote… connected to, newest first (`RemoteHost.Recents`): how to
    /// reach them, never their boards.
    static let remoteHosts = support.appendingPathComponent("remote-hosts.json")
    /// Testing only: the easl support directory to use on every remote host instead of its own
    /// (a development instance there, docs/testing.md).
    static let devRemoteHome: String? = ProcessInfo.processInfo.environment["EASL_DEV_REMOTE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    /// Where this client left each board's view (`SavedViewport`), one `<boardId>.json` per board.
    /// Client state, not the board's: a board is shared by every client that opens it.
    static func viewport(of board: BoardID) -> URL {
        support.appendingPathComponent("viewport", isDirectory: true).appendingPathComponent("\(board).json")
    }
    /// The app's own settings (`ChromeTextScale`).
    static let uiSettings = support.appendingPathComponent("ui-settings.json")
    /// easl › Check for Updates…'s downloads (`Updater`): one folder per version with the zip,
    /// the unpacked app, the app it replaced and the helper's result, deleted at the next launch.
    static let updates = support.appendingPathComponent("updates", isDirectory: true)

    /// A bundled asset from the repo's `resources/` directory (copied into the app bundle by
    /// scripts/bundle.sh), e.g. `asset("kit/mermaid.min.js")`.
    static func asset(_ relativePath: String) -> URL? {
        resources?.appendingPathComponent("resources").appendingPathComponent(relativePath)
    }

    /// Directory holding `schema/`, `bin/easl`, and `clients/python` — the repo when run via
    /// `swift run`, or the bundle's Resources once packaged. EASL_RESOURCES overrides.
    static let resources: URL? = {
        if let override = ProcessInfo.processInfo.environment["EASL_RESOURCES"] { return URL(fileURLWithPath: override) }
        if let bundled = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("schema/easl-api.json").path) {
            return bundled
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("schema/easl-api.json").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    /// GUI apps don't get the login shell's PATH, so look in the usual install locations too.
    static let zmx: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { "\($0)/zmx" } ?? []
        return (["/opt/homebrew/bin/zmx", "/usr/local/bin/zmx"] + path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Where zmx writes each session's log (`<session>.log`): `$XDG_STATE_HOME/zmx/logs`, else
    /// `~/.local/state/zmx/logs`. easl deletes its sessions' logs (`Housekeeping`).
    static let zmxLogs: URL = {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state", isDirectory: true)
        return state.appendingPathComponent("zmx/logs", isDirectory: true)
    }()
    static let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
}
