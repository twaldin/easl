import Testing
@testable import CanvasCore

struct MediaByteRangeTests {
    @Test func closedOpenAndSuffixRequestsSelectExactBytes() throws {
        let closed = try MediaByteRange(header: "bytes=2-5", size: 10)
        #expect(closed.bytes == 2..<6)
        #expect(closed.headers(size: 10) == ["Accept-Ranges": "bytes", "Content-Length": "4", "Content-Range": "bytes 2-5/10"])
        let open = try MediaByteRange(header: "bytes=7-", size: 10)
        #expect(open.bytes == 7..<10)
        let suffix = try MediaByteRange(header: "bytes=-3", size: 10)
        #expect(suffix.bytes == 7..<10)
        let clipped = try MediaByteRange(header: "bytes=7-999", size: 10)
        #expect(clipped.bytes == 7..<10)
        let whole = try MediaByteRange(header: nil, size: 0)
        #expect(whole.bytes == 0..<0)
        #expect(whole.partial == false)
    }

    @Test func malformedAndUnavailableRangesAreRefused() throws {
        for header in ["bytes=10-", "bytes=5-2", "bytes=-0", "bytes=0-1,3-4", "bytes=+1-2", "bytes=0-9223372036854775808", "items=0-1"] {
            #expect(throws: MediaByteRange.Failure.self) { try MediaByteRange(header: header, size: 10) }
        }
        #expect(throws: MediaByteRange.Failure.self) { try MediaByteRange(header: "bytes=0-", size: 0) }
    }
}
