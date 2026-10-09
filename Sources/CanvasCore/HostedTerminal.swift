import CryptoKit
import Foundation

/// A terminal tile whose session runs on another machine (`props.host`, an ssh target such as
/// `deckbox`; docs/contracts.md "Hosted terminals"). The host's easld starts the session as its
/// own child (`session.spawn`), so on Linux it stays in easld's unit and slice; the tile only
/// attaches to it, over the app's one ssh connection to that host (`TerminalHost`). That
/// connection also forwards a loopback port on the host back to this app (`RelayGate`), which
/// easld serves as this instance's sockets there (`relay.open`), so the agent's integration and
/// the `easl` CLI on the host reach the board. (Not ssh's forward of a unix socket: Tailscale
/// SSH makes that socket root's only.)
///
/// The layout on the host (scripts/offload-setup.sh installs it):
/// - `~/.local/bin/zmx`, `~/.local/bin/easld`, `~/.local/bin/easl`;
/// - `~/.local/share/easl/`: what the app bundle's Resources hold for agents (bin, cli, clients,
///   extensions, skills, schema) and Ghostty's shell integration (`ghostty/shell-integration`);
/// - `~/.local/state/easl/`: easld's home and its socket `easl.sock`; `zmx/` holds the hosted
///   sessions' zmx sockets and logs (`zmxDir`); `run/<instance>/` holds this app instance's
///   relayed `easl.sock` and `cmux.sock` (and the reports integrations spool while the app is
///   away, `agent-reports/`).
public enum HostedTerminal {
    /// The ssh target `object`'s session runs on; nil for a terminal of this Mac.
    public static func host(of object: CanvasObject) -> String? {
        guard object.type == .terminal, let host = object.props["host"]?.string?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        return host
    }

    /// easl's files for agents on the host.
    public static func resources(home: String) -> String { home + "/.local/share/easl" }

    /// This app instance as hosts know it: the Mac's name and a hash of its support directory, so
    /// two Macs, or a dev instance beside the app, never share a forwarded socket.
    public static func instance(hostname: String, support: String) -> String {
        let name = hostname.split(separator: ".").first.map(String.init) ?? hostname
        let safe = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }.prefix(24))
        let digest = SHA256.hash(data: Data(support.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return (safe.isEmpty ? "mac" : safe) + "-" + digest
    }

    /// A command line for ssh to run on the host: `script` under /bin/sh with `args` as $1…,
    /// whatever the user's login shell there is.
    public static func remote(_ script: String, _ args: [String] = []) -> String {
        ShellWords.quote(["/bin/sh", "-c", script, "easl"] + args)
    }

    /// The hosted sessions' zmx directory on the host, as a shell word: easld's `<home>/zmx`, the
    /// user's only (easld's `session.Manager.Secure`). Never zmx's default, `/tmp/zmx-<uid>`,
    /// which another user of the host could make first.
    public static let zmxDir = #""$HOME/.local/state/easl/zmx""#

    /// zmx on the host, in the hosted sessions' directory (`zmxDir`).
    public static func zmx(_ arguments: [String]) -> String {
        remote(#"ZMX_DIR=\#(zmxDir) exec "$HOME/.local/bin/zmx" "$@""#, arguments)
    }

    /// easld's socket on the host, relayed by `nc`: one JSON line per request (`request`). With
    /// `-N` nc shuts its side of the connection down when ssh's input ends, after the reply, and
    /// exits once easld closes it; without it nc outlives the call, holding a connection to easld
    /// (`RemoteHost.ncHasShutdown`).
    public static let easldRelay = remote(#"""
        s="$HOME/.local/state/easl/easl.sock"
        if \#(RemoteHost.ncHasShutdown); then exec nc -N -U "$s"; fi
        exec nc -U "$s"
        """#)

    /// Runs `executable` (ssh running `easldRelay`), sends it `line` and reads one reply line, then
    /// ends its input and waits for it to exit, so nothing is left running on the host; the whole
    /// call is bounded by `timeout`. The reply is nil when none came.
    public static func request(_ executable: String, _ arguments: [String], line: Data, timeout: TimeInterval = 20) -> (line: Data?, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return (nil, "\(executable) didn't start") }
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        // A process that already ended (ssh couldn't connect) makes the write fail, not raise
        // SIGPIPE, which would end the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForWriting.write(contentsOf: line)
        var reply = Data()
        let reader = output.fileHandleForReading
        // `availableData` returns what has arrived; `read(upToCount:)` waits for the whole count or
        // the end, which made every call wait out its timeout.
        while !reply.contains(UInt8(ascii: "\n")) {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            reply.append(chunk)
        }
        // The input's end, after the reply: easld drops a request whose client stopped sending.
        try? input.fileHandleForWriting.close()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let first = reply.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: true).first.map { Data($0) }
        return (first, String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Run once per connection: says where home is and whether easld's socket is there
    /// (`home=<path>` and `easld=yes|no` lines).
    public static let probe = remote(#"""
        printf 'home=%s\n' "$HOME"
        if [ -S "$HOME/.local/state/easl/easl.sock" ]; then echo easld=yes; else echo easld=no; fi
        """#)

    /// What `probe` printed: the host's home and whether its easld socket is there.
    public static func parseProbe(_ output: String) -> (home: String, easld: Bool)? {
        var home: String?, easld = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("home=") { home = String(line.dropFirst(5)) }
            if line == "easld=yes" { easld = true }
        }
        guard let home, home.hasPrefix("/") else { return nil }
        return (home, easld)
    }

    /// The host side of a tile's attach: waits until easld has started the session (the app asks
    /// it to as the connection comes up), then attaches, only if the session is this tile's:
    /// labelled with this instance's `home` label, `tile`, and `board` or one of `merged`, as
    /// easld checks the sessions it starts (`spawnParams`). A board copied into another home
    /// has the same ids, so another instance's session of the same name is refused, as a local
    /// tile's `ownerGuard` does: the host prints whose it is and exits `refused`. Never creates a session: `zmx attach`
    /// to a missing one would start a login shell under ssh, outside easld's slice, so in the
    /// moment between the check and the attach `SHELL=/bin/false` makes that one exit at once.
    public static func attach(session: String, home: String, board: BoardID, tile: ObjectID, merged: [BoardID] = []) -> String {
        remote(#"""
        export ZMX_DIR=\#(zmxDir)
        z="$HOME/.local/bin/zmx"
        if [ ! -x "$z" ]; then printf 'zmx is not installed on %s: run scripts/offload-setup.sh %s on the Mac.\r\n' "$(hostname)" "$(hostname)"; exit 2; fi
        shown=
        seen=
        while :; do
          fields=$("$z" list 2>/dev/null | awk -F'\t' -v n="name=$1" '{ s = $1; sub(/^.*name=/, "name=", s) } s == n { for (i = 2; i <= NF; i++) print $i }')
          # zmx lists a new session a moment before its labels land: one without them gets another look.
          case "$fields" in pid=*canvas.home=*) break ;; pid=*) [ -z "$seen" ] || break; seen=1 ;; esac
          if [ -z "$shown" ]; then shown=1; printf '\r\033[K\033[2mWaiting for %s to start on %s…\033[0m' "$1" "$(hostname)"; fi
          sleep 1
        done
        [ -z "$shown" ] || printf '\r\033[K'
        owned=1
        for label in "canvas.home=$2" "canvas.tile=$4"; do
          if ! printf '%s\n' "$fields" | grep -qxF -- "$label"; then owned=; break; fi
        done
        session=$1
        board=$3
        shift 4
        boardOwned=
        for candidate in "$board" "$@"; do
          [ -n "$candidate" ] || continue
          if printf '%s\n' "$fields" | grep -qxF -- "canvas.board=$candidate"; then boardOwned=1; break; fi
        done
        if [ -z "$owned" ] || [ -z "$boardOwned" ]; then
          owner=$(printf '%s\n' "$fields" | sed -n 's/^canvas\.home=//p')
          printf '\r\nThis terminal session (%s on %s) belongs to another easl instance or board (%s).\r\nNot attaching: this copy of the board can neither type into it nor end it.\r\n' "$session" "$(hostname)" "${owner:-no owner}"
          exit \#(refused)
        fi
        SHELL=/bin/false exec "$z" attach "$session"
        """#, [session, home, board, tile] + merged)
    }

    /// `attach`'s status when the session isn't this tile's (zmx's own attach exits 0 or 1).
    public static let refused: Int32 = 3

    /// A tar on standard output of the reports integrations spooled on the host for `tiles` while
    /// this instance was away (`<run>/agent-reports/<tile>/…`, as `AgentReportSpool` reads
    /// them); nothing when there are none.
    public static func spooled(run: String, tiles: [ObjectID]) -> String {
        remote(#"""
        cd "$1" 2>/dev/null || exit 0
        shift
        n=$#
        while [ "$n" -gt 0 ]; do t=$1; shift; n=$((n - 1)); if [ -d "$t" ]; then set -- "$@" "$t"; fi; done
        [ $# -gt 0 ] || exit 0
        exec tar -cf - -- "$@"
        """#, [run + "/agent-reports"] + tiles)
    }

    /// Deletes replayed reports from the host's spool (`files` relative to it, `<tile>/<name>`),
    /// and the tiles' folders left empty.
    public static func removeSpooled(run: String, files: [String]) -> String {
        remote(#"cd "$1" || exit 0; shift; rm -f -- "$@"; for f; do rmdir -- "${f%/*}" 2>/dev/null; done; true"#,
               [run + "/agent-reports"] + files)
    }

    /// The Mac side, Ghostty's command (`sh -c` with $1 ssh, $2 the connection's control path,
    /// $3 the host, $4 the session, $5 `attach`): attaches through the app's connection to the
    /// host once it is up, and again whenever ssh fails (255: the connection dropped), so the tile
    /// reattaches to the same session after a network loss. A session the host refused (another
    /// instance's: `refused`) is never attached: the tile keeps saying whose it is, as a local
    /// tile's `ownerGuard` does. Any other exit is zmx's (the session ended, or a detach) and ends
    /// the command, as a local tile's does.
    public static let attachLoop = #"""
    waiting=
    while :; do
      if "$1" -S "$2" -O check "$3" 2>/dev/null; then
        waiting=
        "$1" -S "$2" -o ControlMaster=no -tt "$3" "$5"
        status=$?
        [ "$status" -ne \#(refused) ] || exec sleep 2147483647
        [ "$status" -eq 255 ] || exit "$status"
        printf '\r\n\033[2m[%s: the connection dropped; reattaching to %s]\033[0m\r\n' "$3" "$4"
      elif [ -z "$waiting" ]; then
        waiting=1
        printf '\r\033[K\033[2mWaiting for the connection to %s…\033[0m' "$3"
      fi
      sleep 1
    done
    """#

    /// ssh options of every connection the app makes to a host: through the control socket at
    /// `controlPath` when the app's connection is up, never asking for a password (a key the agent
    /// holds), and a dead link noticed within 30 s.
    public static func sshOptions(controlPath: String) -> [String] {
        ["-S", controlPath, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
    }

    /// `session.spawn`'s params for terminal `tile` on board `board`: `argv` in the login shell
    /// (nil: the login shell), in `cwd` on the host (nil: the user's home), with the tile's
    /// variables pointing at this instance's relayed sockets in `run` (`relay.open`), and easl's
    /// files under the host's `home` (`LoginSession.tileShellIntegration`: easl's bin first on PATH,
    /// its Python client, the zsh and bash integration, the `open` shim as `BROWSER`).
    public static func spawnParams(tile: ObjectID, board: BoardID, merged: [BoardID] = [], argv: [String]?, cwd: String?, home: String, run: String,
                                   homeLabel: String, cmuxPassword: String?, ghosttyIntegration: Bool) -> JSONValue {
        let files = resources(home: home)
        var env = LoginSession.tileShellIntegration(resources: files, inherited: [:])
        env["PATH"] = files + "/bin"
        env.merge([
            "EASL_ENV": "1",
            "EASL_SOCKET": run + "/easl.sock",
            "EASL_TILE_ID": tile,
            "EASL_BOARD_ID": board,
            "CMUX_SOCKET_PATH": run + "/cmux.sock",
            "CMUX_SURFACE_ID": tile,
            "CMUX_WORKSPACE_ID": board,
            // The host has no xterm-ghostty terminfo of its own.
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        ]) { _, new in new }
        if let cmuxPassword { env["CMUX_SOCKET_PASSWORD"] = cmuxPassword }
        if ghosttyIntegration { env["EASL_GHOSTTY_INTEGRATION"] = files + "/ghostty/shell-integration" }
        var params: [String: JSONValue] = [
            "tile": .string(tile),
            "env": .object(env.mapValues(JSONValue.string)),
            "labels": .object(["canvas.board": .string(board), "canvas.tile": .string(tile), "canvas.home": .string(homeLabel)]),
        ]
        if !merged.isEmpty { params["merged"] = .array(merged.map(JSONValue.string)) }
        if let argv, !argv.isEmpty { params["command"] = .array(argv.map(JSONValue.string)) }
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        return .object(params)
    }
}
