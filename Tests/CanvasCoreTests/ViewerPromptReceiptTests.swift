import Darwin
import Foundation
import Testing
@testable import CanvasCore

@MainActor
final class ViewerPromptReceiptTests {
    enum Cut: Sendable { case beforeHost, afterHost, none }

    struct Traffic {
        var originals: [[String: JSONValue]] = []
        var queries: [[String: JSONValue]] = []
        var preflights = 0
        var allowQueries = false
        var queryDelivery: String?
        var queryResult: JSONValue?
        var queryFailure: JSONValue?
        var queryConnection: SocketServer.Connection?
    }

    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("vpr-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let host: Board
    let terminal: ObjectID
    let quoted: ObjectID
    let traffic = Locked(Traffic())
    let typed = Locked<[String]>([])
    var server: SocketServer?
    var mirror: BoardMirror?

    init() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        host = try await registry.open(root: dir.appendingPathComponent("root"))
        router = ApiRouter(registry: registry)
        terminal = host.create(type: .terminal, props: .object([:])).id
        quoted = host.create(type: .note, props: .object(["markdown": "quoted context"])).id
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let typed = typed
        router.submitToTerminal = { _, _, text in
            typed.withLock { $0.append(text) }
            return true
        }
    }

    deinit {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func connect(cut: Cut, epochSupported: Bool = true) async throws -> (BoardMirror, Board) {
        let router = router, traffic = traffic
        let socket = dir.appendingPathComponent("s").path
        let server = SocketServer(path: socket) { request, connection in
            let params = request["params"]?.object ?? [:]
            if request["method"]?.string == "agent.prompt_epoch" {
                traffic.withLock { $0.preflights += 1 }
                if !epochSupported {
                    return .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["version": 2])])
                }
            }
            guard request["method"]?.string == "agent.prompt" else {
                return await router.handle(request, connection: connection)
            }
            if params["reconcile"]?.bool == true {
                traffic.withLock {
                    $0.queries.append(params)
                    $0.queryConnection = connection
                }
                while !traffic.withLock({ $0.allowQueries }) { try? await Task.sleep(for: .milliseconds(10)) }
                if let failure = traffic.withLock({ $0.queryFailure }) {
                    return .object(["id": request["id"] ?? .null, "ok": .bool(false), "error": failure])
                }
                if let result = traffic.withLock({ $0.queryResult }) {
                    return .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": result])
                }
                if let delivery = traffic.withLock({ $0.queryDelivery }) {
                    return .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["delivery": .string(delivery)])])
                }
                return await router.handle(request, connection: connection)
            }
            let first = traffic.withLock {
                $0.originals.append(params)
                return $0.originals.count == 1
            }
            if first, cut == .beforeHost {
                shutdown(connection.fd, SHUT_RDWR)
                return nil
            }
            let response = await router.handle(request, connection: connection)
            if first, cut == .afterHost {
                shutdown(connection.fd, SHUT_RDWR)
                return nil
            }
            return response
        }
        self.server = server
        try server.start()
        let fast = EaslConnection.Backoff(initial: .milliseconds(20), maximum: .milliseconds(100))
        func link() -> EaslConnection { .unixSocket(socket, backoff: fast, handshakeTimeout: .seconds(60)) }
        let mirror = BoardMirror(hostName: "home", board: host.id, connection: link(), diagrams: link())
        self.mirror = mirror
        return (mirror, try await mirror.load())
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    func submission(on view: Board) throws -> ComposerSend {
        let mention = try view.stage(.object(quoted))
        return try #require(ComposerSend.begin(ComposerDraft(text: "review \(ComposerDraft.mark)", tokens: [mention]), targets: [terminal], on: view)).send
    }

    func expectSameReceipt() throws {
        let original = try #require(traffic.withLock { $0.originals.first })
        let queries = traffic.withLock { $0.queries }
        #expect(traffic.withLock { $0.originals.count } == 1)
        #expect(traffic.withLock { $0.preflights } == 1)
        #expect(original["submission"]?["id"]?.string?.hasPrefix("sub_") == true)
        #expect(original["submission"]?["epoch"]?.string?.isEmpty == false)
        #expect(original["submission"]?["createdAt"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) } != nil)
        #expect(!queries.isEmpty)
        for var query in queries {
            #expect(query.removeValue(forKey: "reconcile") == .bool(true))
            #expect(query == original)
        }
    }

    @Test func lostSuccessfulReplySettlesDeliveredWithoutReturningTheDraft() async throws {
        let (mirror, view) = try await connect(cut: .afterHost)
        defer { mirror.close() }
        let outgoing = try submission(on: view)
        var state = ComposerState()
        state.sending(outgoing.draft)
        var statuses: [BoardMirror.PromptDelivery] = []
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        let send = Task { try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false) }
        try await eventually { statuses.contains(.checking) && !self.traffic.withLock({ $0.queries.isEmpty }) }
        #expect(state.outgoing == [outgoing.draft] && view.tray.isEmpty)
        state.draft = ComposerDraft(text: "next draft")
        traffic.withLock { $0.allowQueries = true }
        try await send.value
        state.reached(outgoing.draft)
        let settled = outgoing.settle(reached: [terminal], into: state.draft, on: view)
        #expect(settled.sent && settled.draft.text == "next draft")
        #expect(state.outgoing.isEmpty && state.history == [outgoing.draft])
        #expect(view.tray.isEmpty && typed.withLock { $0 } == ["review [1]"])
        #expect(statuses.last == .delivered)
        try expectSameReceipt()
        try host.releaseAgent(tile: terminal)
        try await eventually { view.tray.map(\.id) == outgoing.draft.tokens.map(\.id) }
    }

    @Test func cutBeforeHostRestoresOnlyAfterDefiniteNonDelivery() async throws {
        let (mirror, view) = try await connect(cut: .beforeHost)
        defer { mirror.close() }
        let outgoing = try submission(on: view)
        var state = ComposerState()
        state.sending(outgoing.draft)
        var statuses: [BoardMirror.PromptDelivery] = []
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        let send = Task { try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false) }
        try await eventually { statuses.contains(.checking) && !self.traffic.withLock({ $0.queries.isEmpty }) }
        #expect(state.outgoing == [outgoing.draft] && view.tray.isEmpty)
        let next = try view.stage(.object(terminal))
        state.draft = ComposerDraft(text: "later \(ComposerDraft.mark)", tokens: [next])
        traffic.withLock { $0.allowQueries = true }
        do {
            try await send.value
            Issue.record("a cancelled submission must report definite non-delivery")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "not_delivered")
        }
        let settled = outgoing.settle(reached: [], into: state.draft, on: view)
        state.returned(outgoing.draft)
        #expect(!settled.sent && settled.draft.prompt == "review [1] later [2]")
        #expect(settled.draft.tokens.map(\.target) == outgoing.draft.tokens.map(\.target) + [next.target])
        #expect(settled.draft.tokens.last?.id == next.id)
        #expect(view.tray.map(\.id) == settled.draft.tokens.map(\.id))
        #expect(state.outgoing.isEmpty && typed.withLock { $0.isEmpty })
        #expect(statuses.last == .notDelivered)
        try expectSameReceipt()
    }

    @Test func unknownReceiptStaysHeldAndCanBeCheckedAfterAnotherReconnect() async throws {
        traffic.withLock { $0.queryDelivery = "unknown"; $0.allowQueries = true }
        let (mirror, view) = try await connect(cut: .afterHost)
        defer { mirror.close() }
        let outgoing = try submission(on: view)
        var statuses: [BoardMirror.PromptDelivery] = []
        var finished = false
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        let send = Task {
            try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false)
            finished = true
        }
        try await eventually { statuses.contains(.unknown) }
        #expect(!finished && view.tray.isEmpty && traffic.withLock { $0.originals.count } == 1)
        let connection = try #require(traffic.withLock { $0.queryConnection })
        traffic.withLock { $0.queryDelivery = nil }
        shutdown(connection.fd, SHUT_RDWR)
        try await send.value
        #expect(finished && statuses.last == .delivered && view.tray.isEmpty)
        #expect(typed.withLock { $0 } == ["review [1]"])
        try expectSameReceipt()
    }

    @Test func pendingReceiptPollsWithoutRepeatingTheOriginalSubmission() async throws {
        traffic.withLock { $0.queryDelivery = "pending"; $0.allowQueries = true }
        let (mirror, view) = try await connect(cut: .afterHost)
        defer { mirror.close() }
        let outgoing = try submission(on: view)
        var statuses: [BoardMirror.PromptDelivery] = []
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        let send = Task { try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false) }
        try await eventually { self.traffic.withLock { $0.queries.count >= 2 } }
        #expect(statuses.last == .checking && view.tray.isEmpty)
        #expect(traffic.withLock { $0.originals.count } == 1)
        traffic.withLock { $0.queryDelivery = nil }
        try await send.value
        #expect(statuses.last == .delivered && typed.withLock { $0 } == ["review [1]"])
        try expectSameReceipt()
    }

    @Test func boardClosingDoesNotTurnAKnownSuccessfulReceiptIntoFailure() async throws {
        let (mirror, view) = try await connect(cut: .afterHost)
        defer { mirror.close() }
        let outgoing = try submission(on: view)
        var statuses: [BoardMirror.PromptDelivery] = []
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        let send = Task { try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false) }
        try await eventually { statuses.contains(.checking) && !self.traffic.withLock({ $0.queries.isEmpty }) }
        registry.setWindowOpen(false, board: host.id)
        try await eventually { mirror.availability == .closed }
        traffic.withLock { $0.allowQueries = true }
        try await send.value
        #expect(statuses.last == .delivered && view.tray.isEmpty)
        #expect(typed.withLock { $0 } == ["review [1]"])
        try expectSameReceipt()
    }

    @Test func anotherTargetAndANewDraftSurviveAnUncertainDelivery() async throws {
        let beta = host.create(type: .terminal, props: .object([:])).id
        try host.reportLifecycle(tile: beta, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        traffic.withLock { $0.queryDelivery = "unknown"; $0.allowQueries = true }
        let (mirror, view) = try await connect(cut: .afterHost)
        defer { mirror.close() }
        let mention = try view.stage(.object(quoted))
        let outgoing = try #require(ComposerSend.begin(ComposerDraft(text: "review \(ComposerDraft.mark)", tokens: [mention]), targets: [terminal, beta], on: view)).send
        var state = ComposerState()
        state.sending(outgoing.draft)
        var statuses: [BoardMirror.PromptDelivery] = []
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        let first = Task { try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false) }
        try await eventually { statuses.contains(.unknown) }
        try await mirror.prompt(outgoing.draft.prompt, to: beta, mentions: outgoing.draft.tokens, answer: false)
        state.record(outgoing.draft)
        let next = try view.stage(.object(beta))
        state.draft = ComposerDraft(text: "next \(ComposerDraft.mark)", tokens: [next])
        #expect(state.outgoing == [outgoing.draft] && view.tray.map(\.id) == [next.id])
        let connection = try #require(traffic.withLock { $0.queryConnection })
        traffic.withLock { $0.queryDelivery = nil }
        shutdown(connection.fd, SHUT_RDWR)
        try await first.value
        state.reached(outgoing.draft)
        let settled = outgoing.settle(reached: [terminal, beta], into: state.draft, on: view)
        #expect(settled.sent && settled.draft == state.draft)
        #expect(state.outgoing.isEmpty && state.history == [outgoing.draft])
        #expect(view.tray.map(\.id) == [next.id])
        #expect(typed.withLock { $0 } == ["review [1]", "review [1]"])
        let originals = traffic.withLock { $0.originals }
        #expect(originals.count == 2)
        #expect(Set(originals.compactMap { $0["submission"]?["id"]?.string }).count == 2)
        for var query in traffic.withLock({ $0.queries }) {
            #expect(query.removeValue(forKey: "reconcile") == .bool(true))
            #expect(query == originals.first)
        }
    }

    @Test(arguments: [false, true])
    func rejectedOrMalformedReceiptQueryCannotRestoreAnAlreadyDeliveredPrompt(malformed: Bool) async throws {
        traffic.withLock {
            $0.allowQueries = true
            if malformed {
                $0.queryResult = .object([:])
            } else {
                $0.queryFailure = .object(["code": "invalid_params", "message": "receipt protocol unavailable"])
            }
        }
        let (mirror, view) = try await connect(cut: .afterHost)
        defer { mirror.close() }
        let outgoing = try submission(on: view)
        var statuses: [BoardMirror.PromptDelivery] = []
        var finished = false
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        let send = Task {
            try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false)
            finished = true
        }
        try await eventually { statuses.contains(.unknown) }
        #expect(!finished && view.tray.isEmpty)
        #expect(typed.withLock { $0 } == ["review [1]"])
        #expect(!statuses.contains(.notDelivered) && !statuses.contains(.delivered))
        let connection = try #require(traffic.withLock { $0.queryConnection })
        traffic.withLock { $0.queryResult = nil; $0.queryFailure = nil }
        shutdown(connection.fd, SHUT_RDWR)
        try await send.value
        #expect(finished && statuses.last == .delivered && view.tray.isEmpty)
        try expectSameReceipt()
    }

    @Test func cachedDefiniteRefusalRestoresTheOriginalHostFailure() async throws {
        router.submitToTerminal = { _, _, _ in false }
        traffic.withLock { $0.allowQueries = true }
        let (mirror, view) = try await connect(cut: .afterHost)
        defer { mirror.close() }
        let outgoing = try submission(on: view)
        var statuses: [BoardMirror.PromptDelivery] = []
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        do {
            try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false)
            Issue.record("a cached refusal must return the host's definitive error")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "unavailable")
        }
        #expect(statuses.last == .notDelivered && typed.withLock { $0.isEmpty })
        let settled = outgoing.settle(reached: [], into: ComposerDraft(text: "next"), on: view)
        #expect(!settled.sent && settled.draft.prompt == "review [1] next")
        #expect(view.tray.map(\.target) == outgoing.draft.tokens.map(\.target))
        try expectSameReceipt()
    }

    @Test func closingTheViewerEndsItsPendingTaskWithoutRestoringUncertainText() async throws {
        traffic.withLock { $0.queryDelivery = "unknown"; $0.allowQueries = true }
        let (mirror, view) = try await connect(cut: .afterHost)
        let outgoing = try submission(on: view)
        var statuses: [BoardMirror.PromptDelivery] = []
        mirror.onPromptDelivery = { _, _, delivery in statuses.append(delivery) }
        let send = Task { try await mirror.prompt(outgoing.draft.prompt, to: terminal, mentions: outgoing.draft.tokens, answer: false) }
        try await eventually { statuses.contains(.unknown) }
        mirror.close()
        await #expect(throws: BoardMirror.PromptOutcomeUnknown.self) { try await send.value }
        #expect(statuses.last == .unknown && view.tray.isEmpty)
        #expect(typed.withLock { $0 } == ["review [1]"])
        #expect(traffic.withLock { $0.originals.count } == 1)
    }

    @Test func hostWithoutEpochNeverReceivesThePrompt() async throws {
        let (mirror, view) = try await connect(cut: .none, epochSupported: false)
        defer { mirror.close() }
        let mention = try view.stage(.object(quoted))
        await #expect(throws: ApiRouter.Failure.self) {
            try await mirror.prompt("review [1]", to: terminal, mentions: [mention], answer: false)
        }
        #expect(traffic.withLock { $0.originals.isEmpty && $0.preflights == 1 })
        #expect(typed.withLock { $0.isEmpty } && view.tray.map(\.id) == [mention.id])
    }
}
