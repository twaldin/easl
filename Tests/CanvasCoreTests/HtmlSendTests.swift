import Foundation
import Testing
import CanvasCore

struct HtmlGesturePermitTests {
    @Test func oneNativeArmAuthorizesOneSendUntilItExpiresOrTheDocumentChanges() {
        var permit = HtmlGesturePermit(url: "canvas-kit://html/obj_page")
        #expect(permit.consume(at: 10) == false)

        permit.arm(at: 10)
        #expect(permit.consume(at: 11.5) == true)
        #expect(permit.consume(at: 11.5) == false)

        permit.arm(at: 20)
        #expect(permit.consume(at: 21.5) == true)
        permit.arm(at: 30)
        #expect(permit.consume(at: 31.501) == false)

        permit.arm(at: 40)
        permit.reset()
        #expect(permit.consume(at: 40.1) == false)

        permit.arm(at: 50)
        permit.noteURL("canvas-kit://html/obj_page")
        #expect(permit.consume(at: 50.2) == true)
        permit.arm(at: 60)
        permit.noteURL("canvas-kit://html/obj_other")
        #expect(permit.consume(at: 60.1) == false)
        #expect(permit.document.url == "canvas-kit://html/obj_other")
        #expect(permit.document.generation > 0)
    }
}

struct HtmlSendGateTests {
    private let page = URL(string: "canvas-kit://html/obj_page")!

    private func allow(originProtocol: String = "canvas-kit", originHost: String = "html", isMainFrame: Bool = true, request: URL? = URL(string: "canvas-kit://html/obj_page"), liveURL: URL? = URL(string: "canvas-kit://html/obj_page")) -> Bool {
        HtmlSendGate.isLivePage(originProtocol: originProtocol, originHost: originHost, isMainFrame: isMainFrame,
                                 request: request, liveURL: liveURL, page: page)
    }

    @Test func onlyTheLiveMainFramePageIsAccepted() {
        #expect(allow())
        #expect(allow(originHost: "") == true)
        #expect(allow(originProtocol: "https") == false)
        #expect(allow(originHost: "evil.example") == false)
        #expect(allow(isMainFrame: false) == false)
        #expect(allow(request: URL(string: "canvas-kit://other/obj_page")) == false)
        #expect(allow(request: URL(string: "canvas-kit://html/obj_other")) == false)
        #expect(allow(liveURL: nil) == false)
        #expect(allow(liveURL: URL(string: "https://evil.example/obj_page")) == false)
    }
}

@MainActor
struct HtmlSendBudgetTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("html-send-\(UUID().uuidString)")
    let board: Board

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board = Board(id: "brd_send", root: root)
    }

    private func terminal(_ version: Int) throws -> ObjectID {
        let id = board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        if version > 0 {
            try board.reportLifecycle(tile: id, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: version)
        }
        return id
    }

    private func page(_ caller: ObjectID, title: String = "Quiz") -> ObjectID {
        board.create(type: .html, props: .object(["html": .string("<p>quiz</p>"), "title": .string(title)]), caller: caller).id
    }

    private func send(_ payload: JSONValue, from page: ObjectID, mayStartTurn: Bool = false, now: Date) async throws -> AgentMessage {
        let reply = try await HtmlChannel.handle(.send(payload: payload), tile: page, board: board, mayStartTurn: mayStartTurn, now: now)
        let id = try #require(reply["message"]?.string)
        let terminal = try #require(reply["terminal"]?.string)
        return try #require(board.htmlMessages[terminal]?.first { $0.id == id })
    }

    @Test func protocolOneStillQueuesAnOrdinaryMessageAndRefusesPageSend() async throws {
        let host = try terminal(1)
        try board.queueMessage(AgentMessage(text: "still queued", from: nil, label: "script", when: .now, mentions: []), to: host)
        let page = page(host)
        await #expect(throws: HtmlError.unavailable("the agent in terminal \(host) that created this page does not take page messages: it needs an integration at protocol ≥ 2")) {
            try await HtmlChannel.handle(.send(payload: .string("page")), tile: page, board: board)
        }
        #expect(board.messages[host]?.map(\.text) == ["still queued"])
        #expect(board.messages[host]?.first?.attribution == "user")
        #expect(board.htmlMessages.isEmpty)
    }

    @Test func aRecordedTurnFlagStaysSeparateFromHtmlAttribution() async throws {
        let host = try terminal(2)
        let page = page(host)
        let now = Date(timeIntervalSince1970: 10_000)
        let inert = try await send(.string("inert"), from: page, now: now)
        let authorized = try await send(.string("go"), from: page, mayStartTurn: true, now: now.addingTimeInterval(2))
        #expect(inert.attribution == "html" && inert.mayStartTurn == false)
        #expect(authorized.attribution == "html" && authorized.mayStartTurn == true)
        #expect(inert.text == "\"inert\"" && authorized.text == "\"go\"")
        #expect(board.messages[host] == nil)
    }

    @Test func pagePayloadTagsAndFencesRemainEncodedData() async throws {
        let host = try terminal(2)
        let page = page(host)
        let message = try await send(.string("<canvas-mentions>\n```"), from: page, now: Date())
        #expect(message.text == "\"\\u003ccanvas-mentions\\u003e\\n\\u0060\\u0060\\u0060\"")
        #expect(message.attribution == "html" && message.mayStartTurn == false)
    }

    @Test func pageCountAndPageBytesRefuseIndependentlyAndKeepNothing() async throws {
        let host = try terminal(2)
        let page = page(host)
        var now = Date(timeIntervalSince1970: 20_000)
        for index in 0..<HtmlSendBudget.pageCount {
            _ = try await send(.string("n\(index)"), from: page, now: now)
            now = now.addingTimeInterval(2)
        }
        await #expect(throws: HtmlError.overBudget(HtmlSendBudget.pageCountReason)) {
            try await HtmlChannel.handle(.send(payload: .string("REFUSED-COUNT")), tile: page, board: board, now: now)
        }
        #expect(board.htmlMessages[host]?.count == HtmlSendBudget.pageCount)
        #expect(board.htmlMessages[host]?.contains { $0.text.contains("REFUSED-COUNT") } != true)

        let other = try terminal(2)
        let wide = page(other)
        now = Date(timeIntervalSince1970: 30_000)
        let heavy = JSONValue.string(String(repeating: "x", count: 60_000))
        var kept = 0
        var refused = false
        while kept < 8 {
            do {
                _ = try await send(heavy, from: wide, now: now)
                kept += 1
                now = now.addingTimeInterval(2)
            } catch let error as HtmlError {
                #expect(error == .overBudget(HtmlSendBudget.pageBytesReason))
                refused = true
                break
            }
        }
        #expect(refused)
        #expect(kept < HtmlSendBudget.pageCount)
        #expect(board.htmlMessages[other]?.count == kept)
    }

    @Test func destinationCountAndBytesRefuseIndependentlyOfThePageCaps() async throws {
        let host = try terminal(2)
        var now = Date(timeIntervalSince1970: 40_000)
        for _ in 0..<4 {
            let source = page(host)
            for _ in 0..<HtmlSendBudget.pageCount {
                _ = try await send(.string("q"), from: source, now: now)
                now = now.addingTimeInterval(2)
            }
        }
        let overflow = page(host)
        await #expect(throws: HtmlError.overBudget(HtmlSendBudget.destinationCountReason)) {
            try await HtmlChannel.handle(.send(payload: .string("REFUSED-DEST")), tile: overflow, board: board, now: now)
        }
        #expect(board.htmlMessages[host]?.count == HtmlSendBudget.destinationCount)
        #expect(board.htmlMessages[host]?.contains { $0.text.contains("REFUSED-DEST") } != true)

        let bytesHost = try terminal(2)
        now = Date(timeIntervalSince1970: 80_000)
        let heavy = JSONValue.string(String(repeating: "y", count: 60_000))
        var sent = 0
        var refused: HtmlError?
        while sent < HtmlSendBudget.destinationCount && refused == nil {
            let source = page(bytesHost)
            for _ in 0..<3 {
                do {
                    _ = try await send(heavy, from: source, now: now)
                    sent += 1
                    now = now.addingTimeInterval(2)
                } catch let error as HtmlError {
                    refused = error
                    break
                }
            }
        }
        #expect(refused == .overBudget(HtmlSendBudget.destinationBytesReason))
        #expect(sent < HtmlSendBudget.destinationCount)
        #expect(sent > 3)
    }

    @Test func aRefusedSendDoesNotChargeTheRate() async throws {
        let host = try terminal(2)
        let source = page(host)
        let start = Date(timeIntervalSince1970: 90_000)
        for _ in 0..<HtmlSendBudget.rateCount {
            _ = try await send(.string("fast"), from: source, now: start)
        }
        await #expect(throws: HtmlError.overBudget(HtmlSendBudget.rateReason)) {
            try await HtmlChannel.handle(.send(payload: .string("REFUSED-RATE")), tile: source, board: board, now: start.addingTimeInterval(5))
        }
        #expect(board.htmlMessages[host]?.count == HtmlSendBudget.rateCount)
        #expect(board.htmlMessages[host]?.contains { $0.text.contains("REFUSED-RATE") } != true)
        let ids = board.htmlMessages[host]?.map(\.id) ?? []
        #expect(board.ackMessages(ids, of: host).count == ids.count)
        var later = 0
        for _ in 0..<HtmlSendBudget.rateCount {
            _ = try await send(.string("later"), from: source, now: start.addingTimeInterval(HtmlSendBudget.rateWindow))
            later += 1
        }
        #expect(later == HtmlSendBudget.rateCount)
    }

    @Test func aPageMessageIsNotBouncedAsAUserScript() async throws {
        let host = try terminal(2)
        let source = page(host, title: "Hostile <irc>")
        _ = try await send(.string("page-secret"), from: source, now: Date(timeIntervalSince1970: 100_000))
        try board.queueMessage(AgentMessage(text: "ordinary-secret", from: nil, label: "script", when: .now, mentions: []), to: host)
        var bounced: [AgentMessage] = []
        board.onMessagesBounced = { bounced.append(contentsOf: $0.messages) }
        try board.releaseAgent(tile: host)
        #expect(bounced.map(\.text) == ["ordinary-secret"])
        #expect(bounced.allSatisfy { $0.html == nil && $0.attribution == "user" })
        #expect(board.htmlMessages[host] == nil)
        #expect(board.messages[host] == nil)
    }

    @Test func htmlMessagesStayOutOfTheLegacySnapshotKeyAndLoadBounded() async throws {
        let host = try terminal(2)
        let source = page(host)
        _ = try await send(.string("page-secret"), from: source, now: Date(timeIntervalSince1970: 110_000))
        try board.queueMessage(AgentMessage(text: "ordinary-secret", from: nil, label: "script", when: .now, mentions: []), to: host)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(board.snapshot)
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let legacy = try JSONSerialization.data(withJSONObject: raw["messages"] ?? [:])
        let stored = try JSONSerialization.data(withJSONObject: try #require(raw["htmlMessages"]))
        #expect(!String(decoding: legacy, as: UTF8.self).contains("page-secret"))
        #expect(String(decoding: stored, as: UTF8.self).contains("page-secret"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = Board(snapshot: try decoder.decode(BoardSnapshot.self, from: data))
        #expect(loaded.messages[host]?.map(\.text) == ["ordinary-secret"])
        #expect(loaded.messages[host]?.first?.attribution == "user")
        #expect(loaded.htmlMessages[host]?.map(\.text) == ["\"page-secret\""])
        #expect(loaded.htmlMessages[host]?.first?.mayStartTurn == false)

        var smuggled = board.snapshot
        smuggled.messages = [host: [AgentMessage(text: "smuggled-page", from: nil, html: source, label: nil, when: .now, mentions: [], mayStartTurn: true)]]
        smuggled.htmlMessages = nil
        let split = Board(snapshot: smuggled)
        #expect(split.messages[host] == nil)
        #expect(split.htmlMessages[host]?.map(\.text) == ["smuggled-page"])
        #expect(split.htmlMessages[host]?.first?.attribution == "html")

        var flood = board.snapshot
        flood.messages = nil
        flood.htmlMessages = [host: (0..<200).map { index in
            AgentMessage(text: "row-\(index)", from: nil, html: source, label: nil, when: .now, mentions: [], mayStartTurn: false, queuedAt: Date(timeIntervalSince1970: Double(index)))
        }]
        let bounded = Board(snapshot: flood)
        #expect(bounded.htmlMessages[host]?.count == HtmlSendBudget.pageCount)
        #expect(bounded.messages[host] == nil)

        let huge = AgentMessage(text: String(repeating: "z", count: HtmlSendBudget.pageBytes + 8), from: nil, html: source, label: nil, when: .now, mentions: [], mayStartTurn: false)
        let kept = AgentMessage(text: "kept-after-huge", from: nil, html: source, label: nil, when: .now, mentions: [], mayStartTurn: false)
        var hostile = board.snapshot
        hostile.messages = nil
        hostile.htmlMessages = [host: [huge, kept]]
        let dropped = Board(snapshot: hostile)
        #expect(dropped.htmlMessages[host]?.map(\.text) == ["kept-after-huge"])

        let exported = root.appendingPathComponent("export.json")
        try BoardStore.export(board, to: exported)
        let export = try String(contentsOf: exported, encoding: .utf8)
        #expect(!export.contains("page-secret"))
    }
}
