import Foundation
import Testing
import CanvasCore

/// Terminals slow their redraws after a minute without input anywhere on the Mac and return to
/// full rate on the first input; only the transitions report a change.
struct IdleRedrawTests {
    @Test func slowsAtTheThresholdNotBefore() {
        var policy = IdleRedraw()
        let before = policy.sampled(idleSeconds: IdleRedraw.threshold - 0.1)
        #expect(!before && !policy.isIdle)
        let at = policy.sampled(idleSeconds: IdleRedraw.threshold)
        #expect(at && policy.isIdle)
    }

    @Test func inputRestoresFullRateOnceAndSamplesWhileIdleReportNoChange() {
        var policy = IdleRedraw()
        policy.sampled(idleSeconds: 600)
        let stillIdle = policy.sampled(idleSeconds: 601)
        #expect(!stillIdle, "still idle: nothing to switch")
        let restored = policy.input()
        #expect(restored && !policy.isIdle)
        let again = policy.input()
        #expect(!again, "already at full rate")
    }

    @Test func aSampleThatShowsInputElsewhereOnTheMacRestoresFullRate() {
        var policy = IdleRedraw()
        policy.sampled(idleSeconds: 90)
        let changed = policy.sampled(idleSeconds: 0.4)
        #expect(changed && !policy.isIdle)
    }

    @Test func aPulseIsShorterThanTheGapBetweenPulses() {
        // Otherwise a terminal would be visible more than it is occluded, and Ghostty would present
        // on most of its changes after all.
        #expect(IdleRedraw.pulse * IdleRedraw.idleHertz < 0.5)
    }

    @Test func samplesAMinuteAtMostWhileActiveAndEverySecondWhileIdle() {
        var policy = IdleRedraw()
        #expect(policy.nextSample(idleSeconds: 0) == IdleRedraw.threshold)
        #expect(policy.nextSample(idleSeconds: 45) == IdleRedraw.threshold - 45)
        #expect(policy.nextSample(idleSeconds: 59.9) == 1, "never busier than a sample a second")
        policy.sampled(idleSeconds: 60)
        #expect(policy.nextSample(idleSeconds: 60) == 1)
    }
}
