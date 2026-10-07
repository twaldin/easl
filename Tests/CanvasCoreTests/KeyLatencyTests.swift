import Foundation
import Testing
@testable import CanvasCore

/// Keys into terminals are summed on the key path and handed over in batches: wait and handling
/// stay apart, the longest of each survives the sum, late keys are counted, and a flush empties.
struct KeyLatencyTests {
    @Test func sumsWaitAndHandlingApartAndKeepsEachMaximum() {
        var latency = KeyLatency()
        latency.add(waitMs: 10, handleMs: 1)
        latency.add(waitMs: 30, handleMs: 2)
        let batch = latency.flush()
        #expect(batch.keys == 2)
        #expect(batch.waitMs == 40 && batch.waitMaxMs == 30)
        #expect(batch.handleMs == 3 && batch.handleMaxMs == 2)
        #expect(batch.late == 0)
    }

    @Test func aKeyThatWaitedTheHitchLengthIsLate() {
        var latency = KeyLatency()
        latency.add(waitMs: KeyLatency.lateMs - 0.1, handleMs: 0.2)
        latency.add(waitMs: KeyLatency.lateMs, handleMs: 0.2)
        latency.add(waitMs: 1890, handleMs: 0.2)
        let batch = latency.flush()
        #expect(batch.late == 2)
        #expect(batch.waitMaxMs == 1890)
    }

    @Test func aFlushHandsOverTheBatchAndStartsAnEmptyOne() {
        var latency = KeyLatency()
        latency.add(waitMs: 5, handleMs: 0.5)
        #expect(!latency.flush().isEmpty)
        let next = latency.flush()
        #expect(next.isEmpty && next == KeyLatency.Batch())
    }
}
