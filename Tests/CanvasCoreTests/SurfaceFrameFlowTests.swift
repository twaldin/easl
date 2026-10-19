import Testing
import CanvasCore

struct SurfaceFrameFlowTests {
    @Test func inputSupersedesOnlyAnIdleRefinement() {
        var flow = SurfaceFrameFlow(adaptive: true)
        #expect(flow.supersedeRefinement() == false)
        #expect(flow.acknowledge(0, at: 0) == .granted)
        #expect(flow.publish(1, refinement: false, at: 1) == nil)
        #expect(flow.supersedeRefinement() == false)
        #expect(flow.next == nil)
        #expect(flow.acknowledge(1, at: 1.1) == .granted)
        #expect(flow.publish(2, refinement: true, at: 2) == nil)
        #expect(flow.supersedeRefinement() == true)
        #expect(flow.next == 3)
        #expect(flow.acknowledge(2, at: 2.1) == .stale)
        #expect(flow.publish(3, refinement: false, at: 2.2) == 2)
        #expect(flow.acknowledge(2, at: 2.3) == .stale)
        #expect(flow.next == nil)
        #expect(flow.acknowledge(3, at: 2.4) == .granted)
        #expect(flow.next == 4)
    }

    @Test func consecutiveCanceledRefinementsRetainTheEarliestSupersededSequenceUntilMatchedAck() {
        var flow = SurfaceFrameFlow(adaptive: true)
        #expect(flow.acknowledge(0, at: 0) == .granted)
        #expect(flow.publish(1, refinement: false, at: 1) == nil)
        #expect(flow.supersedeRefinement() == false)
        #expect(flow.acknowledge(1, at: 1.01) == .granted)
        #expect(flow.publish(2, refinement: true, at: 2) == nil)
        #expect(flow.supersedeRefinement() == true)
        #expect(flow.acknowledge(2, at: 2.01) == .stale)
        #expect(flow.next == 3)
        #expect(flow.publish(3, refinement: true, at: 3) == 2)
        #expect(flow.acknowledge(2, at: 3.01) == .stale)
        #expect(flow.next == nil)
        #expect(flow.supersedeRefinement() == true)
        #expect(flow.acknowledge(3, at: 3.02) == .stale)
        #expect(flow.acknowledge(4, at: 3.03) == .invalid)
        #expect(flow.next == 4)
        #expect(flow.publish(4, refinement: false, at: 4) == 2)
        #expect(flow.supersedeRefinement() == false)
        for canceled in [2, 3, 2, 3] {
            #expect(flow.acknowledge(canceled, at: 4.01) == .stale)
            #expect(flow.next == nil)
        }
        #expect(flow.acknowledge(5, at: 4.02) == .invalid)
        #expect(flow.next == nil)
        #expect(flow.acknowledge(4, at: 4.03) == .granted)
        #expect(flow.acknowledge(4, at: 4.04) == .stale)
        #expect(flow.next == 5)
        #expect(flow.publish(5, refinement: true, at: 5) == nil)
        #expect(flow.supersedeRefinement() == true)
        #expect(flow.publish(6, refinement: false, at: 6) == 5)
        #expect(flow.acknowledge(5, at: 6.01) == .stale)
        #expect(flow.next == nil)
        #expect(flow.acknowledge(6, at: 6.02) == .granted)
        #expect(flow.publish(7, refinement: false, at: 7) == nil)
        #expect(flow.supersedeRefinement() == false)
        #expect(flow.next == nil)
    }

    @Test func futureAndDuplicateAcknowledgementsNeverAccumulateCredit() {
        var flow = SurfaceFrameFlow(adaptive: false)
        #expect(flow.acknowledge(1, at: 0) == .invalid)
        #expect(flow.next == nil)
        #expect(flow.acknowledge(0, at: 1) == .granted)
        #expect(flow.acknowledge(0, at: 2) == .stale)
        #expect(flow.acknowledge(1, at: 2) == .invalid)
        #expect(flow.next == 1)
    }

    @Test func decodedWarmFramesMeasureTheLinkWithoutColdDecoderBias() {
        var fast = SurfaceFrameFlow(adaptive: true)
        #expect(fast.acknowledge(0, at: 100) == .granted)
        #expect(fast.mode == .probing)
        for (frame, elapsed) in [(1, 0.12), (2, 0.015), (3, 0.02)] {
            _ = fast.publish(frame, refinement: false, at: Double(frame))
            #expect(fast.acknowledge(frame, at: Double(frame) + elapsed) == .granted)
            #expect(fast.mode == (frame == 3 ? .jpeg : .probing))
        }
        var slow = SurfaceFrameFlow(adaptive: true)
        _ = slow.acknowledge(0, at: 0)
        for (frame, elapsed) in [(1, 0.12), (2, 0.08), (3, 0.09)] {
            _ = slow.publish(frame, refinement: false, at: Double(frame))
            _ = slow.acknowledge(frame, at: Double(frame) + elapsed)
        }
        #expect(slow.mode == .video)
        var raw = SurfaceFrameFlow(adaptive: false)
        _ = raw.acknowledge(0, at: 0)
        _ = raw.publish(1, refinement: false, at: 1)
        _ = raw.acknowledge(1, at: 1.001)
        #expect(raw.mode == .video)
    }
}
