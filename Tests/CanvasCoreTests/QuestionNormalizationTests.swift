import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct QuestionNormalizationTests {
    private func fixture(_ confidence: Double, picked: String? = "b", key: String? = "a", forged: Bool = true) -> BoardSnapshot {
        let board = Board(id: "brd_questionNormalization", root: URL(fileURLWithPath: "/tmp"))
        var answer: [String: JSONValue] = ["note": "Stored answer", "confidence": .number(confidence), "correct": .bool(forged)]
        if let picked { answer["option"] = .string(picked) }
        var props: [String: JSONValue] = [
            "question": "Which?", "options": .array([.object(["id": "a", "label": "A"]), .object(["id": "b", "label": "B"])]),
            "asker": .object(["name": "test"]), "askConfidence": .bool(true), "status": "answered", "answer": .object(answer), "keep": .bool(true),
        ]
        if let key { props["correct"] = .string(key) }
        board.create(type: .question, props: .object(props))
        return board.snapshot
    }

    private func check(_ props: JSONValue, confidence: Double?, correct: Bool?) {
        #expect(props["answer"]?["confidence"]?.number == confidence)
        #expect(props["answer"]?["correct"]?.bool == correct)
        let spec = QuestionSpec(props)
        #expect(spec.answer?.confidence == confidence)
        #expect(spec.answer?.correct == correct)
        #expect(QuestionSpec.mentionLines(props).contains { $0.contains("incorrect") } == (correct == false))
    }

    @Test func snapshotAndRemoteAnswersAreNormalized() throws {
        Run6Trace.event("body.enter", "selector=QuestionNormalizationTests/snapshotAndRemoteAnswersAreNormalized")
        defer { Run6Trace.event("body.exit", "selector=QuestionNormalizationTests/snapshotAndRemoteAnswersAreNormalized") }
        for value in [1e100, Double.nan, -1, Double.infinity, -Double.infinity, 0.8] {
            let snapshot = fixture(value)
            let expected: Double? = value == 0.8 ? 0.8 : nil
            let object = try #require(snapshot.objects.first)
            let direct = QuestionSpec(object.props)
            #expect(direct.answer?.confidence == expected)
            #expect(direct.answer?.correct == false)
            check(try Board(snapshot: snapshot).object(object.id).props, confidence: expected, correct: false)
            let remote = Board(remote: snapshot.id, root: URL(fileURLWithPath: snapshot.root), host: nil)
            remote.applyHost(object)
            check(try remote.object(object.id).props, confidence: expected, correct: false)
            var update = object
            update.props = fixture(0.8, picked: "a", forged: false).objects[0].props
            update.rev += 1
            remote.applyHost(update)
            check(try remote.object(object.id).props, confidence: 0.8, correct: true)
        }
        for snapshot in [fixture(0.8, picked: nil), fixture(0.8, key: nil)] {
            let object = snapshot.objects[0]
            check(try Board(snapshot: snapshot).object(object.id).props, confidence: 0.8, correct: nil)
            #expect(QuestionSpec(object.props).answer?.correct == nil)
        }
    }

    @Test func boardFileAnswersAreNormalizedAndNaNIsRejected() throws {
        Run6Trace.event("body.enter", "selector=QuestionNormalizationTests/boardFileAnswersAreNormalizedAndNaNIsRejected")
        defer { Run6Trace.event("body.exit", "selector=QuestionNormalizationTests/boardFileAnswersAreNormalizedAndNaNIsRejected") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("board.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for value in [1e100, -1, 0.8] {
            try encoder.encode(fixture(value)).write(to: url)
            let snapshot = try #require(try BoardFile.read(url, backupUnreadable: false))
            check(snapshot.objects[0].props, confidence: value == 0.8 ? 0.8 : nil, correct: false)
        }
        let json = String(decoding: try encoder.encode(fixture(0.8)), as: UTF8.self)
        try Data(json.replacingOccurrences(of: "0.8", with: "NaN").utf8).write(to: url)
        #expect(throws: BoardFile.Unreadable.self) { try BoardFile.read(url, backupUnreadable: false) }
    }

    @Test func percentNeverConvertsInvalidConfidenceToAnInteger() {
        Run6Trace.event("body.enter", "selector=QuestionNormalizationTests/percentNeverConvertsInvalidConfidenceToAnInteger")
        defer { Run6Trace.event("body.exit", "selector=QuestionNormalizationTests/percentNeverConvertsInvalidConfidenceToAnInteger") }
        for value in [1e100, Double.nan, -1, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
            #expect(QuestionSpec.percent(value) == "—")
        }
        #expect(QuestionSpec.percent(0.8) == "80%")
        #expect(QuestionSpec.percent(0) == "0%")
        #expect(QuestionSpec.percent(1) == "100%")
    }
}
