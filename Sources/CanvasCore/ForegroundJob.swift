import Foundation

/// A terminal's foreground job as the last walk of the process table found it, kept by its tile
/// so that the next look (every title change: omp's spinner changes a working tile's title every
/// 80 ms) costs a few `proc_pidinfo` reads instead of the walk (docs/design.md, Performance).
/// `holds` says whether the walk would find the same job again; the tile walks again when it
/// doesn't, and in any case once the job is `maxAge` old, which bounds what the reads can't see
/// (an exec in place into a same-named binary, a newer sibling beside a living child).
public struct ForegroundJob: Equatable, Sendable {
    /// A process as the kernel describes it (`proc_bsdinfo`): pid reuse changes the start time,
    /// an exec the executable name.
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        public var startSeconds: UInt64
        public var startMicros: UInt64
        /// The executable's name (`pbi_comm`).
        public var executable: String
        public var parent: Int32
        public var group: Int32
        /// The foreground process group of the process's terminal (`e_tpgid`); 0 without one.
        public var foregroundGroup: Int32

        public init(pid: Int32, startSeconds: UInt64, startMicros: UInt64, executable: String, parent: Int32, group: Int32, foregroundGroup: Int32) {
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicros = startMicros
            self.executable = executable
            self.parent = parent
            self.group = group
            self.foregroundGroup = foregroundGroup
        }

        /// The same process: pid, start time and executable name.
        public func isSame(as other: Process) -> Bool {
            pid == other.pid && startSeconds == other.startSeconds && startMicros == other.startMicros && executable == other.executable
        }
    }

    /// How the walk found the leader.
    public enum Via: Equatable, Sendable {
        /// The foreground group's own leader (the shell itself when it runs the program without a shell).
        case leader
        /// The newest child of a `-c` shell in its group.
        case child
        /// The oldest member of a group whose leader exited (the first stage of a pipeline).
        case oldest
    }

    public var shell: Process
    public var leader: Process
    public var via: Via
    public var argv: [String]
    /// When the walk ran.
    public var found: Date

    /// How long a job is reused before the walk runs again whatever the reads say.
    public static let maxAge: TimeInterval = 1

    public init(shell: Process, leader: Process, via: Via, argv: [String], found: Date) {
        self.shell = shell
        self.leader = leader
        self.via = via
        self.argv = argv
        self.found = found
    }

    /// Whether the walk would find this job again, from the shell and leader as they are now
    /// (nil: gone) and, for a job found as a group's oldest member, whether the group's leader
    /// is still gone: the job is younger than `maxAge`, the shell is the same process with the
    /// same foreground group, the leader the same process in that group, and a child is still
    /// the shell's.
    public func holds(shell now: Process?, leader current: Process?, groupLeaderGone: Bool, at time: Date) -> Bool {
        guard time.timeIntervalSince(found) < Self.maxAge, let now, now.isSame(as: shell), now.foregroundGroup == shell.foregroundGroup,
              let current, current.isSame(as: leader), current.group == shell.foregroundGroup else { return false }
        switch via {
        case .leader: return true
        case .child: return current.parent == shell.pid
        case .oldest: return groupLeaderGone
        }
    }
}
