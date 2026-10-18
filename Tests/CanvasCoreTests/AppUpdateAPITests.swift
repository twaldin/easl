import Foundation
import Testing
import CanvasCore

extension ApiRouterTests {
    @Test func appUpdateValidatesBeforeCheckingHandlerAvailability() async throws {
        let client = try connect()
        for mode in ["check", "install"] {
            let reply = try await call(client, "app.update", ["mode": .string(mode)])
            #expect(reply["error"]?["code"] == .string("unavailable"))
        }
        let reply = try await call(client, "app.update", ["mode": .string("download")])
        #expect(reply["error"]?["code"] == .string("invalid_params"))
    }

    @Test func appUpdateRejectsInvalidParamsBeforeInvokingUpdater() async throws {
        var receivedModes: [String] = []
        router.updateApp = { mode in
            receivedModes.append(mode)
            return .null
        }
        let client = try connect()
        let malformed: [[String: JSONValue]] = [
            [:],
            ["mode": .null],
            ["mode": .string("")],
            ["mode": .string("download")],
            ["mode": .string("INSTALL")],
            ["mode": .bool(true)],
            ["mode": .number(1)],
            ["mode": .array([.string("install")])],
            ["mode": .object(["install": .bool(true)])],
            ["mode": .string("install"), "force": .bool(true)],
        ]
        for params in malformed {
            let reply = try await call(client, "app.update", params)
            #expect(reply["error"]?["code"] == .string("invalid_params"))
        }
        #expect(receivedModes == [])

        for mode in ["check", "install"] {
            _ = try await call(client, "app.update", ["mode": .string(mode)])
        }
        #expect(receivedModes == ["check", "install"])
    }
}
