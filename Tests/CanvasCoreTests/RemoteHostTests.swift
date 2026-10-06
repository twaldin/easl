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
        let result = await RemoteHost.run("/bin/sh", ["-c", "printf '%s\\n' \(line)"], timeout: 5)
        return result.output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    @Test func aMacKeepsEaslInApplicationSupportAndItsBundle() {
        let output = "os=Darwin\nhome=/Users/tim\ntmpdir=/var/folders/3b/x/T/\nstate=\nzmx=/opt/homebrew/bin/zmx\n"
        let host = RemoteHost.parseDiscovery(output, name: "work", sshTarget: "work")
        #expect(host == RemoteHost(name: "work", sshTarget: "work", socketPath: "/Users/tim/Library/Application Support/Easl/easl.sock",
                                   tmpdir: "/var/folders/3b/x/T/", easlBin: "/Applications/easl.app/Contents/Resources/bin/easl", zmxBin: "/opt/homebrew/bin/zmx"))
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

    @Test func anAnswerWithoutHomeOrTmpdirIsNoHost() {
        #expect(RemoteHost.parseDiscovery("Welcome to work!\n", name: "work", sshTarget: "work") == nil)
    }

    /// The script as the host's shell runs it, on this Mac: the GUI session's TMPDIR, which an
    /// ssh session's TMPDIR isn't.
    @Test func theDiscoveryScriptFindsThisMacsGuiTmpdir() async throws {
        let result = await RemoteHost.run("/bin/sh", ["-c", RemoteHost.discoveryScript], timeout: 10)
        let host = try #require(RemoteHost.parseDiscovery(result.output, name: "here", sshTarget: "here"))
        let gui = await RemoteHost.run("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], timeout: 5).output.trimmingCharacters(in: .newlines)
        #expect(host.tmpdir == gui)
        #expect(host.socketPath == NSHomeDirectory() + "/Library/Application Support/Easl/easl.sock")
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
            return await RemoteHost.run("/bin/sh", ["-c", command[(index + 1)...].joined(separator: " ")], timeout: 5)
        }
        let present = try await run("present")
        #expect(present.status == 0)
        #expect(present.output == "attached present in /var/folders/3b/x/T/\n")
        let missing = try await run("it's missing")
        #expect(missing.status == RemoteHost.noSessionStatus)
        #expect(missing.output.isEmpty, "never attached, so zmx never created it")
        #expect(missing.errors == "no session it's missing yet\n")
    }
}
