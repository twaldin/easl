import Foundation
import Testing
@testable import CanvasCore

struct NeedsYouDerivationFixture {
    static let now = Date(timeIntervalSince1970: 1_893_456_000)
    var objects: [ObjectID: CanvasObject] = [:]
    var attention: [ObjectID: Attention] = [:]

    init(questionCount: Int = 320) {
        let variants: [[String: JSONValue]] = [
            ["status": "open"],
            ["status": "answered", "expiresAt": "2029-12-31T23:00:00Z"],
            ["status": "cancelled", "expiresAt": "2029-12-31T23:00:00Z"],
            ["status": "expired", "expiresAt": "2029-12-31T23:00:00Z"],
            ["status": "answered", "archived": .bool(true), "expiresAt": "2029-12-31T23:00:00Z"],
            ["status": "open", "archived": .bool(true)],
            ["status": "future-status"],
            [:],
            ["expiresAt": "invalid"],
            ["expiresAt": "2029-12-31T23:59:59Z"],
            ["expiresAt": "2030-01-01T00:00:00Z"],
            ["expiresAt": "2030-01-01T00:00:00.125Z"],
            ["expiresAt": "2030-01-01T02:00:00+02:00"],
            ["expiresAt": "2029-12-31T19:00:00.250-05:00"],
            ["expiresAt": .null],
            ["status": 7, "expiresAt": 42],
        ]
        for index in 0..<questionCount {
            let id = String(format: "question-%04d", index)
            var props = Self.questionProps(id)
            props.merge(variants[index % variants.count]) { _, new in new }
            if index % variants.count == 7 { props.removeValue(forKey: "status") }
            props["answer"] = .object([
                "option": "yes", "note": .string("Answer \(index)"), "confidence": .number(0.75),
                "at": .string(index.isMultiple(of: 2) ? "2029-12-31T12:00:00Z" : "2029-12-31T14:00:00.125+02:00"),
                "by": .object(["kind": "user"]),
            ])
            add(id, type: .question, props: props, index: index)
            if index.isMultiple(of: 7) { mark(id) }
        }
        for (index, state) in ["blocked", "done", "done", "idle", "blocked", "done", "idle"].enumerated() {
            let id = "terminal-\(index)"
            add(id, type: .terminal, props: ["lifecycle": .object([
                "state": .string(state), "message": .string("Lifecycle \(index)"), "seen": .bool(index == 2),
            ])], index: index)
            if index >= 4 { mark(id) }
        }
        add("unrelated-note", type: .note, props: ["markdown": "Unrelated"], index: 0)
        add("marked-note", type: .note, props: ["markdown": "Marked"], index: 1)
        mark("marked-note")
    }

    static func questionProps(_ id: String) -> [String: JSONValue] {
        ["question": .string("Question \(id)?"), "status": "open",
         "options": .array((0..<8).map { .object(["id": .string($0 == 0 ? "yes" : "option-\($0)"), "label": .string("Choice \($0)"), "why": "A reason"]) }),
         "recommended": "yes", "asker": .object(["name": "fixture", "host": "remote"]),
         "context": .array([.object(["path": "Sources/example.swift", "lines": .object(["start": 1, "end": 20])]), .object(["url": "https://example.com/context"])])]
    }

    mutating func add(_ id: ObjectID, type: ObjectType, props: [String: JSONValue], index: Int) {
        objects[id] = CanvasObject(id: id, type: type,
            frame: Frame(x: Double(index % 3) * 200, y: Double(index % 5) * 100, w: 400, h: 260),
            z: Double(index), createdBy: .user,
            createdAt: Self.now.addingTimeInterval(-Double(index % 11)), props: .object(props))
    }

    mutating func mark(_ id: ObjectID) {
        attention[id] = Attention(object: id, message: "Marker \(id)", raisedBy: "terminal-0", raisedAt: Self.now)
    }

    @MainActor func remoteBoard() -> Board {
        let board = Board(remote: "needs-you-fixture", root: URL(fileURLWithPath: "/tmp/needs-you-fixture"), host: nil)
        for object in objects.values { board.applyHost(object) }
        for marker in attention.values { board.applyHostAttention(marker, on: marker.object) }
        return board
    }
}

@MainActor
struct NeedsYouDerivationTests {
    @Test func mixedQuestionsMatchFrozenDerivationAcrossExpiryBoundaries() throws {
        let fixture = NeedsYouDerivationFixture()
        #expect(fixture.objects.values.filter { $0.type == .question }.count >= 300)
        let board = fixture.remoteBoard()
        let moments = [-1.001, -1, -0.001, 0, 0.125, 0.250, 1].map { NeedsYouDerivationFixture.now.addingTimeInterval($0) }
        let expected = moments.map { now in
            (Self.baseItems(board.objects, attention: board.attention, now: now), Self.baseWaiting(board.objects, now: now))
        }
        for (index, now) in moments.enumerated() {
            #expect(NeedsYouItem.all(board.objects, attention: board.attention, now: now) == expected[index].0)
            #expect(board.waitingQuestions(at: now) == expected[index].1)
        }
    }

    @Test func edgeCasesHaveIndependentExpectedMembershipAndPrecedence() {
        var fixture = NeedsYouDerivationFixture(questionCount: 0)
        let cases: [(String, [String: JSONValue])] = [
            ("a-missing-status", [:]),
            ("b-unknown-status", ["status": "unknown"]),
            ("c-archived-open", ["status": "open", "archived": .bool(true)]),
            ("d-answer-open", ["status": "open", "answer": .object(["option": "yes", "at": "2029-12-31T23:00:00.125Z"])]),
            ("e-invalid-expiry", ["expiresAt": "not a date"]),
            ("f-fraction-future", ["expiresAt": "2030-01-01T00:00:00.125Z"]),
            ("g-offset-future", ["expiresAt": "2029-12-31T19:00:00.250-05:00"]),
            ("h-boundary-whole", ["expiresAt": "2030-01-01T00:00:00Z"]),
            ("i-boundary-offset", ["expiresAt": "2030-01-01T02:00:00.000+02:00"]),
            ("j-past", ["expiresAt": "2029-12-31T23:59:59.999Z"]),
            ("k-answered", ["status": "answered"]),
            ("l-cancelled", ["status": "cancelled"]),
            ("m-expired", ["status": "expired"]),
        ]
        for (id, extra) in cases {
            var props = NeedsYouDerivationFixture.questionProps(id)
            props.removeValue(forKey: "status")
            props.merge(extra) { _, new in new }
            fixture.add(id, type: .question, props: props, index: 0)
            fixture.mark(id)
        }
        let board = fixture.remoteBoard()
        let now = NeedsYouDerivationFixture.now
        let waitingIDs = ["a-missing-status", "b-unknown-status", "c-archived-open", "d-answer-open", "e-invalid-expiry", "f-fraction-future", "g-offset-future"]
        #expect(board.waitingQuestions(at: now).map(\.id) == waitingIDs)
        let items = NeedsYouItem.all(board.objects, attention: board.attention, now: now)
        #expect(items.filter { $0.reason == .question }.map(\.id) == waitingIDs)
        #expect(items.filter { $0.reason == .blocked }.map(\.id) == ["terminal-0", "terminal-4"])
        #expect(items.filter { $0.reason == .done }.map(\.id) == ["terminal-1"])
        #expect(items.filter { $0.reason == .marked }.map(\.id) == [
            "h-boundary-whole", "i-boundary-offset", "j-past", "k-answered", "l-cancelled", "m-expired", "terminal-5", "terminal-6", "marked-note",
        ])
        #expect(items == Self.baseItems(board.objects, attention: board.attention, now: now))
        #expect(board.waitingQuestions(at: now) == Self.baseWaiting(board.objects, now: now))
        #expect(board.waitingQuestions(at: now.addingTimeInterval(0.125)).map(\.id) == waitingIDs.filter { $0 != "f-fraction-future" })
        #expect(board.waitingQuestions(at: now.addingTimeInterval(0.250)).map(\.id) == Array(waitingIDs.prefix(5)))
    }

    #if DEBUG
    @Test func unrelatedHostChangesParseOnlyOpenQuestionExpiryDates() throws {
        let fixture = NeedsYouDerivationFixture()
        let board = fixture.remoteBoard()
        let now = NeedsYouDerivationFixture.now
        let expectedItems = Self.baseItems(board.objects, attention: board.attention, now: now)
        let expectedWaiting = Self.baseWaiting(board.objects, now: now)
        let dateBound = board.objects.values.filter {
            $0.type == .question && QuestionSpec.status(of: $0.props) == .open && $0.props["expiresAt"]?.string != nil
        }.count
        let count = DateParseCount()
        for revision in 1...100 {
            var note = try #require(board.objects["unrelated-note"])
            note.rev += 1
            note.props = .object(["markdown": .string("Host change \(revision)")])
            board.applyHost(note)
            let before = count.value
            QuestionSpec.$observeDateParsing.withValue({ count.parsed() }) {
                #expect(NeedsYouItem.all(board.objects, attention: board.attention, now: now) == expectedItems)
                #expect(board.waitingQuestions(at: now) == expectedWaiting)
            }
            #expect(count.value - before <= 2 * dateBound,
                    "Each caller may parse one expiry per open question, never closed-question or answer dates")
        }
    }

    private final class DateParseCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func parsed() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
    #endif

    // Frozen full-decoding derivation from 4aa97b02, deliberately independent of the optimized path.
    static func baseItems(_ objects: [ObjectID: CanvasObject], attention: [ObjectID: Attention], now: Date) -> [NeedsYouItem] {
        var items: [NeedsYouItem] = []
        for object in objects.values {
            let state = object.type == .terminal ? object.props["lifecycle"]?["state"]?.string : nil
            let question = object.type == .question ? QuestionSpec(object.props) : nil
            if state == "blocked" {
                items.append(NeedsYouItem(id: object.id, reason: .blocked, message: object.props["lifecycle"]?["message"]?.string, frame: object.frame))
            } else if let question, question.status == .open && (question.expiresAt.map { $0 > now } ?? true) {
                items.append(NeedsYouItem(id: object.id, reason: .question, message: question.question, frame: object.frame))
            } else if let marker = attention[object.id] {
                items.append(NeedsYouItem(id: object.id, reason: .marked, message: marker.message, frame: object.frame))
            } else if state == "done", object.props["lifecycle"]?["seen"]?.bool != true {
                items.append(NeedsYouItem(id: object.id, reason: .done, message: object.props["lifecycle"]?["message"]?.string, frame: object.frame))
            }
        }
        return items.sorted {
            ($0.reason.rawValue, $0.frame.y, $0.frame.x, $0.id) < ($1.reason.rawValue, $1.frame.y, $1.frame.x, $1.id)
        }
    }

    static func baseWaiting(_ objects: [ObjectID: CanvasObject], now: Date) -> [CanvasObject] {
        objects.values.filter {
            guard $0.type == .question else { return false }
            let question = QuestionSpec($0.props)
            return question.status == .open && (question.expiresAt.map { $0 > now } ?? true)
        }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}
