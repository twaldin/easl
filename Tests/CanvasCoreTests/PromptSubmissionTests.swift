import Darwin
import Foundation
import Testing
import CanvasCore

@MainActor
final class PromptSubmissionTests {
    @MainActor
    private final class Replies {
        var dropNextPrompt = false
        var dropped: JSONValue?

        func forward(_ reply: JSONValue?, for request: JSONValue) -> JSONValue? {
            if request["method"] == .string("agent.prompt"), dropNextPrompt {
                dropNextPrompt = false
                dropped = reply
                return nil
            }
            return reply
        }
    }

    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("ps-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    private let replies: Replies
    var submitted: [String] = []

    init() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        board = try await registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        let replies = Replies()
        self.replies = replies
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            let reply = await router.handle(request, connection: connection)
            return await replies.forward(reply, for: request)
        }
        try server.start()
        router.submitToTerminal = { [unowned self] _, _, text in
            submitted.append(text)
            return true
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func connect() throws -> LineClient { try LineClient(path: dir.appendingPathComponent("s").path) }

    func send(_ client: LineClient, _ method: String, _ params: [String: JSONValue]) throws {
        let request: JSONValue = .object(["id": .string("1"), "method": .string(method), "params": .object(params)])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let client = try connect()
        try send(client, method, params)
        return try await client.next()
    }

    func terminal(agent: Bool = false) throws -> ObjectID {
        let tile = board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        if agent { try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp") }
        return tile
    }

    func params(_ tile: ObjectID, text: String = "review this", createdAt: Date = Date(), epoch: String? = nil) async throws -> [String: JSONValue] {
        let currentEpoch = try #require(try await call("agent.prompt_epoch")["result"]?["promptEpoch"]?.string)
        return [
            "target": .string(tile), "text": .string(text), "composer": .bool(true),
            "submission": .object([
                "id": .string("sub_" + UUID().uuidString), "epoch": .string(epoch ?? currentEpoch),
                "createdAt": .string(createdAt.formatted(.iso8601)),
            ]),
        ]
    }

    func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(ready(), "the original prompt reached its controlled suspension")
    }

    @Test func pingAdvertisesOneEpochWithoutChangingLegacyPing() async throws {
        let legacy = try await call("system.ping")
        #expect(legacy["result"] == .object(["version": .number(Double(ApiRouter.schemaVersion)), "app": .string("easl")]))
        let first = try #require(try await call("agent.prompt_epoch")["result"]?["promptEpoch"]?.string)
        #expect(UUID(uuidString: first) != nil)
        #expect(try await call("agent.prompt_epoch")["result"]?["promptEpoch"] == .string(first))
    }

    @Test func duplicateAndReconcileReturnExactSuccessAfterTargetAndMentionDeletion() async throws {
        let tile = try terminal(agent: true)
        let note = board.create(type: .note, props: .object(["markdown": .string("context")]))
        let mention = try board.stage(.object(note.id))
        var request = try await params(tile, text: "inspect [1]")
        request["staged"] = try JSONValue.encode([mention])
        request["viewer"] = .string("vw_viewer01")
        let first = try await call("agent.prompt", request)
        #expect(first["ok"] == .bool(true) && first["result"]?["delivery"] == .string("typed"))
        #expect(submitted == ["inspect [1]"])
        try board.delete(note.id)
        try board.delete(tile)
        #expect(try await call("agent.prompt", request) == first)
        request["reconcile"] = .bool(true)
        #expect(try await call("agent.prompt", request) == first)
        #expect(submitted == ["inspect [1]"])
    }

    @Test func concurrentCallsAndReconciliationStayPendingBeforeAnyPaste() async throws {
        let tile = try terminal()
        let request = try await params(tile)
        var release: CheckedContinuation<TerminalTail.Tail?, Never>?
        router.readTerminal = { _, _, _ in
            await withCheckedContinuation { release = $0 }
        }
        defer { release?.resume(returning: nil) }
        let original = try connect()
        try send(original, "agent.prompt", request)
        try await waitUntil { release != nil }
        #expect(submitted.isEmpty)
        #expect(try await call("agent.prompt", request)["result"] == .object(["delivery": .string("pending")]))
        var reconcile = request
        reconcile["reconcile"] = .bool(true)
        #expect(try await call("agent.prompt", reconcile)["result"] == .object(["delivery": .string("pending")]))
        #expect(submitted.isEmpty)
        release?.resume(returning: nil)
        release = nil
        let first = try await original.next()
        #expect(first["result"]?["delivery"] == .string("typed"))
        #expect(try await call("agent.prompt", reconcile) == first)
        #expect(try await call("agent.prompt", request) == first)
        #expect(submitted == ["review this"])
    }

    @Test func lostReplyReconcilesWithoutSubmittingAgain() async throws {
        let tile = try terminal()
        var request = try await params(tile)
        let original = try connect()
        replies.dropNextPrompt = true
        try send(original, "agent.prompt", request)
        try await waitUntil { replies.dropped != nil }
        let lost = try #require(replies.dropped)
        #expect(lost["ok"] == .bool(true))
        _ = shutdown(original.fd, SHUT_RDWR)
        request["reconcile"] = .bool(true)
        #expect(try await call("agent.prompt", request) == lost)
        #expect(submitted == ["review this"])
    }

    @Test func reconciliationCancelsAnOriginalThatHasNotArrivedEvenWhenItsTargetIsMissing() async throws {
        var request = try await params("obj_missing")
        request["staged"] = .array([.object(["invalid": .bool(true)])])
        request["reconcile"] = .bool(true)
        let cancelled = try await call("agent.prompt", request)
        #expect(cancelled["ok"] == .bool(true))
        #expect(cancelled["result"] == .object(["delivery": .string("not-delivered")]))
        request.removeValue(forKey: "reconcile")
        #expect(try await call("agent.prompt", request) == cancelled)
        request["reconcile"] = .bool(true)
        #expect(try await call("agent.prompt", request) == cancelled)
        #expect(submitted.isEmpty)
    }

    @Test func aDefiniteRefusalStaysExactAfterTheSurfaceAndTargetChange() async throws {
        let tile = try terminal()
        var request = try await params(tile)
        router.submitToTerminal = { _, _, _ in false }
        let refused = try await call("agent.prompt", request)
        #expect(refused["ok"] == .bool(false))
        #expect(refused["error"]?["code"] == .string("unavailable"))
        router.submitToTerminal = { [unowned self] _, _, text in
            submitted.append(text)
            return true
        }
        #expect(try await call("agent.prompt", request) == refused)
        try board.delete(tile)
        request["reconcile"] = .bool(true)
        let reconciled = try await call("agent.prompt", request)
        #expect(reconciled["ok"] == .bool(true))
        #expect(reconciled["result"]?["delivery"] == .string("not-delivered"))
        #expect(reconciled["result"]?["error"] == refused["error"])
        #expect(submitted.isEmpty)
    }

    @Test func aValidationRefusalIsRememberedBeforeTheTargetCanAppear() async throws {
        let request = try await params("not-an-agent")
        let refused = try await call("agent.prompt", request)
        #expect(refused["ok"] == .bool(false))
        let tile = try terminal()
        try board.update(tile, props: .object(["name": .string("not-an-agent")]))
        #expect(try await call("agent.prompt", request) == refused)
        #expect(submitted.isEmpty)
    }

    @Test func changingAnyPromptPayloadForAnExistingIDIsInvalid() async throws {
        let tile = try terminal()
        let request = try await params(tile)
        #expect(try await call("agent.prompt", request)["ok"] == .bool(true))
        let submission = try #require(request["submission"])
        let mutations: [[String: JSONValue]] = [
            ["text": .string("different")], ["target": .string("obj_missing")],
            ["viewer": .string("vw_viewer01")], ["staged": .array([])],
            ["submission": submission.merging(.object(["epoch": .string(UUID().uuidString)]))],
            ["submission": submission.merging(.object(["createdAt": .string(Date().addingTimeInterval(-60).formatted(.iso8601))]))],
        ]
        for mutation in mutations {
            var changed = request.merging(mutation) { _, new in new }
            #expect(try await call("agent.prompt", changed)["error"]?["code"] == .string("invalid_params"))
            changed["reconcile"] = .bool(true)
            #expect(try await call("agent.prompt", changed)["error"]?["code"] == .string("invalid_params"))
        }
        #expect(submitted == ["review this"])
    }

    @Test func missingReceiptsWithOldEpochExpiredAgeOrFutureClockAreUnknown() async throws {
        let requests = try await [
            params("obj_missing", epoch: UUID().uuidString),
            params("obj_missing", createdAt: Date().addingTimeInterval(-25 * 60 * 60)),
            params("obj_missing", createdAt: Date().addingTimeInterval(10 * 60)),
        ]
        for var request in requests {
            #expect(try await call("agent.prompt", request)["result"] == .object(["delivery": .string("unknown")]))
            request["reconcile"] = .bool(true)
            #expect(try await call("agent.prompt", request)["result"] == .object(["delivery": .string("unknown")]))
        }
        #expect(submitted.isEmpty)
    }

    @Test func malformedMetadataAndReconcileWithoutSubmissionAreInvalid() async throws {
        let tile = try terminal()
        let request = try await params(tile)
        let submission = try #require(request["submission"])
        let bad: [JSONValue] = [
            .string("not an object"),
            submission.merging(.object(["id": .string("sub_é-invalid")])),
            submission.merging(.object(["id": .string("sub_" + String(repeating: "a", count: 77))])),
            submission.merging(.object(["epoch": .string("")])),
            submission.merging(.object(["createdAt": .string("yesterday")])),
            submission.merging(.object(["createdAt": .string("2026-10-20")])),
            submission.merging(.object(["createdAt": .string("2026-10-20T01:02:03,4Z")])),
            submission.merging(.object(["createdAt": .string("2026-10-20T01:02:03+24:00")])),
        ]
        for metadata in bad {
            var changed = request
            changed["submission"] = metadata
            #expect(try await call("agent.prompt", changed)["error"]?["code"] == .string("invalid_params"))
        }
        for reconcile in [JSONValue.bool(true), .bool(false), .string("true")] {
            #expect(try await call("agent.prompt", ["target": .string(tile), "text": .string("never"), "reconcile": reconcile])["error"]?["code"] == .string("invalid_params"))
        }
        #expect(submitted.isEmpty)
    }

    @Test func messageDeliveryReplaysTheOriginalWithoutQueueingADuplicate() async throws {
        let tile = try terminal(agent: true)
        var request = try await params(tile)
        request.removeValue(forKey: "composer")
        let first = try await call("agent.prompt", request)
        #expect(first["result"]?["delivery"] == .string("message"))
        #expect(try await call("agent.prompt", request) == first)
        request["reconcile"] = .bool(true)
        #expect(try await call("agent.prompt", request) == first)
        #expect(board.messages[tile]?.count == 1)
        #expect(submitted.isEmpty)
    }

    @Test func capacityRefusesNewExecutionAndCannotFalselyCancelAMissingReceipt() async throws {
        let tile = try terminal()
        let request = try await params(tile)
        let submission = try #require(request["submission"])
        let client = try connect()
        let cancelled: JSONValue = .object(["delivery": .string("not-delivered")])
        var first: [String: JSONValue]?
        for index in 0..<4096 {
            var reservation = request
            reservation["submission"] = submission.merging(.object(["id": .string("sub_capacity_\(index)")]))
            reservation["reconcile"] = .bool(true)
            if index == 0 { first = reservation }
            try send(client, "agent.prompt", reservation)
            #expect(try await client.next()["result"] == cancelled)
        }
        #expect(try await call("agent.prompt", try #require(first))["result"] == cancelled)
        let refused = try await call("agent.prompt", request)
        #expect(refused["error"]?["code"] == .string("unavailable"))
        var reconcile = request
        reconcile["reconcile"] = .bool(true)
        #expect(try await call("agent.prompt", reconcile)["result"] == .object(["delivery": .string("unknown")]))
        #expect(submitted.isEmpty)
    }

    @Test func legacyCallsAndLocalComposerKeepTheirExistingSignaturesAndBehavior() async throws {
        let tile = try terminal()
        let request: [String: JSONValue] = ["target": .string(tile), "text": .string("legacy")]
        #expect(try await call("agent.prompt", request)["result"]?["delivery"] == .string("typed"))
        #expect(try await call("agent.prompt", request)["result"]?["delivery"] == .string("typed"))
        try await router.composerPrompt("local", to: tile, on: board, mentions: [], answer: false)
        #expect(submitted == ["legacy", "legacy", "local"])
    }
}
