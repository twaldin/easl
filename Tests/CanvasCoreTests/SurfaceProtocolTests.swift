import Foundation
import Testing
@testable import CanvasCore

struct SurfaceProtocolTests {
    @Test func wheelGestureIdentityIsOptionalAndStrict() throws {
        let base: [String: JSONValue] = ["kind": "scroll", "seq": 1, "x": 2, "y": 3, "dx": 0, "dy": -4,
                                              "phase": 4, "momentum": 0]
        for gesture in [nil, .number(7)] as [JSONValue?] {
            var event = base
            event["gesture"] = gesture
            let request = try SurfaceRequest(method: "surface.input", params: .object([
                "stream": "str_page", "events": .array([.object(event)]),
            ]))
            guard let request, case .input(_, let events) = request, case .scroll(let scroll) = events[0].action else {
                Issue.record("Expected native scroll input")
                continue
            }
            #expect(scroll.gesture == (gesture == nil ? nil : 7))
            #expect(scroll.phase == 4)
            #expect(scroll.gestureStep == .changed)
        }
        for invalid in [.number(0), .number(-1), .number(1.5), .string("7"), .bool(true)] as [JSONValue] {
            var event = base
            event["gesture"] = invalid
            #expect(throws: ApiRouter.Failure.self) {
                try SurfaceRequest(method: "surface.input", params: .object([
                    "stream": "str_page", "events": .array([.object(event)]),
                ]))
            }
        }
    }

    @Test func wheelRejectionRequiresExactStreamAndPositiveGestureFields() {
        let valid = SurfaceScrollUnhandled.data(stream: "str_page", gesture: 7)
        #expect(SurfaceScrollUnhandled(valid)?.stream == "str_page")
        #expect(SurfaceScrollUnhandled(valid)?.gesture == 7)
        for invalid in [
            .object(["stream": "obj_page", "gesture": 7]),
            .object(["stream": "str_page", "gesture": 0]),
            .object(["stream": "str_page", "gesture": .number(1.5)]),
            .object(["stream": "str_page", "gesture": "7"]),
            .object(["stream": "str_page"]),
            .object(["stream": "str_page", "gesture": 7, "extra": .bool(true)]),
        ] as [JSONValue] {
            #expect(SurfaceScrollUnhandled(invalid) == nil)
        }
    }

    @Test func wireWheelPhasesUseTheSharedGestureBoundary() {
        var boundary = ScrollGesture()
        let phases: [(UInt, UInt, Bool)] = [(32, 0, true), (1, 0, false), (4, 0, false),
                                          (8, 0, false), (0, 1, false), (0, 4, false),
                                          (0, 8, false), (1, 0, true)]
        for (index, sample) in phases.enumerated() {
            let scroll = SurfaceScroll(x: 0, y: 0, dx: 0, dy: -1, precise: true,
                                       phase: sample.0, momentum: sample.1, mods: 0)
            #expect(boundary.starts(step: scroll.gestureStep, timestamp: Double(index) / 100) == sample.2)
        }
    }

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
