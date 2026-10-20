import Foundation
import Testing
@testable import CanvasCore

struct SurfaceProtocolTests {
    @Test func progressIsASeparatePrivateRequest() throws {
        #expect(try SurfaceRequest(method: "surface.progress", params: .object([
            "stream": "str_refresh", "frame": 7, "offset": 16384,
        ])) == .progress(stream: "str_refresh", frame: 7, offset: 16384))
        #expect(try SurfaceRequest(method: "surface.ack", params: .object([
            "stream": "str_refresh", "frame": 0,
        ])) == .ack(stream: "str_refresh", frame: 0))
        #expect(try SurfaceRequest(method: "surface.progress", params: .object([
            "stream": "str_refresh", "frame": 7, "offset": 573440,
        ])) == .progress(stream: "str_refresh", frame: 7, offset: 573440))
    }

    @Test func malformedProgressIsRejectedAtTheBoundary() {
        let valid: [String: JSONValue] = ["stream": .string("str_refresh"), "frame": .number(7), "offset": .number(0)]
        let invalid: [(String, JSONValue?)] = [
            ("stream", .string("obj_wrong")), ("stream", nil), ("frame", .number(0)), ("frame", .number(-1)),
            ("frame", .number(1.5)), ("frame", nil), ("offset", .number(-16384)), ("offset", .number(1)),
            ("offset", .number(589824)), ("offset", .number(0.5)), ("offset", .string("0")), ("offset", nil),
        ]
        for (key, value) in invalid {
            var params = valid
            params[key] = value
            #expect(throws: ApiRouter.Failure.self) {
                try SurfaceRequest(method: "surface.progress", params: .object(params))
            }
        }
    }

    @Test func removedRegionFormatIsNotNegotiated() throws {
        #expect(SurfaceFormat(rawValue: "patch") == nil)
        #expect(throws: ApiRouter.Failure.self) {
            try SurfaceRequest(method: "surface.stream", params: .object(["id": "obj_page", "format": "patch"]))
        }
        #expect(try SurfaceRequest(method: "surface.stream", params: .object(["id": "obj_page", "format": "h264"])) ==
            .stream(tile: "obj_page", scale: 1, format: .h264))
    }

}
