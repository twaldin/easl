import Foundation

/// Another machine whose easl boards this one opens (File › Open Remote…, docs/design.md
/// "Remote boards"). SSH is the only transport: the API is the host's socket relayed by
/// `ssh -T <host> nc -U <socket>`, and terminals attach to the host's zmx sessions over `ssh -t`.
/// A value with no board content, so recent hosts can be remembered as they are.
public struct RemoteHost: Codable, Hashable, Sendable {
    /// The tailnet name, as the user knows the machine ("twaldin-work").
    public var name: String
    /// What `ssh` connects to: the tailnet name, or an ssh config alias or `user@host`.
    public var sshTarget: String
    /// The host's easl socket.
    public var socketPath: String
    /// The host's GUI session TMPDIR, where zmx keeps its sessions; an ssh session's differs on
    /// a Mac (`getconf DARWIN_USER_TEMP_DIR` finds the GUI's).
    public var tmpdir: String
    /// The host's `easl` CLI.
    public var easlBin: String
    /// The host's zmx: a non-interactive ssh session's PATH may lack Homebrew's directory.
    public var zmxBin: String

    public init(name: String, sshTarget: String, socketPath: String, tmpdir: String, easlBin: String, zmxBin: String = "zmx") {
        self.name = name
        self.sshTarget = sshTarget
        self.socketPath = socketPath
        self.tmpdir = tmpdir
        self.easlBin = easlBin
        self.zmxBin = zmxBin
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

    /// `ssh`'s arguments for `connection()`.
    public var relayArguments: [String] {
        ["-T"] + Self.batchOptions + [sshTarget, "nc", "-U", Self.quote(socketPath)]
    }

    /// Exit status of `terminalAttachCommand` when the host has no such session (yet).
    public static let noSessionStatus: Int32 = 75

    /// The command a terminal tile runs to show the host's zmx session `session`. It attaches
    /// only to a session that exists, else exits `noSessionStatus`: `zmx attach` creates a
    /// missing one (a bare shell without labels), and the host's own tile attaching later would
    /// find it and never run its agent.
    public func terminalAttachCommand(session: String) -> [String] {
        let zmx = Self.quote(zmxBin)
        let script = "\(zmx) get \"$1\" >/dev/null 2>&1 || { echo \"no session $1 yet\" >&2; exit \(Self.noSessionStatus); }; exec \(zmx) attach \"$1\""
        return [Self.ssh, "-t", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", sshTarget,
                "env", "TMPDIR=" + Self.quote(tmpdir), "sh", "-c", Self.quote(script), "sh", Self.quote(session)]
    }

    /// Starts easl on the host, without bringing it forward there. Needs a logged-in GUI session.
    public var startCommand: [String] {
        [Self.ssh, "-T"] + Self.batchOptions + [sshTarget, "open", "-g", "-a", "easl"]
    }

    // MARK: Discovery

    /// Asks the host where its socket, GUI TMPDIR, easl and zmx are, in one ssh call. `support`
    /// replaces the host's easl support directory (`EASL_DEV_REMOTE_HOME`: a development
    /// instance on the host, docs/testing.md). Throws `unavailable` with ssh's reason when the
    /// host can't be reached.
    public static func discover(name: String, sshTarget: String, support: String? = nil, timeout: TimeInterval = 20) async throws -> RemoteHost {
        let result = await run(ssh, ["-T"] + batchOptions + [sshTarget, "sh", "-c", quote(discoveryScript)], timeout: timeout)
        guard result.status == 0, let host = parseDiscovery(result.output, name: name, sshTarget: sshTarget, support: support) else {
            let reason = lastLine(result.errors) ?? (result.status == 0 ? "unexpected answer from \(sshTarget)" : "ssh exited with status \(result.status)")
            throw EaslConnection.Failure("unavailable", reason)
        }
        return host
    }

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
        """

    /// The host the discovery script's `output` describes: a Mac's easl lives in its app bundle
    /// and Application Support; elsewhere easld's home is `$XDG_STATE_HOME/easl`, else
    /// `~/.local/state/easl`. Nil without a home or a TMPDIR.
    public static func parseDiscovery(_ output: String, name: String, sshTarget: String, support: String? = nil) -> RemoteHost? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let home = values["home"], !home.isEmpty, let tmpdir = values["tmpdir"], !tmpdir.isEmpty else { return nil }
        let mac = values["os"] == "Darwin"
        let directory = support ?? (mac ? home + "/Library/Application Support/Easl" : ((values["state"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state") + "/easl"))
        let easl = mac ? "/Applications/easl.app/Contents/Resources/bin/easl" : (values["easl"] ?? "easl")
        return RemoteHost(name: name, sshTarget: sshTarget, socketPath: directory + "/easl.sock", tmpdir: tmpdir, easlBin: easl, zmxBin: values["zmx"] ?? "zmx")
    }

    // MARK: Helpers

    /// `word` as one word of a remote shell command: ssh joins its arguments with spaces and the
    /// host's shell splits them again ("Application Support" would be two).
    public static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Runs `executable` off the cooperative pool (it blocks on pipes), terminated after
    /// `timeout`; stdin is empty.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> (status: Int32, output: String, errors: String) {
        await offPool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return (-1, "", "cannot run \(executable): \(error.localizedDescription)")
            }
            let running = UncheckedBox(process)
            let deadline = DispatchWorkItem { if running.value.isRunning { running.value.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            let stderr = Locked(Data())
            let drained = DispatchGroup()
            drained.enter()
            DispatchQueue.global().async {
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
    }
}

/// A non-Sendable value handed to another queue whose access is otherwise ordered.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
