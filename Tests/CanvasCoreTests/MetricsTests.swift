import Testing
import CanvasCore

/// The main-thread monitor's turn timing across a metrics reset.
struct MetricsTests {
    @Test func aResetDropsBusyTimeAndTheTurnBeforeIt() {
        var turns = RunLoopTurns(at: 100)
        _ = turns.activity(sleeping: false, at: 100.0)
        _ = turns.activity(sleeping: false, at: 100.4)  // a 400 ms turn, not yet flushed
        // The reset lands 300 ms into the next turn, which ends 50 ms later.
        let rebased = turns.rebase(reset: 100.7)
        #expect(rebased)
        #expect(turns.turnStart == 100.4, "the turn keeps its start: its stall sample is correlated by it")
        let step = turns.activity(sleeping: true, at: 100.75)
        #expect(abs((step.turn ?? 0) - 50) < 0.001, "the turn counts from the reset")
        #expect(step.flush == nil)
        _ = turns.activity(sleeping: false, at: 101.5)
        let flushed = turns.activity(sleeping: true, at: 101.8).flush
        #expect(flushed?.turns == 2)
        #expect(abs((flushed?.ms ?? 0) - 350) < 0.001, "only time after the reset: 50 + 300 ms")
    }

    @Test func aResetIsAppliedOnce() {
        var turns = RunLoopTurns(at: 0)
        let first = turns.rebase(reset: 5)
        _ = turns.activity(sleeping: false, at: 6)
        let again = turns.rebase(reset: 5)
        #expect(first && !again)
        #expect(turns.turnStart == 6, "a reset already seen leaves the turn alone")
    }
}
