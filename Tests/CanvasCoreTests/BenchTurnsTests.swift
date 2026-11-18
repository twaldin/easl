#if EASL_BENCH_TURNS
import Testing
@testable import CanvasCore

struct BenchTurnsTests {
    @Test func thresholdsQuantilesOverflowAndReset() {
        var turns = Metrics.BenchTurns()
        guard case .object(let empty) = turns.json else {
            Issue.record("Missing empty turn distribution")
            return
        }
        #expect(empty["n"] == .number(0))
        #expect(empty["p50UpperMs"] == .null)
        turns.record(15.999)
        turns.record(16)
        turns.record(49.999)
        turns.record(50)
        #expect(turns.over16 == 3)
        #expect(turns.over50 == 1)
        #expect(turns.maximum == 50)
        guard case .object(let measured) = turns.json,
              case .number(let median)? = measured["p50UpperMs"] else {
            Issue.record("Missing measured median")
            return
        }
        #expect(abs(median - 16.01) < 0.000001)
        turns.reset()
        guard case .object(let cleared) = turns.json else {
            Issue.record("Missing reset distribution")
            return
        }
        #expect(cleared["n"] == .number(0))
        #expect(cleared["maxMs"] == .number(0))
        #expect(cleared["p50UpperMs"] == .null)
        turns.record(200)
        turns.record(100)
        guard case .object(let overflow) = turns.json else {
            Issue.record("Missing overflow distribution")
            return
        }
        #expect(overflow["n"] == .number(2))
        #expect(overflow["p50UpperMs"] == .number(200))
        #expect(turns.over16 == 2)
        #expect(turns.over50 == 2)
    }
}
#endif
