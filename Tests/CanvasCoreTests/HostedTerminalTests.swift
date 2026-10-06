import Foundation
import Testing
import CanvasCore

/// A hosted terminal's scripts, run here with stand-ins for ssh and the host's zmx: the attach
/// survives a dropped connection, never starts a session itself and never attaches to another
/// instance's, the probe readies this instance's run directory, and reports spooled on the host
/// come back once. The relay's gate opens only to the current token's holder, and a terminal
/// never changes host.
struct HostedTerminalTests {
    let tile = "obj_01M3MWD38ZV1P794MV"
    var session: String { "canvas-" + tile }

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

    /// Runs `sh -c script` (what sshd does with a command line) with `arguments` and `env`, waiting
    /// on a GCD thread, never on Swift's cooperative pool: suites run in parallel, and a pool full
    /// of threads waiting on processes starves the tests that need it (`LineClient`).
    func sh(_ script: String, _ arguments: [String] = [], env: [String: String] = [:]) async throws -> (status: Int32, output: Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
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
                })
            }
        }
    }

    /// A stand-in for ssh that records each attach and exits with the next of `statuses`; its
    /// `-O check` fails once (no connection yet).
    func fakeSSH(in dir: URL, statuses: [Int32]) throws -> URL {
        let ssh = dir.appendingPathComponent("ssh")
        try executable(ssh, """
        #!/bin/sh
        d="\(dir.path)"
        case " $* " in
        *" -O check "*) n=$(cat "$d/checks" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/checks"; [ "$n" -ge 1 ] ;;
        *) n=$(cat "$d/attaches" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/attaches"
           for last; do :; done; printf '%s' "$last" > "$d/remote"
           set -- \(statuses.map(String.init).joined(separator: " ")); shift "$n"; exit "$1" ;;
        esac
        """)
        return ssh
    }

    /// The Mac side waits for the app's connection, attaches through it, attaches again when ssh
    /// fails (the connection dropped), and ends with zmx's own status.
    @Test func theAttachComesBackAfterTheConnectionDrops() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The first attach drops (255), the second ends as zmx does when its session ends.
        let ssh = try fakeSSH(in: dir, statuses: [255, 7])
        let remote = HostedTerminal.attach(session: session, home: "home", board: "brd_b", tile: tile)
        let (status, output) = try await sh(HostedTerminal.attachLoop, ["canvas-host", ssh.path, "/tmp/ctl", "deckbox", session, remote])
        #expect(status == 7, "zmx's exit ends the loop with its status")
        #expect(try String(contentsOf: dir.appendingPathComponent("attaches"), encoding: .utf8) == "2\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("remote"), encoding: .utf8) == remote, "the host gets the attach as one command line")
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("Waiting for the connection to deckbox"))
        #expect(text.contains("deckbox: the connection dropped; reattaching to \(session)"))
    }

    /// A session the host refused (another instance's) is never attached, nor retried: the loop
    /// holds the tile on the host's refusal, and doesn't end (which would close the tile).
    @Test func aRefusedAttachHoldsTheTile() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ssh = try fakeSSH(in: dir, statuses: [HostedTerminal.refused, 0])
        let loop = Process()
        loop.executableURL = URL(fileURLWithPath: "/bin/sh")
        loop.arguments = ["-c", HostedTerminal.attachLoop, "canvas-host", ssh.path, "/tmp/ctl", "deckbox", session, "attach"]
        loop.standardOutput = FileHandle.nullDevice
        loop.standardError = FileHandle.nullDevice
        try loop.run()
        defer { loop.terminate() }
        let attaches = dir.appendingPathComponent("attaches")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: attaches.path) { try await Task.sleep(for: .milliseconds(100)) }
        // Past the loop's 1 s pause: a retry would have attached again by now.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(loop.isRunning, "the tile stays, showing whose the session is")
        #expect(try String(contentsOf: attaches, encoding: .utf8) == "1\n")
    }

    /// A zmx on the host whose `list` prints `lists[n]` (zmx 0.8.1's lines) at its call `n`, the
    /// last one from then on, and which records what `attach` gets.
    func fakeZmx(home: URL, lists: [String]) throws {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] where name == "lists" || name.hasPrefix("list-") {
            try? fm.removeItem(at: home.appendingPathComponent(name))
        }
        for (n, list) in lists.enumerated() {
            try list.write(to: home.appendingPathComponent(n == lists.count - 1 ? "list-last" : "list-\(n)"), atomically: true, encoding: .utf8)
        }
        try executable(home.appendingPathComponent(".local/bin/zmx"), """
        #!/bin/sh
        d="\(home.path)"
        case "$1" in
        list) n=$(cat "$d/lists" 2>/dev/null || echo 0); echo $((n + 1)) > "$d/lists"; f="$d/list-$n"; [ -f "$f" ] || f="$d/list-last"; cat "$f" ;;
        attach) printf 'attach %s SHELL=%s ZMX_DIR=%s\\n' "$2" "$SHELL" "$ZMX_DIR" ;;
        esac
        """)
    }

    func listed(_ labels: String) -> String {
        "  name=other\tpid=1\tclients=0\tcreated=1\n  name=\(session)\tpid=2\tclients=0\tcreated=1\tcmd=bash -l\(labels.isEmpty ? "" : "\t" + labels)\n"
    }

    var ownLabels: String { "canvas.board=brd_b\tcanvas.home=home\tcanvas.tile=\(tile)" }

    /// The host side attaches only once easld has started the session, in the user's own zmx
    /// directory, and never lets zmx start one (a login shell outside easld's slice) in the moment
    /// between its check and the attach. A session zmx lists before its labels land (they follow
    /// its creation) is looked at again, not refused.
    @Test func theHostSideWaitsForTheSessionAndNeverStartsOne() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        for lists in [["", listed(ownLabels)], [listed(""), listed(ownLabels)]] {
            try fakeZmx(home: home, lists: lists)
            let (status, output) = try await sh(HostedTerminal.attach(session: session, home: "home", board: "brd_b", tile: tile), env: ["HOME": home.path])
            #expect(status == 0)
            let text = String(decoding: output, as: UTF8.self)
            #expect(text.contains("Waiting for \(session) to start"))
            #expect(text.hasSuffix("attach \(session) SHELL=/bin/false ZMX_DIR=\(home.path)/.local/state/easl/zmx\n"), "\(text)")
        }
    }

    /// A session of the tile's name that isn't this tile's (another instance's home: a board copied
    /// there has the same ids; another board's; one without labels) is refused, never attached.
    @Test func theHostSideRefusesAnotherOwnersSession() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        for (labels, owner) in [("canvas.board=brd_b\tcanvas.home=other\tcanvas.tile=\(tile)", "other"),
                                ("canvas.board=brd_x\tcanvas.home=home\tcanvas.tile=\(tile)", "home"),
                                ("", "no owner")] {
            try fakeZmx(home: home, lists: [listed(labels)])
            let (status, output) = try await sh(HostedTerminal.attach(session: session, home: "home", board: "brd_b", tile: tile), env: ["HOME": home.path])
            let text = String(decoding: output, as: UTF8.self)
            #expect(status == HostedTerminal.refused, "\(labels)")
            #expect(text.contains("belongs to another easl instance or board (\(owner))"), "\(labels): \(text)")
            #expect(!text.contains("attach "), "\(labels): never attached")
        }
    }

    /// A call to the host's easld (`HostedTerminal.request` running `easldRelay`, here without
    /// ssh, against a server that, like easld, closes a connection once its client's input ends)
    /// returns as soon as the reply is in, and leaves no `nc` behind: OpenBSD nc, stood in for
    /// here, keeps reading after its input ends unless `-N` shuts its side down.
    @Test func aCallToEasldLeavesNothingRunning() async throws {
        // Under /tmp: the socket's path must fit a sockaddr_un (104 bytes).
        let home = URL(fileURLWithPath: "/tmp/easl-nc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let socket = home.appendingPathComponent(".local/state/easl/easl.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = SocketServer(path: socket.path) { request, _ in
            .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["pong": .bool(true)])])
        }
        try server.start()
        defer { server.stop() }
        let bin = home.appendingPathComponent("bin"), pids = home.appendingPathComponent("nc.pids")
        try executable(bin.appendingPathComponent("nc"), #"""
        #!/usr/bin/env python3
        import os, select, socket, sys
        args = sys.argv[1:]
        if args == ["-h"]:
            sys.stderr.write("OpenBSD netcat\n\t-N\t\tShutdown the network socket after EOF on stdin\n")
            sys.exit(1)
        with open(os.environ["FAKE_NC_PIDS"], "a") as f:
            f.write(f"{os.getpid()}\n")
        s = socket.socket(socket.AF_UNIX)
        s.connect(args[-1])
        reading = True
        while True:
            ready, _, _ = select.select([s] + ([0] if reading else []), [], [])
            if 0 in ready:
                data = os.read(0, 65536)
                if data:
                    s.sendall(data)
                else:
                    reading = False
                    if "-N" in args:
                        s.shutdown(socket.SHUT_WR)
            if s in ready:
                data = s.recv(65536)
                if not data:
                    break
                os.write(1, data)
        """#)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let env = ["HOME=\(home.path)", "PATH=\(bin.path):\(path)", "FAKE_NC_PIDS=\(pids.path)"]
        let start = Date()
        let reply = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // `env` stands in for ssh: it runs the command line as sshd would, with `sh -c`.
                continuation.resume(returning: HostedTerminal.request("/usr/bin/env", ["-i"] + env + ["/bin/sh", "-c", HostedTerminal.easldRelay],
                                                                      line: Data(#"{"id":"1","method":"system.ping"}"#.utf8 + [0x0A]), timeout: 60))
            }
        }
        #expect(reply.line.map { String(decoding: $0, as: UTF8.self).contains(#""pong":true"#) } == true, "\(reply.errors)")
        // Far below the timeout, and far above a slow runner's two python starts (6 s on CI).
        #expect(Date().timeIntervalSince(start) < 30, "the reply ends the call, not the timeout")
        let pid = try #require(Int32(String(contentsOf: pids, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "nc exited with the call")
    }

    /// The probe says where the host's home is and whether its easld is up.
    @Test func theProbeFindsHomeAndEasld() async throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        // `remote` quotes the probe for the host's shell; sshd hands that line to `sh -c`.
        let (status, output) = try await sh(HostedTerminal.probe, env: ["HOME": home.path])
        #expect(status == 0)
        let found = HostedTerminal.parseProbe(String(decoding: output, as: UTF8.self))
        #expect(found?.home == home.path && found?.easld == false)
    }

    /// easld's side of a connection through the gate, holding `token`: the gate's answer to its
    /// challenge, then (when that came) the API's reply to a ping, nil when the gate closed instead.
    func throughGate(_ gate: RelayGate, token: String, name: String = "easl") async throws -> (answer: String?, reply: String?) {
        let client = try LineClient(path: gate.path)
        // The gate closes on a wrong proof, before the ping that follows it: a failed write, not SIGPIPE.
        var on: Int32 = 1
        setsockopt(client.fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let nonce = "00112233445566778899aabbccddeeff"
        client.send("\(name) \(nonce)")
        // The default 30 s: a slow runner's splice took over 5. A connection the gate refuses closes at once.
        guard let answer = try? await client.nextText() else { return (nil, nil) }
        let theirs = String(answer.prefix(32))
        client.send(RelayGate.proof(token: token, role: "easld", name: name, easld: nonce, gate: theirs))
        client.send(#"{"id":"1","method":"system.ping"}"#)
        return (answer, try? await client.nextText())
    }

    /// The gate proves its token without sending it, splices only a connection that proves it back
    /// (a socket it serves), and after `rotate` (each new connection to the host) the old token
    /// opens nothing. Its proofs are easld's (`relay.Proof`'s pinned value).
    @Test func theRelayGateOpensOnlyToTheCurrentToken() async throws {
        #expect(RelayGate.proof(token: "0123456789abcdef0123456789abcdef", role: "gate", name: "easl",
                                easld: "00112233445566778899aabbccddeeff", gate: "ffeeddccbbaa99887766554433221100")
                == "f15a835e2e2f2ab2f5235980e309b1312d70b0dfad121e0f30d011fc406bc9b6")
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

        let old = gate.token
        let through = try await throughGate(gate, token: old)
        let answer = try #require(through.answer)
        #expect(!answer.contains(old), "the gate never sends its token")
        #expect(answer == "\(answer.prefix(32)) " + RelayGate.proof(token: old, role: "gate", name: "easl", easld: "00112233445566778899aabbccddeeff", gate: String(answer.prefix(32))))
        #expect(through.reply?.contains(#""pong":true"#) == true)
        #expect(try await throughGate(gate, token: String(repeating: "0", count: 64)).reply == nil, "a wrong token gets nothing")
        #expect(try await throughGate(gate, token: old, name: "other").answer == nil, "nor a socket the gate doesn't serve")

        let new = gate.rotate()
        #expect(new != old && gate.token == new)
        #expect(try await throughGate(gate, token: old).reply == nil, "the previous connection's token opens nothing")
        #expect(try await throughGate(gate, token: new).reply?.contains(#""pong":true"#) == true)
    }

    /// Reports spooled on the host for the open tiles come back as `AgentReportSpool` reads them,
    /// and removing the replayed ones leaves other tiles' alone.
    @Test func spooledReportsComeBackOnce() async throws {
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
        let archive = try await sh(HostedTerminal.spooled(run: run, tiles: ["obj_a", "obj_gone"]))
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

        _ = try await sh(HostedTerminal.removeSpooled(run: run, files: ["obj_a/3-1-r.json"]))
        #expect(!FileManager.default.fileExists(atPath: spool.appendingPathComponent("obj_a").path), "the emptied folder goes too")
        #expect(FileManager.default.fileExists(atPath: spool.appendingPathComponent("obj_b/4-1-r.json").path))
        #expect(try await sh(HostedTerminal.spooled(run: run, tiles: ["obj_a"])).output.isEmpty)
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

    /// A terminal's host is where its session runs, and the live terminal stays attached there:
    /// an update naming another host, or none (or giving a local terminal one), is refused and
    /// changes nothing, so history, kill and the surface can't disagree. The same host written
    /// differently, and other props, pass.
    @MainActor @Test func aTerminalsHostCantChange() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = Board(id: "brd_b", root: dir)
        let hosted = board.create(type: .terminal, props: .object(["host": "deckbox", "command": .array(["omp"])]))
        let local = board.create(type: .terminal, props: .object([:]))
        for (id, props) in [(hosted.id, ["host": JSONValue.string("mini")]), (hosted.id, ["host": .null]), (hosted.id, ["host": .string(" ")]),
                            (local.id, ["host": .string("deckbox")]), (hosted.id, ["name": .string("x"), "host": .string("mini")])] {
            do {
                try board.update(id, props: .object(props))
                Issue.record("\(props) was accepted")
            } catch BoardError.invalidParams(let message) {
                #expect(message.contains("host can't change"), "\(props): \(message)")
            }
        }
        #expect(board.objects[hosted.id]?.props["host"] == "deckbox" && board.objects[hosted.id]?.props["name"] == nil)
        #expect(board.objects[hosted.id]?.rev == hosted.rev)
        let renamed = try board.update(hosted.id, props: .object(["host": " deckbox ", "name": "agent"]))
        #expect(renamed.props["name"] == "agent")
    }
}
