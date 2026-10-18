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
            return ApiRouter.UpdateReply(value: .null)
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
    }

    @Test func appUpdateSendsItsOwnEnvelopeOnceAndCompletesAfterWriting() async throws {
        let (completion, continuation) = AsyncStream<Bool>.makeStream()
        defer { continuation.finish() }
        var sentResults: [Bool] = []
        router.updateApp = { _ in
            ApiRouter.UpdateReply(value: .object(["phase": .string("installing")])) { sent in
                sentResults.append(sent)
                continuation.yield(sent)
            }
        }
        let client = try connect()
        client.send(#"{"id":"install","method":"app.update","params":{"mode":"install"}}"#)
        client.send(#"{"id":"after-install","method":"system.ping","params":{}}"#)

        #expect(try await client.next() == .object([
            "id": .string("install"),
            "ok": .bool(true),
            "result": .object(["phase": .string("installing")]),
        ]))
        let ping = try await client.next()
        #expect(ping["id"] == .string("after-install"))
        #expect(ping["ok"] == .bool(true))
        var completed = completion.makeAsyncIterator()
        #expect(await completed.next() == true)
        #expect(sentResults == [true])
    }
}
