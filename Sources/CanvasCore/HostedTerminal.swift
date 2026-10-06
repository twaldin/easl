import CryptoKit
import Foundation

/// A terminal tile whose session runs on another machine (`props.host`, an ssh target such as
/// `deckbox`; docs/contracts.md "Hosted terminals"). The host's easld starts the session as its
/// own child (`session.spawn`), so on Linux it stays in easld's unit and slice; the tile only
/// attaches to it, over the app's one ssh connection to that host (`TerminalHost`), which also
/// forwards this app's sockets to a directory of this instance's on the host so the agent's
/// integration and the `easl` CLI there reach the board.
///
/// The layout on the host (scripts/offload-setup.sh installs it):
/// - `~/.local/bin/zmx`, `~/.local/bin/easld`, `~/.local/bin/easl`;
/// - `~/.local/share/easl/`: what the app bundle's Resources hold for agents (bin, cli, clients,
///   extensions, skills, schema) and Ghostty's shell integration (`ghostty/shell-integration`);
/// - `~/.local/state/easl/`: easld's home and its socket `easl.sock`; `run/<instance>/` holds this
///   app instance's forwarded `easl.sock` and `cmux.sock` (and the reports integrations spool
///   while the app is away, `agent-reports/`).
public enum HostedTerminal {
    /// The ssh target `object`'s session runs on; nil for a terminal of this Mac.
    public static func host(of object: CanvasObject) -> String? {
        guard object.type == .terminal, let host = object.props["host"]?.string?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        return host
    }

    /// easl's files for agents on the host.
    public static func resources(home: String) -> String { home + "/.local/share/easl" }

    /// Where this app instance's sockets are forwarded to on the host.
    public static func runDirectory(home: String, instance: String) -> String { home + "/.local/state/easl/run/" + instance }

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

    /// zmx on the host, in the hosted sessions' socket directory (easld's `session.New`: a system
    /// unit and an ssh session don't get the same `TMPDIR` or `XDG_RUNTIME_DIR`).
    public static func zmx(_ arguments: [String]) -> String {
        remote(#"ZMX_DIR="/tmp/zmx-$(id -u)" exec "$HOME/.local/bin/zmx" "$@""#, arguments)
    }

    /// easld's socket on the host, relayed by `nc`: one JSON line per request.
    public static let easldRelay = remote(#"exec nc -U "$HOME/.local/state/easl/easl.sock""#)

    /// Run once per connection: makes this instance's run directory, removes the sockets a lost
    /// connection left there (sshd binds a forward only to a free path), and says where home is
    /// and whether easld is up: `home=<path>` and `easld=yes|no` lines.
    public static func probe(instance: String) -> String {
        remote(#"""
        set -e
        state="$HOME/.local/state/easl"; run="$state/run/$1"
        mkdir -p "$run"; chmod 700 "$state" "$state/run" "$run"
        rm -f "$run/easl.sock" "$run/cmux.sock"
        printf 'home=%s\n' "$HOME"
        if [ -S "$state/easl.sock" ]; then echo easld=yes; else echo easld=no; fi
        """#, [instance])
    }

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
    /// it to as the connection comes up), then attaches. Never creates one: `zmx attach` to a
    /// missing session would start a login shell under ssh, outside easld's slice, so in the
    /// moment between the check and the attach `SHELL=/bin/false` makes that one exit at once.
    public static func attach(session: String) -> String {
        remote(#"""
        export ZMX_DIR="/tmp/zmx-$(id -u)"
        z="$HOME/.local/bin/zmx"
        if [ ! -x "$z" ]; then printf 'zmx is not installed on %s: run scripts/offload-setup.sh %s on the Mac.\r\n' "$(hostname)" "$(hostname)"; exit 2; fi
        shown=
        until "$z" list --short 2>/dev/null | grep -qx -- "$1"; do
          if [ -z "$shown" ]; then shown=1; printf '\r\033[K\033[2mWaiting for %s to start on %s…\033[0m' "$1" "$(hostname)"; fi
          sleep 1
        done
        [ -z "$shown" ] || printf '\r\033[K'
        SHELL=/bin/false exec "$z" attach "$1"
        """#, [session])
    }

    /// The Mac side, Ghostty's command (`sh -c` with $1 ssh, $2 the connection's control path,
    /// $3 the host, $4 the session, $5 `attach(session:)`): attaches through the app's
    /// connection to the host once it is up, and again whenever ssh fails (255: the connection
    /// dropped), so the tile reattaches to the same session after a network loss. Any other exit
    /// is zmx's (the session ended, or a detach) and ends the command, as a local tile's does.
    public static let attachLoop = #"""
    waiting=
    while :; do
      if "$1" -S "$2" -O check "$3" 2>/dev/null; then
        waiting=
        "$1" -S "$2" -o ControlMaster=no -tt "$3" "$5"
        status=$?
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
    /// variables pointing at this instance's forwarded sockets in `run`, and easl's files at
    /// `resources` on the host (`LoginSession.tileShellIntegration`: easl's bin first on PATH,
    /// its Python client, the zsh and bash integration, the `open` shim as `BROWSER`).
    public static func spawnParams(tile: ObjectID, board: BoardID, argv: [String]?, cwd: String?, home: String, instance: String,
                                   homeLabel: String, cmuxPassword: String?, ghosttyIntegration: Bool) -> JSONValue {
        let run = runDirectory(home: home, instance: instance), files = resources(home: home)
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
        if let argv, !argv.isEmpty { params["command"] = .array(argv.map(JSONValue.string)) }
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        return .object(params)
    }
}
