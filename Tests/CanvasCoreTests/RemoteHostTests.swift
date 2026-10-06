import Foundation
import Testing
import CanvasCore

/// Where a host keeps its easl socket, GUI TMPDIR and zmx, and the ssh commands built from them.
struct RemoteHostTests {
    /// The words the host's shell runs for ssh arguments after the target: sshd joins them with
    /// spaces and hands the line to the user's shell.
    func remoteWords(_ arguments: [String], after target: String) async throws -> [String] {
        let index = try #require(arguments.firstIndex(of: target))
        let line = arguments[(index + 1)...].joined(separator: " ")
        let result = try await RemoteHost.run("/bin/sh", ["-c", "printf '%s\\n' \(line)"], timeout: 5)
        return result.output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    @Test func aMacKeepsEaslInApplicationSupportAndItsBundle() {
        let output = "os=Darwin\nhome=/Users/tim\ntmpdir=/var/folders/3b/x/T/\nstate=\nzmx=/opt/homebrew/bin/zmx\n"
        let host = RemoteHost.parseDiscovery(output, name: "work", sshTarget: "work")
        #expect(host == RemoteHost(name: "work", sshTarget: "work", socketPath: "/Users/tim/Library/Application Support/Easl/easl.sock",
                                   tmpdir: "/var/folders/3b/x/T/", easlBin: "/Applications/easl.app/Contents/Resources/bin/easl", zmxBin: "/opt/homebrew/bin/zmx",
                                   appBundle: "/Applications/easl.app"))
    }

    @Test func linuxKeepsEasldsHomeUnderXDGState() {
        let plain = RemoteHost.parseDiscovery("os=Linux\nhome=/home/tim\ntmpdir=/tmp\nstate=\neasl=/home/tim/.local/bin/easl\n", name: "deckbox", sshTarget: "deckbox")
        #expect(plain?.socketPath == "/home/tim/.local/state/easl/easl.sock")
        #expect(plain?.tmpdir == "/tmp")
        #expect(plain?.easlBin == "/home/tim/.local/bin/easl")
        #expect(plain?.zmxBin == "zmx", "not installed: the PATH's, if any")
        let xdg = RemoteHost.parseDiscovery("os=Linux\nhome=/home/tim\ntmpdir=/tmp\nstate=/srv/state\n", name: "deckbox", sshTarget: "deckbox")
        #expect(xdg?.socketPath == "/srv/state/easl/easl.sock")
    }

    @Test func aSupportDirectoryOverridesTheHostsOwn() {
        let host = RemoteHost.parseDiscovery("os=Darwin\nhome=/Users/tim\ntmpdir=/var/folders/T/\n", name: "localhost", sshTarget: "localhost", support: "/tmp/easl-dev-host")
        #expect(host?.socketPath == "/tmp/easl-dev-host/easl.sock")
    }

    @Test func startOpensTheInstalledBundleOnlyForTheInstanceWhoseSocketWasFound() {
        let mac = "os=Darwin\nhome=/Users/tim\ntmpdir=/var/folders/T/\n"
        let production = RemoteHost.parseDiscovery(mac, name: "work", sshTarget: "work.tail1234.ts.net")
        #expect(production?.startCommand?.suffix(4) == ["work.tail1234.ts.net", "open", "-g", "/Applications/easl.app"])
        #expect(production?.startCommand?.contains("-a") == false, "not whichever app the name easl resolves to")
        let development = RemoteHost.parseDiscovery(mac, name: "localhost", sshTarget: "localhost", support: "/tmp/easl-dev-host")
        #expect(development?.socketPath == "/tmp/easl-dev-host/easl.sock")
        #expect(development?.startCommand == nil, "a development instance's launcher isn't known: starting the installed app would open another home")
        let linux = RemoteHost.parseDiscovery("os=Linux\nhome=/home/tim\ntmpdir=/tmp\n", name: "deckbox", sshTarget: "deckbox")
        #expect(linux?.startCommand == nil)
        let known = RemoteHost(name: "dev", sshTarget: "dev", socketPath: "/s", tmpdir: "/tmp", easlBin: "easl", appBundle: "/Users/tim/dev bundles/easl.app")
        #expect(known.startCommand?.suffix(3) == ["open", "-g", "'/Users/tim/dev bundles/easl.app'"], "quoted for the host's shell")
    }

    @Test func theRelayAsksNcToShutDownAtEofWhereTheHostCan() {
        func host(_ shutdown: Bool) -> RemoteHost {
            RemoteHost(name: "deckbox", sshTarget: "deckbox", socketPath: "/s", tmpdir: "/tmp", easlBin: "easl", ncShutdown: shutdown)
        }
        #expect(host(true).relayArguments.suffix(3) == ["-U", "-N", "/s"])
        #expect(host(false).relayArguments.suffix(2) == ["-U", "/s"], "macOS's nc has no -N")
    }

    /// The discovery script as a host's shell runs it, where `nc -h` prints `help`.
    func discover(ncHelp help: String) async throws -> RemoteHost {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nc = dir.appendingPathComponent("nc").path
        try "#!/bin/sh\ncat >&2 <<'EOF'\n\(help)\nEOF\nexit 1\n".write(toFile: nc, atomically: true, encoding: .utf8)
        chmod(nc, 0o755)
        let result = try await RemoteHost.run("/usr/bin/env", ["PATH=\(dir.path):/usr/bin:/bin", "/bin/sh", "-c", RemoteHost.discoveryScript], timeout: 10)
        return try #require(RemoteHost.parseDiscovery(result.output, name: "h", sshTarget: "h"))
    }

    /// Apple's `nc` lists `-N num_probes` (a TCP write-timeout option): given as `-N <socket>` it
    /// would take the socket's path for its argument, so only a `-N` that shuts down at EOF counts.
    @Test func theDiscoveryScriptFindsWhetherNcShutsDownAtEof() async throws {
        let openbsd = "usage: nc [-46CDdFhklNnrStUuvZz] [-I length]\n\tCommand Summary:\n\t\t-4\t\tUse IPv4\n\t\t-N\t\tShutdown the network socket after EOF on stdin\n\t\t-n\t\tSuppress name/port resolutions"
        let apple = "usage: nc [-46AacCDdEFhklMnOortUuvz] [-K tc]\n\tCommand Summary:\n\t-4\t\t\tUse IPv4\n\t-N num_probes\t\tNumber of probes to send before generating a write timeout event\n\t-n\t\t\tSuppress name/port resolutions"
        #expect(try await discover(ncHelp: openbsd).ncShutdown)
        #expect(try await discover(ncHelp: apple).ncShutdown == false)
    }

    @Test func anAnswerWithoutHomeOrTmpdirIsNoHost() {
        #expect(RemoteHost.parseDiscovery("Welcome to work!\n", name: "work", sshTarget: "work") == nil)
    }

    /// The script as the host's shell runs it, on this Mac: the GUI session's TMPDIR, which an
    /// ssh session's TMPDIR isn't.
    @Test func theDiscoveryScriptFindsThisMacsGuiTmpdir() async throws {
        let result = try await RemoteHost.run("/bin/sh", ["-c", RemoteHost.discoveryScript], timeout: 10)
        let host = try #require(RemoteHost.parseDiscovery(result.output, name: "here", sshTarget: "here"))
        let gui = try await RemoteHost.run("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], timeout: 5).output.trimmingCharacters(in: .newlines)
        #expect(host.tmpdir == gui)
        #expect(host.socketPath == NSHomeDirectory() + "/Library/Application Support/Easl/easl.sock")
        #expect(!host.ncShutdown, "this Mac's nc has no shutdown-at-EOF -N; its -N takes a count")
    }

    @Test func theRelaySurvivesTheHostsShellSplittingASocketPathWithSpaces() async throws {
        let host = RemoteHost(name: "work", sshTarget: "work", socketPath: "/Users/tim/Library/Application Support/Easl/easl.sock", tmpdir: "/var/folders/T/", easlBin: "easl")
        #expect(host.relayArguments.first == "-T")
        #expect(try await remoteWords(host.relayArguments, after: "work") == ["nc", "-U", "/Users/tim/Library/Application Support/Easl/easl.sock"])
    }

    /// The attach command's remote half as the host's shell runs it, with a zmx that knows one
    /// session ("present") and says what it attached to.
    @Test func aTerminalAttachesOnlyToASessionTheHostHasWithItsGuiTmpdir() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rh-\(UUID().uuidString.prefix(8)) zmx")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zmx = dir.appendingPathComponent("zmx").path
        try "#!/bin/sh\ncase \"$1\" in get) [ \"$2\" = present ] ;; attach) echo \"attached $2 in $TMPDIR\" ;; *) exit 2 ;; esac\n".write(toFile: zmx, atomically: true, encoding: .utf8)
        chmod(zmx, 0o755)
        let host = RemoteHost(name: "work", sshTarget: "work", socketPath: "/s", tmpdir: "/var/folders/3b/x/T/", easlBin: "easl", zmxBin: zmx)

        func run(_ session: String) async throws -> (status: Int32, output: String, errors: String) {
            let command = host.terminalAttachCommand(session: session)
            #expect(command.first == RemoteHost.ssh)
            #expect(command.contains("-t"), "zmx attach needs a terminal")
            let index = try #require(command.firstIndex(of: "work"))
            return try await RemoteHost.run("/bin/sh", ["-c", command[(index + 1)...].joined(separator: " ")], timeout: 5)
        }
        let present = try await run("present")
        #expect(present.status == 0)
        #expect(present.output == "attached present in /var/folders/3b/x/T/\n")
        let missing = try await run("it's missing")
        #expect(missing.status == RemoteHost.noSessionStatus)
        #expect(missing.output.isEmpty, "never attached, so zmx never created it")
        #expect(missing.errors == "no session it's missing yet\n")
    }

    @Test func recentHostsAreNewestFirstOncePerTargetAndCapped() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rh-\(UUID().uuidString.prefix(8))/remote-hosts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func host(_ target: String, tmpdir: String = "/tmp") -> RemoteHost {
            RemoteHost(name: target, sshTarget: target, socketPath: "/s", tmpdir: tmpdir, easlBin: "easl")
        }
        #expect(RemoteHost.Recents.load(url).isEmpty)
        for index in 0..<10 { RemoteHost.Recents.remember(host("h\(index)"), in: url) }
        RemoteHost.Recents.remember(host("h5", tmpdir: "/var/folders/new/T/"), in: url)
        let recents = RemoteHost.Recents.load(url)
        #expect(recents.map(\.sshTarget) == ["h5", "h9", "h8", "h7", "h6", "h4", "h3", "h2"])
        #expect(recents.first?.tmpdir == "/var/folders/new/T/", "the newest discovery replaces the old")
    }

    @Test func boardsListOpenOnesFirstWithTheirAgents() {
        let boards: JSONValue = .object(["boards": .array([
            .object(["board": .string("brd_z"), "root": .string("/Users/tim/dev/zeta"), "open": .bool(true), "archived": .bool(false), "objects": .number(3)]),
            .object(["board": .string("brd_gone"), "root": .string("/Users/tim/dev/old"), "open": .bool(false), "archived": .bool(true), "objects": .number(0)]),
            .object(["board": .string("brd_a"), "root": .string("/Users/tim/dev/alpha"), "open": .bool(false), "archived": .bool(false), "objects": .number(9)]),
            .object(["board": .string("brd_l"), "root": .string("/Users/tim/dev/lindy"), "open": .bool(true), "archived": .bool(false), "objects": .number(40)]),
        ])])
        let agents: JSONValue = .object(["agents": .array([
            .object(["tile": .string("obj_1"), "board": .string("brd_l"), "kind": .string("omp")]),
            .object(["tile": .string("obj_2"), "board": .string("brd_l"), "kind": .string("claude")]),
            .object(["tile": .string("obj_3"), "board": .string("brd_l"), "kind": .string("unknown")]),
            .object(["tile": .string("obj_4"), "board": .string("brd_z"), "kind": .string("codex")]),
        ])])
        let rows = RemoteBoard.list(boards: boards, agents: agents)
        #expect(rows.map(\.name) == ["lindy", "zeta", "alpha", "old"])
        #expect(rows.map(\.agents) == [2, 1, 0, 0], "a plain shell isn't an agent")
        #expect(rows.map(\.open) == [true, true, false, false])
        #expect(rows.last?.archived == true)
    }

    @Test func theTailnetsPeersComeFromTailscaleStatus() throws {
        let status = #"""
        {"Self": {"HostName": "twaldin-home", "DNSName": "twaldin-home.tail1234.ts.net.", "OS": "macOS", "Online": true},
         "Peer": {
           "k1": {"HostName": "twaldin-work", "DNSName": "twaldin-work.tail1234.ts.net.", "OS": "macOS", "Online": true},
           "k2": {"HostName": "deckbox", "DNSName": "deckbox.tail1234.ts.net.", "OS": "linux", "Online": true},
           "k3": {"HostName": "studio", "DNSName": "studio.tail1234.ts.net.", "OS": "macOS", "Online": false},
           "k4": {"HostName": "twaldin-phone", "DNSName": "twaldin-phone.tail1234.ts.net.", "OS": "iOS", "Online": true}}}
        """#
        let peers = try Tailnet.peers(status: Data(status.utf8))
        #expect(peers.map(\.name) == ["deckbox", "studio", "twaldin-phone", "twaldin-work"], "this machine isn't a peer")
        #expect(peers.filter { $0.isMac && $0.online }.map(\.name) == ["twaldin-work"])
        #expect(try Tailnet.peers(status: Data(#"{"BackendState": "Stopped", "Peer": null}"#.utf8)).isEmpty)
    }

    /// `HostName` is neither a DNS name nor unique (tailscale's ipnstate): ssh to it reaches
    /// nothing for a renamed machine and the wrong one for a namesake.
    @Test func aPeerIsReachedByItsDnsNameElseItsTailscaleAddressNeverItsHostName() throws {
        let status = #"""
        {"Peer": {
           "k1": {"HostName": "MacBook-Pro", "DNSName": "studio.tail1234.ts.net.", "TailscaleIPs": ["100.64.0.7", "fd7a:115c:a1e0::7"], "OS": "macOS", "Online": true},
           "k2": {"HostName": "MacBook-Pro", "DNSName": "laptop.tail1234.ts.net.", "TailscaleIPs": ["100.64.0.8"], "OS": "macOS", "Online": true},
           "k3": {"HostName": "bare", "DNSName": "", "TailscaleIPs": ["100.64.0.9", "fd7a:115c:a1e0::9"], "OS": "macOS", "Online": true},
           "k4": {"HostName": "bare-too", "TailscaleIPs": ["100.64.0.10"], "OS": "macOS", "Online": true},
           "k5": {"HostName": "nowhere", "OS": "macOS", "Online": true}}}
        """#
        let peers = try Tailnet.peers(status: Data(status.utf8))
        #expect(peers.map(\.name) == ["bare", "bare-too", "MacBook-Pro", "MacBook-Pro"], "a peer with no name to connect to isn't offered")
        #expect(peers.map(\.sshTarget) == ["100.64.0.9", "100.64.0.10", "laptop.tail1234.ts.net", "studio.tail1234.ts.net"],
                "the DNS name without its trailing dot, else the first Tailscale address; namesakes stay apart")
    }

    @Test func hostsOpenedBeforeMatchTheirPeerByTargetAndNamesakesStayApart() {
        func peer(_ name: String, _ target: String, os: String = "macOS", online: Bool = true) -> TailnetPeer {
            TailnetPeer(name: name, sshTarget: target, os: os, online: online)
        }
        func recent(_ name: String, _ target: String) -> RemoteHost {
            RemoteHost(name: name, sshTarget: target, socketPath: "/s", tmpdir: "/tmp", easlBin: "easl")
        }
        let rows = RemoteHost.candidates(
            peers: [peer("MacBook-Pro", "laptop.tail1234.ts.net"), peer("MacBook-Pro", "studio.tail1234.ts.net"),
                    peer("deckbox", "deckbox.tail1234.ts.net", os: "linux"), peer("old-mac", "old-mac.tail1234.ts.net", online: false)],
            recents: [recent("MacBook-Pro", "studio.tail1234.ts.net"), recent("old-mac", "old-mac.tail1234.ts.net"),
                      recent("deckbox", "deckbox.tail1234.ts.net"), recent("twaldin-work", "twaldin-work")])
        #expect(rows.map(\.sshTarget) == ["laptop.tail1234.ts.net", "studio.tail1234.ts.net", "old-mac.tail1234.ts.net", "deckbox.tail1234.ts.net", "twaldin-work"])
        #expect(rows[0].detail == "Mac, online, laptop.tail1234.ts.net", "a namesake is named by its target")
        #expect(rows[1].detail == "Mac, online, studio.tail1234.ts.net, opened before", "the one that was opened, not its namesake")
        #expect(rows.map(\.name) == ["MacBook-Pro", "MacBook-Pro", "old-mac", "deckbox", "twaldin-work"])
        #expect(rows[2].detail == "offline" && !rows[2].online)
        #expect(rows[3].detail == "linux, online, opened before" && rows[3].online)
        #expect(rows[4].detail == "opened before" && rows[4].online, "the tailnet doesn't list a name it was opened by")
    }

    /// Polls for the pid a test script wrote to `file`: long, since a CI runner can stall every
    /// test for seconds.
    func pid(in file: String) async -> Int32? {
        for _ in 0..<3000 {
            if let text = try? String(contentsOfFile: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func cancellingARunEndsAndReapsItsProcess() async throws {
        let file = NSTemporaryDirectory() + "rh-\(UUID().uuidString.prefix(8)).pid"
        defer { try? FileManager.default.removeItem(atPath: file) }
        let task = Task { try await RemoteHost.run("/bin/sh", ["-c", "echo $$ > '\(file)'; exec sleep 60"], timeout: 120) }
        let pid = try #require(await pid(in: file))
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 30, "it didn't wait out the sleep, or the timeout")
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "gone, not a zombie waiting to be reaped")
    }

    @Test func aRunCancelledBeforeItStartsNeverStarts() async throws {
        let marker = NSTemporaryDirectory() + "rh-\(UUID().uuidString.prefix(8)).ran"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let task = Task {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return try await RemoteHost.run("/bin/sh", ["-c", "touch '\(marker)'"], timeout: 30)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func tailscaleIsTheMacAppsElseOnPathElseHomebrews() {
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        #expect(Tailnet.binary(path: "/usr/bin:/opt/homebrew/bin", isExecutable: { [app, "/opt/homebrew/bin/tailscale"].contains($0) }) == app)
        #expect(Tailnet.binary(path: "/usr/bin:/custom/bin", isExecutable: { ["/custom/bin/tailscale", "/opt/homebrew/bin/tailscale"].contains($0) }) == "/custom/bin/tailscale")
        #expect(Tailnet.binary(path: "/usr/bin:/bin", isExecutable: { $0 == "/opt/homebrew/bin/tailscale" }) == "/opt/homebrew/bin/tailscale", "launchd's PATH lacks Homebrew's")
        #expect(Tailnet.binary(path: "/usr/bin", isExecutable: { _ in false }) == nil)
    }
}
