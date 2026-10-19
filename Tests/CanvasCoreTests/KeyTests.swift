import Foundation
import Testing
import CanvasCore

/// `props.key`, `object.find`, and `object.upsert` over the socket, as a reconciler drives them.
@MainActor
final class KeyTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-keys-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let server: SocketServer
    let board: Board
    let client: LineClient
    var sequence = 0

    init() async throws {
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = await registry.open(root: root)
        let router = ApiRouter(registry: registry)
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

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        sequence += 1
        let request: JSONValue = .object(["id": .string("r\(sequence)"), "method": .string(method), "params": params])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    func result(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let reply = try await call(method, params)
        #expect(reply["ok"] == .bool(true), "\(method): \(reply["error"] ?? .null)")
        return reply["result"] ?? .null
    }

    /// The id `object.find` answers for `key`, nil when it answers not_found.
    func found(_ key: String) async throws -> String? {
        let reply = try await call("object.find", .object(["key": .string(key)]))
        if reply["error"]?["code"] == .string("not_found") { return nil }
        return try #require(reply["result"]?["object"]?["id"]?.string, "\(reply)")
    }

    static func note(_ x: Double, _ text: String) -> JSONValue {
        .object(["type": "note", "props": .object(["markdown": .string(text)]), "frame": .object(["x": .number(x), "y": 0, "w": 200, "h": 100])])
    }

    static func upsert(_ key: String, _ type: String, _ props: JSONValue) -> JSONValue {
        .object(["method": "object.upsert", "params": .object(["key": .string(key), "type": .string(type), "props": props])])
    }

    @Test func aKeyAnotherObjectHoldsIsAConflictNamingIt() async throws {
        let first = try #require(try await result("object.create", Self.note(0, "a").merging(.object(["props": .object(["markdown": "a", "key": "REL-1"])])))["object"]?["id"]?.string)
        let taken = try await call("object.create", Self.note(300, "b").merging(.object(["props": .object(["markdown": "b", "key": "REL-1"])])))
        #expect(taken["error"]?["code"] == .string("conflict"))
        #expect(taken["error"]?["message"]?.string?.contains(first) == true)
        #expect(board.objects.count == 1)

        let second = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 300, y: 0, w: 200, h: 100))
        let renamed = try await call("object.update", .object(["id": .string(second.id), "props": .object(["key": "REL-1"])]))
        #expect(renamed["error"]?["code"] == .string("conflict"))
        #expect(try board.object(second.id).props["key"] == nil)
        #expect(try await call("object.update", .object(["id": .string(second.id), "props": .object(["key": ""])]))["error"]?["code"] == .string("invalid_params"))

        // Given up (null), the key is free; its new holder is what find answers.
        _ = try await result("object.update", .object(["id": .string(first), "props": .object(["key": .null])]))
        _ = try await result("object.update", .object(["id": .string(second.id), "props": .object(["key": "REL-1"])]))
        #expect(try await found("REL-1") == second.id)
    }

    @Test func upsertingAgainKeepsTheIdAndChangesOnlyProps() async throws {
        let created = try await result("object.upsert", .object(["key": "REL-7", "type": "note", "props": .object(["markdown": "open"]), "frame": .object(["x": 0, "y": 0, "w": 200, "h": 100])]))
        #expect(created["created"] == .bool(true))
        let id = try #require(created["object"]?["id"]?.string)
        #expect(try board.object(id).props["key"] == .string("REL-7"))
        // The user moves it; the script runs again without a frame.
        _ = try board.update(id, frame: Frame(x: 500, y: 40, w: 200, h: 100))

        let again = try await result("object.upsert", .object(["key": "REL-7", "type": "note", "props": .object(["markdown": "merged"])]))
        #expect(again["created"] == .bool(false))
        #expect(again["object"]?["id"] == .string(id))
        #expect(board.objects.count == 1)
        let object = try board.object(id)
        #expect(object.props["markdown"] == .string("merged") && object.props["key"] == .string("REL-7"))
        #expect(object.frame == Frame(x: 500, y: 40, w: 200, h: 100), "where the user put it")

        let wrongType = try await call("object.upsert", .object(["key": "REL-7", "type": "group", "props": .object(["members": []])]))
        #expect(wrongType["error"]?["code"] == .string("conflict"))
        #expect(board.objects.count == 1)
    }

    /// A reconciler's batch: a region per ticket, its notes named by "$n" whether the upsert
    /// created or updated them, run twice.
    @Test func aBatchOfUpsertsRunTwiceUpdatesTheSameObjects() async throws {
        func run(_ status: String) async throws -> [String] {
            let reply = try await result("object.batch", .object(["ops": .array([
                Self.upsert("REL-1/status", "note", .object(["markdown": .string(status)])),
                Self.upsert("REL-1/pr", "note", .object(["markdown": "PR #1"])),
                Self.upsert("REL-1", "group", .object(["members": ["$0", "$1"], "title": .string("REL-1 \(status)")])),
                // A second upsert of a key an earlier op creates updates that object.
                Self.upsert("REL-1/status", "note", .object(["markdown": .string(status + "!")])),
                .object(["method": "layout.stack", "params": .object(["ids": ["$3", "$1"], "origin": .object(["x": 0, "y": 0])])]),
            ])]))
            let results = try #require(reply["results"]?.array)
            return try (0..<4).map { try #require(results[$0]["object"]?["id"]?.string) }
        }
        let first = try await run("open")
        #expect(first[3] == first[0])
        let revision = board.revision
        let second = try await run("merged")
        #expect(second == first)
        #expect(board.objects.count == 3)
        #expect(board.revision == revision + 1)
        #expect(try board.object(first[0]).props["markdown"] == .string("merged!"))
        #expect(try board.object(first[2]).props["members"] == .array([.string(first[0]), .string(first[1])]))
    }

    @Test func aFailedBatchLeavesNoKeyBehind() async throws {
        let reply = try await call("object.batch", .object(["ops": .array([
            Self.upsert("REL-2", "note", .object(["markdown": "new"])),
            .object(["method": "object.create", "params": Self.note(0, "copy").merging(.object(["props": .object(["markdown": "copy", "key": "REL-2"])]))]),
        ])]))
        #expect(reply["error"]?["code"] == .string("conflict"))
        #expect(reply["error"]?["message"]?.string?.hasPrefix("op 1 (object.create)") == true)
        #expect(board.objects.isEmpty)
        #expect(try await found("REL-2") == nil)
        // The key was never taken: a create may have it, and find names only that one.
        let later = try await result("object.create", Self.note(0, "later").merging(.object(["props": .object(["markdown": "later", "key": "REL-2"])])))
        #expect(try await found("REL-2") == later["object"]?["id"]?.string)
    }

    @Test func undoRedoAndReloadKeepFindExact() async throws {
        let id = try #require(try await result("object.upsert", .object(["key": "REL-3", "type": "note", "props": .object(["markdown": "x"])]))["object"]?["id"]?.string)
        _ = try await result("object.update", .object(["id": .string(id), "props": .object(["key": "REL-3b"])]))
        #expect(try await found("REL-3") == nil)
        #expect(board.undo())
        #expect(try await found("REL-3") == id, "the rename undone")
        #expect(try await found("REL-3b") == nil)

        _ = try await result("object.delete", .object(["id": .string(id)]))
        #expect(try await found("REL-3") == nil)
        // Deleted, it no longer holds the key: a new object takes it alone.
        let other = try await result("object.upsert", .object(["key": "REL-3", "type": "note", "props": .object(["markdown": "y"])]))
        #expect(other["created"] == .bool(true))
        #expect(try await found("REL-3") == other["object"]?["id"]?.string)
        #expect(board.undo())
        #expect(board.undo())
        #expect(try await found("REL-3") == id, "the delete undone")
        #expect(board.undo())
        #expect(try await found("REL-3") == nil, "the create undone")
        #expect(board.redo())
        #expect(try await found("REL-3") == id)

        let reloaded = Board(snapshot: board.snapshot)
        #expect(try reloaded.holder(ofKey: "REL-3")?.id == id)
        #expect(reloaded.objects(keyPrefix: "REL-").map(\.id) == [id])
    }

    @Test func keyPrefixListsInKeyOrder() async throws {
        for key in ["REL-20", "OPS-1", "REL-3"] {
            _ = try await result("object.upsert", .object(["key": .string(key), "type": "shape", "props": .object(["kind": "rect"])]))
        }
        let listed = try await result("object.find", .object(["keyPrefix": "REL-"]))
        #expect(listed["objects"]?.array?.compactMap { $0["props"]?["key"]?.string } == ["REL-20", "REL-3"])
        #expect(try await call("object.find", .object([:]))["error"]?["code"] == .string("invalid_params"))
    }
}
