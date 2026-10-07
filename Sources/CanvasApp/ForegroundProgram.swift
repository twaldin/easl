import CanvasCore
import Darwin
import Foundation

/// What runs in the foreground of a terminal tile's zmx session, read from the process table
/// (libproc, sysctl): no process is started once the session's shell is known.
enum ForegroundProgram {
    enum State: Equatable {
        /// The session's shell is gone (the session ended or was replaced).
        case gone
        /// The shell's prompt: nothing runs in the foreground.
        case prompt
        /// The foreground job's argv.
        case running([String])
    }

    /// The pid of the session's shell (`zmx list`'s `pid=`); nil when zmx or the session is
    /// missing. Blocks until zmx exits: call it off the main actor.
    static func shellPid(session: String) -> pid_t? {
        for line in (Zmx.list() ?? "").split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t")
            guard fields.first?.drop(while: { $0 == " " || $0 == "*" }) == "name=\(session)" else { continue }
            return fields.lazy.compactMap { $0.hasPrefix("pid=") ? pid_t($0.dropFirst(4)) : nil }.first
        }
        return nil
    }

    /// The foreground job of the terminal `shell` runs in: the leader of the terminal's
    /// foreground process group. While that is the shell itself, the command a `-c` shell runs
    /// without job control (a tile's `zsh -l -c '<command>; exec zsh -l'`: its child in the same
    /// group), else its prompt (an interactive shell's own children, like a prompt's `git`
    /// status, aren't jobs). A process that isn't a shell (a tmux pane's program started
    /// without one) is its own job. A few syscalls; fine on the main actor.
    static func state(shell: pid_t) -> State {
        guard let leader = leader(shell: shell) else { return .gone }
        return leader.flatMap(arguments).map(State.running) ?? .prompt
    }

    /// `state`, and the directory what runs works in: the foreground job's current directory
    /// (`cd ../wt && codex` runs codex in `wt`, which the shell reports only at its next
    /// prompt), at the prompt the shell's own; nil when the shell is gone or it can't be read.
    /// Asked on every title change (omp's working title changes every 80 ms per tile), so the
    /// last running job found for `shell` is kept, and while it still holds (`Found.holds`:
    /// two or three `proc_pidinfo`s) its argv is reused instead of walked for again.
    @MainActor static func foreground(shell: pid_t) -> (state: State, directory: String?) {
        if let kept = kept[shell] {
            if kept.holds(shell: shell) { return (.running(kept.argv), SessionProcesses.directory(of: kept.leader)) }
            Self.kept[shell] = nil
        }
        guard let seen = job(shell: shell) else { return (.gone, nil) }
        guard let seen, let argv = arguments(seen.leader) else { return (.prompt, SessionProcesses.directory(of: shell)) }
        kept[shell] = seen.found(argv: argv)
        return (.running(argv), SessionProcesses.directory(of: seen.leader))
    }

    /// The last running job `foreground` found, per shell (main actor: `foreground`'s callers).
    @MainActor private static var kept: [pid_t: Found] = [:]

    /// A process as it was when seen: pid reuse and an exec in place (same pid, new program)
    /// both change it. The start time survives exec; the executable name (`pbi_comm`) changes
    /// with it, except for an exec into a same-named binary.
    private struct Identity: Equatable {
        var start: UInt64
        var startMicros: UInt64
        var comm: String

        init(_ info: proc_bsdinfo) {
            start = info.pbi_start_tvsec
            startMicros = info.pbi_start_tvusec
            comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    /// A foreground job `job` found, with how (`Via`), so `Found.holds` can check cheaply that
    /// the same walk would find it again.
    private struct Job {
        enum Via: Equatable {
            /// The group's own leader (the shell itself when it runs the program without a shell).
            case leader
            /// The newest child of a `-c` shell, among the group's members at the time.
            case child(members: [pid_t])
            /// The oldest member of a group whose leader exited, among the members at the time.
            case oldest(members: [pid_t])
        }

        var group: pid_t
        var shell: Identity
        var leader: pid_t
        var identity: Identity
        var via: Via

        func found(argv: [String]) -> Found { Found(job: self, argv: argv) }
    }

    private struct Found {
        var job: Job
        var argv: [String]
        var leader: pid_t { job.leader }

        /// Whether `job(shell:)` would find the same process again: the shell is the same
        /// process in the same foreground group, the leader is the same process, and a leader
        /// picked among the group's members was picked among the same pids (start times don't
        /// change, so the newest or oldest of them is still it).
        func holds(shell: pid_t) -> Bool {
            guard let info = bsdInfo(shell), pid_t(bitPattern: info.e_tpgid) == job.group, Identity(info) == job.shell,
                  let leader = bsdInfo(job.leader), Identity(leader) == job.identity else { return false }
            switch job.via {
            case .leader: return true
            case .child(let members): return leader.pbi_ppid == UInt32(shell) && ForegroundProgram.members(of: job.group) == members
            case .oldest(let members): return bsdInfo(job.group) == nil && ForegroundProgram.members(of: job.group) == members
            }
        }
    }

    /// What process `pid` runs, as a person names it (`TerminalName.program`; a login shell's
    /// `-zsh` is `zsh`).
    static func name(_ pid: pid_t) -> String? {
        guard var argv = arguments(pid), let first = argv.first else { return nil }
        if first.hasPrefix("-") { argv[0] = String(first.dropFirst()) }
        return TerminalName.program(argv: argv)
    }

    /// The foreground job's leader (`state`) as a pid: the agent when one runs in the session
    /// (agent.list `pid`); nil at the prompt or when the shell is gone.
    static func foregroundPid(shell: pid_t) -> pid_t? {
        leader(shell: shell) ?? nil
    }

    /// The foreground job's leader (`state`): nil when the shell is gone, `.some(nil)` at its prompt.
    private static func leader(shell: pid_t) -> pid_t?? {
        job(shell: shell).map { $0?.leader }
    }

    /// The foreground job (`leader`), with how it was found; nil when the shell is gone,
    /// `.some(nil)` at its prompt.
    private static func job(shell: pid_t) -> Job?? {
        guard let info = bsdInfo(shell) else { return nil }
        let group = pid_t(bitPattern: info.e_tpgid)
        guard group > 0 else { return .some(nil) }
        if group == shell {
            let argv = arguments(shell) ?? []
            if let first = argv.first, !SessionProcesses.isShell(first) {
                return .some(Job(group: group, shell: Identity(info), leader: shell, identity: Identity(info), via: .leader))
            }
            guard argv.contains("-c") else { return .some(nil) }
            let pids = members(of: group)
            let child = pids.filter { $0 != shell }.compactMap { pid in bsdInfo(pid).map { (pid, $0) } }
                .filter { $0.1.pbi_ppid == UInt32(shell) }
                .max { ($0.1.pbi_start_tvsec, $0.1.pbi_start_tvusec) < ($1.1.pbi_start_tvsec, $1.1.pbi_start_tvusec) }
            guard let child else { return .some(nil) }
            return .some(Job(group: group, shell: Identity(info), leader: child.0, identity: Identity(child.1), via: .child(members: pids)))
        }
        if let leader = bsdInfo(group) {
            return .some(Job(group: group, shell: Identity(info), leader: group, identity: Identity(leader), via: .leader))
        }
        // The group's leader exited (the first stage of a pipeline): its oldest member.
        let pids = members(of: group)
        guard let member = pids.min(), let oldest = bsdInfo(member) else { return .some(nil) }
        return .some(Job(group: group, shell: Identity(info), leader: member, identity: Identity(oldest), via: .oldest(members: pids)))
    }

    /// What closing the session ends (`SessionProcesses`): its foreground program and the
    /// other processes the shell or that program started. Nil when the shell is gone. Walks the
    /// process table once (a few hundred syscalls, ~1 ms): fine on the main actor for the close
    /// sheet, not for a timer.
    static func session(shell: pid_t) -> SessionProcesses? {
        guard let leader = leader(shell: shell) else { return nil }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let table = pids.prefix(max(0, Int(listed))).filter { $0 > 0 }.compactMap { pid in bsdInfo(pid).map { (pid, pid_t(bitPattern: $0.pbi_ppid)) } }
        let processes = SessionProcesses.descendants(of: shell, in: table).map { SessionProcesses.Process(pid: $0.pid, parent: $0.parent, argv: arguments($0.pid) ?? []) }
        return SessionProcesses(shell: shell, foreground: leader, processes: processes)
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func members(of group: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return bytes > 0 ? Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }) : []
    }

    /// Inside tmux, what typing into the session reaches: the program the active pane of the
    /// session's tmux client runs (`name`: `omp`, `vim`; at that pane's prompt, its shell), asked
    /// of the client's own server (its `-L`/`-S`, `TMUX_TMPDIR`, binary) for the pane shown on
    /// the client's terminal. Nil when the foreground program isn't tmux or tmux doesn't say.
    /// Runs tmux and waits for it: call it off the main actor.
    nonisolated static func tmuxPane(shell: pid_t) -> String? {
        guard let found = leader(shell: shell), let client = found, let running = process(client),
              running.argv.first?.split(separator: "/").last == "tmux", let info = bsdInfo(client),
              let tty = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let argv = running.argv
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(client, &path, UInt32(path.count)) > 0 else { return nil }
        // The server's socket, as the client chose it: `-S path`, `-L name`, else `default`.
        var server: [String] = []
        var index = 1
        while index < argv.count, argv[index].hasPrefix("-") {
            let option = argv[index]
            if option == "--" { break }
            if ["-L", "-S"].contains(option), index + 1 < argv.count {
                server = [option, argv[index + 1]]
                index += 1
            } else if option.hasPrefix("-L") || option.hasPrefix("-S"), option.count > 2 {
                server = [String(option.prefix(2)), String(option.dropFirst(2))]
            } else if ["-c", "-f", "-T"].contains(option) {
                index += 1
            }
            index += 1
        }
        let tmux = Process()
        tmux.executableURL = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }, as: UTF8.self))
        tmux.arguments = server + ["display-message", "-p", "-c", "/dev/" + String(cString: tty), "#{pane_pid}"]
        var env = ProcessInfo.processInfo.environment
        env["TMUX"] = nil
        env["TMUX_TMPDIR"] = running.environment.first { $0.hasPrefix("TMUX_TMPDIR=") }.map { String($0.dropFirst("TMUX_TMPDIR=".count)) }
        tmux.environment = env
        let output = Pipe()
        tmux.standardOutput = output
        tmux.standardError = FileHandle.nullDevice
        guard (try? tmux.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        tmux.waitUntilExit()
        guard tmux.terminationStatus == 0,
              let pane = pid_t(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return switch state(shell: pane) {
        case .running(let argv): TerminalName.program(argv: argv)
        case .prompt: name(pane)
        case .gone: nil
        }
    }

    private static func arguments(_ pid: pid_t) -> [String]? {
        process(pid, environment: false)?.argv
    }

    /// `KERN_PROCARGS2`: argc, the executable path, padding, argc NUL-terminated arguments, then
    /// the environment's `NAME=value` strings up to an empty one (read only when asked: a few
    /// kilobytes of strings nobody wants for the argv).
    private static func process(_ pid: pid_t, environment wanted: Bool = true) -> (argv: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // executable path
        while index < size, buffer[index] == 0 { index += 1 }  // padding
        var argv: [String] = []
        while argv.count < argc, index < size {
            let end = buffer[index..<size].firstIndex(of: 0) ?? size
            argv.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        guard !argv.isEmpty else { return nil }
        var environment: [String] = []
        while wanted, index < size, buffer[index] != 0 {
            let end = buffer[index..<size].firstIndex(of: 0) ?? size
            environment.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return (argv, environment)
    }
}
