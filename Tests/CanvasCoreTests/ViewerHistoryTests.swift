import Foundation
import Testing
@testable import CanvasCore

@MainActor
final class ViewerHistoryTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("vh-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    let client: LineClient
    let viewer = "vw_0123456789ABCDEFGH"
    let other = "vw_otherwindow01"

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        client = try LineClient(path: dir.appendingPathComponent("s").path)
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func reply(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let request: JSONValue = .object(["id": .string(method), "method": .string(method), "params": .object(params)])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let answer = try await reply(method, params)
        #expect(answer["ok"] == .bool(true), "\(method) failed: \(answer["error"] ?? .null)")
        return answer["result"] ?? .null
    }

    func note(_ markdown: String, x: Double = 0, props: [String: JSONValue] = [:]) -> CanvasObject {
        board.create(type: .note, props: .object(props.merging(["markdown": .string(markdown)]) { $1 }), frame: Frame(x: x, y: 0, w: 280, h: 200))
    }

    func agent() -> ObjectID {
        board.create(type: .terminal, props: .object(["cwd": .string(dir.path)]), frame: Frame(x: 0, y: 900, w: 800, h: 500)).id
    }

    func x(_ id: ObjectID) -> Double? { board.objects[id]?.frame.x }

    func move(_ id: ObjectID, to x: Double, step: Int, by viewer: String? = nil) async throws {
        _ = try await call("object.update", ["id": .string(id), "frame": .object(["x": .number(x)]), "viewer": .string(viewer ?? self.viewer), "step": .number(Double(step))])
    }

    func undo(_ step: Int, redo: Bool = false, by viewer: String? = nil) async throws -> JSONValue {
        try await call(redo ? "board.redo" : "board.undo", ["board": .string(board.id), "viewer": .string(viewer ?? self.viewer), "step": .number(Double(step))])
    }

    func ids(_ value: JSONValue?) -> [ObjectID] {
        (value?.array ?? []).compactMap { $0.string ?? $0["id"]?.string }
    }

    @Test func undoingAViewersMoveKeepsAnAgentsTextOnTheSameNote() async throws {
        let edited = note("draft")
        let agent = agent()
        try await move(edited.id, to: 300, step: 1)
        _ = try await call("object.update", ["id": .string(edited.id), "props": .object(["markdown": "agent text"]), "caller": .string(agent)])
        let undone = try await undo(1)
        #expect(undone["step"] == .number(1))
        #expect(ids(undone["changed"]) == [edited.id])
        #expect(undone["deleted"] == .array([]) && undone["kept"] == .array([]))
        #expect(undone["pushed"] == .bool(true))
        #expect(x(edited.id) == 0)
        #expect(board.objects[edited.id]?.props["markdown"] == "agent text")
        _ = try await undo(1, redo: true)
        #expect(x(edited.id) == 300)
        #expect(board.objects[edited.id]?.props["markdown"] == "agent text")
    }

    @Test func aFieldSomeoneChangedSinceIsKeptAndRetryingThatUndoUndoesNothingElse() async throws {
        let first = note("first"), second = note("second", x: 400)
        let agent = agent()
        try await move(first.id, to: 100, step: 1)
        try await move(second.id, to: 500, step: 2)
        _ = try await call("object.update", ["id": .string(second.id), "frame": .object(["x": 900]), "caller": .string(agent)])
        let kept = try await undo(2)
        #expect(kept == .object(["step": 2, "changed": .array([]), "deleted": .array([]), "kept": .array([.string(second.id)]), "pushed": .bool(false)]))
        #expect(x(second.id) == 900)
        let revision = board.revision
        #expect(try await undo(2) == kept)
        #expect(board.revision == revision)
        #expect(x(first.id) == 100, "a retry of the consumed step must not undo the step before it")
        _ = try await undo(1)
        #expect(x(first.id) == 0)
    }

    @Test func aPartlyKeptUndoIsRedoneOnlyAsFarAsItWent() async throws {
        let edited = note("mine")
        let agent = agent()
        _ = try await call("object.update", ["id": .string(edited.id), "frame": .object(["x": 200]), "props": .object(["markdown": "viewer text"]),
                                             "viewer": .string(viewer), "step": 1])
        _ = try await call("object.update", ["id": .string(edited.id), "props": .object(["markdown": "agent text"]), "caller": .string(agent)])
        let undone = try await undo(1)
        #expect(ids(undone["kept"]) == [edited.id])
        #expect(ids(undone["changed"]) == [edited.id])
        #expect(x(edited.id) == 0)
        #expect(board.objects[edited.id]?.props["markdown"] == "agent text")
        _ = try await call("object.update", ["id": .string(edited.id), "props": .object(["markdown": "agent again"]), "caller": .string(agent)])
        let redone = try await undo(1, redo: true)
        #expect(redone["kept"] == .array([]))
        #expect(x(edited.id) == 200)
        #expect(board.objects[edited.id]?.props["markdown"] == "agent again")
    }

    @Test func eachViewerUndoesOnlyItsOwnSteps() async throws {
        let mine = note("mine"), theirs = note("theirs", x: 400)
        try await move(mine.id, to: 100, step: 1)
        try await move(theirs.id, to: 600, step: 1, by: other)
        _ = try await undo(1)
        #expect(x(mine.id) == 0 && x(theirs.id) == 600)
        _ = try await undo(1, by: other)
        #expect(x(theirs.id) == 400)
        #expect(try await undo(2)["step"] == nil, "the first viewer has nothing left to undo")
    }

    @Test func undoingACreateRemovesItUnlessSomeoneEditedIt() async throws {
        let agent = agent()
        func create(_ markdown: String, step: Int) async throws -> ObjectID {
            let made = try await call("object.create", ["board": .string(board.id), "type": "note", "props": .object(["markdown": .string(markdown)]),
                                                        "frame": .object(["x": 0, "y": 300, "w": 280, "h": 200]), "viewer": .string(viewer), "step": .number(Double(step))])
            return try #require(made["object"]?["id"]?.string)
        }
        let fresh = try await create("fresh", step: 1)
        let undone = try await undo(1)
        #expect(undone["deleted"] == .array([.string(fresh)]))
        #expect(board.objects[fresh] == nil)
        _ = try await undo(1, redo: true)
        #expect(board.objects[fresh]?.props["markdown"] == "fresh", "redo brings back the same object")
        let edited = try await create("viewer's", step: 2)
        _ = try await call("object.update", ["id": .string(edited), "props": .object(["markdown": "agent's"]), "caller": .string(agent)])
        let kept = try await undo(2)
        #expect(ids(kept["kept"]) == [edited])
        #expect(board.objects[edited]?.props["markdown"] == "agent's")
    }

    @Test func undoingADeleteBringsBackTheSameObjectAtANewRevisionWithItsArrows() async throws {
        let source = note("source"), target = note("target", x: 400)
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .object(source.id), to: .object(target.id)).props)
        _ = try await call("object.update", ["id": .string(target.id), "props": .object(["markdown": "edited first"])])
        let deleted = try #require(board.objects[target.id])
        _ = try await call("object.delete", ["id": .string(target.id), "viewer": .string(viewer), "step": 1])
        #expect(ArrowSpec(try board.object(arrow.id).props)?.to.objectID == nil)
        let undone = try await undo(1)
        let back = try #require(board.objects[target.id])
        #expect(back.z == deleted.z && back.frame == deleted.frame && back.props == deleted.props)
        #expect(back.rev > deleted.rev)
        #expect(ArrowSpec(try board.object(arrow.id).props)?.to.objectID == target.id)
        #expect(Set(ids(undone["changed"])) == [target.id, arrow.id])
    }

    @Test func aDeleteWhoseKeyAnotherObjectTookStaysDeleted() async throws {
        let keyed = note("plan", props: ["key": "plan"])
        _ = try await call("object.delete", ["id": .string(keyed.id), "viewer": .string(viewer), "step": 1])
        let taken = note("another plan", x: 400, props: ["key": "plan"])
        let undone = try await undo(1)
        #expect(ids(undone["kept"]) == [keyed.id])
        #expect(board.objects[keyed.id] == nil)
        #expect(try board.holder(ofKey: "plan")?.id == taken.id)
    }

    @Test func aRetryAfterALostReplyAnswersTheSameAndKeepsRedo() async throws {
        let moved = note("moved")
        try await move(moved.id, to: 300, step: 1)
        let undone = try await undo(1)
        let revision = board.revision
        #expect(try await undo(1) == undone)
        #expect(board.revision == revision && x(moved.id) == 0)
        let redone = try await undo(1, redo: true)
        #expect(redone["pushed"] == .bool(true))
        #expect(x(moved.id) == 300)
        #expect(try await undo(1, redo: true) == redone)
        _ = try await undo(1)
        #expect(x(moved.id) == 0 && board.revision > revision)
    }

    @Test func aStepThatNeverReachedTheHostUndoesTheOneBeforeIt() async throws {
        let moved = note("moved")
        try await move(moved.id, to: 300, step: 1)
        let undone = try await undo(2)
        #expect(undone["step"] == .number(1))
        #expect(x(moved.id) == 0)
        #expect(try await undo(2) == undone)
        #expect(x(moved.id) == 0)
        #expect(try await undo(1) == undone, "the step undone in its place answers the same")
    }

    @Test func aLateWriteOfAnEarlierGestureJoinsItsOwnStep() async throws {
        let first = note("first"), second = note("second", x: 400)
        try await move(second.id, to: 500, step: 2)
        try await move(first.id, to: 100, step: 1)
        _ = try await undo(2)
        #expect(x(second.id) == 400 && x(first.id) == 100)
        _ = try await undo(1)
        #expect(x(first.id) == 0)
    }

    @Test func aNewStepClearsRedo() async throws {
        let first = note("first"), second = note("second", x: 400)
        try await move(first.id, to: 100, step: 1)
        _ = try await undo(1)
        try await move(second.id, to: 500, step: 2)
        #expect(try await undo(1, redo: true)["step"] == nil)
        #expect(x(first.id) == 0)
    }

    @Test func undoingAGroupMembersMoveFitsTheGroupAgain() async throws {
        let first = note("first"), second = note("second", x: 400)
        let group = board.create(type: .group, props: .object(["members": .array([.string(first.id), .string(second.id)])]))
        let fitted = try #require(board.objects[group.id]).frame
        try await move(second.id, to: 900, step: 1)
        #expect(board.objects[group.id]?.frame != fitted)
        _ = try await undo(1)
        #expect(x(second.id) == 400)
        #expect(board.objects[group.id]?.frame == fitted)
    }

    @Test func aRestackIsOneStep() async throws {
        let back = note("back"), middle = note("middle", x: 100), front = note("front", x: 200)
        for (id, z) in [(back.id, front.z + 1), (middle.id, front.z + 2)] {
            _ = try await call("object.update", ["id": .string(id), "z": .number(z), "viewer": .string(viewer), "step": 1])
        }
        #expect(board.objects[back.id]?.z == front.z + 1 && board.objects[middle.id]?.z == front.z + 2)
        _ = try await undo(1)
        #expect(board.objects[back.id]?.z == back.z && board.objects[middle.id]?.z == middle.z)
    }

    @Test func viewerAndStepGoTogetherAndNeverInsideABatch() async throws {
        let edited = note("edited")
        let alone = try await reply("object.update", ["id": .string(edited.id), "frame": .object(["x": 300]), "viewer": .string(viewer)])
        #expect(alone["error"]?["code"] == "invalid_params")
        let malformed = try await reply("object.update", ["id": .string(edited.id), "frame": .object(["x": 300]), "viewer": "window", "step": 1])
        #expect(malformed["error"]?["code"] == "invalid_params")
        let batched = try await reply("object.batch", ["ops": .array([
            .object(["method": "object.update", "params": .object(["id": .string(edited.id), "frame": .object(["x": 300])])]),
            .object(["method": "object.update", "params": .object(["id": .string(edited.id), "props": .object(["markdown": "x"]), "viewer": .string(viewer), "step": 1])]),
        ])])
        #expect(batched["error"]?["code"] == "invalid_params")
        #expect(board.objects[edited.id] == edited)
        #expect(try await undo(1)["step"] == nil)
    }

    @Test func pastSixteenViewersTheLeastRecentlyUsedIsForgotten() async throws {
        let moved = note("moved")
        let viewers = (0..<17).map { "vw_window\(String(format: "%04d", $0))" }
        for (index, viewer) in viewers.enumerated() { try await move(moved.id, to: Double(index + 1) * 10, step: 1, by: viewer) }
        #expect(try await undo(1, by: viewers[0])["step"] == nil)
        #expect(try await undo(1, by: viewers[16])["step"] == .number(1))
        #expect(x(moved.id) == 160)
    }

    @Test func aStepOlderThanTheKeptHistoryIsAConflictNotAnOlderUndo() async throws {
        let moved = note("moved")
        for step in 1...(ViewerHistory.limit + 1) { try await move(moved.id, to: Double(step), step: step) }
        let refused = try await reply("board.undo", ["board": .string(board.id), "viewer": .string(viewer), "step": 1])
        #expect(refused["error"]?["code"] == "conflict")
        #expect(x(moved.id) == Double(ViewerHistory.limit + 1))
        _ = try await undo(ViewerHistory.limit + 1)
        #expect(x(moved.id) == Double(ViewerHistory.limit))
    }
}
