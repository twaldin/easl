import CoreGraphics
import Foundation
import Testing
import CanvasCore

extension LayoutApiTests {
    private func archivedQuestion(frame: Frame, archived: Bool = true) -> CanvasObject {
        board.create(type: .question, props: .object([
            "question": "Ship?", "options": .array([.object(["id": "yes", "label": "Yes"])]),
            "asker": .object(["name": "test"]), "status": "answered", "keep": .bool(true),
            "answer": .object(["option": "yes"]), "archived": .bool(archived),
        ]), frame: frame)
    }

    @Test func archivedQuestionHasNoLayoutOverlapAndRemainsReadable() async throws {
        let question = archivedQuestion(frame: Frame(x: 0, y: 0, w: 200, h: 100))
        _ = board.create(type: .note, props: .object(["markdown": "note"]), frame: Frame(x: 100, y: 0, w: 200, h: 100))
        let report = try await result("layout.check", .object([:]))
        #expect(report["overlaps"] == .array([]))
        let scoped = try await result("layout.check", .object(["ids": [.string(question.id)]]))
        #expect(scoped["overlaps"] == .array([]))
        let raw = try await result("object.get", .object(["id": .string(question.id)]))
        #expect(raw["object"]?["props"]?["archived"] == .bool(true))
        let found = try await result("object.find", .object(["type": "question"]))
        #expect(found["objects"]?.array?.compactMap { $0["id"]?.string } == [question.id])
        _ = try await result("object.update", .object(["id": .string(question.id), "props": .object(["archived": .bool(false)])]))
        let visible = try await result("layout.check", .object([:]))
        #expect(visible["overlaps"]?.array?.count == 1)
    }

    @Test func automaticPlacementReusesArchivedQuestionSpace() async throws {
        _ = archivedQuestion(frame: Frame(x: -100, y: -50, w: 200, h: 100))
        let note = try await result("object.create", .object(["type": "note", "props": .object(["markdown": "note"]), "frame": .object(["w": 200, "h": 100])]))
        let frame = try #require(note["object"]?["frame"]).decode(Frame.self)
        #expect(frame.x == -frame.w / 2)
        #expect(frame.y == -frame.h / 2)
    }

    @Test func fitAndContentGrowthIgnoreArchivedQuestion() throws {
        let note = board.create(type: .note, props: .object(["markdown": "note"]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        _ = archivedQuestion(frame: Frame(x: 150, y: 0, w: 100, h: 100))
        let expected = Frame(x: 0, y: 0, w: 300, h: 100)
        #expect(try board.refitFrame(note.id, to: CGSize(width: 300, height: 100)) == expected)
        #expect(try board.grownFrame(note.id, toward: CGSize(width: 300, height: 100)) == expected)
    }

    @Test func sizeFitGrowsIntoArchivedQuestionSpace() async throws {
        let code = board.create(type: .code, props: Self.code(1, 10), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        _ = archivedQuestion(frame: Frame(x: 150, y: 0, w: 200, h: 200))
        let fitted = try await result("object.update", .object(["id": .string(code.id), "size": "fit"]))
        let frame = try #require(fitted["object"]?["frame"]).decode(Frame.self)
        #expect(frame.x == 0 && frame.y == 0)
        #expect(frame.w > 150)
    }

    @Test func archivingObstacleInvalidatesSettledAvoidRoute() throws {
        let question = archivedQuestion(frame: Frame(x: 200, y: -80, w: 100, h: 160), archived: false)
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .point(CGPoint(x: 0, y: 0)), to: .point(CGPoint(x: 500, y: 0)), route: .avoid).props)
        let settled = board.geometry.routing()
        let before = try #require(settled.paths[arrow.id])
        #expect(before.contains { abs($0.y) > 1 })
        _ = try board.update(question.id, props: .object(["archived": .bool(true)]))
        let after = try #require(BoardGeometry(objects: board.objects, labelSizes: [:], settled: settled).routes()[arrow.id])
        #expect(after.allSatisfy { abs($0.y) < 0.01 })
    }

    @Test func archivedQuestionIsNeitherArrowObstacleNorCrossing() async throws {
        let question = archivedQuestion(frame: Frame(x: 200, y: -80, w: 100, h: 160))
        let from = ArrowBinding.point(CGPoint(x: 0, y: 0))
        let to = ArrowBinding.point(CGPoint(x: 500, y: 0))
        let avoid = board.create(type: .arrow, props: ArrowSpec(from: from, to: to, route: .avoid).props)
        let straight = board.create(type: .arrow, props: ArrowSpec(from: from, to: to).props)
        let route = try #require(board.geometry.routes()[avoid.id])
        #expect(route.allSatisfy { abs($0.y) < 0.01 })
        let report = try await result("layout.check", .object(["ids": [.string(straight.id)]]))
        #expect(report["arrowCrossings"] == .array([]))
        _ = try board.update(question.id, props: .object(["archived": .bool(false)]))
        let visible = try await result("layout.check", .object(["ids": [.string(straight.id)]]))
        #expect(visible["arrowCrossings"]?.array?.first?["crosses"] == .array([.string(question.id)]))
    }

    @Test func archivedQuestionHasNoSpatialGraphEdgesInEitherDirection() async throws {
        let hidden = archivedQuestion(frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let enclosing = board.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: -50, y: -50, w: 400, h: 300))
        let overlapping = board.create(type: .note, props: .object(["markdown": "note"]), frame: Frame(x: 100, y: 0, w: 200, h: 100))
        let inside = board.create(type: .note, props: .object(["markdown": "inside"]), frame: Frame(x: 20, y: 20, w: 40, h: 40))
        for object in [hidden, enclosing, overlapping, inside] {
            let graph = try await result("object.get", .object(["id": .string(object.id), "as": "graph"]))["graph"]
            for edge in ["encloses", "enclosedBy", "overlaps"] {
                let ids = try #require(graph?[edge]?.array).compactMap(\.string)
                if object.id == hidden.id { #expect(ids.isEmpty) }
                else { #expect(!ids.contains(hidden.id)) }
            }
        }
    }

    @Test func archiveAndUnarchiveRefitNestedGroupsWithoutMovingQuestion() async throws {
        let question = archivedQuestion(frame: Frame(x: 100, y: 100, w: 200, h: 100), archived: false)
        let inner = board.create(type: .group, props: .object(["members": [.string(question.id)]]))
        let outer = board.create(type: .group, props: .object(["members": [.string(inner.id)]]))
        _ = try await result("object.update", .object(["id": .string(question.id), "props": .object(["archived": .bool(true)])]))
        for group in [inner, outer] {
            let frame = try board.object(group.id).frame
            #expect(frame == Frame(x: group.frame.x, y: group.frame.y, w: 0, h: 0))
        }
        #expect(board.geometry.regions.isEmpty)
        #expect(board.place(question.frame) == question.frame)
        let graph = try await result("object.get", .object(["id": .string(question.id), "as": "graph"]))
        #expect(graph["graph"]?["enclosedBy"] == .array([]))
        let restored = Board(snapshot: board.snapshot)
        #expect(try restored.object(outer.id).frame.w == 0)
        _ = try await result("object.update", .object(["id": .string(question.id), "props": .object(["archived": .bool(false)])]))
        #expect(try board.object(question.id).frame == question.frame)
        #expect(try board.object(inner.id).frame == inner.frame)
        #expect(try board.object(outer.id).frame == outer.frame)
    }

    @Test func archiveShrinksGroupToItsRemainingVisibleMember() throws {
        let question = archivedQuestion(frame: Frame(x: 1000, y: 1000, w: 200, h: 100), archived: false)
        let note = board.create(type: .note, props: .object(["markdown": "note"]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let group = board.create(type: .group, props: .object(["members": [.string(question.id), .string(note.id)]]))
        _ = try board.update(question.id, props: .object(["archived": .bool(true)]))
        #expect(try board.object(group.id).frame == Frame(x: -24, y: -56, w: 148, h: 180))
        _ = try board.update(question.id, props: .object(["archived": .bool(false)]))
        #expect(try board.object(group.id).frame == group.frame)
    }

    @Test func arrowsBoundToArchivedQuestionDisappearAndReturnWithoutLosingBinding() throws {
        let question = archivedQuestion(frame: Frame(x: 0, y: 0, w: 200, h: 100), archived: false)
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .object(question.id), to: .point(CGPoint(x: 500, y: 50))).props)
        let before = try #require(board.geometry.routes()[arrow.id])
        let settled = board.geometry.routing()
        _ = try board.update(question.id, props: .object(["archived": .bool(true)]))
        #expect(BoardGeometry(objects: board.objects, labelSizes: [:], settled: settled).routes()[arrow.id] == nil)
        #expect(ArrowSpec(try board.object(arrow.id).props)?.from.objectID == question.id)
        _ = try board.update(question.id, props: .object(["archived": .bool(false)]))
        #expect(board.geometry.routes()[arrow.id] == before)
        _ = try board.update(question.id, props: .object(["archived": .bool(true)]))
        try board.delete(question.id)
        #expect(ArrowSpec(try board.object(arrow.id).props)?.from.objectID == nil)
    }

    @Test func archivedEndpointArrowsDoNotProduceLayoutHints() {
        let question = archivedQuestion(frame: Frame(x: 0, y: 0, w: 200, h: 100))
        for index in 0...BoardGeometry.sameColorLimit {
            _ = board.create(type: .arrow, props: ArrowSpec(
                from: .object(question.id), to: .point(CGPoint(x: 500, y: index * 40)), label: "Answer"
            ).props)
        }
        #expect(board.geometry.layoutCheck().hints.isEmpty)
    }

    @Test func drawingMentionsIgnoreArchivedQuestionGeometry() async throws {
        let box = board.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: 0, y: 0, w: 400, h: 400))
        let question = archivedQuestion(frame: Frame(x: 100, y: 100, w: 100, h: 100), archived: false)
        let mark = board.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: 120, y: 120, w: 20, h: 20))
        _ = board.create(type: .arrow, props: ArrowSpec(from: .object(question.id), to: .point(CGPoint(x: 10, y: 10))).props)
        for object in [box, mark] {
            try board.stage(.object(object.id))
            let context = await board.drain().context
            #expect(context.contains(question.id))
        }
        _ = try board.update(question.id, props: .object(["archived": .bool(true)]))
        for object in [box, mark] {
            try board.stage(.object(object.id))
            let context = await board.drain().context
            #expect(!context.contains(question.id))
        }
    }

    @Test func unsupportedArchivePropsDoNotHideNoteGeometry() async throws {
        _ = board.create(type: .note, props: .object(["markdown": "one", "archived": .bool(true), "hidden": .bool(true)]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        _ = board.create(type: .note, props: .object(["markdown": "two"]), frame: Frame(x: 100, y: 0, w: 200, h: 100))
        let report = try await result("layout.check", .object([:]))
        #expect(report["overlaps"]?.array?.count == 1)
    }
}
