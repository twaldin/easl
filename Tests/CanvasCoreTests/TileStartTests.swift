import Foundation
import Testing
import CanvasCore

/// A terminal's initial command (a spawn's `command`, an agent's resume or agent.restart's
/// relaunch) in an app launched by launchd (Finder, the Dock, `open`, the updater): it inherits
/// only `/usr/bin:/bin:/usr/sbin:/sbin`, and the user's PATH is set in an interactive rc file
/// (`.zshrc`, or a `.bashrc` that returns when not interactive), as bun's installer writes it.
/// The command ran in `$SHELL -l -c`, which reads neither: `zsh:1: command not found: omp`.
final class TileStartTests {
    static let launchdPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("easl-tile-start-\(UUID().uuidString.prefix(8))")
    var home: String { dir.path + "/home" }
    var tools: String { dir.path + "/tools" }

    /// A home whose zsh and bash put `tools` (holding a stub `omp` that prints its arguments and
    /// PATH) on PATH only in interactive shells.
    init() throws {
        for path in [home, tools] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        try "#!/bin/sh\necho \"stub omp $*\"\necho \"PATH=$PATH\"\n".write(toFile: tools + "/omp", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools + "/omp")
        try rc(".zshrc", "export PATH=\"\(tools):$PATH\"")
        try rc(".bash_profile", ". \"$HOME/.bashrc\"")
        try rc(".bashrc", "case $- in *i*) ;; *) return;; esac\nexport PATH=\"\(tools):$PATH\"")
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func rc(_ name: String, _ body: String) throws {
        try (body + "\n").write(toFile: home + "/" + name, atomically: true, encoding: .utf8)
    }

    func loginShell(_ shell: String, timeout: Duration = .seconds(30)) -> LoginShell {
        LoginShell(shell: shell, home: home, inherited: ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": shell,
                                                         "TMPDIR": NSTemporaryDirectory(), "PATH": Self.launchdPath], timeout: timeout)
    }

    /// Runs a tile's session command `argv` from launchd's environment, without a terminal (the
    /// login shell after the command reads stdin's end and exits): what it printed.
    func spawn(_ argv: [String], shell: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["-i", "HOME=\(home)", "USER=\(NSUserName())", "SHELL=\(shell)", "PATH=\(Self.launchdPath)"] + argv
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let reader = output.fileHandleForReading
        let data = await offPool { reader.readDataToEndOfFile() }
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func aBareCommandResolvesAsAtTheTilesPrompt(shell: String) async throws {
        let command = ShellWords.quote(["omp", "--model", "x"])
        let before = try await spawn(LoginSession.tileStart(shell: shell, command: command, path: nil), shell: shell)
        #expect(before.contains("command not found") && !before.contains("stub omp"), "the login shell's own PATH lacks the rc's: \(before)")

        let login = loginShell(shell)
        let path = try #require(await offPool { login.interactivePath(from: Self.launchdPath) })
        #expect(path.split(separator: ":").first.map(String.init) == tools, "the rc's directory first: \(path)")
        let start = LoginSession.tileStart(shell: shell, command: command, path: LoginSession.commandPath(path, bin: "/easl/bin"))
        let after = try await spawn(start, shell: shell)
        #expect(after.contains("stub omp --model x\n"), "\(after)")
        #expect(after.contains("PATH=/easl/bin:\(tools):"), "easl's bin stays first: \(after)")
    }

    /// agent.restart (`--mode resume`) and a resume after a reboot run the agent's relaunch in a
    /// new session: the same start, so the same PATH.
    @Test func aRestartsRelaunchResolvesToo() async throws {
        let shell = "/bin/zsh"
        let relaunch = try #require(AgentResume.relaunch(kind: "omp", command: ["omp", "--model", "x"], session: "/sessions/s1.jsonl", model: nil, thinking: nil, args: []))
        let login = loginShell(shell)
        let path = await offPool { login.interactivePath(from: Self.launchdPath) }
        let output = try await spawn(LoginSession.tileStart(shell: shell, command: ShellWords.quote(relaunch.argv), path: path), shell: shell)
        #expect(output.contains("stub omp --model x --resume=/sessions/s1.jsonl\n"), "\(output)")
    }

    /// An rc file that hangs or fails doesn't hold the start up: the shell is ended at the
    /// deadline, and the command starts as before, with the login shell's own PATH.
    @Test(arguments: ["sleep 60", "exit 3"])
    func aHangingOrFailingRcStillSpawnsWithTheLoginShellsPath(rc body: String) async throws {
        let shell = "/bin/zsh"
        try rc(".zshrc", body + "\nexport PATH=\"\(tools):$PATH\"")
        let deadline: Duration = .seconds(1)
        let login = loginShell(shell, timeout: deadline)
        let asked = ContinuousClock.now
        let path = await offPool { login.interactivePath(from: Self.launchdPath) }
        // Bound as LoginShellTests': room for a loaded runner, and still well short of the 60 s.
        #expect(path == nil)
        #expect(asked.duration(to: .now) < deadline + .seconds(9))

        let command = ShellWords.quote(["/bin/sh", "-c", "echo spawned; echo \"PATH=$PATH\""])
        let start = LoginSession.tileStart(shell: shell, command: command, path: path)
        #expect(start == [shell, "-l", "-c", "\(command); exec '\(shell)' -l"], "as before the fix")
        let output = try await spawn(start, shell: shell)
        #expect(output.contains("spawned\n") && output.contains("/usr/bin") && !output.contains(tools), "\(output)")
    }

    /// Editing a startup file asks the shell again; until then the answer is cached.
    @Test func aChangedRcIsAskedAgain() async throws {
        let login = loginShell("/bin/zsh")
        let first = await offPool { login.interactivePath(from: Self.launchdPath) }
        #expect(first?.hasPrefix(tools + ":") == true)
        try rc(".zshrc", "export PATH=\"\(tools)/more:\(tools):$PATH\"")
        let second = await offPool { login.interactivePath(from: Self.launchdPath) }
        #expect(second?.hasPrefix("\(tools)/more:\(tools):") == true, "\(second ?? "nil")")
    }

    @Test func easlsBinGoesFirstOnce() {
        #expect(LoginSession.commandPath("/a:/easl/bin:/b", bin: "/easl/bin") == "/easl/bin:/a:/b")
        #expect(LoginSession.commandPath("/a:/b", bin: nil) == "/a:/b")
        #expect(LoginSession.tileStart(shell: "/bin/zsh", command: nil, path: "/a") == ["/bin/zsh", "-l"], "a plain shell reads the user's files itself")
    }
}
