import Foundation
import Testing
@testable import CanvasCore

extension ApiRouterTests {
    @Test func closeAnnouncesAvailabilityAndReopenOnTheSameSubscription() async throws {
        board.repo = RepoRecord(commonDir: dir.appendingPathComponent("common.git").path, merged: ["brd_old"])
        let subscriber = try connect(), client = try connect()
        #expect(try await call(subscriber, "events.subscribe", ["board": "brd_old", "events": ["board.closed", "board.opened"]])["ok"] == .bool(true))
        #expect(try await call(client, "board.close", ["board": "brd_old"])["ok"] == .bool(true))
        #expect(try await subscriber.next() == .object(["event": "board.closed", "board": .string(board.id), "data": .object([:])]))
        #expect(try await call(client, "board.get", ["board": .string(board.id)])["error"]?["code"] == "not_found")
        #expect(try await call(client, "board.open", ["root": .string(board.root.path)])["result"]?["board"] == .string(board.id))
        #expect(try await subscriber.next() == .object(["event": "board.opened", "board": .string(board.id), "data": .object([:])]))
        _ = try await call(client, "board.open", ["root": .string(board.root.path)])
        #expect(try await call(subscriber, "system.ping", [:])["ok"] == .bool(true))
    }

    @Test func closeKeepsTerminalsAndReopensTheirLatestObjects() async throws {
        let named = board.create(type: .terminal, props: .object(["name": "worker", "title": "ignored"]))
        let titled = board.create(type: .terminal, props: .object(["name": "", "title": "review"]))
        let unnamed = board.create(type: .terminal, props: .object([:]))
        let note = board.create(type: .note, props: .object(["markdown": "latest unsaved text"]))
        var killed: [ObjectID] = []
        registry.onTerminalsEnded = { _, terminals in killed += terminals.map(\.id) }
        let client = try connect()
        let result = try await call(client, "board.close", ["board": .string(board.id)])["result"]
        let names = [(named.id, "worker"), (titled.id, "review"), (unnamed.id, "Terminal")].sorted { $0.0 < $1.0 }
        #expect(result == .object([
            "board": .string(board.id), "root": .string(board.root.path),
            "kept": .array(names.map { .object(["id": .string($0.0), "name": .string($0.1)]) }), "ended": .array([]),
        ]))
        #expect(killed == [])
        #expect(try await call(client, "board.get", ["board": .string(board.id)])["error"]?["code"] == "not_found")
        let listed = try await call(client, "board.list", [:])["result"]?["boards"]?.array
        #expect(listed?.first { $0["board"] == .string(board.id) }?["open"] == .bool(false))
        #expect(try await call(client, "board.open", ["root": .string(board.root.path)])["result"]?["board"] == .string(board.id))
        let reopened = try #require(registry.boards[board.id])
        #expect(reopened !== board)
        #expect(Set(reopened.objects.keys) == [named.id, titled.id, unnamed.id, note.id])
        #expect(reopened.objects[note.id]?.props["markdown"] == "latest unsaved text")
        #expect(reopened.objects[named.id]?.props["name"] == "worker")
        #expect(killed == [])
    }

    @Test func closeUsesTheCanonicalDefaultAndExplicitFalseKeepsSessions() async throws {
        board.repo = RepoRecord(commonDir: dir.appendingPathComponent("common.git").path, merged: ["brd_old"])
        let terminal = terminal()
        let client = try connect()
        let result = try await call(client, "board.close", ["board": "brd_old", "endSessions": .bool(false)])["result"]
        #expect(result?["board"] == .string(board.id))
        #expect(result?["kept"] == .array([.object(["id": .string(terminal), "name": "Terminal"])]))
        #expect(registry.boards[board.id] == nil)
        #expect(registry.frontmost == nil)
        _ = try await call(client, "board.open", ["root": .string(board.root.path)])
        #expect(try await call(client, "board.close", [:])["result"]?["board"] == .string(board.id))
        #expect(try await call(client, "system.ping", [:])["ok"] == .bool(true), "headless close of its last board never stops the server")
    }

    @Test func closeRefusesMalformedParamsAndCannotPretendToEndHeadlessSessions() async throws {
        let tile = terminal()
        let client = try connect()
        let invalid: [JSONValue] = [.null, .string("false"), .number(0), .array([]), .object([:])]
        for value in invalid {
            #expect(try await call(client, "board.close", ["endSessions": value])["error"]?["code"] == "invalid_params")
        }
        #expect(try await call(client, "board.close", ["caller": .string(tile)])["error"]?["code"] == "invalid_params")
        #expect(try await call(client, "board.close", ["endSessions": .bool(true)])["error"]?["code"] == "unsupported")
        #expect(try await call(client, "board.get", [:])["result"]?["objects"]?.array?.first { $0["id"] == .string(tile) }?["id"] == .string(tile))
        #expect(registry.boards[board.id] === board)
    }

    @Test func failedBoardSaveLeavesTheBoardOpenAndRetryClosesIt() async throws {
        let note = board.create(type: .note, props: .object(["markdown": "must survive"]))
        let blocked = registry.store.url(for: board.id)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let client = try connect(), subscriber = try connect()
        _ = try await call(subscriber, "events.subscribe", ["board": .string(board.id), "events": ["board.closed"]])
        #expect(try await call(client, "board.close", [:])["error"]?["code"] == "unavailable")
        #expect(registry.boards[board.id] === board)
        #expect(!board.isClosed)
        #expect(board.objects[note.id]?.props["markdown"] == "must survive")
        #expect(try await call(subscriber, "system.ping", [:])["ok"] == .bool(true))
        try FileManager.default.removeItem(at: blocked)
        #expect(try await call(client, "board.close", [:])["result"]?["board"] == .string(board.id))
        #expect(try await subscriber.next() == .object(["event": "board.closed", "board": .string(board.id), "data": .object([:])]))
        #expect(try await registry.open(root: board.root).objects[note.id]?.props["markdown"] == "must survive")
    }

    @Test func failedReopenListWriteLeavesTheBoardOpen() async throws {
        let note = board.create(type: .note, props: .object(["markdown": "saved before eviction"]))
        let blocked = dir.appendingPathComponent("open-boards.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        do {
            try registry.close(board.id) { try Data("[]".utf8).write(to: blocked, options: .atomic) }
            Issue.record("close accepted a failed reopen-list write")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "unavailable")
        }
        #expect(registry.boards[board.id] === board)
        #expect(!board.isClosed)
        #expect(board.objects[note.id]?.props["markdown"] == "saved before eviction")
        try FileManager.default.removeItem(at: blocked)
        try registry.close(board.id) { try Data("[]".utf8).write(to: blocked, options: .atomic) }
        #expect(try String(contentsOf: blocked, encoding: .utf8) == "[]")
        #expect(try await registry.open(root: board.root).objects[note.id]?.props["markdown"] == "saved before eviction")
    }

    @Test func closedBoardCannotOverwriteItsReopenedReplacement() async throws {
        let note = board.create(type: .note, props: .object(["markdown": "before close"]))
        let client = try connect()
        _ = try await call(client, "board.close", [:])
        _ = try await call(client, "board.open", ["root": .string(board.root.path)])
        let reopened = try #require(registry.boards[board.id])
        _ = try reopened.update(note.id, props: .object(["markdown": "new board owns this file"]))
        try registry.store.saveChecked(reopened)
        _ = try board.update(note.id, props: .object(["markdown": "stale board"]))
        registry.store.scheduleSave(board)
        registry.store.save(board)
        try await Task.sleep(for: .milliseconds(650))
        let data = try Data(contentsOf: registry.store.url(for: board.id))
        let snapshot = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(snapshot["objects"]?.array?.first { $0["id"] == .string(note.id) }?["props"]?["markdown"] == "new board owns this file")
        #expect(board.isClosed)
        #expect(!reopened.isClosed)
        #expect(try await call(client, "board.close", ["board": "brd_missing"])["error"]?["code"] == "not_found")
        #expect(try Data(contentsOf: registry.store.url(for: board.id)) == data)
    }

    @Test func closingAHostWindowKeepsAgentReportsAndReopensItsExistingBoard() async throws {
        let tile = terminal()
        let subscriber = try connect(), client = try connect()
        _ = try await call(subscriber, "events.subscribe", ["board": .string(board.id), "events": .array(["board.closed", "board.opened"])])
        registry.setWindowOpen(false, board: board.id)
        registry.setWindowOpen(false, board: board.id)
        #expect(try await subscriber.next() == .object(["event": "board.closed", "board": .string(board.id), "data": .object([:])]))
        #expect(try await call(client, "board.get", ["board": .string(board.id)])["result"]?["closed"] == .bool(true))
        #expect(try await call(client, "board.list", [:])["result"]?["boards"]?.array?.first { $0["board"] == .string(board.id) }?["open"] == .bool(false))
        #expect(try await call(client, "agent.report", ["tile": .string(tile), "kind": "omp", "state": "idle", "seq": 1])["ok"] == .bool(true))
        #expect(board.objects[tile]?.props["lifecycle"]?["state"] == "idle")
        #expect(try await registry.open(root: board.root) === board)
        #expect(try await subscriber.next() == .object(["event": "board.opened", "board": .string(board.id), "data": .object([:])]))
        #expect(try await call(client, "board.get", ["board": .string(board.id)])["result"]?["closed"] == nil)
        #expect(try await call(client, "board.list", [:])["result"]?["boards"]?.array?.first { $0["board"] == .string(board.id) }?["open"] == .bool(true))
        #expect(board.objects[tile]?.props["lifecycle"]?["state"] == "idle")
    }

    @Test func closeAnswersWaitsAndInboxButKeepsEventSubscriptionsConnected() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        let wait = try connect(), inbox = try connect(), subscriber = try connect(), client = try connect()
        wait.send(#"{"id":"wait","method":"agent.wait","params":{"target":"\#(tile)"}}"#)
        wait.send(#"{"id":"ready","method":"system.ping","params":{}}"#)
        #expect(try await wait.next()["id"] == "ready")
        inbox.send(#"{"id":"inbox","method":"agent.inbox","params":{"tile":"\#(tile)","waitMs":60000}}"#)
        inbox.send(#"{"id":"ready","method":"system.ping","params":{}}"#)
        #expect(try await inbox.next()["id"] == "ready")
        #expect(try await call(subscriber, "events.subscribe", ["board": .string(board.id)])["ok"] == .bool(true))
        #expect(try await call(client, "board.close", [:])["ok"] == .bool(true))
        #expect(try await wait.next()["error"]?["code"] == "not_found")
        #expect(try await inbox.next()["error"]?["code"] == "not_found")
        #expect(try await subscriber.next() == .object(["event": "board.closed", "board": .string(board.id), "data": .object([:])]))
        _ = try await call(client, "board.open", ["root": .string(board.root.path)])
        #expect(try await subscriber.next() == .object(["event": "board.opened", "board": .string(board.id), "data": .object([:])]))
        let created = try await call(client, "object.create", ["type": "note", "props": .object(["markdown": "after reopen"])])
        let event = try await subscriber.next()
        #expect(event["event"] == "object.created")
        #expect(event["board"] == .string(board.id))
        #expect(event["data"]?["id"] == created["result"]?["object"]?["id"])
        #expect(event["data"]?["props"]?["markdown"] == "after reopen")
    }

    @Test func rolledBackTerminalDeletionKeepsItsInboxWaitPending() async throws {
        let tile = terminal()
        let inbox = try connect(), client = try connect()
        inbox.send(#"{"id":"inbox","method":"agent.inbox","params":{"tile":"\#(tile)","waitMs":60000}}"#)
        inbox.send(#"{"id":"ready","method":"system.ping","params":{}}"#)
        #expect(try await inbox.next()["id"] == "ready")
        do {
            try board.atomically {
                try board.delete(tile)
                throw CancellationError()
            }
            Issue.record("the transaction did not roll back")
        } catch is CancellationError {}
        #expect(board.objects[tile]?.type == .terminal)
        inbox.send(#"{"id":"after","method":"system.ping","params":{}}"#)
        #expect(try await inbox.next()["id"] == "after")
        _ = try await call(client, "object.delete", ["id": .string(tile)])
        #expect(try await inbox.next()["error"]?["code"] == "not_found")
    }

    @Test func anExistingWaitKeepsItsGraceWhileAnAsyncCloseFails() async throws {
        let tile = terminal()
        router.firstReportGrace = 0.5
        let waiter = try connect(), client = try connect()
        waiter.send(#"{"id":"wait","method":"agent.wait","params":{"target":"\#(tile)","timeoutMs":3000}}"#)
        waiter.send(#"{"id":"ready","method":"system.ping","params":{}}"#)
        #expect(try await waiter.next()["id"] == "ready")
        router.closeBoard = { _, _ in
            let response = try await waiter.next()
            #expect(response["error"]?["code"] == "unavailable")
            throw ApiRouter.Failure("unavailable", "session ending failed")
        }
        #expect(try await call(client, "board.close", ["board": .string(board.id), "endSessions": .bool(true)])["error"]?["code"] == "unavailable")
        #expect(registry.boards[board.id] === board)
    }

    @Test func aPromptSuspendedBeforeTypingRefusesABoardThatStartedClosing() async throws {
        let tile = terminal()
        let client = try connect(), closer = try connect()
        var started: CheckedContinuation<Void, Never>?
        var finish: CheckedContinuation<Void, Never>?
        defer { finish?.resume() }
        router.closeBoard = { _, _ in
            started?.resume()
            await withCheckedContinuation { finish = $0 }
            throw ApiRouter.Failure("unavailable", "session ending failed")
        }
        router.readTerminal = { [self] _, _, _ in
            await withCheckedContinuation {
                started = $0
                closer.send(#"{"id":"close","method":"board.close","params":{"board":"\#(board.id)","endSessions":true}}"#)
            }
            return nil
        }
        let refused = try await call(client, "agent.prompt", ["target": .string(tile), "text": "must not be typed", "force": .bool(true)])
        #expect(refused["error"]?["code"] == "conflict")
        #expect(submitted.isEmpty)
        finish?.resume()
        finish = nil
        #expect(try await closer.next()["error"]?["code"] == "unavailable")
        router.readTerminal = nil
        #expect(try await call(client, "agent.prompt", ["target": .string(tile), "text": "board is usable", "force": .bool(true)])["ok"] == .bool(true))
        #expect(submitted == ["board is usable"])
    }

    @Test(arguments: [false, true])
    func aQueuedPromptCannotResumeAfterItsBoardClosed(reopen: Bool) async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: 1)
        let client = try connect(), closer = try connect()
        router.readTerminal = { [self] _, _, _ in
            let closed = try? await call(closer, "board.close", ["board": .string(board.id)])
            #expect(closed?["result"]?["board"] == .string(board.id))
            if reopen {
                let opened = try? await call(closer, "board.open", ["root": .string(board.root.path)])
                #expect(opened?["result"]?["board"] == .string(board.id))
            }
            return nil
        }
        let response = try await call(client, "agent.prompt", ["target": .string(tile), "text": "must not be lost on a detached board"])
        #expect(response["error"]?["code"] == "not_found")
        #expect(board.messages[tile] == nil)
        let active = try await registry.open(root: board.root)
        #expect(active.messages[tile] == nil)
    }

    @Test func aSecondCloseIsNotFoundAndLeavesTheStoredBoardAlone() async throws {
        _ = terminal()
        let client = try connect()
        #expect(try await call(client, "board.close", [:])["ok"] == .bool(true))
        let saved = try Data(contentsOf: registry.store.url(for: board.id))
        #expect(try await call(client, "board.close", ["board": .string(board.id)])["error"]?["code"] == "not_found")
        #expect(try Data(contentsOf: registry.store.url(for: board.id)) == saved)
        #expect(try await call(client, "board.open", ["root": .string(board.root.path)])["result"]?["objects"] == .number(1))
    }
}

extension QuestionTests {
    @Test func closingStopsExpiryOnAHeldBoardAndReopeningResumesIt() async throws {
        let deadline = Date().addingTimeInterval(3600)
        let question = try await question(["expiresAt": .string(deadline.formatted(.iso8601))])
        #expect(try await call("board.close", .object(["board": .string(board.id)]))["ok"] == .bool(true))
        let future = deadline.addingTimeInterval(1)
        board.scheduleQuestionExpiry(now: future)
        #expect(board.expireQuestions(now: future) == [])
        #expect(board.objects[question.id]?.props["status"] == "open")
        let reopened = try await registry.open(root: board.root)
        #expect(reopened.expireQuestions(now: future) == [question.id])
        #expect(reopened.objects[question.id]?.props["status"] == "expired")
    }
}

extension AgentControlTests {
    @Test func closeDuringRestartIsRefusedBeforeEviction() async throws {
        let worker = terminal(name: "worker", command: ["omp"])
        router.restartTerminal = { [unowned self] _, tile, argv, killing, ended in
            let refused = try await call("board.close", ["board": .string(board.id)])
            #expect(refused["error"]?["code"] == "conflict")
            #expect(registry.boards[board.id] === board)
            try killing()
            try ended()
            restarted.append((tile, argv))
        }
        #expect(try await call("agent.restart", ["target": "worker", "mode": "fresh", "force": .bool(true)])["ok"] == .bool(true))
        #expect(restarted.map(\.0) == [worker])
        #expect(try await call("board.close", ["board": .string(board.id)])["result"]?["kept"] == .array([.object(["id": .string(worker), "name": "worker"])]))
    }

    @Test func restartCannotBeginWhileAnAsyncCloseOwnsTheBoard() async throws {
        let worker = terminal(name: "worker", command: ["omp"])
        router.closeBoard = { [unowned self] id, _ in
            let refused = try await call("agent.restart", ["target": "worker", "mode": "fresh", "force": .bool(true)])
            #expect(refused["error"]?["code"] == "conflict")
            let duplicate = try await call("board.close", ["board": .string(id)])
            #expect(duplicate["error"]?["code"] == "conflict")
            let result = BoardCloseResult(board: board)
            try registry.close(id)
            return result
        }
        #expect(try await call("board.close", ["board": .string(board.id)])["result"]?["kept"] == .array([.object(["id": .string(worker), "name": "worker"])]))
        #expect(restarted.isEmpty)
        #expect(try await call("board.get", ["board": .string(board.id)])["error"]?["code"] == "not_found")
    }

    @Test func aClosingBoardRefusesConcurrentRequestsAndAFailedCloseReleasesIt() async throws {
        let worker = terminal(name: "worker", command: ["omp"])
        let mention = try board.stage(.object(worker))
        let otherRoot = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = try await registry.open(root: otherRoot)
        router.closeBoard = { [unowned self] _, _ in
            let requests: [(String, [String: JSONValue])] = [
                ("object.create", ["board": .string(board.id), "type": "terminal", "props": .object(["name": "intruder"])]),
                ("object.create", ["caller": .string(worker), "type": "terminal", "props": .object(["name": "intruder"])]),
                ("object.create", ["type": "terminal", "props": .object(["name": "intruder"])]),
                ("agent.prompt", ["target": .string(worker), "text": "must not reach a closing terminal"]),
                ("board.open", ["root": .string(board.root.path + "/.")]),
                ("object.update", ["id": .string(worker), "props": .object(["name": "changed"])]),
                ("tray.unstage", ["id": .string(mention.id)]),
            ]
            for (method, params) in requests {
                let response = try await call(method, params)
                #expect(response["error"]?["code"] == "conflict", "\(method): \(response)")
            }
            let created = try await call("object.create", ["board": .string(other.id), "type": "note", "props": .object(["markdown": "other board stays writable"])])
            #expect(created["result"]?["object"]?["props"]?["markdown"] == "other board stays writable")
            throw ApiRouter.Failure("unavailable", "session ending failed")
        }
        let response = try await call("board.close", ["board": .string(board.id), "endSessions": .bool(true)])
        #expect(response["error"]?["code"] == "unavailable")
        #expect(Set(board.objects.keys) == [worker])
        #expect(board.objects[worker]?.props["name"] == "worker")
        #expect(board.tray.map(\.id) == [mention.id])
        #expect(registry.boards[board.id] === board)
        let created = try await call("object.create", ["board": .string(board.id), "type": "note", "props": .object(["markdown": "close failed, board is usable"])])
        #expect(created["result"]?["object"]?["props"]?["markdown"] == "close failed, board is usable")
    }
}
