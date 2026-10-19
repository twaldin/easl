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

    init() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        board = await registry.open(root: dir.appendingPathComponent("root"))
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

    @Test func restartRetainsDeadlineAndReopenDeletesOverdueObjectsSynchronously() async throws {
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
        let reopened = await registry.open(root: root)
        #expect(deleted == [expired.id])
        #expect(reopened.objects[expired.id] == nil)
        #expect(reopened.objects[kept.id]?.expires == deadline)
        let restarted = await BoardRegistry(store: registry.store).open(root: root)
        #expect(restarted.objects[kept.id]?.expires == deadline)
    }

    @Test func closedPastDeadlineWaitsForOpenAndUsesStoredAbsoluteTime() async throws {
        let object = try await create(["expiresIn": "0.15s"])
        try registry.close(board.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(board.objects[object.id] == object)
        let reopened = await registry.open(root: board.root)
        #expect(reopened.objects[object.id] == nil)
        #expect(reopened.objects.count == 0)
    }

    @Test func futurePersistedDeadlineFiresAfterRegistryAndStoreRestartWithSystemAttribution() async throws {
        let object = try await create(["expiresIn": "2s"])
        let deadline = try #require(object.expires?.date)
        try registry.close(board.id)
        let restarted = BoardRegistry(store: BoardStore(directory: registry.store.directory, debounce: 60))
        var deleted: [ObjectID] = []
        restarted.onEvent = { _, event in
            if case .objectDeleted(let id) = event { deleted.append(id) }
        }
        let reopened = await restarted.open(root: board.root)
        defer { try? restarted.close(reopened.id) }
        #expect(deadline > Date())
        #expect(reopened.objects[object.id]?.expires == object.expires)
        #expect(deleted.isEmpty)
        try await Task.sleep(for: .milliseconds(2500))
        #expect(reopened.objects[object.id] == nil)
        #expect(deleted == [object.id])
        #expect(board.objects[object.id] == object)
        let entries = reopened.activity.query(since: nil, limit: 100).entries.filter { $0.kind == .deleted }
        #expect(entries.map(\.id) == [object.id])
        #expect(entries.map(\.actor) == [.system])
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

    @Test func staleBoundaryRequiresObservedRunningSessionAndRejectsInvalidDuration() async throws {
        let terminal = board.create(type: .terminal, props: .object(["name": "shell"]))
        let liveNote = board.create(type: .note, props: .object(["markdown": "live"]), caller: terminal.id)
        try registry.store.saveChecked(board)
        let persisted = try Data(contentsOf: registry.store.url(for: board.id))
        let before = board.snapshot
        let cursor = board.activity.cursor
        var writes = 0
        var events = 0
        let changeHook = board.onChange
        let eventHook = board.onEvent
        board.onChange = { writes += 1; changeHook?() }
        board.onEvent = { events += 1; eventHook?($0) }
        router.terminalSessions = { nil }
        let unknown = try await call("board.stale", ["board": .string(board.id)])
        #expect(unknown["result"]?["objects"] == .array([]))
        router.terminalSessions = { TerminalSessions() }
        let unstarted = try await call("board.stale", ["board": .string(board.id)])
        #expect(unstarted["result"]?["objects"] == .array([]))
        router.terminalSessions = { TerminalSessions(running: [terminal.id: TerminalSession(board: self.board.id, pid: nil)]) }
        let running = try await call("board.stale", ["board": .string(board.id)])
        #expect(running["result"]?["objects"] == .array([]))
        router.terminalSessions = { nil }
        let unavailable = try await call("board.stale", ["board": .string(board.id)])
        #expect(unavailable["result"]?["objects"] == .array([]))
        router.terminalSessions = { TerminalSessions() }
        let ended = try await call("board.stale", ["board": .string(board.id)])
        #expect(ended["result"]?["objects"]?.array?.map { $0["id"] } == [.string(terminal.id)])
        #expect(ended["result"]?["objects"]?.array?.first?["reasons"] == .array(["exited"]))
        #expect(board.objects[liveNote.id] == liveNote)
        #expect(board.snapshot.objects == before.objects)
        #expect(board.revision == before.revision)
        #expect(board.activity.cursor == cursor)
        #expect(writes == 0)
        #expect(events == 0)
        #expect(try Data(contentsOf: registry.store.url(for: board.id)) == persisted)
        let invalid = try await call("board.stale", ["board": .string(board.id), "olderThan": "forever"])
        #expect(invalid["error"]?["code"] == "invalid_params")
    }

    @Test func staleHostedSessionsRequireRunningObservationAndKnownHostSnapshot() async throws {
        let terminal = board.create(type: .terminal, props: .object(["host": "scratch-host"]))
        router.terminalSessions = { [boardID = board.id] in TerminalSessions(running: [terminal.id: TerminalSession(board: boardID, pid: nil)]) }
        router.hostedSessions = { _ in [:] }
        let unknown = try await call("board.stale", ["board": .string(board.id)])
        #expect(unknown["result"]?["objects"] == .array([]))
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions()] }
        let unstarted = try await call("board.stale", ["board": .string(board.id)])
        #expect(unstarted["result"]?["objects"] == .array([]))
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions(running: [terminal.id: TerminalSession(board: nil, pid: nil)])] }
        let running = try await call("board.stale", ["board": .string(board.id)])
        #expect(running["result"]?["objects"] == .array([]))
        router.hostedSessions = { _ in [:] }
        let unavailable = try await call("board.stale", ["board": .string(board.id)])
        #expect(unavailable["result"]?["objects"] == .array([]))
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions()] }
        let ended = try await call("board.stale", ["board": .string(board.id)])
        #expect(ended["result"]?["objects"]?.array?.map { $0["id"] } == [.string(terminal.id)])
        #expect(ended["result"]?["objects"]?.array?.first?["reasons"] == .array(["exited"]))
    }

    @Test(arguments: [false, true])
    func staleKeepsListedUnreachableSessionsUntilAuthoritativeAbsence(hosted: Bool) async throws {
        let props: JSONValue = hosted ? .object(["host": "scratch-host"]) : .object([:])
        let observed = board.create(type: .terminal, props: props)
        let unstarted = board.create(type: .terminal, props: props)
        let running = TerminalSessions(running: [observed.id: TerminalSession(board: board.id, pid: nil)])
        router.terminalSessions = { hosted ? nil : running }
        router.hostedSessions = { _ in hosted ? ["scratch-host": running] : [:] }
        _ = try await call("board.stale", ["board": .string(board.id)])
        let unreachable: TerminalSessions
        if hosted {
            let wire = """
            {"sessions":[{"session":"canvas-\(observed.id)","tile":"\(observed.id)","labels":{},"unreachable":true},
                         {"session":"canvas-\(unstarted.id)","tile":"\(unstarted.id)","labels":{},"unreachable":true}]}
            """
            let response = try JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8))
            unreachable = TerminalSessions.hosted(try #require(response["sessions"]?.array), home: dir.path)
        } else {
            let output = [observed.id, unstarted.id].map {
                "name=canvas-\($0)\terr=Timeout\tstatus=unreachable"
            }.joined(separator: "\n") + "\n"
            unreachable = TerminalSessions.zmx(output, home: dir.path, legacy: [], foregroundPID: { _ in nil })
        }
        router.terminalSessions = { hosted ? nil : unreachable }
        router.hostedSessions = { _ in hosted ? ["scratch-host": unreachable] : [:] }
        let listed = try await call("board.stale", ["board": .string(board.id)])
        #expect(listed["result"]?["objects"] == .array([]))
        router.terminalSessions = { TerminalSessions() }
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions()] }
        let absent = try await call("board.stale", ["board": .string(board.id)])
        #expect(absent["result"]?["objects"]?.array?.map { $0["id"] } == [.string(observed.id)])
        #expect(absent["result"]?["objects"]?.array?.first?["reasons"] == .array(["exited"]))
    }

    @Test func staleFirstCallReportsSessionsPreviouslyObservedByApp() async throws {
        let local = board.create(type: .terminal, props: .object([:]))
        let hosted = board.create(type: .terminal, props: .object(["host": "scratch-host"]))
        let failed = board.create(type: .terminal, props: .object(["host": "scratch-host"]))
        board.observeRunningTerminalSession(try #require(board.terminalSessionIdentity(local.id)))
        board.observeRunningTerminalSession(try #require(board.terminalSessionIdentity(hosted.id)))
        _ = board.terminalSessionIdentity(failed.id)
        router.terminalSessions = { TerminalSessions() }
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions()] }
        let reply = try await call("board.stale", ["board": .string(board.id)])
        let entries = try #require(reply["result"]?["objects"]?.array)
        #expect(entries.compactMap { $0["id"]?.string } == [local.id, hosted.id].sorted())
        #expect(entries.allSatisfy { $0["reasons"] == .array(["exited"]) })
    }

    @Test func staleUsesRunningSessionsObservedByAgentList() async throws {
        let local = board.create(type: .terminal, props: .object([:]))
        let hosted = board.create(type: .terminal, props: .object(["host": "scratch-host"]))
        router.terminalSessions = { TerminalSessions(running: [local.id: TerminalSession(board: self.board.id, pid: nil)]) }
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions(running: [hosted.id: TerminalSession(board: nil, pid: nil)])] }
        let agents = try await call("agent.list", [:])
        #expect(agents["result"]?["agents"]?.array?.filter { $0["live"] == .bool(true) }.count == 2)
        router.terminalSessions = { TerminalSessions() }
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions()] }
        let reply = try await call("board.stale", ["board": .string(board.id)])
        #expect(reply["result"]?["objects"]?.array?.compactMap { $0["id"]?.string } == [local.id, hosted.id].sorted())
    }

    @Test func staleDoesNotUseRunningObservationNewerThanSessionQuery() async throws {
        let terminal = board.create(type: .terminal, props: .object([:]))
        let identity = try #require(board.terminalSessionIdentity(terminal.id))
        router.terminalSessions = {
            self.board.observeRunningTerminalSession(identity)
            return TerminalSessions()
        }
        let pending = try await call("board.stale", ["board": .string(board.id)])
        #expect(pending["result"]?["objects"] == .array([]))
        router.terminalSessions = { TerminalSessions() }
        let next = try await call("board.stale", ["board": .string(board.id)])
        #expect(next["result"]?["objects"]?.array?.map { $0["id"] } == [.string(terminal.id)])
    }

    @Test func batchResolvesEqualDurationsAgainstOneRequestClockIncludingUpserts() async throws {
        let updated = board.create(type: .note, props: .object(["markdown": "update"]))
        let upserted = board.create(type: .note, props: .object(["markdown": "upsert", "key": "existing"]))
        let start = Date()
        let reply = try await call("object.batch", ["board": .string(board.id), "ops": .array([
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "created", "key": "created"]), "expiresIn": "1h"])]),
            .object(["method": "object.update", "params": .object(["id": .string(updated.id), "expiresIn": "1h"])]),
            .object(["method": "object.upsert", "params": .object(["key": "existing", "type": "note", "props": .object([:]), "expiresIn": "1h"])]),
            .object(["method": "object.upsert", "params": .object(["key": "new", "type": "note", "props": .object(["markdown": "new"]), "expiresIn": "1h"])]),
            .object(["method": "object.upsert", "params": .object(["key": "created", "type": "note", "props": .object([:]), "expiresIn": "1h"])])
        ])])
        let results = try #require(reply["result"]?["results"]?.array, "\(reply)")
        try #require(results.count == 5)
        #expect(results[2]["created"] == .bool(false))
        #expect(results[2]["object"]?["id"] == .string(upserted.id))
        #expect(results[3]["created"] == .bool(true))
        #expect(results[4]["created"] == .bool(false))
        let ids = results.compactMap { $0["object"]?["id"]?.string }
        let deadline = try #require(board.objects[updated.id]?.expires?.date)
        #expect(deadline >= start.addingTimeInterval(3600))
        #expect(deadline <= Date().addingTimeInterval(3600))
        #expect(ids.count == 5)
        #expect(ids.allSatisfy { board.objects[$0]?.expires?.date == deadline })
        #expect(Set(results.compactMap { $0["object"]?["expires"]?.string }).count == 1)
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
        _ = try await undo(1)
        #expect(try board.object(object.id).expires == nil)
        _ = try await undo(1, redo: true)
        #expect(try board.object(object.id).expires == expiry)
        _ = try await call("object.update", ["id": .string(object.id), "expiresIn": "2h", "viewer": .string(viewer), "step": .number(2)])
        let later = ObjectExpiry(Date().addingTimeInterval(10800))
        _ = try board.update(object.id, expires: .set(later))
        let crossed = try await undo(2)
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
        let restartedDuringRead = board.create(type: .terminal, props: .object(["name": "restart while reading"]))
        for terminal in [changed, restarting, relaunched, ended, restartedDuringRead] {
            board.observeRunningTerminalSession(try #require(board.terminalSessionIdentity(terminal.id)))
        }
        board.agentRestartBegan(restarting.id)
        try board.restartedAgent(tile: relaunched.id, command: ["true"], agent: .null)
        router.terminalSessions = {
            _ = try? self.board.update(changed.id, props: .object(["name": "running now"]))
            _ = self.board.create(type: .terminal, props: .object(["name": "new session"]))
            self.board.agentRestartBegan(restartedDuringRead.id)
            self.board.agentRestartEnded(restartedDuringRead.id)
            return TerminalSessions()
        }
        let reply = try await call("board.stale", ["board": .string(board.id)])
        #expect(reply["result"]?["objects"]?.array?.compactMap { $0["id"]?.string } == [ended.id])
        #expect(reply["result"]?["objects"]?.array?.first?["reasons"] == .array(["exited"]))
    }

    @Test func staleDeleteRestoreEraseAndRecreationDropSessionAuthority() async throws {
        router.terminalSessions = { TerminalSessions() }
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions()] }
        for props: JSONValue in [.object([:]), .object(["host": "scratch-host"])] {
            let terminal = board.create(type: .terminal, props: props)
            let identity = try #require(board.terminalSessionIdentity(terminal.id))
            board.observeRunningTerminalSession(identity)
            try board.delete(terminal.id)
            board.restore(terminal)
            #expect(!board.observeRunningTerminalSession(identity))
            let restored = try await call("board.stale", ["board": .string(board.id)])
            #expect(restored["result"]?["objects"] == .array([]))

            let restoredIdentity = try #require(board.terminalSessionIdentity(terminal.id))
            board.observeRunningTerminalSession(restoredIdentity)
            let ended = try await call("board.stale", ["board": .string(board.id)])
            #expect(ended["result"]?["objects"]?.array?.map { $0["id"] } == [.string(terminal.id)])
            board.removeHost(terminal.id)
            board.applyHost(terminal)
            #expect(!board.observeRunningTerminalSession(restoredIdentity))
            let erased = try await call("board.stale", ["board": .string(board.id)])
            #expect(erased["result"]?["objects"] == .array([]))

            let erasedIdentity = try #require(board.terminalSessionIdentity(terminal.id))
            board.observeRunningTerminalSession(erasedIdentity)
            var recreated = try board.object(terminal.id)
            recreated.createdAt = terminal.createdAt.addingTimeInterval(1)
            board.restore(recreated)
            #expect(!board.observeRunningTerminalSession(erasedIdentity))
            let replaced = try await call("board.stale", ["board": .string(board.id)])
            #expect(replaced["result"]?["objects"] == .array([]))
        }
    }

    @Test func staleHostChangesDropSessionAuthorityIncludingReturningToAnEarlierHost() async throws {
        let terminal = board.create(type: .terminal, props: .object([:]))
        router.terminalSessions = { TerminalSessions() }
        router.hostedSessions = { _ in ["scratch-a": TerminalSessions(), "scratch-b": TerminalSessions()] }
        for host: JSONValue in ["scratch-a", "scratch-b", .null, "scratch-a"] {
            let identity = try #require(board.terminalSessionIdentity(terminal.id))
            board.observeRunningTerminalSession(identity)
            var replacement = try board.object(terminal.id)
            replacement.props = replacement.props.merging(.object(["host": host]))
            board.restore(replacement)
            #expect(!board.observeRunningTerminalSession(identity))
            let reply = try await call("board.stale", ["board": .string(board.id)])
            #expect(reply["result"]?["objects"] == .array([]))
        }
    }

    @Test func staleRestartRequiresFreshSessionObservation() async throws {
        router.terminalSessions = { TerminalSessions() }
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions()] }
        for props: JSONValue in [.object([:]), .object(["host": "scratch-host"])] {
            let terminal = board.create(type: .terminal, props: props)
            let identity = try #require(board.terminalSessionIdentity(terminal.id))
            board.observeRunningTerminalSession(identity)
            board.agentRestartBegan(terminal.id)
            #expect(!board.observeRunningTerminalSession(identity))
            let restarting = try await call("board.stale", ["board": .string(board.id)])
            #expect(restarting["result"]?["objects"] == .array([]))
            try board.restartedAgent(tile: terminal.id, command: ["true"], agent: .null)
            #expect(!board.observeRunningTerminalSession(identity))
            let unstarted = try await call("board.stale", ["board": .string(board.id)])
            #expect(unstarted["result"]?["objects"] == .array([]))
            let next = try #require(board.terminalSessionIdentity(terminal.id, continuing: identity))
            board.observeRunningTerminalSession(next)
            let ended = try await call("board.stale", ["board": .string(board.id)])
            #expect(ended["result"]?["objects"]?.array?.map { $0["id"] } == [.string(terminal.id)])
            try board.delete(terminal.id)
        }
    }

    @Test func staleCloseReopenDropsSessionAuthorityAndRejectsOldAppObservations() async throws {
        let local = board.create(type: .terminal, props: .object([:]))
        let hosted = board.create(type: .terminal, props: .object(["host": "scratch-host"]))
        let localIdentity = try #require(board.terminalSessionIdentity(local.id))
        let hostedIdentity = try #require(board.terminalSessionIdentity(hosted.id))
        board.observeRunningTerminalSession(localIdentity)
        board.observeRunningTerminalSession(hostedIdentity)
        try registry.close(board.id)
        #expect(!board.observeRunningTerminalSession(localIdentity))
        #expect(!board.observeRunningTerminalSession(hostedIdentity))
        let reopened = await registry.open(root: board.root)
        #expect(reopened.terminalSessionIdentity(local.id, continuing: localIdentity) == nil)
        #expect(reopened.terminalSessionIdentity(hosted.id, continuing: hostedIdentity) == nil)
        router.terminalSessions = { TerminalSessions() }
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions()] }
        let unknown = try await call("board.stale", ["board": .string(board.id)])
        #expect(unknown["result"]?["objects"] == .array([]))
        reopened.observeRunningTerminalSession(try #require(reopened.terminalSessionIdentity(local.id)))
        reopened.observeRunningTerminalSession(try #require(reopened.terminalSessionIdentity(hosted.id)))
        let ended = try await call("board.stale", ["board": .string(board.id)])
        #expect(ended["result"]?["objects"]?.array?.compactMap { $0["id"]?.string } == [local.id, hosted.id].sorted())
    }

    @Test func staleSessionSnapshotsDoNotGrantAuthorityAcrossIdentityChanges() async throws {
        let changed = board.create(type: .terminal, props: .object([:]))
        let recreated = board.create(type: .terminal, props: .object([:]))
        let restarted = board.create(type: .terminal, props: .object([:]))
        let hosted = board.create(type: .terminal, props: .object(["host": "scratch-host"]))
        router.terminalSessions = {
            _ = try? self.board.update(changed.id, props: .object(["name": "changed"]))
            try? self.board.delete(recreated.id)
            self.board.restore(recreated)
            self.board.agentRestartBegan(restarted.id)
            self.board.agentRestartEnded(restarted.id)
            let new = self.board.create(type: .terminal, props: .object([:]))
            return TerminalSessions(running: Dictionary(uniqueKeysWithValues: [changed.id, recreated.id, restarted.id, new.id].map {
                ($0, TerminalSession(board: self.board.id, pid: nil))
            }))
        }
        router.hostedSessions = { _ in
            var moved = hosted
            moved.props = moved.props.merging(.object(["host": "scratch-other"]))
            self.board.restore(moved)
            return ["scratch-host": TerminalSessions(running: [hosted.id: TerminalSession(board: nil, pid: nil)])]
        }
        let pending = try await call("board.stale", ["board": .string(board.id)])
        #expect(pending["result"]?["objects"] == .array([]))
        router.terminalSessions = { TerminalSessions() }
        router.hostedSessions = { _ in ["scratch-host": TerminalSessions(), "scratch-other": TerminalSessions()] }
        let next = try await call("board.stale", ["board": .string(board.id)])
        #expect(next["result"]?["objects"] == .array([]))
    }

    @Test func remoteViewerRejectsLocalSessionAuthority() throws {
        let terminal = board.create(type: .terminal, props: .object([:]))
        let identity = try #require(board.terminalSessionIdentity(terminal.id))
        let view = Board(remote: board.id, root: board.root, host: nil)
        view.applyHost(terminal)
        #expect(view.terminalSessionIdentity(terminal.id) == nil)
        #expect(!view.observeRunningTerminalSession(identity))
        #expect(view.staleObjects()["objects"] == .array([]))
        #expect(view.objects[terminal.id] == terminal)
    }

    @Test func staleListingRejectsAReplacedBoardAfterSessionRead() async throws {
        _ = board.create(type: .terminal, props: .object(["name": "original"]))
        router.terminalSessions = {
            try? self.registry.close(self.board.id)
            _ = await self.registry.open(root: self.board.root)
            return TerminalSessions()
        }
        let reply = try await call("board.stale", ["board": .string(board.id)])
        #expect(reply["error"]?["code"] == "not_found")
        #expect(registry.boards[board.id] !== board)
    }

    @Test func expiryTimerRearmsAfterClearingAndAfterFiring() async throws {
        let deadline = ObjectExpiry(Date().addingTimeInterval(0.3))
        let kept = board.create(type: .note, props: .object(["markdown": "kept"]), expires: deadline)
        _ = try board.update(kept.id, expires: .set(nil))
        let first = board.create(type: .note, props: .object(["markdown": "first"]), expires: deadline)
        for index in 0..<50 {
            _ = try board.update(kept.id, props: .object(["title": .string("status \(index)")]))
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(board.objects[kept.id]?.expires == nil)
        #expect(board.objects[kept.id] != nil)
        #expect(board.objects[first.id] == nil)
        let second = board.create(type: .note, props: .object(["markdown": "second"]), expires: deadline)
        try await Task.sleep(for: .milliseconds(100))
        #expect(board.objects[second.id] == nil)
    }
}
