import Foundation
import Testing
@testable import CanvasCore

@MainActor
final class ObjectExpiryTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("expiry-\(UUID().uuidString)")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        board = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        client.send(String(decoding: try JSONEncoder().encode(JSONValue.object(["id": "1", "method": .string(method), "params": .object(params)])), as: UTF8.self))
        return try await client.next()
    }

    func create(_ expiry: [String: JSONValue] = [:]) async throws -> CanvasObject {
        var params: [String: JSONValue] = ["board": .string(board.id), "type": "note", "props": .object(["markdown": "temporary"])]
        params.merge(expiry) { _, new in new }
        let reply = try await call("object.create", params)
        let id = try #require(reply["result"]?["object"]?["id"]?.string, "\(reply)")
        return try board.object(id)
    }

    @Test func timerDeletesThroughOrdinaryEventsAndKeepsLiveObjects() async throws {
        let kept = try await create()
        var deleted: [ObjectID] = []
        let hook = board.onEvent
        board.onEvent = { event in
            hook?(event)
            if case .objectDeleted(let id) = event { deleted.append(id) }
        }
        let temporary = try await create(["expiresIn": "0.15s"])
        try await Task.sleep(for: .milliseconds(350))
        #expect(deleted == [temporary.id])
        #expect(board.objects[temporary.id] == nil)
        #expect(board.objects[kept.id] == kept)
    }

    @Test func nullAndMovedDeadlineCancelOldTimerAndOmissionPreservesDeadline() async throws {
        let cleared = try await create(["expiresIn": "0.2s"])
        let moved = try await create(["expiresIn": "0.2s"])
        let clearReply = try await call("object.update", ["id": .string(cleared.id), "expires": .null])
        #expect(clearReply["result"]?["object"]?["rev"]?.int == 2)
        let moveReply = try await call("object.update", ["id": .string(moved.id), "expiresIn": "1h"])
        #expect(moveReply["result"]?["object"]?["rev"]?.int == 2)
        let deadline = try board.object(moved.id).expires
        _ = try await call("object.update", ["id": .string(moved.id), "props": .object(["title": "kept"])])
        try await Task.sleep(for: .milliseconds(350))
        #expect(try board.object(cleared.id).expires == nil)
        #expect(try board.object(moved.id).expires == deadline)
        #expect(try board.object(moved.id).rev == 3)
    }

    @Test func relativeAndOffsetTimestampsNormalizeAndInvalidWritesAreAtomic() async throws {
        let start = Date()
        let relative = try await create(["expiresIn": "1.25h"])
        let deadline = try #require(relative.expires?.date)
        #expect(deadline.timeIntervalSince(start) >= 4500)
        #expect(deadline.timeIntervalSinceNow <= 4500)
        let absolute = try await create(["expires": "2099-01-02t03:04:05.250+02:00"])
        let stamp = try #require(JSONValue(absolute)["expires"]?.string)
        #expect(QuestionSpec.date(stamp) == QuestionSpec.date("2099-01-02T01:04:05.250Z"))
        #expect(stamp.hasSuffix("Z"))
        let invalidPatches: [[String: JSONValue]] = [
            ["expires": "tomorrow"], ["expires": "2099-01-02T03:04:05"], ["expires": .number(5)],
            ["expires": "2099-02-30T03:04:05Z"], ["expires": "2099-01-02T03:04:05+24:00"],
            ["expiresIn": "-1s"], ["expiresIn": "1e3s"], ["expiresIn": "1w"], ["expiresIn": .null],
            ["expiresIn": .string(String(repeating: "9", count: 400) + "d")],
            ["expires": .null, "expiresIn": "1s"],
        ]
        for invalid in invalidPatches {
            var params = invalid
            params["id"] = .string(absolute.id)
            params["props"] = .object(["markdown": "must not land"])
            let reply = try await call("object.update", params)
            #expect(reply["error"]?["code"] == "invalid_params")
            #expect(try board.object(absolute.id) == absolute)
        }
        let conflict = try await call("object.update", ["id": .string(absolute.id), "rev": .number(99), "expires": .null])
        #expect(conflict["error"]?["code"] == "conflict")
        #expect(try board.object(absolute.id) == absolute)
    }

    @Test func restartRetainsDeadlineAndReopenDeletesOverdueObjectsSynchronously() throws {
        let root = board.root
        let deadline = ObjectExpiry(Date().addingTimeInterval(100))
        let expired = board.create(type: .note, props: .object(["markdown": "overdue"]), expires: ObjectExpiry(Date().addingTimeInterval(-1)))
        let kept = board.create(type: .note, props: .object(["markdown": "future"]), expires: deadline)
        try registry.close(board.id)
        #expect(board.isClosed)
        #expect(board.expireObjects(now: Date().addingTimeInterval(200)).isEmpty)
        var deleted: [ObjectID] = []
        registry.onEvent = { registered, event in
            #expect(self.registry.boards[registered.id] === registered)
            if case .objectDeleted(let id) = event { deleted.append(id) }
        }
        let reopened = registry.open(root: root)
        #expect(deleted == [expired.id])
        #expect(reopened.objects[expired.id] == nil)
        #expect(reopened.objects[kept.id]?.expires == deadline)
        let restarted = BoardRegistry(store: registry.store).open(root: root)
        #expect(restarted.objects[kept.id]?.expires == deadline)
    }

    @Test func closedPastDeadlineWaitsForOpenAndUsesStoredAbsoluteTime() async throws {
        let object = try await create(["expiresIn": "0.15s"])
        try registry.close(board.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(board.objects[object.id] == object)
        let reopened = registry.open(root: board.root)
        #expect(reopened.objects[object.id] == nil)
        #expect(reopened.objects.count == 0)
    }

    @Test func staleReasonsAreOrderedAndListingDoesNotWrite() throws {
        let now = Date()
        var snapshot = board.snapshot
        let all = board.create(type: .terminal, props: .object(["title": "Exited\nsecond", "key": "worker"]), caller: "obj_missing")
        let fresh = board.create(type: .note, props: .object(["markdown": "fresh"]))
        snapshot = board.snapshot
        for index in snapshot.objects.indices where snapshot.objects[index].id == all.id {
            snapshot.objects[index].expires = ObjectExpiry(now.addingTimeInterval(-1))
            snapshot.objects[index].updatedAt = now.addingTimeInterval(-8 * 86400)
        }
        let loaded = Board(snapshot: snapshot)
        var events = 0
        loaded.onEvent = { _ in events += 1 }
        let before = loaded.snapshot
        let result = loaded.staleObjects(now: now, exited: [all.id])
        let entry = try #require(result["objects"]?.array?.first)
        #expect(result["objects"]?.array?.count == 1)
        #expect(entry["id"] == .string(all.id))
        #expect(entry["type"] == "terminal")
        #expect(entry["title"] == "Exited")
        #expect(entry["key"] == "worker")
        #expect(entry["createdBy"] == .object(["kind": "agent", "tile": "obj_missing"]))
        #expect(entry["reasons"] == .array(["creator-gone", "expired", "untouched", "exited"]))
        #expect(loaded.snapshot.objects == before.objects)
        #expect(loaded.revision == before.revision)
        #expect(events == 0)
        #expect(loaded.objects[fresh.id] == fresh)
    }

    @Test func staleBoundaryUsesSessionAuthorityAndDurationValidation() async throws {
        let terminal = board.create(type: .terminal, props: .object(["name": "shell"]))
        let liveNote = board.create(type: .note, props: .object(["markdown": "live"]), caller: terminal.id)
        router.terminalSessions = { nil }
        let unknown = try await call("board.stale", ["board": .string(board.id)])
        #expect(unknown["result"]?["objects"] == .array([]))
        router.terminalSessions = { [:] }
        let ended = try await call("board.stale", ["board": .string(board.id)])
        #expect(ended["result"]?["objects"]?.array?.map { $0["id"] } == [.string(terminal.id)])
        #expect(ended["result"]?["objects"]?.array?.first?["reasons"] == .array(["exited"]))
        #expect(board.objects[liveNote.id] == liveNote)
        let invalid = try await call("board.stale", ["board": .string(board.id), "olderThan": "forever"])
        #expect(invalid["error"]?["code"] == "invalid_params")
    }

    @Test func upsertAndFailedBatchPreserveExpiryAndRevision() async throws {
        let params: [String: JSONValue] = ["board": .string(board.id), "key": "scratch", "type": "note", "props": .object(["markdown": "initial"]), "expiresIn": "1h"]
        let first = try await call("object.upsert", params)
        let id = try #require(first["result"]?["object"]?["id"]?.string)
        let before = try board.object(id)
        let second = try await call("object.upsert", ["board": .string(board.id), "key": "scratch", "type": "note", "props": .object(["markdown": "updated"])])
        #expect(second["result"]?["created"] == .bool(false))
        #expect(try board.object(id).expires == before.expires)
        let updated = try board.object(id)
        let batch = try await call("object.batch", ["board": .string(board.id), "ops": .array([
            .object(["method": "object.update", "params": .object(["id": .string(id), "expires": .null])]),
            .object(["method": "object.update", "params": .object(["id": .string(id), "expiresIn": "bad"])])
        ])])
        #expect(batch["error"] != nil)
        #expect(try board.object(id).expires == updated.expires)
        #expect(try board.object(id).props == updated.props)
    }

    @Test func expiryOnlyEditsRemainVisibleInBoardHistory() throws {
        let object = board.create(type: .note, props: .object(["markdown": "history"]))
        let cursor = board.activity.query(since: nil, limit: 100).cursor
        _ = try board.update(object.id, expires: .set(ObjectExpiry(Date().addingTimeInterval(3600))))
        _ = try board.update(object.id, expires: .set(nil))
        let entries = board.activity.query(since: .seq(cursor), limit: 100).entries
        #expect(entries.map(\.kind) == [.updated, .updated])
        #expect(entries.map(\.id) == [object.id, object.id])
        #expect(entries.map(\.rev) == [2, 3])
    }

    @Test func zeroDeadlineAndNormalUndoRestoreExpiryWithoutExtraWrites() throws {
        let reply = try router.dispatch("object.create", .object(["board": .string(board.id), "type": "note", "props": .object(["markdown": "zero"]), "expiresIn": "0s"]))
        let id = try #require(reply["object"]?["id"]?.string)
        #expect(try board.object(id).rev == 1)
        #expect(board.expireObjects() == [id])
        let kept = board.create(type: .note, props: .object(["markdown": "undo"]))
        let deadline = ObjectExpiry(Date().addingTimeInterval(3600))
        _ = try board.update(kept.id, expires: .set(deadline))
        #expect(board.undo())
        #expect(try board.object(kept.id).expires == nil)
        #expect(board.redo())
        #expect(try board.object(kept.id).expires == deadline)
    }

    @Test func staleReasonsRemainIndependentAndCreatorMustBeATerminal() throws {
        let now = Date()
        let wrongCreator = board.create(type: .note, props: .object(["markdown": "not a terminal"]))
        let gone = board.create(type: .note, props: .object(["markdown": "orphan"]), caller: wrongCreator.id)
        let expired = board.create(type: .note, props: .object(["caption": "expired"]), expires: ObjectExpiry(now.addingTimeInterval(-1)))
        let old = board.create(type: .note, props: .object(["markdown": "old", "title": ""]))
        let exited = board.create(type: .terminal, props: .object(["name": "ended"]))
        var snapshot = board.snapshot
        for index in snapshot.objects.indices where snapshot.objects[index].id == old.id {
            snapshot.objects[index].updatedAt = now.addingTimeInterval(-8 * 86400)
        }
        let loaded = Board(snapshot: snapshot)
        let entries = try #require(loaded.staleObjects(now: now, exited: [exited.id])["objects"]?.array)
        #expect(entries.compactMap { $0["id"]?.string } == [gone.id, expired.id, old.id, exited.id].sorted())
        let byID = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry["id"]?.string.map { ($0, entry["reasons"] ?? .null) } })
        #expect(byID[gone.id] == .array(["creator-gone"]))
        #expect(byID[expired.id] == .array(["expired"]))
        #expect(byID[old.id] == .array(["untouched"]))
        #expect(entries.first { $0["id"] == .string(old.id) }?["title"] == "old")
        #expect(byID[exited.id] == .array(["exited"]))
    }
}

extension BoardMirrorTests {
    @Test func expiryMirrorsAndViewerDoesNotDeleteOverdueObjects() async throws {
        let deadline = ObjectExpiry(Date().addingTimeInterval(3600))
        let object = host.create(type: .note, props: .object(["markdown": "host clock"]), expires: deadline)
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        #expect(view.objects[object.id]?.expires == deadline)
        #expect(view.expireObjects(now: Date().addingTimeInterval(7200)).isEmpty)
        #expect(view.objects[object.id]?.props["markdown"] == "host clock")
        _ = try view.update(object.id, expires: .set(nil))
        try await eventually { self.host.objects[object.id]?.expires == nil }
        #expect(host.objects[object.id]?.rev == 2)
    }
}

extension ViewerHistoryTests {
    @Test func viewerExpiryUndoRedoAndCrossedWriteRemainGuarded() async throws {
        let object = note("expiry")
        _ = try await call("object.update", ["id": .string(object.id), "expiresIn": "1h", "viewer": .string(viewer), "step": .number(1)])
        let expiry = try board.object(object.id).expires
        _ = try await undo(2)
        #expect(try board.object(object.id).expires == nil)
        _ = try await undo(3, redo: true)
        #expect(try board.object(object.id).expires == expiry)
        let later = ObjectExpiry(Date().addingTimeInterval(7200))
        _ = try board.update(object.id, expires: .set(later))
        let crossed = try await undo(4)
        #expect(crossed["kept"] == .array([.string(object.id)]))
        #expect(try board.object(object.id).expires == later)
    }
}

extension ObjectExpiryTests {
    @Test func staleSessionSnapshotDoesNotClassifyChangedOrNewTerminalsAsExited() async throws {
        let changed = board.create(type: .terminal, props: .object(["name": "before"]))
        let restarting = board.create(type: .terminal, props: .object(["name": "restarting"]))
        let relaunched = board.create(type: .terminal, props: .object(["name": "relaunched"]))
        let ended = board.create(type: .terminal, props: .object(["name": "ended"]))
        board.restartingAgents[restarting.id] = false
        board.relaunchedAgents.insert(relaunched.id)
        router.terminalSessions = {
            _ = try? self.board.update(changed.id, props: .object(["name": "running now"]))
            _ = self.board.create(type: .terminal, props: .object(["name": "new session"]))
            return [:]
        }
        let reply = try await call("board.stale", ["board": .string(board.id)])
        #expect(reply["result"]?["objects"]?.array?.compactMap { $0["id"]?.string } == [ended.id])
        #expect(reply["result"]?["objects"]?.array?.first?["reasons"] == .array(["exited"]))
    }

    @Test func staleListingRejectsAReplacedBoardAfterSessionRead() async throws {
        _ = board.create(type: .terminal, props: .object(["name": "original"]))
        router.terminalSessions = {
            try? self.registry.close(self.board.id)
            _ = self.registry.open(root: self.board.root)
            return [:]
        }
        let reply = try await call("board.stale", ["board": .string(board.id)])
        #expect(reply["error"]?["code"] == "not_found")
        #expect(registry.boards[board.id] !== board)
    }
}
