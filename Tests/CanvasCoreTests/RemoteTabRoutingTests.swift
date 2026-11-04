import Foundation
import Testing
@testable import CanvasCore

@MainActor
private final class RemoteTabTestHost: BoardHost {
    static let shared = RemoteTabTestHost()
    func send(_ write: RemoteWrite) { Issue.record("API routing must not mutate a mirror") }
    var historyUnavailable: String? { nil }
}

@MainActor
private func remoteTabFixture(board: Board? = nil, id: String = "host|brd_remote|socket", open: Bool = true,
                              request: @escaping (String, JSONValue) async throws -> JSONValue = { _, _ in
                                  throw ApiRouter.Failure("unavailable", "host is offline")
                              }) -> RemoteBoardTab {
    let board = board ?? Board(remote: "brd_remote", root: URL(fileURLWithPath: "/host/repo"), host: RemoteTabTestHost.shared)
    return RemoteBoardTab(id: id,
                          info: OpenedRemoteBoard(host: "deckbox", sshTarget: "agents@deckbox", board: board.id,
                                                  root: board.root.path, title: "repo @ deckbox", window: 47, alreadyOpen: true),
                          board: board, isOpen: open, request: request)
}

extension ApiRouterTests {
    @Test func remoteTabListHasExactFieldsAndClosingOmitsRetainedAttachments() async throws {
        let client = try connect()
        registry.store.save(board)
        let before = try #require(try await call(client, "board.list", [:])["result"]?["boards"]?.array)
        let remote = remoteTabFixture()
        var open = true
        router.remoteTabs = { [remoteTabFixture(board: remote.board, open: open)] }
        router.closeBoard = { id, _ in
            #expect(id == remote.board.id)
            open = false
            return BoardCloseResult(board: remote.board)
        }
        let listed = try #require(try await call(client, "board.list", [:])["result"]?["boards"]?.array)
        #expect(listed == before + [.object([
            "remote": .bool(true), "host": "deckbox", "sshTarget": "agents@deckbox", "board": "brd_remote",
            "root": "/host/repo", "title": "repo @ deckbox", "window": 47, "open": .bool(true),
        ])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(Array(listed.dropLast())) == encoder.encode(before))
        #expect(registry.boards[remote.board.id] == nil)
        #expect(try await call(client, "board.close", ["board": "brd_remote"])["ok"] == .bool(true))
        #expect(try await call(client, "board.list", [:])["result"]?["boards"] == .array(before))
        #expect(try await call(client, "view.get", ["board": "brd_remote"])["error"]?["code"] == "not_found")
    }

    @Test func remoteViewUsesThisTabAndInlineRenderWithoutHostRequests() async throws {
        let remote = remoteTabFixture()
        router.remoteTabs = { [remote] }
        let state = ViewState(viewport: Viewport(rect: Frame(x: 10, y: 20, w: 800, h: 600), zoom: 2),
                              promptTarget: "obj_term", focused: "obj_note", selection: ["obj_note"],
                              enteredGroup: "obj_group", visible: true, appearance: "dark")
        router.viewState = { candidate in candidate === remote.board ? state : nil }
        router.renderView = { candidate, request, format in
            #expect(candidate === remote.board)
            #expect(request.target == .rect(Frame(x: 0, y: 0, w: 20, h: 15)))
            return RenderOutput(image: Data([1, 2, 3]), format: format, width: 40, height: 30,
                                canvasRect: Frame(x: 0, y: 0, w: 20, h: 15), scale: 2, objects: [])
        }
        let client = try connect()
        #expect(try await call(client, "view.get", ["board": "brd_remote"])["result"] == .object([
            "board": "brd_remote", "viewport": state.viewport.json, "selection": ["obj_note"], "visible": .bool(true),
            "appearance": "dark", "promptTarget": "obj_term", "focused": "obj_note", "enteredGroup": "obj_group",
        ]))
        let rect: JSONValue = .object(["x": 0, "y": 0, "w": 20, "h": 15])
        let result = try await call(client, "view.render", ["board": "brd_remote", "target": rect, "inline": .bool(true)])["result"]
        #expect(result?["data"] == "AQID")
        #expect(result?["width"] == 40)
        #expect(result?["height"] == 30)
        #expect(result?["path"] == nil)
        #expect(try await call(client, "view.render", ["board": "brd_remote", "target": rect])["error"]?["code"] == "invalid_params")
        #expect(try await call(client, "view.render", ["board": "brd_remote", "target": rect, "inline": .bool(true), "out": "/tmp/remote.png"])["error"]?["code"] == "invalid_params")
        #expect(try await call(client, "view.snapshot", ["board": "brd_remote"])["error"]?["code"] == "unsupported")
        router.viewState = { _ in nil }
        #expect(try await call(client, "view.get", ["board": "brd_remote"])["error"]?["code"] == "unavailable")
    }


    @Test func remoteCreatesAndReadsUseTheAuthoritativeHost() async throws {
        let host = try await ApiRouterTests()
        let hostClient = try host.connect()
        let mirror = Board(remote: host.board.id, root: host.board.root, host: RemoteTabTestHost.shared)
        let remote = remoteTabFixture(board: mirror) { method, params in
            let response = try await host.call(hostClient, method, params.object ?? [:])
            if let error = response["error"], let code = error["code"]?.string {
                throw EaslConnection.Failure(code, error["message"]?.string ?? code)
            }
            return response["result"] ?? .null
        }
        router.remoteTabs = { [remote] }
        let client = try connect()
        let created = try await call(client, "object.create", ["board": .string(mirror.id), "type": "note", "props": .object(["key": "host-note", "markdown": "authoritative"])])
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        #expect(host.board.objects[id]?.props["markdown"] == "authoritative")
        #expect(mirror.objects.isEmpty)
        let found = try await call(client, "object.find", ["board": .string(mirror.id), "key": "host-note"])
        #expect(found["result"]?["object"]?["id"] == .string(id))
        let read = try await call(client, "board.get", ["board": .string(mirror.id)])
        #expect(read["result"]?["objects"]?.array?.contains { $0["id"] == .string(id) } == true)
        #expect(read["result"]?["revision"] == .number(Double(host.board.revision)))
        #expect(mirror.objects.isEmpty)
    }

    @Test func remoteStaleUsesHostContentAgeAfterLayoutAndMarkdownEdits() async throws {
        let host = try await ApiRouterTests()
        let creator = host.board.create(type: .terminal, props: .object([:]))
        let otherCreator = host.board.create(type: .terminal, props: .object([:]))
        let note = host.board.create(type: .note, props: .object(["markdown": "old"]), caller: creator.id)
        let other = host.board.create(type: .note, props: .object(["markdown": "other"]), caller: otherCreator.id)
        let group = host.board.create(type: .group, props: .object(["members": .array([.string(note.id)]), "title": "old group"]), caller: creator.id)
        var snapshot = host.board.snapshot
        for index in snapshot.objects.indices {
            snapshot.objects[index].updatedAt = Date().addingTimeInterval(-8 * 86400)
            snapshot.objects[index].contentUpdatedAt = nil
            snapshot.objects[index].contentRev = nil
        }
        let oldGroup = try #require(snapshot.objects.first { $0.id == group.id })
        try host.registry.close(host.board.id)
        try host.registry.store.saveChecked(Board(snapshot: snapshot))
        let authoritative = try await host.registry.open(root: host.board.root)
        let socket = host.dir.appendingPathComponent("s").path
        let mirror = BoardMirror(hostName: "host", board: authoritative.id, connection: .unixSocket(socket), diagrams: .unixSocket(socket))
        defer { mirror.close() }
        let view = try await mirror.load()
        router.remoteTabs = {
            [remoteTabFixture(board: view) { method, params in
                try await mirror.connection.request(method, params)
            }]
        }
        let client = try connect()
        func stale(createdBy: ObjectID? = nil) async throws -> Set<ObjectID> {
            var params: [String: JSONValue] = ["board": .string(view.id), "olderThan": "7d"]
            if let createdBy { params["createdBy"] = .string(createdBy) }
            let response = try await call(client, "board.stale", params)
            #expect(response["ok"] == .bool(true))
            let entries = try #require(response["result"]?["objects"]?.array)
            return Set(entries.compactMap { entry in
                entry["reasons"]?.array?.contains("untouched") == true ? entry["id"]?.string : nil
            })
        }
        for frame in [Frame(x: 600, y: 400, w: 280, h: 200), Frame(x: 600, y: 400, w: 500, h: 350)] {
            let response = try await call(client, "object.batch", ["board": .string(view.id), "ops": .array([
                .object(["method": "object.update", "params": .object(["id": .string(note.id), "frame": JSONValue(frame)])]),
            ])])
            #expect(response["ok"] == .bool(true), "\(response)")
            let revision = try #require(response["result"]?["results"]?.array?.first?["object"]?["rev"]?.int)
            for _ in 0..<500 where view.objects[note.id]?.rev != revision {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(view.objects[note.id]?.rev == revision)
            #expect(view.objects[note.id]?.frame == frame)
            #expect(try await stale(createdBy: creator.id) == [note.id, group.id])
            #expect(try await stale(createdBy: otherCreator.id) == [other.id])
        }
        #expect(try authoritative.object(group.id).updatedAt > oldGroup.updatedAt)
        try view.delete(note.id)
        for _ in 0..<500 where authoritative.objects[note.id] != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(authoritative.objects[note.id] == nil)
        _ = await mirror.undo(redo: false).value
        #expect(authoritative.objects[note.id]?.props["markdown"] == "old")
        #expect(try await stale(createdBy: creator.id) == [note.id, group.id])
        let edited = try await call(client, "object.batch", ["board": .string(view.id), "ops": .array([
            .object(["method": "object.update", "params": .object(["id": .string(note.id), "props": .object(["markdown": "fresh"])])]),
        ])])
        #expect(edited["ok"] == .bool(true))
        #expect(try await stale(createdBy: creator.id) == [group.id])
        #expect(try await stale(createdBy: otherCreator.id) == [other.id])
    }

    @Test func remoteLookupReportsAmbiguityButLocalAndMergedIdsWin() async throws {
        let first = remoteTabFixture()
        let second = remoteTabFixture(id: "other|brd_remote|socket")
        router.remoteTabs = { [first, second] }
        let client = try connect()
        for method in ["view.get", "board.get", "object.find"] {
            #expect(try await call(client, method, ["board": "brd_remote"])["error"]?["code"] == "ambiguous")
        }
        let message = try #require(try await call(client, "view.get", ["board": "brd_remote"])["error"]?["message"]?.string)
        #expect(message.contains(first.id) && message.contains(second.id))
        #expect(try await call(client, "view.get", ["board": "brd_unknown"])["error"]?["code"] == "not_found")
        #expect(try await call(client, "board.list", [:])["result"]?["boards"]?.array?.filter { $0["remote"] == .bool(true) }.count == 2)
        board.repo = RepoRecord(commonDir: dir.appendingPathComponent("common.git").path, merged: ["brd_remote"])
        #expect(try await call(client, "board.get", ["board": "brd_remote"])["result"]?["board"] == .string(board.id))
        let collision = remoteTabFixture(board: Board(remote: board.id, root: URL(fileURLWithPath: "/other/root"), host: RemoteTabTestHost.shared))
        router.remoteTabs = { [collision, collision] }
        #expect(try await call(client, "board.get", ["board": .string(board.id)])["result"]?["root"] == .string(board.root.path))
        #expect(try await call(client, "board.get", [:])["result"]?["board"] == .string(board.id))
    }

    @Test func remoteHostErrorsAndConnectionScopedRestrictionsAreExplicit() async throws {
        let remote = remoteTabFixture { _, _ in
            throw EaslConnection.Failure("conflict", "host refused the revision", data: .object(["currentRev": 7]))
        }
        router.remoteTabs = { [remote] }
        let client = try connect()
        #expect(try await call(client, "board.get", ["board": "brd_remote"])["error"] == .object([
            "code": "conflict", "message": "host refused the revision", "data": .object(["currentRev": 7]),
        ]))
        #expect(try await call(client, "events.subscribe", ["board": "brd_remote"])["error"]?["code"] == "unsupported")
        #expect(try await call(client, "viewer.activity", ["board": "brd_remote", "input": .bool(true)])["error"]?["code"] == "unsupported")
        #expect(try await call(client, "view.open_url", ["board": "brd_remote", "url": "https://example.com"])["error"]?["code"] == "unsupported")
        let hidden = remoteTabFixture(open: false)
        router.remoteTabs = { [hidden] }
        #expect(try await call(client, "board.get", ["board": "brd_remote"])["error"]?["code"] == "not_found")
        #expect(try router.remoteTab(id: "brd_remote", includingClosed: true)?.id == hidden.id)
        router.remoteTabs = { [remoteTabFixture()] }
        #expect(try await call(client, "board.get", ["board": "brd_remote"])["error"]?["code"] == "unavailable")
    }

    @Test func remotePickerDoesNotOfferAnotherAppsRemoteTabsAsItsBoards() {
        let result = RemoteBoard.list(boards: .object(["boards": .array([
            .object(["board": "brd_owned", "root": "/host/owned", "open": .bool(true), "archived": .bool(false), "objects": 0]),
            .object(["board": "brd_elsewhere", "root": "/other/elsewhere", "remote": .bool(true), "open": .bool(true),
                     "host": "other", "sshTarget": "other", "title": "elsewhere @ other", "window": 22]),
        ])]), agents: .object(["agents": .array([])]))
        #expect(result.map(\.id) == ["brd_owned"])
    }

    @Test func remoteTrayChangesOnlyThisViewersPrivateMentions() async throws {
        let host = try await ApiRouterTests()
        let hostClient = try host.connect()
        let notes = ["one", "two", "three"].map { host.board.create(type: .note, props: .object(["markdown": .string($0)])) }
        let hostMention = try host.board.stage(.object(notes[0].id))
        let mirror = Board(remote: host.board.id, root: host.board.root, host: RemoteTabTestHost.shared)
        notes.forEach { mirror.applyHost($0) }
        let remote = remoteTabFixture(board: mirror) { method, params in
            let response = try await host.call(hostClient, method, params.object ?? [:])
            if let error = response["error"], let code = error["code"]?.string {
                throw EaslConnection.Failure(code, error["message"]?.string ?? code)
            }
            return response["result"] ?? .null
        }
        router.remoteTabs = { [remote] }
        let client = try connect()
        var mentions: [String] = []
        for note in notes {
            let staged = try await call(client, "tray.stage", [
                "board": .string(mirror.id), "target": .object(["kind": "object", "object": .string(note.id)]),
            ])
            mentions.append(try #require(staged["result"]?["mention"]?["id"]?.string))
        }
        let listed = try await call(client, "tray.list", ["board": .string(mirror.id)])
        #expect(listed["result"]?["mentions"]?.array?.compactMap { $0["id"]?.string } == mentions)
        #expect(try await call(client, "tray.unstage", ["id": .string(mentions[0])])["ok"] == .bool(true))
        let peeked = try await call(client, "tray.drain", ["board": .string(mirror.id), "peek": .bool(true)])
        #expect(peeked["result"]?["mentions"]?.array?.compactMap { $0["id"]?.string } == Array(mentions.dropFirst()))
        #expect(mirror.tray.map(\.id) == Array(mentions.dropFirst()))
        #expect(try await call(client, "tray.commit", ["board": .string(mirror.id), "ids": [.string(mentions[1])]])["ok"] == .bool(true))
        let drained = try await call(client, "tray.drain", ["board": .string(mirror.id)])
        #expect(drained["result"]?["mentions"]?.array?.compactMap { $0["id"]?.string } == [mentions[2]])
        #expect(mirror.tray.isEmpty)
        #expect(host.board.tray == [hostMention])
    }

    @Test func closedLocalAndMigratedIdsNeverRedirectToRemoteHosts() async throws {
        let legacyRoot = dir.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacy = Board(id: BoardStore.pathID(legacyRoot), root: legacyRoot)
        registry.store.save(legacy)
        let backups = registry.store.directory.appendingPathComponent(RepoBoardMigration.backupFolder)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: registry.store.url(for: legacy.id),
                                         to: backups.appendingPathComponent("\(legacy.id).json"))
        board.repo = RepoRecord(commonDir: dir.appendingPathComponent("common.git").path, merged: [legacy.id])
        let host = try await ApiRouterTests()
        let hostClient = try host.connect()
        let hostedLocal = try await host.registry.open(root: board.root)
        let hostedLegacy = try await host.registry.open(root: legacyRoot)
        let hosted = [hostedLocal, hostedLegacy]
        let tabs = hosted.map { candidate in
            remoteTabFixture(board: Board(remote: candidate.id, root: candidate.root, host: RemoteTabTestHost.shared),
                             id: "host|\(candidate.id)|socket") { method, params in
                let response = try await host.call(hostClient, method, params.object ?? [:])
                if let error = response["error"], let code = error["code"]?.string {
                    throw EaslConnection.Failure(code, error["message"]?.string ?? code)
                }
                return response["result"] ?? .null
            }
        }
        router.remoteTabs = { tabs }
        let client = try connect()
        #expect(try await call(client, "board.close", ["board": .string(board.id)])["ok"] == .bool(true))
        for id in [board.id, legacy.id] {
            let result = try await call(client, "object.create", [
                "board": .string(id), "type": "note", "props": .object(["markdown": "must stay local"]),
            ])
            #expect(result["error"]?["code"] == "not_found")
            #expect(try await call(client, "board.export", ["board": .string(id)])["error"]?["code"] == "not_found")
        }
        #expect(hosted.allSatisfy { $0.objects.isEmpty })
    }

    @Test func localSubscriptionCanConnectWhileItsBoardIsClosing() async throws {
        let watcher = try connect()
        router.closeBoard = { [unowned self] _, _ in
            #expect(try await call(watcher, "events.subscribe", ["board": .string(board.id)])["ok"] == .bool(true))
            throw ApiRouter.Failure("unavailable", "close held for subscription")
        }
        let client = try connect()
        #expect(try await call(client, "board.close", ["board": .string(board.id)])["error"]?["code"] == "unavailable")
        let note = board.create(type: .note, props: .object(["markdown": "subscription stays connected"]))
        let event = try await watcher.next()
        #expect(event["event"] == "object.created")
        #expect(event["data"]?["id"] == .string(note.id))
    }

    @Test func remoteRequestsConflictWhileTheirTabIsClosing() async throws {
        let remote = remoteTabFixture()
        router.remoteTabs = { [remote] }
        let observer = try connect()
        router.closeBoard = { [unowned self] _, _ in
            #expect(try await call(observer, "view.get", ["board": "brd_remote"])["error"]?["code"] == "conflict")
            #expect(try await call(observer, "board.get", ["board": "brd_remote"])["error"]?["code"] == "conflict")
            throw ApiRouter.Failure("unavailable", "close held for requests")
        }
        let client = try connect()
        #expect(try await call(client, "board.close", ["board": "brd_remote"])["error"]?["code"] == "unavailable")
    }
}
