import Foundation
import Testing
import CanvasCore

/// A tile keeps the foreground job the process-table walk found and reuses it while `holds`
/// says the walk would find the same job: the title changes of a working agent (every 80 ms)
/// then cost a few `proc_pidinfo` reads, not the walk.
struct ForegroundJobTests {
    let at = Date(timeIntervalSince1970: 1_000_000)
    /// A tile's `zsh -l -c 'omp; exec zsh -l'` (pid 10, its own foreground group) running omp (pid 11).
    let zsh = ForegroundJob.Process(pid: 10, startSeconds: 500, startMicros: 1, executable: "zsh", parent: 9, group: 10, foregroundGroup: 10)
    let omp = ForegroundJob.Process(pid: 11, startSeconds: 501, startMicros: 2, executable: "bun", parent: 10, group: 10, foregroundGroup: 10)

    var job: ForegroundJob { ForegroundJob(shell: zsh, leader: omp, via: .child, argv: ["omp"], found: at) }

    @Test func holdsWhileTheSameShellRunsTheSameChildInTheSameGroup() {
        #expect(job.holds(shell: zsh, leader: omp, groupLeaderGone: false, at: at.addingTimeInterval(0.5)))
    }

    @Test func expiresAtMaxAgeSoAnExecInPlaceOrANewerSiblingIsSeenWithinASecond() {
        // `python3 bootstrap.py` exec'ing `python3 agent.py`: same pid, start and executable name,
        // another argv. The reads can't tell, so the walk runs again once the job is a second old.
        #expect(!job.holds(shell: zsh, leader: omp, groupLeaderGone: false, at: at.addingTimeInterval(ForegroundJob.maxAge)))
        #expect(job.holds(shell: zsh, leader: omp, groupLeaderGone: false, at: at.addingTimeInterval(ForegroundJob.maxAge - 0.01)))
    }

    @Test func endsWhenTheLeaderIsGoneOrAnotherProcess() {
        var reused = omp
        reused.startSeconds += 1  // omp exited; its pid came back as another process
        var execd = omp
        execd.executable = "node"  // an exec in place into another binary
        #expect(!job.holds(shell: zsh, leader: nil, groupLeaderGone: false, at: at))
        #expect(!job.holds(shell: zsh, leader: reused, groupLeaderGone: false, at: at))
        #expect(!job.holds(shell: zsh, leader: execd, groupLeaderGone: false, at: at))
    }

    @Test func endsWhenTheShellIsGoneReplacedOrInAnotherForegroundGroup() {
        var replaced = zsh
        replaced.startSeconds += 7
        var backgrounded = zsh
        backgrounded.foregroundGroup = 12  // the terminal's foreground is another job now
        #expect(!job.holds(shell: nil, leader: omp, groupLeaderGone: false, at: at))
        #expect(!job.holds(shell: replaced, leader: omp, groupLeaderGone: false, at: at))
        #expect(!job.holds(shell: backgrounded, leader: omp, groupLeaderGone: false, at: at))
    }

    @Test func aChildEndsWhenItLeavesTheShellOrTheGroup() {
        var reparented = omp
        reparented.parent = 1  // the shell exec'd on; the child is launchd's now
        var ownGroup = omp
        ownGroup.group = 11  // setpgid: no longer in the terminal's foreground group
        #expect(!job.holds(shell: zsh, leader: reparented, groupLeaderGone: false, at: at))
        #expect(!job.holds(shell: zsh, leader: ownGroup, groupLeaderGone: false, at: at))
        // The group's own leader is nobody's child in particular.
        let direct = ForegroundJob(shell: zsh, leader: ForegroundJob.Process(pid: 10, startSeconds: 500, startMicros: 1, executable: "python3", parent: 9, group: 10, foregroundGroup: 10),
                                   via: .leader, argv: ["python3", "agent.py"], found: at)
        #expect(direct.holds(shell: zsh, leader: direct.leader, groupLeaderGone: false, at: at))
    }

    @Test func aGroupsOldestMemberHoldsOnlyWhileItsLeaderStaysGone() {
        // `a | b` with `a` exited: `b` (pid 21) stands for the pipeline until `a`'s pid is back.
        let shell = ForegroundJob.Process(pid: 10, startSeconds: 500, startMicros: 1, executable: "zsh", parent: 9, group: 10, foregroundGroup: 20)
        let b = ForegroundJob.Process(pid: 21, startSeconds: 502, startMicros: 0, executable: "sort", parent: 10, group: 20, foregroundGroup: 20)
        let pipeline = ForegroundJob(shell: shell, leader: b, via: .oldest, argv: ["sort"], found: at)
        #expect(pipeline.holds(shell: shell, leader: b, groupLeaderGone: true, at: at))
        #expect(!pipeline.holds(shell: shell, leader: b, groupLeaderGone: false, at: at))
    }
}
