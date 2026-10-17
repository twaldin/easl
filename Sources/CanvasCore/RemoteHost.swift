import Foundation

/// Another machine whose easl boards this one opens (File › Open Remote…, docs/design.md
/// "Remote boards"). SSH is the only transport: the API is the host's socket relayed by
/// `ssh -T <host> nc -U <socket>`, and terminals attach to the host's zmx sessions over `ssh -t`.
/// A value with no board content, so recent hosts can be remembered as they are.
public struct RemoteHost: Codable, Hashable, Sendable {
    /// The tailnet name, as the user knows the machine ("twaldin-work").
    public var name: String
    /// What `ssh` connects to: the peer's tailnet DNS name (else its Tailscale address), an ssh
    /// config alias or `user@host`. Never a tailnet `HostName`, which isn't a DNS name and
    /// needn't be unique.
    public var sshTarget: String
    /// The host's easl socket.
    public var socketPath: String
    /// The host's temporary directory. A Mac app's zmx uses its GUI session's TMPDIR,
    /// found with `getconf DARWIN_USER_TEMP_DIR`, rather than an ssh session's.
    public var tmpdir: String
    /// The host's `easl` CLI.
    public var easlBin: String
    /// The host's zmx: a non-interactive ssh session's PATH may lack Homebrew's directory.
    public var zmxBin: String
    /// The server's zmx directory; nil for the installed Mac app, which uses the GUI TMPDIR.
    public var zmxDir: String?
    /// The app bundle that owns `socketPath`, which `startCommand` opens; nil when the viewer
    /// can't tell (a development instance's launcher isn't discoverable) or the host isn't a Mac.
    public var appBundle: String?
    /// The host's `nc` shuts its socket down at the end of its stdin with `-N` (OpenBSD's and
    /// FreeBSD's; Apple's `-N` takes a probe count). Without it `nc -U` outlives a closed stdin, so
    /// a relay the viewer ended could stay on the host.
    public var ncShutdown: Bool
    /// What answers at `socketPath`: the Mac app, which answers a viewer's delegated calls itself
    /// and takes no `client.attach`, or easld, whose viewers attach as its clients. Nil for a host
    /// remembered before easl recorded it (`Recents`): every board opens from a fresh discovery.
    public var server: Server?

    public enum Server: String, Codable, Sendable {
        case app, easld
    }

    public init(name: String, sshTarget: String, socketPath: String, tmpdir: String, easlBin: String, zmxBin: String = "zmx",
                appBundle: String? = nil, ncShutdown: Bool = false, zmxDir: String? = nil, server: Server? = nil) {
        self.name = name
        self.sshTarget = sshTarget
        self.socketPath = socketPath
        self.tmpdir = tmpdir
        self.easlBin = easlBin
        self.zmxBin = zmxBin
        self.zmxDir = zmxDir
        self.appBundle = appBundle
        self.ncShutdown = ncShutdown
        self.server = server
    }

    /// The ssh client every remote command runs: `/usr/bin/ssh`, or `EASL_DEV_SSH` (a wrapper
    /// that adds `-F <config>`, for testing against a private sshd, docs/testing.md).
    public static let ssh: String = ProcessInfo.processInfo.environment["EASL_DEV_SSH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin/ssh"

    /// Never prompt (there's no terminal to answer in), give up on an unreachable host in 10 s,
    /// and notice a dead link in 30 s instead of waiting for TCP.
    static let batchOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]

    /// The host's API: its socket relayed over ssh's stdio.
    public func connection(backoff: EaslConnection.Backoff = .standard) -> EaslConnection {
        .process(Self.ssh, relayArguments, backoff: backoff)
    }

    /// `ssh`'s arguments for `connection()`: `nc -U`, with `-N` where the host's `nc` has it, so
    /// the relay ends when the viewer's end of it does.
    public var relayArguments: [String] {
        ["-T"] + Self.batchOptions + [sshTarget, "nc", "-U"] + (ncShutdown ? ["-N"] : []) + [Self.quote(socketPath)]
    }

    /// Runs a script with the same GUI temporary directory as this host's terminals.
    public func scriptArguments(_ script: String, _ args: [String]) -> [String] {
        ["-T"] + Self.batchOptions + [sshTarget, "env", Self.quote("TMPDIR=" + tmpdir), HostedTerminal.remote(script, args)]
    }

    /// The session runs on `props.host` when hosted, otherwise on the board host. Its owner is
    /// always the board host's home, with this tile and a current or merged board label.
    public func terminalAttachCommand(for terminal: CanvasObject, board: BoardID, merged: [BoardID]) -> [String] {
        let tile = terminal.id
        let home = HostedTerminal.homeLabel((socketPath as NSString).deletingLastPathComponent)
        let target: String
        let command: String
        if let hosted = HostedTerminal.host(of: terminal) {
            if let problem = Self.problem(withHost: hosted) {
                return ["/bin/sh", "-c", #"printf '%s\r\n' "$1"; exec sleep 2147483647"#,
                        "easl-remote", "Not attaching: \(problem)"]
            }
            target = hosted
            command = HostedTerminal.attach(session: "canvas-" + tile, home: home, board: board, tile: tile, merged: merged)
        } else {
            target = sshTarget
            let setup = "export TMPDIR=\(Self.quote(tmpdir))\n"
                + (zmxDir.map { "export ZMX_DIR=\(Self.quote($0))\n" } ?? "")
                + "z=\(Self.quote(zmxBin))"
            command = HostedTerminal.ownershipAttach(session: "canvas-" + tile, home: home,
                                                    board: board, tile: tile, merged: merged, setup: setup)
        }
        return [Self.ssh, "-t"] + Self.batchOptions + [target, command]
    }

    /// Retries transport failures and ended sessions until the viewer disposes the surface.
    /// An ownership refusal holds the notice without retrying or repainting it.
    public static func terminalCommand(_ attach: [String]) -> String {
        let loop = #"""
        while :; do
          "$@"
          case $? in
            \#(HostedTerminal.refused)) exec sleep 2147483647 ;;
            0) sleep 1; continue ;;
          esac
          printf '\r\033[2K[easl] waiting for the host…'
          sleep 2
        done
        """#
        return ShellWords.quote(["/bin/sh", "-c", loop, "easl-remote"] + attach)
    }

    /// Starts the easl whose socket `socketPath` is, without bringing it forward there. Needs a
    /// logged-in GUI session. Nil without a known app bundle: starting some other instance would
    /// leave the viewer polling a socket nothing opens, and touch boards it never asked for.
    public var startCommand: [String]? {
        guard let appBundle else { return nil }
        return [Self.ssh, "-T"] + Self.batchOptions + [sshTarget, "open", "-g", Self.quote(appBundle)]
    }

    /// easl's socket in its home `home` on a host.
    public static func socketPath(home: String) -> String { home + "/easl.sock" }

    /// easl's home on the host, where `discover` given it as `support` finds this socket again;
    /// nil for a socket that isn't `socketPath(home:)`'s, which discovery never answers.
    public var home: String? {
        let name = Self.socketPath(home: "")
        return socketPath.hasSuffix(name) ? String(socketPath.dropLast(name.count)) : nil
    }

    // MARK: Discovery

    /// Asks the host where its socket, GUI TMPDIR, easl and zmx are, in one ssh call. `support`
    /// replaces the host's easl home: `EASL_DEV_REMOTE_HOME` (a development instance on the host,
    /// docs/testing.md) or a reopen-list board's (`RemoteReopen.support`). Throws `unavailable` with
    /// ssh's reason when the host can't be reached, and `CancellationError` (ssh ended) when the
    /// calling task is cancelled.
    public static func discover(name: String, sshTarget: String, support: String? = nil, allowDefault: Bool = true, timeout: TimeInterval = 20) async throws -> RemoteHost {
        let result = try await run(ssh, ["-T"] + batchOptions + [sshTarget, "sh", "-c", quote(discoveryScript)], timeout: timeout)
        guard result.status == 0, let host = parseDiscovery(result.output, name: name, sshTarget: sshTarget, support: support, allowDefault: allowDefault) else {
            let reason = lastLine(result.errors) ?? (result.status == 0 ? "discovery refused or unexpected answer from \(sshTarget)\(allowDefault ? "" : "; the default easl server is disabled")" : "ssh exited with status \(result.status)")
            throw EaslConnection.Failure("unavailable", reason)
        }
        return host
    }

    /// A shell condition: the host's `nc` has OpenBSD's `-N` (shut the socket down at the end of
    /// stdin), as its `nc -h` offers it; Apple's `-N` takes a probe count.
    public static let ncHasShutdown = #"nc -h 2>&1 | grep -q '^[[:space:]]*-N[[:space:]].*EOF'"#

    /// POSIX sh, so the host's login shell doesn't matter. One `key=value` per line.
    public static let discoveryScript = """
        echo "os=$(uname -s)"
        echo "home=$HOME"
        echo "tmpdir=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")"
        echo "state=${XDG_STATE_HOME:-}"
        for z in "$(command -v zmx)" /opt/homebrew/bin/zmx /usr/local/bin/zmx "$HOME/.local/bin/zmx"; do
          if [ -n "$z" ] && [ -x "$z" ]; then echo "zmx=$z"; break; fi
        done
        for e in "$(command -v easl)" "$HOME/.local/bin/easl"; do
          if [ -n "$e" ] && [ -x "$e" ]; then echo "easl=$e"; break; fi
        done
        if \(ncHasShutdown); then echo "ncshutdown=1"; fi
        """

    /// The host the discovery script's `output` describes: a Mac's easl lives in its app bundle
    /// and Application Support; elsewhere easld's home is `$XDG_STATE_HOME/easl`, else
    /// `~/.local/state/easl`. A `support` directory is that home instead. On a Mac it is a
    /// development instance: its launcher isn't known, so the host has no app bundle to start, and
    /// its zmx is in the home (`zmx`, `tmp`) rather than the GUI TMPDIR. Nil without a home or a TMPDIR.
    public static func parseDiscovery(_ output: String, name: String, sshTarget: String, support: String? = nil, allowDefault: Bool = true) -> RemoteHost? {
        if let support, !isHome(support) { return nil }
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let home = values["home"], !home.isEmpty, let tmpdir = values["tmpdir"], !tmpdir.isEmpty else { return nil }
        let mac = values["os"] == "Darwin"
        let defaultDirectory = mac ? home + "/Library/Application Support/Easl" : ((values["state"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state") + "/easl")
        let directory = support ?? defaultDirectory
        let isDefault = (directory as NSString).standardizingPath == (defaultDirectory as NSString).standardizingPath
        guard allowDefault || !isDefault else { return nil }
        let easl = mac ? macEaslBin : (values["easl"] ?? "easl")
        let installedApp = mac && isDefault
        return RemoteHost(name: name, sshTarget: sshTarget, socketPath: socketPath(home: directory), tmpdir: mac && !installedApp ? directory + "/tmp" : tmpdir,
                          easlBin: easl, zmxBin: values["zmx"] ?? "zmx", appBundle: installedApp ? macApp : nil, ncShutdown: values["ncshutdown"] == "1",
                          zmxDir: installedApp ? nil : directory + "/zmx", server: mac ? .app : .easld)
    }

    static func isHome(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The installed easl app on a Mac.
    public static let macApp = "/Applications/easl.app"

    /// The easl CLI inside the installed app on a Mac.
    public static let macEaslBin = macApp + "/Contents/Resources/bin/easl"

    /// The hosts File › Open Remote… connected to, newest first: only how to reach them, never
    /// what their boards hold (`AppPaths.remoteHosts`).
    public enum Recents {
        public static let limit = 8

        public static func load(_ url: URL) -> [RemoteHost] {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([RemoteHost].self, from: data)) ?? []
        }

        /// `host` first, replacing an older entry for its ssh target, at most `limit`.
        public static func remember(_ host: RemoteHost, in url: URL) {
            let hosts = Array(([host] + load(url).filter { $0.sshTarget != host.sshTarget }).prefix(limit))
            guard let data = try? JSONEncoder().encode(hosts) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// A host File › Open Remote… offers: `name` is what the user knows it by, `sshTarget` what
    /// connects to it.
    public struct Candidate: Equatable, Sendable {
        public var name: String
        public var sshTarget: String
        public var home: String?
        public var detail: String
        /// Reachable as far as the tailnet knows; a host it doesn't list counts as online.
        public var online: Bool

        public init(name: String, sshTarget: String, detail: String, online: Bool, home: String? = nil) {
            self.name = name
            self.sshTarget = sshTarget
            self.home = home
            self.detail = detail
            self.online = online
        }
    }

    /// Online Macs first, then the hosts opened before that aren't among them (offline when the
    /// tailnet says so). A peer and a recent host are the same machine when their ssh targets are:
    /// tailnet host names aren't unique, so two Macs with one name stay two rows, told apart by
    /// their targets.
    public static func candidates(peers: [TailnetPeer], recents: [RemoteHost]) -> [Candidate] {
        let used = Set(recents.map(\.sshTarget))
        let macs = peers.filter { $0.isMac && $0.online }
        var rows = macs.map { peer -> Candidate in
            var detail = "Mac, online"
            if macs.filter({ $0.name == peer.name }).count > 1 { detail += ", " + peer.sshTarget }
            if used.contains(peer.sshTarget) { detail += ", opened before" }
            return Candidate(name: peer.name, sshTarget: peer.sshTarget, detail: detail, online: true,
                             home: recents.first { $0.sshTarget == peer.sshTarget }?.home)
        }
        for recent in recents where !macs.contains(where: { $0.sshTarget == recent.sshTarget }) {
            let peer = peers.first { $0.sshTarget == recent.sshTarget }
            rows.append(Candidate(name: recent.name, sshTarget: recent.sshTarget,
                                  detail: peer.map { $0.online ? "\($0.os), online, opened before" : "offline" } ?? "opened before",
                                  online: peer?.online ?? true, home: recent.home))
        }
        return rows
    }

    /// A host typed into File › Open Remote… (`user@host`, an ssh config alias, a tailnet name):
    /// ssh connects to it as typed, and it goes by its host part.
    public static func typed(_ target: String) -> (name: String, sshTarget: String, home: String?) {
        (target.split(separator: "@").last.map(String.init) ?? target, target, nil)
    }

    /// The host `text` names among File › Open Remote…'s rows (`candidates`), as
    /// `board.open_remote` takes it: the row whose ssh target it is, else the one row of that
    /// name, else `text` as an ssh host typed in (`typed`). Tailnet names aren't unique, so a
    /// name two rows have is `ambiguous`, naming their ssh targets.
    public static func target(_ text: String, among rows: [Candidate]) throws -> (name: String, sshTarget: String, home: String?) {
        if let row = rows.first(where: { $0.sshTarget == text }) { return (row.name, row.sshTarget, row.home) }
        let named = rows.filter { $0.name == text }
        guard named.count < 2 else {
            throw ApiRouter.Failure("ambiguous", "\(text) names \(named.count) hosts: \(named.map(\.sshTarget).joined(separator: ", ")); pass one of these ssh targets as host")
        }
        return named.first.map { ($0.name, $0.sshTarget, $0.home) } ?? typed(text)
    }

    private static let shellHostCharacters = CharacterSet(charactersIn: "\"'`$\\;&<>|(){}")

    /// An ssh target must be one word, not an option, with both parts of `user@host` present.
    /// Older ssh clients expand hostnames into shell commands in the user's ssh configuration.
    public static func problem(withHost text: String) -> String? {
        if text.isEmpty { return "host is empty: pass a tailnet name, an ssh config alias or user@host" }
        if text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return "host \(text.debugDescription) isn't one host: a tailnet name, an ssh config alias or user@host has no spaces"
        }
        if text.rangeOfCharacter(from: shellHostCharacters) != nil {
            return "host \(text.debugDescription) contains shell metacharacters"
        }
        if text.hasPrefix("-") { return "host \(text) starts with -, which ssh would take for an option" }
        if let at = text.lastIndex(of: "@") {
            let host = text[text.index(after: at)...]
            if at == text.startIndex || host.isEmpty {
                return "host \(text) needs both parts of user@host"
            }
            if host.hasPrefix("-") { return "host \(text) has a host part starting with -" }
        }
        return nil
    }

    // MARK: Helpers

    /// `word` as one word of a remote shell command: ssh joins its arguments with spaces and the
    /// host's shell splits them again ("Application Support" would be two).
    public static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A process's last non-empty line of output: what it said last before failing.
    public static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Runs blocking process I/O on dedicated threads so GCD can still service socket reads.
    /// Timeout and cancellation end and reap the process, including a blocked stdin writer.
    public static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) async throws -> (status: Int32, output: String, errors: String) {
        try Task.checkCancellation()
        let job = RunningProcess()
        let result: (status: Int32, output: String, errors: String) = await withTaskCancellationHandler {
            let work: @Sendable () -> (status: Int32, output: String, errors: String) = {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                let stdin = input.map { _ in Pipe() }
                if let stdin {
                    process.standardInput = stdin
                } else {
                    process.standardInput = FileHandle.nullDevice
                }
                do {
                    guard try job.launch(process) else { return (-1, "", "cancelled") }
                } catch {
                    return (-1, "", "cannot run \(executable): \(error.localizedDescription)")
                }
                let running = UncheckedBox(process)
                let deadline = DispatchWorkItem { RemoteProcesses.stop(running.value) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let stderr = Locked(Data())
                let drained = DispatchGroup()
                try? stdin?.fileHandleForReading.close()
                if let stdin, let input {
                    let writer = stdin.fileHandleForWriting
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                    drained.enter()
                    Thread.detachNewThread {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                        drained.leave()
                    }
                }
                drained.enter()
                Thread.detachNewThread {
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    stderr.withLock { $0 = data }
                    drained.leave()
                }
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                drained.wait()
                process.waitUntilExit()
                deadline.cancel()
                return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr.withLock { $0 }, as: UTF8.self))
            }
            return await withCheckedContinuation { done in
                let thread = Thread { done.resume(returning: work()) }
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            job.cancel()
        }
        if job.cancelled { throw CancellationError() }
        return result
    }
}

/// One `RemoteHost.run`'s process, which its task's cancellation ends. A cancellation that comes
/// before the process starts keeps it from starting.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    var cancelled: Bool { lock.withLock { isCancelled } }

    /// Starts `process` unless cancelled first (false then).
    func launch(_ process: Process) throws -> Bool {
        try lock.withLock {
            guard !isCancelled else { return false }
            try RemoteProcesses.shared.launch(process)
            self.process = process
            return true
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            if let process { RemoteProcesses.stop(process) }
        }
    }
}

/// One of a host's boards as File › Open Remote… lists it.
public struct RemoteBoard: Equatable, Sendable {
    public var id: BoardID
    /// The root directory's name.
    public var name: String
    public var root: String
    /// Shown in a window on the host.
    public var open: Bool
    /// The root directory is gone on the host.
    public var archived: Bool
    /// Terminals on it whose agent reported (`agent.list` kind other than `unknown`).
    public var agents: Int

    public init(id: BoardID, name: String, root: String, open: Bool, archived: Bool, agents: Int) {
        self.id = id
        self.name = name
        self.root = root
        self.open = open
        self.archived = archived
        self.agents = agents
    }

    /// The boards in `board.list`'s result with their agents from `agent.list`'s: open ones
    /// first, then by name; archived ones last.
    public static func list(boards: JSONValue, agents: JSONValue) -> [RemoteBoard] {
        var counts: [BoardID: Int] = [:]
        for agent in agents["agents"]?.array ?? [] where agent["kind"]?.string != "unknown" {
            if let board = agent["board"]?.string { counts[board, default: 0] += 1 }
        }
        let rows = (boards["boards"]?.array ?? []).compactMap { info -> RemoteBoard? in
            guard let id = info["board"]?.string else { return nil }
            let root = info["root"]?.string ?? ""
            let name = (root as NSString).lastPathComponent
            return RemoteBoard(id: id, name: name.isEmpty ? id : name, root: root, open: info["open"]?.bool ?? false,
                               archived: info["archived"]?.bool ?? false, agents: counts[id] ?? 0)
        }
        return rows.sorted { lhs, rhs in
            if lhs.archived != rhs.archived { return !lhs.archived }
            if lhs.open != rhs.open { return lhs.open }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The host's boards over `connection`: `board.list` and `agent.list`. A failed
    /// `agent.list` only leaves the agent counts at zero.
    public static func load(on connection: EaslConnection, timeout: Duration = .seconds(20)) async throws -> [RemoteBoard] {
        async let boards = connection.request("board.list", timeout: timeout)
        async let agents = connection.request("agent.list", timeout: timeout)
        return list(boards: try await boards, agents: (try? await agents) ?? .null)
    }

    /// What the picker's Retry does, by the connection it has.
    public enum Retry: Equatable, Sendable {
        /// There's no connection: the host wasn't found.
        case discover
        /// The link is up and a request failed on it: ask again. `reconnect()` does nothing on a
        /// link that exists.
        case reload
        /// The link is down: try now instead of waiting out the backoff.
        case reconnect

        public init(connection state: EaslConnection.State?) {
            switch state {
            case nil: self = .discover
            case .online?: self = .reload
            case .connecting?, .offline?: self = .reconnect
            }
        }
    }
}

/// A remote board's tab as `board.open_remote` answers it (`ApiRouter.openRemoteBoard`).
public struct OpenedRemoteBoard: Equatable, Sendable {
    /// The host as the tab names it, and what ssh connects to.
    public var host: String
    public var sshTarget: String
    public var board: BoardID
    /// The board's root on the host.
    public var root: String
    /// The tab's title, `<root's name> @ <host>`.
    public var title: String
    /// The tab's window number (each tab is a window), as `screencapture -l` and yabai take it.
    public var window: Int
    /// The tab was open (or opening) already: it was selected when asked, never opened again.
    public var alreadyOpen: Bool

    public init(host: String, sshTarget: String, board: BoardID, root: String, title: String, window: Int, alreadyOpen: Bool) {
        self.host = host
        self.sshTarget = sshTarget
        self.board = board
        self.root = root
        self.title = title
        self.window = window
        self.alreadyOpen = alreadyOpen
    }

    var json: JSONValue {
        .object([
            "host": .string(host), "sshTarget": .string(sshTarget), "board": .string(board), "root": .string(root),
            "title": .string(title), "window": .number(Double(window)), "alreadyOpen": .bool(alreadyOpen),
        ])
    }
}

/// A non-Sendable value handed to another queue whose access is otherwise ordered.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
