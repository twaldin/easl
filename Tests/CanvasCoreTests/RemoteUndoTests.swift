import Foundation
import Testing
@testable import CanvasCore

extension BoardMirrorTests {
    @Test func undoAndRedoGoThroughTheHostAndAnotherViewerSeesThem() async throws {
        let moved = note("drag me")
        let (mirror, board) = try await mirror()
        let (watcher, other) = try await self.mirror()
        defer {
            mirror.close()
            watcher.close()
        }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 40, w: 280, h: 200))
        try await eventually { host.objects[moved.id]?.frame.x == 300 }
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[moved.id]?.frame == moved.frame)
        try await eventually { board.objects[moved.id] == host.objects[moved.id] && other.objects[moved.id] == host.objects[moved.id] }
        #expect(!board.history.canUndo && board.history.canRedo)
        _ = await mirror.undo(redo: true).value
        #expect(host.objects[moved.id]?.frame.x == 300)
        try await eventually { other.objects[moved.id]?.frame.x == 300 }
        #expect(board.history.canUndo && !board.history.canRedo)
    }

    @Test func aQueuedRedoAndTheGestureAfterItBothReachTheHost() async throws {
        let moved = note("before")
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let delay = Locked(true)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "board.redo", delay.withLock({ value in
                defer { value = false }
                return value
            }), let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, board) = try await mirror()
        let (watcher, other) = try await self.mirror()
        defer {
            mirror.close()
            watcher.close()
        }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { board.objects[moved.id] == host.objects[moved.id] && host.objects[moved.id]?.frame.x == 300 }
        let first = try #require(board.nextUndo).id
        _ = await mirror.undo(redo: false).value
        let redo = mirror.undo(redo: true)
        _ = try board.update(moved.id, frame: Frame(x: 700, y: 0, w: 280, h: 200), props: .object(["markdown": "after"]))
        let second = try #require(board.nextUndo).id
        try await eventually { pending.withLock { $0 != nil } && other.objects[moved.id]?.frame.x == 300 }
        #expect(board.objects[moved.id]?.frame.x == 700)
        #expect(board.objects[moved.id]?.props["markdown"] == "after")
        pending.withLock { $0 }?()
        _ = await redo.value
        try await eventually {
            host.objects[moved.id]?.frame.x == 700 && host.objects[moved.id]?.props["markdown"] == "after"
                && board.objects[moved.id] == host.objects[moved.id] && other.objects[moved.id] == host.objects[moved.id]
        }
        #expect(board.history.undoSteps.map(\.id) == [first, second])
        #expect(!board.history.canRedo)
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[moved.id]?.frame.x == 300)
        #expect(host.objects[moved.id]?.props["markdown"] == "before")
        try await eventually { board.objects[moved.id] == host.objects[moved.id] && other.objects[moved.id] == host.objects[moved.id] }
    }

    @Test func rapidUndoAndRedoStayOrderedBeforeALaterPreview() async throws {
        let first = note("first"), second = note("second", at: 400)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let order = Locked<[String]>([])
        let delay = Locked(true)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let method = request["method"]?.string ?? ""
            if ["board.undo", "board.redo", "object.update"].contains(method) {
                order.withLock { $0.append(method) }
            }
            let reply = await router.handle(request, connection: connection)
            guard method == "board.undo", delay.withLock({ value in
                defer { value = false }
                return value
            }), let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, board) = try await mirror()
        let (watcher, other) = try await self.mirror()
        defer {
            mirror.close()
            watcher.close()
        }
        _ = try board.update(first.id, frame: Frame(x: 100, y: 0, w: 280, h: 200))
        _ = try board.update(second.id, frame: Frame(x: 500, y: 0, w: 280, h: 200))
        try await eventually { board.objects[first.id] == host.objects[first.id] && board.objects[second.id] == host.objects[second.id] }
        let steps = board.history.undoSteps.map(\.id)
        order.withLock { $0 = [] }
        let undoOne = mirror.undo(redo: false)
        let undoTwo = mirror.undo(redo: false)
        let redoOne = mirror.undo(redo: true)
        let redoTwo = mirror.undo(redo: true)
        _ = try board.update(first.id, props: .object(["markdown": "latest"]))
        let latest = try #require(board.nextUndo).id
        try await eventually { pending.withLock { $0 != nil } && other.objects[second.id]?.frame.x == 400 }
        #expect(board.objects[first.id]?.props["markdown"] == "latest")
        pending.withLock { $0 }?()
        _ = await undoOne.value
        _ = await undoTwo.value
        _ = await redoOne.value
        _ = await redoTwo.value
        try await eventually {
            host.objects[first.id]?.frame.x == 100 && host.objects[second.id]?.frame.x == 500
                && host.objects[first.id]?.props["markdown"] == "latest"
                && board.objects[first.id] == host.objects[first.id] && other.objects[first.id] == host.objects[first.id]
                && board.objects[second.id] == host.objects[second.id] && other.objects[second.id] == host.objects[second.id]
        }
        #expect(order.withLock { $0 } == ["board.undo", "board.undo", "board.redo", "board.redo", "object.update"])
        #expect(board.history.undoSteps.map(\.id) == steps + [latest])
        #expect(!board.history.canRedo)
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[first.id]?.props["markdown"] == "first")
        #expect(host.objects[first.id]?.frame.x == 100)
        try await eventually { other.objects[first.id] == host.objects[first.id] }
    }

    @Test func aDelayedReplayReceiptCannotUndoNewerHostDeletionsOrRecreations() async throws {
        let existing = note("existing")
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "board.undo", let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, board) = try await mirror()
        let (watcher, other) = try await self.mirror()
        defer {
            mirror.close()
            watcher.close()
        }
        var provisional: ObjectID = ""
        board.transaction {
            _ = try? board.update(existing.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
            provisional = board.create(type: .note, props: .object(["markdown": "created"])).id
        }
        try await eventually { board.objects[provisional] == nil && host.objects.values.contains { $0.props["markdown"] == "created" } }
        let canonical = try #require(host.objects.values.first { $0.props["markdown"] == "created" }?.id)
        let undo = mirror.undo(redo: false)
        try await eventually { pending.withLock { $0 != nil } && board.objects[canonical] == nil }
        #expect(host.objects[existing.id]?.frame.x == 0)
        #expect(host.undo())
        try host.delete(existing.id)
        try await eventually {
            board.objects[existing.id] == nil && other.objects[existing.id] == nil
                && board.objects[canonical] == host.objects[canonical] && other.objects[canonical] == host.objects[canonical]
        }
        pending.withLock { $0 }?()
        _ = await undo.value
        #expect(host.objects[canonical]?.props["markdown"] == "created")
        #expect(board.objects[canonical] == host.objects[canonical])
        #expect(other.objects[canonical] == host.objects[canonical])
        #expect(host.objects[existing.id] == nil && board.objects[existing.id] == nil && other.objects[existing.id] == nil)
    }

    @Test func undoAndRedoKeepAnotherViewersReplacement() async throws {
        let moved = note("original")
        let (mirror, board) = try await mirror()
        let (watcher, other) = try await self.mirror()
        defer {
            mirror.close()
            watcher.close()
        }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 40, w: 280, h: 200))
        try await eventually { other.objects[moved.id]?.frame.x == 300 }
        _ = try other.update(moved.id, frame: Frame(x: 900, y: 40, w: 280, h: 200), props: .object(["markdown": "other viewer"]))
        try await eventually { board.objects[moved.id] == host.objects[moved.id] && host.objects[moved.id]?.frame.x == 900 }
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[moved.id]?.frame == Frame(x: 900, y: 0, w: 280, h: 200))
        #expect(host.objects[moved.id]?.props["markdown"] == "other viewer")
        try await eventually { board.objects[moved.id] == host.objects[moved.id] && other.objects[moved.id] == host.objects[moved.id] }
        _ = await mirror.undo(redo: true).value
        #expect(host.objects[moved.id]?.frame == Frame(x: 900, y: 40, w: 280, h: 200))
        #expect(host.objects[moved.id]?.props["markdown"] == "other viewer")
        try await eventually { board.objects[moved.id] == host.objects[moved.id] && other.objects[moved.id] == host.objects[moved.id] }
    }

    @Test func aHeldPropsEditStillConflictsWithAnInterveningHostEdit() async throws {
        let moved = note("before")
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let intervene = Once()
        intervene.body = { [unowned self] in
            _ = try? host.update(moved.id, props: .object(["markdown": "host edit"]))
        }
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "board.undo" { await intervene.run() }
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "board.undo", let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, board) = try await mirror()
        let (watcher, other) = try await self.mirror()
        defer {
            mirror.close()
            watcher.close()
        }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { board.objects[moved.id] == host.objects[moved.id] && host.objects[moved.id]?.frame.x == 300 }
        let undo = mirror.undo(redo: false)
        _ = try board.update(moved.id, props: .object(["markdown": "viewer preview"]))
        try await eventually { pending.withLock { $0 != nil } && other.objects[moved.id]?.props["markdown"] == "host edit" }
        #expect(board.objects[moved.id]?.props["markdown"] == "viewer preview")
        pending.withLock { $0 }?()
        _ = await undo.value
        try await eventually { board.objects[moved.id] == host.objects[moved.id] && other.objects[moved.id] == host.objects[moved.id] }
        #expect(host.objects[moved.id]?.frame.x == 0)
        #expect(host.objects[moved.id]?.props["markdown"] == "host edit")
    }

    @Test func aViewersUndoKeepsAnAgentsEditOfTheSameNote() async throws {
        let edited = note("draft")
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": "worker"])).id
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(edited.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { host.objects[edited.id]?.frame.x == 300 }
        _ = try host.update(edited.id, props: .object(["markdown": "agent text"]), caller: agent)
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[edited.id]?.frame.x == 0)
        #expect(host.objects[edited.id]?.props["markdown"] == "agent text")
        try await eventually { board.objects[edited.id] == host.objects[edited.id] }
    }

    @Test func undoFollowsTheGesturesWritesAndHoldsTheOnesMadeAfterIt() async throws {
        let first = note("first"), second = note("second", at: 400)
        let order = Locked<[String]>([])
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let method = request["method"]?.string ?? ""
            guard ["object.update", "board.undo"].contains(method) else { return await router.handle(request, connection: connection) }
            let held = order.withLock { log in
                log.append(method)
                return log == ["object.update"]
            }
            let reply = await router.handle(request, connection: connection)
            guard held, let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(first.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { pending.withLock { $0 != nil } }
        let undo = mirror.undo(redo: false)
        _ = try board.update(second.id, frame: Frame(x: 700, y: 0, w: 280, h: 200))
        try await Task.sleep(for: .milliseconds(200))
        #expect(order.withLock { $0 } == ["object.update"], "the undo waits for the gesture's write, and the later move for the undo")
        pending.withLock { $0 }?()
        _ = await undo.value
        try await eventually { host.objects[second.id]?.frame.x == 700 }
        #expect(order.withLock { $0 } == ["object.update", "board.undo", "object.update"])
        #expect(host.objects[first.id]?.frame.x == 0)
        try await eventually { board.objects[first.id]?.frame.x == 0 && board.objects[second.id]?.frame.x == 700 }
        #expect(board.history.undoSteps.count == 1 && !board.history.canRedo)
    }

    @Test func aRetryAfterALostUndoReplyAnswersWhatWasDoneAndKeepsRedo() async throws {
        let moved = note("moved")
        let undos = Locked(0)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "board.undo", undos.withLock({ count in
                count += 1
                return count
            }) == 1 else { return reply }
            return .object(["id": request["id"] ?? .null, "ok": .bool(false), "error": .object(["code": "unavailable", "message": "the link dropped"])])
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { host.objects[moved.id]?.frame.x == 300 }
        let step = try #require(board.nextUndo).id
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[moved.id]?.frame.x == 0, "the host undid it all the same")
        #expect(board.nextUndo?.id == step && !board.history.canRedo)
        let revision = host.revision
        _ = await mirror.undo(redo: false).value
        #expect(host.revision == revision, "the retry changed nothing on the host")
        #expect(board.nextRedo?.id == step && !board.history.canUndo)
        _ = await mirror.undo(redo: true).value
        #expect(host.objects[moved.id]?.frame.x == 300)
    }

    @Test func aStepTheHostRefusedLeavesTheHistoryAndTheOneBeforeIsUndone() async throws {
        let moved = note("moved"), edited = note("edited", at: 400)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { host.objects[moved.id]?.frame.x == 300 }
        let landed = try #require(board.nextUndo).id
        _ = try host.update(edited.id, props: .object(["markdown": .string("the host's")]))
        _ = try board.update(edited.id, props: .object(["markdown": .string("the viewer's")]))
        try await eventually { board.objects[edited.id]?.props["markdown"]?.string == "the host's" }
        #expect(board.history.undoSteps.count == 2)
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[moved.id]?.frame.x == 0)
        #expect(host.objects[edited.id]?.props["markdown"]?.string == "the host's")
        #expect(board.history.undoSteps.isEmpty)
        #expect(board.history.redoSteps.map(\.id) == [landed])
    }

    @Test func undoingADeleteOnTheHostBringsTheViewersChipsBack() async throws {
        let doomed = note("doomed")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        try board.stage(.object(doomed.id))
        try board.delete(doomed.id)
        try await eventually { host.objects[doomed.id] == nil }
        #expect(board.tray.isEmpty)
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[doomed.id]?.props == doomed.props && host.objects[doomed.id]?.z == doomed.z)
        #expect(board.objects[doomed.id] == host.objects[doomed.id])
        #expect(board.tray.map(\.target) == [.object(doomed.id)])
    }

    @Test func aPasteIntoATerminalIsUndoneHereEvenWithTheHostGone() async throws {
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": "worker"])).id
        let quoted = note("quoted")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        let mention = try board.stage(.object(quoted.id))
        board.commit([mention.id], pastedInto: agent)
        #expect(board.tray.isEmpty)
        server.stop()
        _ = await mirror.undo(redo: false).value
        #expect(board.tray.map(\.id) == [mention.id])
        _ = await mirror.undo(redo: true).value
        #expect(board.tray.isEmpty)
    }

    @Test func bringingTwoNotesToFrontRestacksThemOnTheHostAsOneStep() async throws {
        let back = note("back"), middle = note("middle", at: 400), front = note("front", at: 800)
        let (mirror, board) = try await mirror()
        let (watcher, other) = try await self.mirror()
        defer {
            mirror.close()
            watcher.close()
        }
        #expect(board.hostHistoryUnavailable == nil)
        board.transaction {
            _ = try? board.update(back.id, z: front.z + 1)
            _ = try? board.update(middle.id, z: front.z + 2)
        }
        #expect(board.history.undoSteps.count == 1)
        try await eventually { host.objects[back.id]?.z == front.z + 1 && host.objects[middle.id]?.z == front.z + 2 }
        try await eventually { other.objects[back.id]?.z == front.z + 1 && other.objects[middle.id]?.z == front.z + 2 }
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[back.id]?.z == back.z && host.objects[middle.id]?.z == middle.z)
        try await eventually { other.objects[back.id]?.z == back.z && other.objects[middle.id]?.z == middle.z }
    }

    @Test func conflictedTextRecoveryWritesTheHostWithoutUndoingAnEarlierGesture() async throws {
        let edited = note("base")
        let (mirror, view) = try await mirror()
        let (watcher, other) = try await self.mirror()
        defer {
            mirror.close()
            watcher.close()
        }
        _ = try view.update(edited.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { view.objects[edited.id] == host.objects[edited.id] && host.objects[edited.id]?.frame.x == 300 }
        let session = NoteEditSession(try view.object(edited.id))
        _ = try host.update(edited.id, props: .object(["markdown": "theirs"]))
        try await eventually { view.objects[edited.id]?.props["markdown"] == "theirs" }
        #expect(try session.commit("my unsent text", confirmed: false, on: view) == .conflict)
        #expect(session.keepTheirs(discarding: "my unsent text", on: view))
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[edited.id]?.props["markdown"] == "my unsent text")
        #expect(host.objects[edited.id]?.frame.x == 300)
        try await eventually { other.objects[edited.id]?.props["markdown"] == "my unsent text" }
        _ = await mirror.undo(redo: true).value
        #expect(host.objects[edited.id]?.props["markdown"] == "theirs")
        #expect(host.objects[edited.id]?.frame.x == 300)
        _ = await mirror.undo(redo: false).value
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[edited.id]?.frame == edited.frame)
        #expect(host.objects[edited.id]?.props["markdown"] == "my unsent text")
        try await eventually { view.objects[edited.id] == host.objects[edited.id] && other.objects[edited.id] == host.objects[edited.id] }
    }

    @Test func aRecoveryReplyLostAfterApplyDoesNotBlockOlderUndoOrRedo() async throws {
        let edited = note("base")
        let loseReply = Locked(true)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "object.update", request["params"]?["viewer"] == nil,
                  loseReply.withLock({ value in defer { value = false }; return value }) else { return reply }
            return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                            "error": .object(["code": "unavailable", "message": "reply lost after apply"])])
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        _ = try view.update(edited.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { view.objects[edited.id] == host.objects[edited.id] && host.objects[edited.id]?.frame.x == 300 }
        let move = try #require(view.nextUndo).id
        let session = NoteEditSession(try view.object(edited.id))
        _ = try host.update(edited.id, props: .object(["markdown": "theirs"]))
        try await eventually { view.objects[edited.id]?.props["markdown"] == "theirs" }
        #expect(session.keepTheirs(discarding: "mine", on: view))
        _ = await mirror.undo(redo: false).value
        try await eventually { view.objects[edited.id] == host.objects[edited.id] }
        let applied = try host.object(edited.id)
        #expect(applied.props["markdown"] == "mine")
        _ = await mirror.undo(redo: false).value
        #expect(view.nextUndo?.id == move)
        #expect(host.objects[edited.id]?.rev == applied.rev)
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[edited.id]?.frame == edited.frame)
        #expect(host.objects[edited.id]?.props["markdown"] == "mine")
        _ = await mirror.undo(redo: true).value
        _ = await mirror.undo(redo: true).value
        #expect(host.objects[edited.id]?.frame.x == 300)
        #expect(host.objects[edited.id]?.props["markdown"] == "theirs")
    }

    @Test(arguments: [false, true])
    func noteRecoveryRefusesALaterAgentsTextAndKeepsItsStep(redo: Bool) async throws {
        let edited = note("base")
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let session = NoteEditSession(try view.object(edited.id))
        _ = try host.update(edited.id, props: .object(["markdown": "theirs"]))
        try await eventually { view.objects[edited.id]?.props["markdown"] == "theirs" }
        #expect(session.keepTheirs(discarding: "mine", on: view))
        if redo { _ = await mirror.undo(redo: false).value }
        let undoIDs = view.history.undoSteps.map(\.id), redoIDs = view.history.redoSteps.map(\.id)
        _ = try host.update(edited.id, props: .object(["markdown": "later agent text"]))
        try await eventually { view.objects[edited.id]?.props["markdown"] == "later agent text" }
        let refusal = await mirror.undo(redo: redo).value
        #expect(refusal?.hasPrefix("Couldn't") == true)
        #expect(host.objects[edited.id]?.props["markdown"] == "later agent text")
        #expect(view.history.undoSteps.map(\.id) == undoIDs)
        #expect(view.history.redoSteps.map(\.id) == redoIDs)
        _ = try host.update(edited.id, props: .object(["markdown": .string(redo ? "mine" : "theirs")]))
        try await eventually { view.objects[edited.id] == host.objects[edited.id] }
        _ = await mirror.undo(redo: redo).value
        #expect(host.objects[edited.id]?.props["markdown"]?.string == (redo ? "theirs" : "mine"))
    }

    @Test(arguments: [false, true])
    func noteRecoveryGuardsAHostWriteThatCrossesItsRequest(redo: Bool) async throws {
        let edited = note("base")
        let cross = Once()
        cross.body = { [unowned self] in
            _ = try? host.update(edited.id, props: .object(["markdown": "crossed agent write"]))
        }
        let armed = Locked(false)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "object.update", request["params"]?["viewer"] == nil, armed.withLock({ $0 }) {
                await cross.run()
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let session = NoteEditSession(try view.object(edited.id))
        _ = try host.update(edited.id, props: .object(["markdown": "theirs"]))
        try await eventually { view.objects[edited.id]?.props["markdown"] == "theirs" }
        #expect(session.keepTheirs(discarding: "mine", on: view))
        if redo { _ = await mirror.undo(redo: false).value }
        let undoIDs = view.history.undoSteps.map(\.id), redoIDs = view.history.redoSteps.map(\.id)
        armed.withLock { $0 = true }
        let refusal = await mirror.undo(redo: redo).value
        #expect(refusal?.hasPrefix("Couldn't") == true)
        #expect(host.objects[edited.id]?.props["markdown"] == "crossed agent write")
        try await eventually { view.objects[edited.id] == host.objects[edited.id] }
        #expect(view.history.undoSteps.map(\.id) == undoIDs)
        #expect(view.history.redoSteps.map(\.id) == redoIDs)
    }

    @Test func noteRecoveryStaysAvailableAfterAnOfflineRefusal() async throws {
        let edited = note("base")
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let session = NoteEditSession(try view.object(edited.id))
        _ = try host.update(edited.id, props: .object(["markdown": "theirs"]))
        try await eventually { view.objects[edited.id]?.props["markdown"] == "theirs" }
        #expect(session.keepTheirs(discarding: "mine", on: view))
        let recovery = try #require(view.nextUndo).id
        server.stop()
        try await eventually { mirror.state == .offline }
        let refusal = await mirror.undo(redo: false).value
        #expect(refusal?.hasPrefix("Couldn't") == true)
        #expect(view.nextUndo?.id == recovery && !view.history.canRedo)
        #expect(host.objects[edited.id]?.props["markdown"] == "theirs")
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.state == .online && mirror.reading == nil }
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[edited.id]?.props["markdown"] == "mine")
        #expect(view.nextRedo?.id == recovery)
    }

    @Test func aGestureHeldBehindNoteRecoveryUsesTheRecoveredRevision() async throws {
        let edited = note("base")
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "object.update", request["params"]?["viewer"] == nil, let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let session = NoteEditSession(try view.object(edited.id))
        _ = try host.update(edited.id, props: .object(["markdown": "theirs"]))
        try await eventually { view.objects[edited.id]?.props["markdown"] == "theirs" }
        #expect(session.keepTheirs(discarding: "mine", on: view))
        let recovery = mirror.undo(redo: false)
        _ = try view.update(edited.id, props: .object(["markdown": "later gesture"]))
        try await eventually { pending.withLock { $0 != nil } }
        #expect(host.objects[edited.id]?.props["markdown"] == "mine")
        #expect(view.objects[edited.id]?.props["markdown"] == "later gesture")
        pending.withLock { $0 }?()
        _ = await recovery.value
        try await eventually { host.objects[edited.id]?.props["markdown"] == "later gesture" && view.objects[edited.id] == host.objects[edited.id] }
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[edited.id]?.props["markdown"] == "mine")
    }

    @Test func aRetiredOutcomeDropsOnlyItsOwnStepAndReleasesALaterGesture() async throws {
        let moved = note("move"), deleted = note("delete", at: 400)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "board.undo", reply?["result"]?["retired"]?.bool == true, let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        _ = try view.update(moved.id, frame: Frame(x: 100, y: 0, w: 280, h: 200))
        try await eventually { host.objects[moved.id]?.frame.x == 100 }
        let older = try #require(view.nextUndo).id
        try view.stage(.object(deleted.id))
        try view.delete(deleted.id)
        try await eventually { host.objects[deleted.id] == nil }
        let retired = try #require(view.nextUndo).id
        _ = try host.replayViewer(mirror.viewer, step: retired, redo: false)
        for id in (retired + 1)...(retired + 201) {
            let edit = try #require(try ViewerEdit(.object(["viewer": .string(mirror.viewer), "step": .number(Double(id))])))
            _ = try host.asViewerEdit(edit) {
                try host.update(deleted.id, frame: Frame(x: Double(id), y: 0, w: 280, h: 200))
            }
            _ = try host.replayViewer(mirror.viewer, step: id, redo: false)
        }
        try await eventually { view.objects[deleted.id] == host.objects[deleted.id] }
        #expect(view.tray.isEmpty)
        let replay = mirror.undo(redo: false)
        _ = try view.update(moved.id, frame: Frame(x: 700, y: 0, w: 280, h: 200))
        let later = try #require(view.nextUndo).id
        try await eventually { pending.withLock { $0 != nil } }
        pending.withLock { $0 }?()
        let notice = await replay.value
        #expect(notice?.hasPrefix("Couldn't") == true)
        try await eventually { host.objects[moved.id]?.frame.x == 700 }
        #expect(view.history.undoSteps.map(\.id) == [older, later])
        #expect(view.history.redoSteps.isEmpty && view.tray.isEmpty)
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[moved.id]?.frame.x == 100)
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[moved.id]?.frame == moved.frame)
        #expect(view.tray.isEmpty)
    }

    @Test func anOlderHostTakesPlainEditsAndSaysUndoNeedsAnUpdate() async throws {
        let moved = note("moved")
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let id = request["id"] ?? .null, params = request["params"]?.object ?? [:]
            if request["method"]?.string == "system.ping" {
                return .object(["id": id, "ok": .bool(true), "result": .object(["version": 1, "app": "easl"])])
            }
            if let unknown = ["viewer", "step", "z"].first(where: { params[$0] != nil }) {
                return .object(["id": id, "ok": .bool(false), "error": .object(["code": "invalid_params", "message": .string("unknown param \(unknown)")])])
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { host.objects[moved.id]?.frame.x == 300 }
        try await eventually { board.objects[moved.id] == host.objects[moved.id] }
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[moved.id]?.frame.x == 300)
        #expect(board.history.canUndo)
    }
}
