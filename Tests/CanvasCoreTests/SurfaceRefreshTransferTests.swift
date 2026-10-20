import Foundation
import Testing
@testable import CanvasCore

struct SurfaceRefreshTransferTests {
    private func refresh(bytes: Int = 32769, seq: Int = 7) -> SurfaceEvent.Frame {
        var frame = SurfaceEvent.Frame(stream: "str_refresh", seq: seq, input: 3,
            size: CGSize(width: 640, height: 479), scale: 1, format: .h264,
            data: Data((0..<bytes).map { UInt8($0 % 251) }), width: 640, height: 479,
            back: true, forward: false, loading: false)
        frame.refresh = true
        frame.canvas = CGSize(width: 640, height: 479)
        frame.supersedes = 6
        return frame
    }

    private func part(_ frame: SurfaceEvent.Frame, offset: Int) -> SurfaceEvent.Frame {
        var part = frame
        part.offset = offset
        part.total = frame.data.count
        part.data = frame.data.subdata(in: offset..<min(offset + 16384, frame.data.count))
        return part
    }

    @Test func cumulativeReceiptsReleaseOnlyNewlyAcknowledgedCredit() throws {
        var transmission = try SurfaceRefreshTransmission(frame: refresh(bytes: 200000))
        #expect(throws: SurfaceRefreshTransferError.invalidOffset) { try transmission.progress(offset: 0) }
        let first = transmission.start()
        #expect(first.map(\.offset) == Array(stride(from: 0, to: 131072, by: 16384)))
        #expect(first.allSatisfy { $0.data.count == 16384 && $0.total == 200000 })
        #expect(transmission.start().isEmpty)
        for offset in [-16384, -1, 1, 131072, 147456, Int.max] {
            #expect(throws: SurfaceRefreshTransferError.invalidOffset) { try transmission.progress(offset: offset) }
        }
        #expect(try transmission.progress(offset: 16384).map(\.offset) == [131072, 147456])
        #expect(try transmission.progress(offset: 16384).isEmpty)
        #expect(try transmission.progress(offset: 0).isEmpty)
        #expect(throws: SurfaceRefreshTransferError.invalidOffset) { try transmission.progress(offset: 163840) }
        #expect(try transmission.progress(offset: 147456).map(\.offset) == [163840, 180224, 196608])
        #expect(try transmission.progress(offset: 49152).isEmpty)
        #expect(try transmission.progress(offset: 147456).isEmpty)
    }

    @Test(arguments: [589824, 589823, 131073])
    func batchedReceiptsAssembleEveryByteWithAtMost128KiBOutstanding(bytes: Int) throws {
        let original = refresh(bytes: bytes)
        var transmission = try SurfaceRefreshTransmission(frame: original)
        var assembly = SurfaceRefreshAssembly()
        var pending = transmission.start()
        var sentBytes = pending.reduce(0) { $0 + $1.data.count }
        var receivedBytes = 0
        var completed: SurfaceEvent.Frame?
        var offsets: [Int] = []
        var batch = 0
        while !pending.isEmpty {
            #expect(sentBytes - receivedBytes <= 131072)
            #expect(pending.count <= 8)
            let count = min([1, 7, 2, 8][batch % 4], pending.count)
            let received = Array(pending.prefix(count))
            pending.removeFirst(count)
            for next in received {
                #expect(next.offset == receivedBytes)
                offsets.append(try #require(next.offset))
                receivedBytes += next.data.count
                completed = try assembly.append(frame: next)
                if receivedBytes < bytes { #expect(completed == nil) }
            }
            let offset = try #require(received.last?.offset)
            let released = try transmission.progress(offset: offset)
            sentBytes += released.reduce(0) { $0 + $1.data.count }
            pending += released
            #expect(try transmission.progress(offset: offset).isEmpty)
            #expect(try transmission.progress(offset: 0).isEmpty)
            batch += 1
        }
        #expect(sentBytes == bytes && receivedBytes == bytes)
        #expect(offsets == Array(stride(from: 0, to: bytes, by: 16384)))
        #expect(completed == original)
    }

    @Test(arguments: [1, 16384, 16385, 589823, 589824])
    func independentReceiptsNeverQueueMoreThanOne16KiBChunk(bytes: Int) throws {
        let original = refresh(bytes: bytes)
        var transmission = try SurfaceRefreshTransmission(frame: original, refinement: .independent)
        var assembly = SurfaceRefreshAssembly()
        #expect(throws: SurfaceRefreshTransferError.invalidOffset) { try transmission.progress(offset: 0) }
        var pending = transmission.start()
        var sentBytes = pending.reduce(0) { $0 + $1.data.count }
        var acknowledgedBytes = 0
        var completed: SurfaceEvent.Frame?
        while !pending.isEmpty {
            #expect(pending.count == 1)
            let next = try #require(pending.first)
            let offset = try #require(next.offset)
            #expect(offset == acknowledgedBytes)
            #expect(next.data.count == min(16384, bytes - offset))
            #expect(sentBytes - acknowledgedBytes == next.data.count)
            #expect(sentBytes - acknowledgedBytes <= 16384)
            #expect(transmission.start().isEmpty)
            #expect(throws: SurfaceRefreshTransferError.invalidOffset) {
                try transmission.progress(offset: offset + 16384)
            }
            if offset > 0 { #expect(try transmission.progress(offset: offset - 16384).isEmpty) }
            completed = try assembly.append(frame: next)
            acknowledgedBytes += next.data.count
            if acknowledgedBytes < bytes { #expect(completed == nil) }
            pending = try transmission.progress(offset: offset)
            #expect(pending.count <= 1)
            #expect(try transmission.progress(offset: offset).isEmpty)
            #expect(try transmission.progress(offset: 0).isEmpty)
            sentBytes += pending.reduce(0) { $0 + $1.data.count }
        }
        #expect(sentBytes == bytes && acknowledgedBytes == bytes)
        #expect(completed == original)
        #expect(transmission.start().isEmpty)
    }

    @Test func aShortFinalPartCompletesAfterTheInitialWindow() throws {
        let original = refresh(bytes: 131073)
        var transmission = try SurfaceRefreshTransmission(frame: original)
        var assembly = SurfaceRefreshAssembly()
        for frame in transmission.start() {
            #expect(try assembly.append(frame: frame) == nil)
        }
        let final = try transmission.progress(offset: 114688)
        #expect(final.map(\.offset) == [131072])
        #expect(final.map(\.data) == [Data([50])])
        #expect(try assembly.append(frame: #require(final.first)) == original)
        #expect(try transmission.progress(offset: 131072).isEmpty)
        #expect(try transmission.progress(offset: 114688).isEmpty)
        #expect(transmission.start().isEmpty)
    }

    @Test func assemblyReturnsOnlyTheCompleteLogicalFrame() throws {
        let original = refresh()
        var assembly = SurfaceRefreshAssembly()
        #expect(try assembly.append(frame: part(original, offset: 0)) == nil)
        #expect(try assembly.append(frame: part(original, offset: 16384)) == nil)
        let assembled = try assembly.append(frame: part(original, offset: 32768))
        let completed = try #require(assembled)
        #expect(completed == original)
        #expect(completed.data.count == 32769)
        #expect(completed.offset == nil && completed.total == nil)
        #expect(completed.json["offset"] == nil && completed.json["total"] == nil)
    }

    @Test func oneByteAndExactChunkFramesCompleteWithoutExtraParts() throws {
        for bytes in [1, 16384] {
            let original = refresh(bytes: bytes)
            var transmission = try SurfaceRefreshTransmission(frame: original)
            var assembly = SurfaceRefreshAssembly()
            let parts = transmission.start()
            #expect(parts.count == 1)
            #expect(parts.first?.data.count == bytes)
            #expect(try assembly.append(frame: #require(parts.first)) == original)
            #expect(try transmission.progress(offset: 0).isEmpty)
        }
    }

    @Test func senderRejectsInvalidWholeFrames() {
        var invalid: [SurfaceEvent.Frame] = []
        var frame = refresh(bytes: 0)
        invalid.append(frame)
        invalid.append(refresh(bytes: 589825))
        frame = refresh(); frame.refresh = false; invalid.append(frame)
        frame = refresh(); frame.format = .jpeg; invalid.append(frame)
        frame = refresh(); frame.format = .png; invalid.append(frame)
        frame = refresh(); frame.offset = 0; invalid.append(frame)
        frame = refresh(); frame.total = 32769; invalid.append(frame)
        frame = refresh(); frame.width = Int.max; invalid.append(frame)
        frame = refresh(); frame.height = 0; invalid.append(frame)
        frame = refresh(); frame.size.width = .infinity; invalid.append(frame)
        frame = refresh(); frame.scale = .nan; invalid.append(frame)
        frame = refresh(); frame.canvas = CGSize(width: 4000001, height: 1); invalid.append(frame)
        frame = refresh(); frame.supersedes = frame.seq; invalid.append(frame)
        frame = refresh(); frame.seq = 0; invalid.append(frame)
        frame = refresh(); frame.input = -1; invalid.append(frame)
        frame = refresh(); frame.stream = ""; invalid.append(frame)
        frame = refresh(); frame.canvas = CGSize(width: 640.5, height: 479); invalid.append(frame)
        for frame in invalid {
            #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try SurfaceRefreshTransmission(frame: frame) }
        }
    }

    @Test func malformedPartsDoNotAbandonAValidAssembly() throws {
        let original = refresh()
        var assembly = SurfaceRefreshAssembly()
        #expect(try assembly.append(frame: part(original, offset: 0)) == nil)
        var invalid = part(original, offset: 16384)
        invalid.total = Int.max
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.data.removeLast()
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.offset = 1
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.offset = nil
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.total = 0
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.total = nil
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.offset = -16384
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.offset = 49152
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.refresh = false
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.format = .png
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        invalid = part(original, offset: 16384); invalid.data.append(0)
        #expect(throws: SurfaceRefreshTransferError.invalidFrame) { try assembly.append(frame: invalid) }
        #expect(try assembly.append(frame: part(original, offset: 16384)) == nil)
        #expect(try assembly.append(frame: part(original, offset: 32768)) == original)
    }

    @Test func everyMetadataChangeIsRejectedBeforeStoringPartData() throws {
        let original = refresh()
        let changes: [(inout SurfaceEvent.Frame) -> Void] = [
            { $0.stream = "str_other" }, { $0.input += 1 }, { $0.size.width += 1 },
            { $0.scale = 2 }, { $0.width += 2 }, { $0.height += 2 },
            { $0.back = false }, { $0.forward = true }, { $0.loading = true },
            { $0.canvas = nil }, { $0.supersedes = nil }, { $0.total = 32770 },
        ]
        for change in changes {
            var assembly = SurfaceRefreshAssembly()
            #expect(try assembly.append(frame: part(original, offset: 0)) == nil)
            var changed = part(original, offset: 16384)
            change(&changed)
            #expect(throws: SurfaceRefreshTransferError.inconsistentFrame) { try assembly.append(frame: changed) }
            #expect(try assembly.append(frame: part(original, offset: 16384)) == nil)
            #expect(try assembly.append(frame: part(original, offset: 32768)) == original)
        }
    }

    @Test func duplicateSkippedAndOutOfOrderPartsCannotComplete() throws {
        let original = refresh()
        var assembly = SurfaceRefreshAssembly()
        #expect(throws: SurfaceRefreshTransferError.invalidOffset) { try assembly.append(frame: part(original, offset: 16384)) }
        #expect(try assembly.append(frame: part(original, offset: 0)) == nil)
        #expect(throws: SurfaceRefreshTransferError.invalidOffset) { try assembly.append(frame: part(original, offset: 0)) }
        #expect(throws: SurfaceRefreshTransferError.invalidOffset) { try assembly.append(frame: part(original, offset: 32768)) }
        #expect(try assembly.append(frame: part(original, offset: 16384)) == nil)
        #expect(try assembly.append(frame: part(original, offset: 32768)) == original)
    }

    @Test func newerSequenceAndExplicitResetDiscardPartialBytes() throws {
        let old = refresh()
        var newer = refresh(bytes: 16385, seq: 8)
        newer.supersedes = 7
        newer.input = old.input + 1
        var assembly = SurfaceRefreshAssembly()
        #expect(try assembly.append(frame: part(old, offset: 0)) == nil)
        #expect(try assembly.append(frame: part(newer, offset: 0)) == nil)
        #expect(throws: SurfaceRefreshTransferError.inconsistentFrame) { try assembly.append(frame: part(old, offset: 16384)) }
        #expect(try assembly.append(frame: part(newer, offset: 16384)) == newer)
        #expect(try assembly.append(frame: part(old, offset: 0)) == nil)
        assembly.reset()
        #expect(throws: SurfaceRefreshTransferError.invalidOffset) { try assembly.append(frame: part(old, offset: 16384)) }
        #expect(try assembly.append(frame: part(newer, offset: 0)) == nil)
        #expect(try assembly.append(frame: part(newer, offset: 16384)) == newer)
    }
}
