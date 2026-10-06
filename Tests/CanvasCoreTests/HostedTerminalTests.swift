import Foundation
import Testing
import CanvasCore

/// A hosted terminal's scripts, run here with stand-ins for ssh and the host's zmx: the attach
/// survives a dropped connection and never starts a session itself, the probe readies this
/// instance's run directory, and reports spooled on the host come back once.
struct HostedTerminalTests {
    let session = "canvas-obj_01M3MWD38ZV1P794MV"

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func executable(_ url: URL, _ script: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Runs `sh -c script` (what sshd does with a command line) with `arguments` and `env`.
    func sh(_ script: String, _ arguments: [String] = [], env: [String: String] = [:]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// The Mac side waits for the app's connection, attaches through it, attaches again when ssh
    /// fails (the connection dropped), and ends with zmx's own status.
    @Test func theAttachComesBackAfterTheConnectionDrops() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ssh = dir.appendingPathComponent("ssh")
        // `-O check` fails once (no connection yet); the first attach drops (255), the second
        // ends as zmx does when its session ends.
        try executable(ssh, """
        #!/bin/sh
        d="\(dir.path)"
        case " $* " in
        *" -O check "*) n=$(cat "$d/checks" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/checks"; [ "$n" -ge 1 ] ;;
        *) n=$(cat "$d/attaches" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/attaches"
           for last; do :; done; printf '%s' "$last" > "$d/remote"
           if [ "$n" -eq 0 ]; then exit 255; else exit 7; fi ;;
        esac
        """)
        let remote = HostedTerminal.attach(session: session)
        let (status, output) = try sh(HostedTerminal.attachLoop, ["canvas-host", ssh.path, "/tmp/ctl", "deckbox", session, remote])
        #expect(status == 7, "zmx's exit ends the loop with its status")
        #expect(try String(contentsOf: dir.appendingPathComponent("attaches"), encoding: .utf8) == "2\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("remote"), encoding: .utf8) == remote, "the host gets the attach as one command line")
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("Waiting for the connection to deckbox"))
        #expect(text.contains("deckbox: the connection dropped; reattaching to \(session)"))
    }

    /// The host side attaches only once easld has started the session, and never lets zmx start
    /// one (a login shell outside easld's slice) in the moment between its check and the attach.
    @Test func theHostSideWaitsForTheSessionAndNeverStartsOne() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try executable(home.appendingPathComponent(".local/bin/zmx"), """
        #!/bin/sh
        d="\(home.path)"
        case "$1" in
        list) n=$(cat "$d/lists" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/lists"; [ "$n" -lt 1 ] || printf 'other\\n\(session)\\n' ;;
        attach) printf 'attach %s SHELL=%s ZMX_DIR=%s\\n' "$2" "$SHELL" "$ZMX_DIR" ;;
        esac
        """)
        let (status, output) = try sh(HostedTerminal.attach(session: session), env: ["HOME": home.path])
        #expect(status == 0)
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("Waiting for \(session) to start"))
        #expect(text.hasSuffix("attach \(session) SHELL=/bin/false ZMX_DIR=/tmp/zmx-\(getuid())\n"))
    }

    /// The probe says where the host's home is and whether its easld is up.
    @Test func theProbeFindsHomeAndEasld() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        // `remote` quotes the probe for the host's shell; sshd hands that line to `sh -c`.
        let (status, output) = try sh(HostedTerminal.probe, env: ["HOME": home.path])
        #expect(status == 0)
        let found = HostedTerminal.parseProbe(String(decoding: output, as: UTF8.self))
        #expect(found?.home == home.path && found?.easld == false)
    }

    /// The gate splices a connection carrying its token to the named socket, and closes any other:
    /// the host's loopback port is open to all its users.
    @Test func theRelayGateLetsOnlyTheTokenThrough() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("api.sock").path
        let server = SocketServer(path: target) { request, _ in
            .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["pong": .bool(true)])])
        }
        try server.start()
        defer { server.stop() }
        let gate = RelayGate(path: dir.appendingPathComponent("gate.sock").path, targets: ["easl": target])
        try gate.start()
        defer { gate.stop() }
        func exchange(_ header: String) throws -> String {
            // The request stays open until the reply line is in (a loaded runner answers late).
            let (status, output) = try sh(#"(printf '%s\n%s\n' "$1" '{"id":"1","method":"system.ping"}'; sleep 4) | nc -U "$2" | head -n 1"#,
                                          ["relay", header, gate.path])
            _ = status
            return String(decoding: output, as: UTF8.self)
        }
        #expect(try exchange("\(gate.token) easl").contains(#""pong":true"#))
        #expect(try exchange("\(String(repeating: "0", count: 64)) easl").isEmpty, "a wrong token gets nothing")
        #expect(try exchange("\(gate.token) other").isEmpty, "nor a socket the gate doesn't serve")
    }

    /// Reports spooled on the host for the open tiles come back as `AgentReportSpool` reads them,
    /// and removing the replayed ones leaves other tiles' alone.
    @Test func spooledReportsComeBackOnce() throws {
        let home = try scratch(), local = try scratch()
        defer { for dir in [home, local] { try? FileManager.default.removeItem(at: dir) } }
        let run = home.appendingPathComponent("run/mac-1").path
        let spool = URL(fileURLWithPath: run).appendingPathComponent("agent-reports")
        for (tile, seq) in [("obj_a", 3), ("obj_b", 4)] {
            let folder = spool.appendingPathComponent(tile)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"seq":\#(seq),"method":"agent.report","params":{"state":"idle","source":"canvas-omp"}}"#.utf8)
                .write(to: folder.appendingPathComponent("\(seq)-1-r.json"))
        }
        let archive = try sh(HostedTerminal.spooled(run: run, tiles: ["obj_a", "obj_gone"]))
        #expect(archive.status == 0)
        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xf", "-", "-C", local.path]
        let input = Pipe()
        untar.standardInput = input
        try untar.run()
        try input.fileHandleForWriting.write(contentsOf: archive.output)
        try input.fileHandleForWriting.close()
        untar.waitUntilExit()
        let entries = AgentReportSpool.read(from: local, tiles: ["obj_a", "obj_b"])
        #expect(entries.map(\.tile) == ["obj_a"] && entries.first?.seq == 3, "only the tiles asked for")

        _ = try sh(HostedTerminal.removeSpooled(run: run, files: ["obj_a/3-1-r.json"]))
        #expect(!FileManager.default.fileExists(atPath: spool.appendingPathComponent("obj_a").path), "the emptied folder goes too")
        #expect(FileManager.default.fileExists(atPath: spool.appendingPathComponent("obj_b/4-1-r.json").path))
        #expect(try sh(HostedTerminal.spooled(run: run, tiles: ["obj_a"])).output.isEmpty)
    }

    /// The session's variables point the agent's integration and the CLI at this instance's
    /// relayed sockets and easl's files on the host, never at this Mac's paths.
    @Test func theSessionReachesTheBoardThroughTheForwardedSockets() throws {
        let params = HostedTerminal.spawnParams(tile: "obj_t", board: "brd_b", argv: ["omp", "--model", "x"], cwd: nil, home: "/home/tim",
                                                run: "/home/tim/.local/state/easl/run/mac-1", homeLabel: "home", cmuxPassword: nil, ghosttyIntegration: true)
        let env = params["env"]?.object?.compactMapValues(\.string) ?? [:]
        #expect(env["EASL_SOCKET"] == "/home/tim/.local/state/easl/run/mac-1/easl.sock")
        #expect(env["CMUX_SOCKET_PATH"] == "/home/tim/.local/state/easl/run/mac-1/cmux.sock")
        #expect(env["EASL_TILE_ID"] == "obj_t" && env["CMUX_SURFACE_ID"] == "obj_t" && env["EASL_BOARD_ID"] == "brd_b")
        #expect(env["PATH"] == "/home/tim/.local/share/easl/bin", "easld puts it before its own PATH")
        #expect(env["PYTHONPATH"] == "/home/tim/.local/share/easl/clients/python")
        #expect(env["PROMPT_COMMAND"] == ". '/home/tim/.local/share/easl/extensions/shell/bash/easl.bash'")
        #expect(env["EASL_GHOSTTY_INTEGRATION"] == "/home/tim/.local/share/easl/ghostty/shell-integration")
        #expect(env["CMUX_SOCKET_PASSWORD"] == nil && env["EASL_BOARD_ROOT"] == nil)
        #expect(params["command"] == .array(["omp", "--model", "x"].map(JSONValue.string)) && params["cwd"] == nil)
        #expect(params["labels"] == .object(["canvas.board": .string("brd_b"), "canvas.tile": .string("obj_t"), "canvas.home": .string("home")]))
        let shell = HostedTerminal.spawnParams(tile: "obj_t", board: "brd_b", argv: nil, cwd: "/srv/repo", home: "/home/tim",
                                               run: "/home/tim/.local/state/easl/run/mac-1", homeLabel: "home", cmuxPassword: nil, ghosttyIntegration: false)
        #expect(shell["command"] == nil && shell["cwd"] == .string("/srv/repo") && shell["env"]?["EASL_GHOSTTY_INTEGRATION"] == nil)
    }

    /// Two Macs, or a dev instance beside the app, get run directories of their own.
    @Test func eachInstanceHasItsOwnRunDirectory() {
        let app = HostedTerminal.instance(hostname: "twaldin-home.local", support: "/Users/t/Library/Application Support/Easl")
        let dev = HostedTerminal.instance(hostname: "twaldin-home.local", support: "/tmp/easl-dev-offload")
        #expect(app.hasPrefix("twaldin-home-") && app != dev)
        #expect(app == HostedTerminal.instance(hostname: "twaldin-home.local", support: "/Users/t/Library/Application Support/Easl"))
        #expect(HostedTerminal.instance(hostname: "Tim's Mac", support: "/x").hasPrefix("Tim-s-Mac-"))
    }
}
