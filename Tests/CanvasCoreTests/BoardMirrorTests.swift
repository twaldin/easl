import Foundation
import Testing
@testable import CanvasCore

/// A remote board (docs/design.md "Client mode"): a `BoardMirror` of a board served by a real
/// router over a real socket, as a viewer reaches its host (the ssh relay is just the transport).
@MainActor
final class BoardMirrorTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("bm-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    var server: SocketServer
    let host: Board
    var socket: String { dir.appendingPathComponent("s").path }
    var mirrors: [BoardMirror] = []
    /// What each host terminal was sent, in order.
    var typed: [ObjectID: [String]] = [:]

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        host = registry.open(root: dir.appendingPathComponent("root"))
        router = ApiRouter(registry: registry)
        server = Self.serve(router, at: dir.appendingPathComponent("s").path)
        try server.start()
        router.submitToTerminal = { [unowned self] _, tile, text in
            typed[tile, default: []].append(text)
            return true
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    static func serve(_ router: ApiRouter, at path: String) -> SocketServer {
        SocketServer(path: path) { request, connection in await router.handle(request, connection: connection) }
    }

    func mirror(board: BoardID? = nil) async throws -> (BoardMirror, Board) {
        // The whole suite keeps the main actor (the router's) busy for seconds at a time.
        let fast = EaslConnection.Backoff(initial: .milliseconds(50), maximum: .milliseconds(200))
        func link(_ path: String) -> EaslConnection { .unixSocket(path, backoff: fast, handshakeTimeout: .seconds(60)) }
        let mirror = BoardMirror(hostName: "home", board: board ?? host.id, connection: link(socket), renders: link(socket))
        mirrors.append(mirror)
        return (mirror, try await mirror.load())
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    func note(_ markdown: String, at x: Double = 0) -> CanvasObject {
        host.create(type: .note, props: .object(["markdown": .string(markdown)]), frame: Frame(x: x, y: 0, w: 280, h: 200))
    }

    @Test func terminalReferencesReaimTheHostPreviewAfterCanonicalCreate() async throws {
        let terminal = host.create(type: .terminal, props: .object([:]))
        let (_, view) = try await mirror()
        let first = view.openCode(path: host.root.appendingPathComponent("a.swift").path, lines: LineRange(start: 1, end: 1), beside: terminal.id)
        try await eventually { self.host.objects.values.contains { $0.type == .code } }
        let canonical = try #require(host.objects.values.first { $0.type == .code }?.id)
        try await eventually { view.objects[first.id] == nil && view.objects[canonical] != nil }
        let second = view.openCode(path: host.root.appendingPathComponent("b.swift").path, lines: LineRange(start: 2, end: 2), beside: terminal.id)
        #expect(second.id == canonical)
        #expect(!second.created)
        try await eventually { self.host.objects[canonical]?.props["path"]?.string == "b.swift" }
        let third = view.openCode(path: host.root.appendingPathComponent("c.swift").path, lines: LineRange(start: 3, end: 3), beside: terminal.id)
        #expect(third.id == canonical)
        #expect(!third.created)
        try await eventually { self.host.objects[canonical]?.props["path"]?.string == "c.swift" }
        #expect(host.objects.values.filter { $0.type == .code }.count == 1)
    }

    @Test func attentionSnapshotOnLoadReplacesAndAStaleAckDoesNotClear() async throws {
        let note = self.note("look")
        let raised = try host.raiseAttention(note.id, message: "here", caller: nil)
        let (mirror, view) = try await mirror()
        #expect(view.attention[note.id]?.stamp == raised.marker.stamp)
        #expect(view.attention[note.id]?.message == "here")
        let stale = SeenMarker(id: note.id, message: "here", raisedBy: nil, raisedAt: "2000-01-01T00:00:00.000000000Z")
        #expect(host.seen(note.id, rev: nil, marker: stale).cleared == false)
        #expect(host.attention[note.id]?.stamp == raised.marker.stamp)
        mirror.close()
    }

    @Test func aRefusedSeenAckRestoresTheMarkerWithoutDisablingEditsOrUndo() async throws {
        let note = self.note("look")
        let marker = try host.raiseAttention(note.id, message: nil, caller: nil).marker
        let terminal = host.create(type: .terminal, props: .object([:])).id
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .working, message: nil, seq: nil, source: nil)
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        server.stop()
        let refuse = Locked(true)
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "view.seen", refuse.withLock({ $0 }) {
                return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                "error": .object(["code": "unavailable", "message": "acknowledgment refused"])])
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        view.clearAttention(note.id)
        try await eventually { notices.count == 1 && view.attention[note.id]?.stamp == marker.stamp }
        #expect(mirror.state == .online && mirror.problem == nil)
        #expect(host.attention[note.id]?.stamp == marker.stamp)
        _ = try view.update(note.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { host.objects[note.id]?.frame.x == 300 }
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[note.id]?.frame == note.frame)
        refuse.withLock { $0 = false }
        view.clearAttention(note.id)
        try await eventually { host.attention[note.id] == nil }

        refuse.withLock { $0 = true }
        view.markSeen(terminal)
        try await eventually { notices.count == 2 }
        #expect(host.objects[terminal]?.props["lifecycle"]?["state"] == "done")
        refuse.withLock { $0 = false }
        #expect(mirror.state == .online && mirror.problem == nil)
        view.markSeen(terminal)
        try await eventually { host.objects[terminal]?.props["lifecycle"]?["seen"]?.bool == true }
        #expect(host.objects[terminal]?.props["lifecycle"]?["state"] == "idle")
    }

    @Test func seeingBeforeAPropsEditKeepsItsGuardAgainstACrossedHostReplacement() async throws {
        let edited = note("before")
        _ = try host.raiseAttention(edited.id, message: "look", caller: nil)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "view.seen", let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        view.clearAttention(edited.id)
        _ = try view.update(edited.id, props: .object(["markdown": "viewer preview"]))
        try await eventually { pending.withLock { $0 != nil } }
        _ = try host.update(edited.id, props: .object(["markdown": "host replacement"]))
        pending.withLock { $0 }?()
        try await eventually { view.objects[edited.id]?.props["markdown"] == "host replacement" }
        #expect(host.objects[edited.id]?.props["markdown"] == "host replacement")
        #expect(notices.count == 1)
    }

    @Test(arguments: [false, true])
    func ownSeenAckAllowsTheNextPropsEditButNotACrossedAgentEdit(crossed: Bool) async throws {
        let terminal = host.create(type: .terminal, props: .object(["name": "worker"])).id
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .working, message: nil, seq: nil, source: nil)
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "view.seen", let reply else { return reply }
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        view.markSeen(terminal)
        _ = try view.update(terminal, props: .object(["name": "viewer rename"]))
        try await eventually { pending.withLock { $0 != nil } }
        if crossed { _ = try host.update(terminal, props: .object(["name": "agent replacement"])) }
        pending.withLock { $0 }?()
        let expected = crossed ? "agent replacement" : "viewer rename"
        try await eventually { view.objects[terminal]?.props["name"]?.string == expected && view.objects[terminal] == host.objects[terminal] }
        #expect(host.objects[terminal]?.props["name"]?.string == expected)
        #expect(host.objects[terminal]?.props["lifecycle"]?["seen"] == .bool(true))
    }

    @Test func anAcknowledgmentOfADeletedObjectLeavesEditingAndUndoUsable() async throws {
        let deleted = note("gone"), kept = note("kept", at: 400)
        _ = try host.raiseAttention(deleted.id, message: "look", caller: nil)
        let remove = Once()
        remove.body = { [unowned self] in try? host.delete(deleted.id) }
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "view.seen" { await remove.run() }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        view.clearAttention(deleted.id)
        try await eventually { view.objects[deleted.id] == nil }
        _ = try view.update(kept.id, frame: Frame(x: 700, y: 0, w: 280, h: 200))
        try await eventually { host.objects[kept.id]?.frame.x == 700 }
        _ = await mirror.undo(redo: false).value
        #expect(host.objects[kept.id]?.frame == kept.frame)
        #expect(mirror.state == .online && mirror.problem == nil && notices.isEmpty)
    }

    @Test(arguments: [false, true])
    func aRefusedAcknowledgmentDoesNotResurrectASupersededMarker(clearNewMarker: Bool) async throws {
        let edited = note("look")
        _ = try host.raiseAttention(edited.id, message: "first", caller: nil)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            guard request["method"]?.string == "view.seen" else { return await router.handle(request, connection: connection) }
            let failure: JSONValue = .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                             "error": .object(["code": "unavailable", "message": "ack refused"])])
            pending.withLock { $0 = { connection.send(failure) } }
            return nil
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        view.clearAttention(edited.id)
        try await eventually { pending.withLock { $0 != nil } }
        let newer = try host.raiseAttention(edited.id, message: "second", caller: nil).marker
        try await eventually { view.attention[edited.id]?.stamp == newer.stamp }
        if clearNewMarker {
            host.clearAttention(edited.id)
            try await eventually { view.attention[edited.id] == nil }
        }
        pending.withLock { $0 }?()
        try await eventually { notices.count == 1 }
        #expect(view.attention[edited.id]?.message == (clearNewMarker ? nil : "second"))
        #expect(mirror.state == .online && mirror.problem == nil)
    }

    @Test func aRevisionSeenWhileOfflineCanBeAcknowledgedAfterRefresh() async throws {
        let terminal = host.create(type: .terminal, props: .object([:])).id
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .working, message: nil, seq: nil, source: nil)
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.connection.state == .offline }
        view.markSeen(terminal)
        try await eventually { view.seenForwarded[terminal] == nil }
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.state == .online && mirror.reading == nil }
        view.markSeen(terminal)
        try await eventually { host.objects[terminal]?.props["lifecycle"]?["seen"]?.bool == true }
        #expect(host.objects[terminal]?.props["lifecycle"]?["state"] == "idle")
    }

    @Test(arguments: [1, 2])
    func aMissingAttentionSnapshotIsAuthoritativeOnlyOnANewHost(version: Int) async throws {
        let edited = note("before")
        server.stop()
        let router = router
        let handler: SocketServer.Handler = { request, connection in
            if request["method"]?.string == "system.ping" {
                return .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["version": .number(Double(version)), "app": "easl"])])
            }
            if version == 1, request["params"]?["viewer"] != nil {
                return .object(["id": request["id"] ?? .null, "ok": .bool(false), "error": .object(["code": "invalid_params", "message": "unknown viewer"])])
            }
            guard let reply = await router.handle(request, connection: connection) else { return nil }
            guard request["method"]?.string == "board.get", var result = reply["result"]?.object else { return reply }
            result["attention"] = nil
            return reply.merging(.object(["result": .object(result)]))
        }
        server = SocketServer(path: socket, handler: handler)
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let marker = try host.raiseAttention(edited.id, message: "live", caller: nil).marker
        try await eventually { view.attention[edited.id]?.stamp == marker.stamp }
        server.stop()
        try await eventually { mirror.state == .offline }
        host.clearAttention(edited.id)
        _ = try host.update(edited.id, props: .object(["markdown": "refreshed"]))
        server = SocketServer(path: socket, handler: handler)
        try server.start()
        try await eventually { mirror.state == .online && mirror.reading == nil && view.objects[edited.id]?.props["markdown"] == "refreshed" }
        #expect(view.attention[edited.id]?.message == (version == 1 ? "live" : nil))
    }

    @Test(arguments: [false, true])
    func aComposerWithoutANegotiatedHostDoesNotReportAnUpgradeError(missingVersion: Bool) async throws {
        let terminal = host.create(type: .terminal, props: .object([:])).id
        let quoted = note("quoted")
        if missingVersion {
            server.stop()
            let router = router
            server = SocketServer(path: socket) { request, connection in
                if request["method"]?.string == "system.ping" {
                    return .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["app": "easl"])])
                }
                return await router.handle(request, connection: connection)
            }
            try server.start()
        }
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let mention = try view.stage(.object(quoted.id))
        if !missingVersion {
            server.stop()
            try await eventually { mirror.connection.state == .offline }
        }
        do {
            try await mirror.prompt("review [1]", to: terminal, mentions: [mention], answer: false)
            Issue.record("an offline prompt must fail")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "unavailable")
            #expect(failure.message.contains("offline") && !failure.message.contains("older"))
        }
        #expect(view.tray.map(\.id) == [mention.id])
    }

    @Test func aRefreshDoesNotRestoreAMarkerWhoseClearIsHeldBehindUndo() async throws {
        _ = host.create(type: .html, props: .object(["html": "<p>read whole</p>"]))
        let moved = note("move"), marked = note("look", at: 400)
        _ = try host.raiseAttention(marked.id, message: "pending", caller: nil)
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.state == .offline }
        let read = Locked<(@Sendable () -> Void)?>(nil)
        let update = Locked<(@Sendable () -> Void)?>(nil)
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard let reply else { return nil }
            if request["method"]?.string == "object.get" {
                read.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            if request["method"]?.string == "object.update" {
                update.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            return reply
        }
        try server.start()
        try await eventually { read.withLock { $0 != nil } }
        _ = try view.update(moved.id, frame: Frame(x: 300, y: 0, w: 280, h: 200))
        try await eventually { update.withLock { $0 != nil } }
        let undo = mirror.undo(redo: false)
        view.clearAttention(marked.id)
        read.withLock { $0 }?()
        try await eventually { mirror.reading == nil }
        #expect(view.attention[marked.id] == nil)
        #expect(host.attention[marked.id]?.message == "pending")
        update.withLock { $0 }?()
        _ = await undo.value
        try await eventually { host.attention[marked.id] == nil }
        #expect(host.objects[moved.id]?.frame == moved.frame)
        #expect(view.attention[marked.id] == nil && mirror.state == .online)
    }

    @Test func composerReturnedRestagesOnlyThisViewersTerminal() async throws {
        let alpha = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        let beta = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        try host.reportLifecycle(tile: alpha, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        try host.reportLifecycle(tile: beta, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let quoted = note("mine")
        let (one, view) = try await mirror()
        let (two, other) = try await mirror()
        defer {
            one.close()
            two.close()
        }
        let first = try view.stage(.object(quoted.id))
        let second = try other.stage(.object(quoted.id))
        try await one.prompt("first [1]", to: alpha, mentions: view.withdraw([first.id]), answer: false)
        try await two.prompt("second [1]", to: beta, mentions: other.withdraw([second.id]), answer: false)
        try host.releaseAgent(tile: alpha)
        try await eventually { view.tray.map(\.target) == [.object(quoted.id)] }
        #expect(view.tray.map(\.id) == [first.id])
        #expect(other.tray.isEmpty && host.tray.isEmpty)
        let waiting = await host.drain(peek: true, caller: beta, prompt: "second [1]")
        #expect(waiting.context.contains("mine"))
        try host.releaseAgent(tile: beta)
        try await eventually { other.tray.map(\.target) == [.object(quoted.id)] }
        #expect(other.tray.map(\.id) == [second.id])
        #expect(view.tray.count == 1)
    }

    @Test func aComposerReturnWhileTheHostWindowIsClosedRestoresPrivateMentions() async throws {
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let quoted = note("captured before closing")
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let original = try view.stage(.object(quoted.id))
        try await mirror.prompt("review [1]", to: terminal, mentions: view.withdraw([original.id]), answer: false)
        registry.setWindowOpen(false, board: host.id)
        try await eventually { mirror.availability == .closed }
        try host.releaseAgent(tile: terminal)
        try await eventually { view.tray.map(\.id) == [original.id] }
        #expect(view.tray.map(\.target) == [.object(quoted.id)])
        #expect(mirror.availability == .closed && host.tray.isEmpty)
    }

    @Test func aReturnBeforeAFailedReplyCannotReleaseTheNextDelivery() async throws {
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let delay = Locked(true)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "agent.prompt", delay.withLock({ value in
                defer { value = false }
                return value
            }) else { return reply }
            let failure: JSONValue = .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                               "error": .object(["code": "unavailable", "message": "reply lost"])])
            pending.withLock { $0 = { connection.send(failure) } }
            return nil
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let original = try view.stage(.terminal(object: terminal, text: "first captured output"))
        let mentions = view.withdraw([original.id])
        let first = Task { try await mirror.prompt("first [1]", to: terminal, mentions: mentions, answer: false) }
        try await eventually { pending.withLock { $0 != nil } }
        host.dropComposerPrompts(of: terminal)
        try await eventually { view.tray.map(\.target) == [.terminal(object: terminal, text: "first captured output")] }
        #expect(view.tray.map(\.id) == [original.id])
        try view.unstage(try #require(view.tray.first).id)
        var next = original
        next.target = .terminal(object: terminal, text: "second captured output")
        try await mirror.prompt("second [1]", to: terminal, mentions: [next], answer: false)
        pending.withLock { $0 }?()
        do {
            try await first.value
            Issue.record("the first prompt's failed reply must reach its caller")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "unavailable")
        }
        host.dropComposerPrompts(of: terminal)
        try await eventually { view.tray.map(\.target) == [.terminal(object: terminal, text: "second captured output")] }
        #expect(view.tray.map(\.id) == [original.id])
        #expect(host.tray.isEmpty)
    }

    @Test func aLateSubmissionFromAFailedRequestCannotConsumeTheNextDelivery() async throws {
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let delay = Locked(true)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            guard request["method"]?.string == "agent.prompt", delay.withLock({ value in
                defer { value = false }
                return value
            }) else { return reply }
            let failure: JSONValue = .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                               "error": .object(["code": "unavailable", "message": "reply lost"])])
            pending.withLock { $0 = { connection.send(failure) } }
            return nil
        }
        try server.start()
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let original = try view.stage(.terminal(object: terminal, text: "first captured output"))
        let mentions = view.withdraw([original.id])
        let first = Task { try await mirror.prompt("first [1]", to: terminal, mentions: mentions, answer: false) }
        try await eventually { pending.withLock { $0 != nil } }
        pending.withLock { $0 }?()
        do {
            try await first.value
            Issue.record("the first prompt's failed reply must reach its caller")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "unavailable")
        }
        var next = original
        next.target = .terminal(object: terminal, text: "second captured output")
        try await mirror.prompt("second [1]", to: terminal, mentions: [next], answer: false)
        let submitted = await host.drain(caller: terminal, prompt: "first [1]")
        #expect(submitted.context.contains("first captured output"))
        try host.releaseAgent(tile: terminal)
        try await eventually { view.tray.map(\.target) == [.terminal(object: terminal, text: "second captured output")] }
        #expect(view.tray.map(\.id) == [original.id])
        #expect(host.tray.isEmpty)
    }

    @Test func anExpiryMissedOfflineIsRecoveredOnceWithoutLosingCapturedText() async throws {
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let target = MentionTarget.terminal(object: terminal, text: "private captured output\nsecond line")
        let original = try view.stage(target)
        try await mirror.prompt("review [1]", to: terminal, mentions: view.withdraw([original.id]), answer: false)
        server.stop()
        try await eventually { mirror.state == .offline }
        host.expireComposerPrompts(now: Date().addingTimeInterval(ComposerPrompt.lifetime + 1))
        #expect(view.tray.isEmpty)
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.state == .online && mirror.reading == nil && view.tray.map(\.target) == [target] }
        #expect(view.tray.map(\.id) == [original.id])
        try view.unstage(try #require(view.tray.first).id)
        try host.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        try await mirror.prompt("again [1]", to: terminal, mentions: [original], answer: false)
        server.stop()
        try await eventually { mirror.state == .offline }
        _ = try host.update(terminal, props: .object(["name": "read again"]))
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.state == .online && mirror.reading == nil && view.objects[terminal]?.props["name"] == "read again" }
        #expect(view.tray.isEmpty)
        let waiting = await host.drain(peek: true, caller: terminal, prompt: "again [1]")
        #expect(waiting.context.contains("second line"))
        try host.releaseAgent(tile: terminal)
        try await eventually { view.tray.map(\.target) == [target] }
        #expect(view.tray.count == 1 && host.tray.isEmpty)
    }

    @Test func aSubmissionMissedOfflineReleasesOnlyTheConsumedOrigins() async throws {
        let alpha = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        let beta = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        try host.reportLifecycle(tile: alpha, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        try host.reportLifecycle(tile: beta, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        let firstTarget = MentionTarget.terminal(object: alpha, text: "first captured output")
        let original = try view.stage(firstTarget)
        let mentions = view.withdraw([original.id])
        try await mirror.prompt("first [1]", to: alpha, mentions: mentions, answer: false)
        try await mirror.prompt("first [1]", to: beta, mentions: mentions, answer: false)
        server.stop()
        try await eventually { mirror.state == .offline }
        let submitted = await host.drain(caller: alpha, prompt: "first [1]")
        #expect(submitted.context.contains("first captured output"))
        #expect(host.composerPrompts[alpha] == nil)
        _ = try host.update(beta, props: .object(["name": "read submitted"]))
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.state == .online && mirror.reading == nil && view.objects[beta]?.props["name"] == "read submitted" }
        var next = original
        next.target = .terminal(object: alpha, text: "new captured output")
        try await mirror.prompt("next [1]", to: alpha, mentions: [next], answer: false)
        try host.releaseAgent(tile: alpha)
        try await eventually { view.tray.map(\.target) == [.terminal(object: alpha, text: "new captured output")] }
        #expect(view.tray.map(\.id) == [original.id])
        try view.unstage(original.id)
        try host.releaseAgent(tile: beta)
        try await eventually { view.tray.map(\.target) == [firstTarget] }
        #expect(view.tray.map(\.id) == [original.id])
        #expect(host.tray.isEmpty)
    }

    @Test func movingAProvisionalTerminalPreviewKeepsItAfterCanonicalCreate() async throws {
        let terminal = host.create(type: .terminal, props: .object([:]))
        let (_, view) = try await mirror()
        let first = view.openCode(path: host.root.appendingPathComponent("a.swift").path, lines: LineRange(start: 1, end: 1), beside: terminal.id)
        let before = try #require(view.objects[first.id]?.frame)
        let moved = Frame(x: before.x + 40, y: before.y, w: before.w, h: before.h)
        try view.update(first.id, frame: moved)
        try await eventually { view.objects[first.id] == nil && self.host.objects.values.contains { $0.type == .code && $0.frame == moved } }
        let canonical = try #require(host.objects.values.first { $0.type == .code }?.id)
        let second = view.openCode(path: host.root.appendingPathComponent("b.swift").path, lines: LineRange(start: 2, end: 2), beside: terminal.id)
        #expect(second.created)
        #expect(second.id != canonical)
        #expect(host.objects[canonical]?.props["path"]?.string == "a.swift")
    }

    @Test func theManifestReportsMergedBoardOwnersOnlyWhenPresent() async throws {
        let client = try LineClient(path: socket)
        func manifest(_ params: String = "{}") async throws -> JSONValue {
            client.send(#"{"id":"get","method":"board.get","params":\#(params)}"#)
            let reply = try await client.next()
            #expect(reply["ok"] == .bool(true))
            return try #require(reply["result"])
        }
        #expect(try await manifest()["merged"] == nil)
        host.repo = RepoRecord(commonDir: dir.appendingPathComponent("root/.git").path)
        #expect(try await manifest()["merged"] == nil)
        host.repo?.merged = []
        #expect(try await manifest()["merged"] == nil)
        host.repo?.merged = ["brd_old", "brd_second"]
        let current = try await manifest()
        #expect(current["board"] == .string(host.id))
        #expect(current["merged"] == .array(["brd_old", "brd_second"]))
        let legacy = try await manifest(#"{"board":"brd_old","branch":"main"}"#)
        #expect(legacy["board"] == .string(host.id))
        #expect(legacy["merged"] == .array(["brd_old", "brd_second"]))
    }

    @Test func aLegacyBoardAddressUsesTheCurrentBoardForSessionOwnership() async throws {
        host.repo = RepoRecord(commonDir: dir.appendingPathComponent("root/.git").path, merged: ["brd_old"])
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(host.root.path)]))
        let (mirror, board) = try await mirror(board: "brd_old")
        defer { mirror.close() }
        #expect(mirror.boardID == "brd_old")
        #expect(board.id == "brd_old")
        #expect(mirror.sessionBoardID == host.id)
        #expect(mirror.mergedBoards == ["brd_old"])
        #expect(board.objects[terminal.id] == host.objects[terminal.id])
        let added = host.create(type: .terminal, props: .object(["cwd": .string(host.root.path)]))
        try await eventually { board.objects[added.id] == host.objects[added.id] }
    }

    @Test func theViewerShowsTheHostsBoardWholeAndFollowsItsChanges() async throws {
        let long = String(repeating: "word ", count: 120)
        let first = note(long)
        let shape = host.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 400, y: 0, w: 100, h: 80))
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        #expect(board.isRemote)
        // board.get cuts a long note; the viewer reads it whole.
        #expect(board.objects[first.id]?.props["markdown"]?.string == long)
        #expect(board.objects[shape.id] == host.objects[shape.id])

        _ = try host.update(first.id, frame: Frame(x: 50, y: 60, w: 280, h: 200))
        try await eventually { board.objects[first.id]?.frame.x == 50 }
        #expect(board.objects[first.id]?.rev == host.objects[first.id]?.rev)
        try host.delete(shape.id)
        try await eventually { board.objects[shape.id] == nil }
        let added = note("new on the host", at: 900)
        try await eventually { board.objects[added.id] != nil }
    }

    @Test func htmlArrivesWholeWithoutChangingTheHostAndFollowsUpdates() async throws {
        let pages = ["", "(12 bytes, use object.get)", "<main>" + String(repeating: "live page ", count: 100) + "</main>"]
        let objects = pages.map { html in
            host.create(type: .html, props: .object(["html": .string(html), "state": .object(["choice": .string("kept")])]),
                        frame: Frame(x: 0, y: 0, w: 600, h: 400))
        }
        let original = host.objects
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        #expect(host.objects == original)
        for object in objects { #expect(board.objects[object.id] == object) }
        let page = objects[2]
        _ = try host.update(page.id, props: .object(["html": .string("<h1>Changed on the host</h1>")]))
        try await eventually { board.objects[page.id] == host.objects[page.id] }
        #expect(board.objects[page.id]?.props["state"]?["choice"] == .string("kept"))

        server.stop()
        try await eventually { mirror.state != .online }
        _ = try host.update(page.id, props: .object(["html": .string("<h1>Changed while disconnected</h1>")]))
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { board.objects[page.id] == host.objects[page.id] }
        #expect(board.objects[page.id]?.type == .html)
    }

    @Test func htmlDeletedBetweenTheManifestAndContentReadIsNotShown() async throws {
        let page = host.create(type: .html, props: .object(["html": .string("<h1>Deleted during load</h1>")]),
                               frame: Frame(x: 0, y: 0, w: 600, h: 400))
        server.stop()
        let once = Once()
        once.body = { [unowned self] in try? host.delete(page.id) }
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            if request["method"]?.string == "board.get" { await once.run() }
            return reply
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        #expect(board.objects[page.id] == nil)
        #expect(host.objects[page.id] == nil)
    }

    @Test func unreadableHtmlFailsTheReadRatherThanShowingItsSummary() async throws {
        _ = host.create(type: .html, props: .object(["html": .string("<h1>Must arrive whole</h1>")]),
                        frame: Frame(x: 0, y: 0, w: 600, h: 400))
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "object.get" {
                return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                "error": .object(["code": .string("unavailable"), "message": .string("content read failed")])])
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        do {
            _ = try await mirror()
            Issue.record("a failed content read must not install summarized HTML")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "unavailable")
            #expect(failure.message == "content read failed")
        }
        #expect(mirrors.last?.board == nil)
        for mirror in mirrors { mirror.close() }
    }

    @Test func failedHtmlRefreshIsVisibleAndRetryWorksWithoutDroppingTheLink() async throws {
        let page = host.create(type: .html, props: .object(["html": .string("<p>Before</p>")]),
                               frame: Frame(x: 0, y: 0, w: 600, h: 400))
        let other = note("before")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var shownProblem: String?
        mirror.onState = { [weak mirror] _ in shownProblem = mirror?.problem }
        server.stop()
        try await eventually { mirror.state != .online }
        _ = try host.update(page.id, props: .object(["html": .string("<p>After reconnect</p>")]))
        _ = try host.update(other.id, props: .object(["markdown": .string("after reconnect")]))
        let refuse = Locked<String?>("HTML refresh failed")
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "object.get", let message = refuse.withLock({ value in
                defer { value = nil }
                return value
            }) {
                return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                "error": .object(["code": .string("unavailable"), "message": .string(message)])])
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        try await eventually { refuse.withLock { $0 == nil } && mirror.reading == nil }
        #expect(mirror.connection.state == .online)
        #expect(mirror.state == .offline)
        #expect(mirror.problem?.contains("HTML refresh failed") == true)
        #expect(shownProblem?.contains("HTML refresh failed") == true)
        refuse.withLock { $0 = "HTML retry failed differently" }
        mirror.reconnect()
        try await eventually { refuse.withLock { $0 == nil } && mirror.reading == nil }
        #expect(mirror.connection.state == .online)
        #expect(mirror.state == .offline)
        #expect(shownProblem?.contains("HTML retry failed differently") == true)
        mirror.reconnect()
        try await eventually { board.objects[page.id] == host.objects[page.id] && board.objects[other.id] == host.objects[other.id] }
        #expect(mirror.state == .online)
        #expect(shownProblem == nil)
    }

    @Test func aRereadDoesNotInstallAnUnansweredCreationsSecondTile() async throws {
        _ = host.create(type: .html, props: .object(["html": .string("<p>Refresh</p>")]))
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.state != .online }
        let refuse = Locked(true)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "object.get", refuse.withLock({ value in
                defer { value = false }
                return value
            }) {
                return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                "error": .object(["code": .string("unavailable"), "message": .string("Refresh failed")])])
            }
            let response = await router.handle(request, connection: connection)
            if request["method"]?.string == "object.create", let response {
                pending.withLock { $0 = { connection.send(response) } }
                return nil
            }
            return response
        }
        try server.start()
        try await eventually { !refuse.withLock { $0 } && mirror.reading == nil }
        #expect(mirror.connection.state == .online)
        #expect(mirror.state == .offline)
        let provisional = board.create(type: .browser, props: .object(["url": .string("https://popup.example/")]))
        try await eventually { pending.withLock { $0 != nil } }
        let canonical = try #require(host.objects.values.first { $0.type == .browser }?.id)
        mirror.reconnect()
        try await eventually { mirror.state == .online && mirror.reading == nil }
        #expect(board.objects[provisional.id] != nil)
        #expect(board.objects[canonical] == nil, "a snapshot must not construct a second live page before rekey")
        pending.withLock { $0 }?()
        try await eventually { board.objects[provisional.id] == nil && board.objects[canonical] == host.objects[canonical] }
    }

    @Test func htmlRefreshFailureDoesNotPreventClientAttachmentOrTerminalPrompts() async throws {
        let page = host.create(type: .html, props: .object(["html": .string("<p>Before</p>")]),
                               frame: Frame(x: 0, y: 0, w: 600, h: 400))
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": "worker"])).id
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.state != .online }
        _ = try host.update(page.id, props: .object(["html": .string("<p>After reconnect</p>")]))
        let easld = Easld()
        let failure = Locked<String?>("HTML refresh failed")
        host.repo = RepoRecord(commonDir: dir.appendingPathComponent("root/.git").path, merged: ["brd_old"])
        let added = host.create(type: .terminal, props: .object(["cwd": .string(host.root.path)]))
        var ownershipAtCreation: [BoardID]?
        board.onEvent = { [weak mirror] event in
            if case .objectCreated(let object) = event, object.id == added.id {
                ownershipAtCreation = mirror?.mergedBoards
            }
        }
        try serveEasld(easld, refusingHtml: failure)
        try await eventually { failure.withLock { $0 == nil } && mirror.reading == nil }
        #expect(mirror.state == .offline)
        #expect(mirror.problem?.contains("HTML refresh failed") == true)
        #expect(board.objects[page.id]?.props["html"] == .string("<p>Before</p>"))
        var pasted: [String] = []
        mirror.serve(window(submit: { id, text in
            pasted.append("\(id): \(text)")
            return true
        }), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        try await mirror.prompt("still connected", to: agent, mentions: [], answer: false)
        #expect(pasted == ["\(agent): still connected"])
        #expect(mirror.state == .offline)
        mirror.reconnect()
        try await eventually { board.objects[page.id] == host.objects[page.id] && mirror.state == .online }
        #expect(mirror.problem == nil)
        #expect(board.objects[added.id] == host.objects[added.id])
        #expect(ownershipAtCreation == ["brd_old"])
        #expect(mirror.mergedBoards == ["brd_old"])
        #expect(board.repo == nil)
        #expect(mirror.attachment == .attached(client: "cli_1", version: 1))
        #expect(easld.attaches.count == 1)
    }

    @Test func aMoveShowsAtOnceAndTheHostsVersionReplacesIt() async throws {
        let moved = note("drag me")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 40, w: 280, h: 200))
        #expect(board.objects[moved.id]?.frame.x == 300)
        try await eventually { host.objects[moved.id]?.frame.x == 300 }
        try await eventually { board.objects[moved.id] == host.objects[moved.id] }
        // And the other way.
        _ = try host.update(moved.id, frame: Frame(x: 10, y: 10, w: 280, h: 200))
        try await eventually { board.objects[moved.id]?.frame.x == 10 }
    }

    @Test func anEditThatCrossedTheHostsIsRefusedAndTheHostsTextComesBack() async throws {
        let edited = note("before")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        // Nothing can arrive between these two: the viewer's edit is based on the old revision.
        _ = try host.update(edited.id, props: .object(["markdown": .string("the host's")]))
        _ = try board.update(edited.id, props: .object(["markdown": .string("the viewer's")]))
        #expect(board.objects[edited.id]?.props["markdown"]?.string == "the viewer's")
        try await eventually { board.objects[edited.id]?.props["markdown"]?.string == "the host's" }
        #expect(host.objects[edited.id]?.props["markdown"]?.string == "the host's")
        #expect(notices.count == 1 && notices[0].contains("changed on home meanwhile"))
    }

    @Test func createsAndDeletesGoToTheHost() async throws {
        let doomed = note("delete me")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        let provisional = board.create(type: .note, props: .object(["markdown": .string("from the viewer")]), frame: Frame(x: 600, y: 0, w: 280, h: 200))
        _ = try board.update(provisional.id, frame: Frame(x: 640, y: 20, w: 280, h: 200))
        try board.delete(doomed.id)
        #expect(board.objects[doomed.id] == nil)
        try await eventually { host.objects[doomed.id] == nil }
        func made() -> [CanvasObject] { host.objects.values.filter { $0.props["markdown"]?.string == "from the viewer" } }
        try await eventually { made().first?.frame.x == 640 }
        #expect(made().count == 1)
        let created = try #require(made().first)
        // The provisional object made way for the host's, under the host's id.
        try await eventually { board.objects[provisional.id] == nil && board.objects[created.id] == created }
        #expect(board.objects.values.filter { $0.props["markdown"]?.string == "from the viewer" }.count == 1)
    }

    @Test func theAppsWriteBacksStayWithTheHost() async throws {
        let anchored = note("plain")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(anchored.id, props: .object(["markdown": .string("rewritten by the app")]), actor: .system)
        #expect(board.objects[anchored.id]?.props["markdown"]?.string == "plain")
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.objects[anchored.id]?.props["markdown"]?.string == "plain")
    }

    /// Typed even into an omp that takes peer messages (`protocol`): the composer's prompt is never queued as one.
    @Test func theComposersPromptIsTypedOnTheHostAndAnswersABlockedAgent() async throws {
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": .string("worker")])).id
        try host.reportLifecycle(tile: agent, kind: "omp", state: .idle, message: nil, seq: 1, source: nil, protocol: 1)
        let (mirror, _) = try await mirror()
        defer { mirror.close() }
        try await mirror.prompt("fix the build", to: agent, mentions: [], answer: false)
        #expect(typed[agent] == ["fix the build"])
        #expect(host.messages[agent]?.isEmpty ?? true)
        try host.reportLifecycle(tile: agent, kind: "omp", state: .blocked, message: "Run tests?", seq: 2, source: nil, protocol: 1)
        await #expect(throws: ApiRouter.Failure.self) { try await mirror.prompt("more", to: agent, mentions: [], answer: false) }
        try await mirror.prompt("yes", to: agent, mentions: [], answer: true)
        #expect(typed[agent] == ["fix the build", "yes"])
    }

    @Test func theHostChecksComposerParamsBeforeAnythingElse() async throws {
        let client = try LineClient(path: socket)
        for params in [
            #"{"target":"nobody","text":"x","answer":true}"#,
            #"{"target":"nobody","text":"x","composer":true,"caller":"obj_1"}"#,
            #"{"target":"nobody","text":"x","composer":true,"force":true}"#,
            #"{"target":"nobody","text":"x","composer":true,"from":"machine-watch"}"#,
            #"{"target":"nobody","text":"x","composer":true,"when":"next-turn"}"#,
        ] {
            client.send(#"{"id":"1","method":"agent.prompt","params":\#(params)}"#)
            let reply = try await client.next()
            #expect(reply["error"]?["code"]?.string == "invalid_params")
        }
        client.send(#"{"id":"2","method":"view.render","params":{"target":"nobody","inline":true,"out":"/tmp/x.png"}}"#)
        #expect(try await client.next()["error"]?["code"]?.string == "invalid_params")
    }

    @Test func backOnlineTheViewerCatchesUpWithWhatChangedMeanwhile() async throws {
        let kept = note("kept")
        let gone = note("gone", at: 400)
        host.repo = RepoRecord(commonDir: dir.appendingPathComponent("root/.git").path,
                               merged: ["brd_old", "obj_other", "brd_bad_id", "brd_old\n", ""])
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(host.root.path)]))
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        #expect(mirror.boardID == host.id)
        #expect(mirror.mergedBoards == ["brd_old"])
        #expect(board.objects[terminal.id] == host.objects[terminal.id])
        #expect(board.repo == nil, "a remote board must not acquire the host's local repository state")
        var ownershipAtCreation: [ObjectID: [BoardID]] = [:]
        board.onEvent = { [weak mirror] event in
            guard let mirror else { return }
            if case .objectCreated(let object) = event, object.type == .terminal {
                ownershipAtCreation[object.id] = mirror.mergedBoards
            }
        }
        var states: [EaslConnection.State] = []
        mirror.onState = { states.append($0) }
        server.stop()
        try await eventually { mirror.state != .online }
        try host.delete(gone.id)
        _ = try host.update(kept.id, props: .object(["markdown": .string("changed while away")]))
        host.repo?.merged = ["brd_old", "brd_second"]
        let added = host.create(type: .terminal, props: .object(["cwd": .string(host.root.path)]), frame: Frame(x: 800, y: 0, w: 400, h: 300))
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.state == .online }
        try await eventually { board.objects[gone.id] == nil && board.objects[added.id] != nil && board.objects[kept.id] == host.objects[kept.id] }
        #expect(states.last == .online && states.contains { $0 != .online })
        #expect(mirror.mergedBoards == ["brd_old", "brd_second"])
        #expect(ownershipAtCreation == [added.id: ["brd_old", "brd_second"]])
        #expect(board.repo == nil)

        server.stop()
        try await eventually { mirror.state != .online }
        host.repo?.merged = nil
        let withoutHistory = host.create(type: .terminal, props: .object(["cwd": .string(host.root.path)]), frame: Frame(x: 1300, y: 0, w: 400, h: 300))
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { board.objects[withoutHistory.id] == host.objects[withoutHistory.id] }
        #expect(mirror.mergedBoards == [])
        #expect(ownershipAtCreation == [added.id: ["brd_old", "brd_second"], withoutHistory.id: []])
    }

    /// Runs `body` once, on the main actor (a test's host changes, from a server's handler).
    @MainActor final class Once {
        var body: (() -> Void)?
        func run() {
            body?()
            body = nil
        }
    }

    @Test func whatTheHostChangesWhileTheViewerReadsItAgainStays() async throws {
        let edited = host.create(type: .html, props: .object(["html": .string("<p>Before</p>")]),
                                 frame: Frame(x: 0, y: 0, w: 600, h: 400))
        let doomed = note("doomed", at: 400)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.state != .online }
        // The read after the drop is answered with the board as it was, after the host changed
        // it: the changes' events reach the viewer ahead of that answer.
        var created: ObjectID?
        let once = Once()
        once.body = { [unowned self] in
            _ = try? host.update(edited.id, props: .object(["html": .string("<p>Changed during the read</p>")]))
            try? host.delete(doomed.id)
            created = note("created during the read", at: 800).id
        }
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            if request["method"]?.string == "board.get" { await once.run() }
            return reply
        }
        try server.start()
        try await eventually { once.body == nil }
        try await eventually { mirror.reading == nil }
        let added = try #require(created)
        // The events left the host ahead of the read's answer, but the mirror's event listener and
        // its read are two tasks on the main actor: on a loaded machine the answer can be handled
        // first, and the events after it. Either way the board ends as the host's, never with the
        // read's older state undoing them.
        try await eventually {
            board.objects[edited.id] == host.objects[edited.id] && board.objects[doomed.id] == nil && board.objects[added] == host.objects[added]
        }
        #expect(board.objects[edited.id]?.props["html"]?.string == "<p>Changed during the read</p>")
    }

    @Test func queuedWritesKeepTheHostRevisionTheyWereBasedOn() async throws {
        let moved = note("moved")
        let edited = note("edited", at: 400)
        let chained = note("chained", at: 800)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        // Nothing reaches the host before the host's own edits below: each viewer write is based
        // on the revision before them.
        // A move, then an edit made on its preview; the host's edit crossed both.
        _ = try board.update(moved.id, frame: Frame(x: 0, y: 300, w: 280, h: 200))
        _ = try board.update(moved.id, props: .object(["markdown": .string("the viewer's")]))
        _ = try host.update(moved.id, props: .object(["markdown": .string("the host's")]))
        // Two edits, the second made on the first's preview; the host's crossed both.
        _ = try board.update(edited.id, props: .object(["markdown": .string("first")]))
        _ = try board.update(edited.id, props: .object(["markdown": .string("second")]))
        _ = try host.update(edited.id, props: .object(["markdown": .string("the host's")]))
        // A move and an edit nobody crossed: the edit builds on the answered move.
        _ = try board.update(chained.id, frame: Frame(x: 800, y: 300, w: 280, h: 200))
        _ = try board.update(chained.id, props: .object(["markdown": .string("after the move")]))
        try await eventually { notices.count == 3 && host.objects[chained.id]?.props["markdown"]?.string == "after the move" }
        #expect(notices.allSatisfy { $0.contains("changed on home meanwhile") })
        #expect(host.objects[moved.id]?.frame.y == 300)
        #expect(host.objects[moved.id]?.props["markdown"]?.string == "the host's")
        #expect(host.objects[edited.id]?.props["markdown"]?.string == "the host's")
        #expect(host.objects[chained.id]?.frame.y == 300)
        try await eventually { [moved, edited, chained].allSatisfy { board.objects[$0.id] == host.objects[$0.id] } }
    }

    @Test func aNewObjectGoesOnUnderTheHostsIDWithWhatTheUserHadGoingOnIt() async throws {
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var swaps: [(provisional: ObjectID, host: ObjectID)] = []
        board.onHostRekey = { provisional, id in
            // Heard while the provisional note is still here, so its open editor can be taken over.
            #expect(board.objects[provisional] != nil && board.objects[id] == nil)
            swaps.append((provisional, id))
        }
        let provisional = board.create(type: .note, props: .object(["markdown": .string("")]), frame: Frame(x: 0, y: 300, w: 280, h: 200))
        _ = try board.update(provisional.id, frame: Frame(x: 40, y: 320, w: 280, h: 200))
        try await eventually { swaps.count == 1 }
        let id = try #require(swaps.first).host
        #expect(swaps.first?.provisional == provisional.id)
        // The preview, the move queued behind the create included, goes on under the host's id.
        #expect(board.objects[provisional.id] == nil)
        #expect(board.objects[id]?.frame.x == 40)
        // The note's draft, saved under the host's id once editing ends, reaches the host.
        _ = try board.update(id, props: .object(["markdown": .string("typed before the host answered")]))
        try await eventually { host.objects[id]?.props["markdown"]?.string == "typed before the host answered" && host.objects[id]?.frame.x == 40 }
        try await eventually { board.objects[id] == host.objects[id] }
        #expect(host.objects.values.filter { $0.type == .note }.count == 1)
    }

    @Test func closingAndReopeningKeepsTheLastSeenBoardAndResumesPrompts() async throws {
        let edited = note("last seen")
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)]))
        let easld = Easld()
        easld.clients = [client("mch_01STUDIO", serving: host.id)]
        try serveEasld(easld)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var pasted: [String] = []
        mirror.serve(window(submit: { id, text in
            pasted.append("\(id): \(text)")
            return true
        }), as: identity)
        try await eventually {
            mirror.attachment == .attached(client: "cli_1", version: 1) && mirror.drawingMachines == ["mch_01STUDIO"]
        }
        try await mirror.prompt("before close", to: terminal.id, mentions: [], answer: false)
        let served = try #require(mirror.serving)
        var availability: [BoardMirror.Availability] = []
        var closedObjects: [ObjectID: CanvasObject]?
        mirror.onAvailability = { [weak mirror] in
            availability.append($0)
            if $0 == .closed {
                closedObjects = board.objects
                #expect(mirror?.attachment == .waiting)
            }
        }
        var redraws = 0
        mirror.onRedraw = { redraws += 1 }
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        #expect(closedObjects == [edited.id: edited, terminal.id: terminal])
        #expect(board.objects == closedObjects)
        #expect(mirror.connection.state == .online)
        #expect(mirror.attachment == .waiting)
        #expect(mirror.drawingMachines == nil)
        #expect(mirror.serving == nil, "a stream opened for this board's calls ends with it")
        _ = try board.update(edited.id, props: .object(["markdown": "must not be sent"]))
        try board.delete(terminal.id)
        let provisional = board.create(type: .note, props: .object(["markdown": "must not be created"]))
        #expect(board.objects[edited.id] == edited)
        #expect(board.objects[terminal.id] == terminal)
        #expect(board.objects[provisional.id] == nil)
        mirror.userFocused()
        await #expect(throws: ApiRouter.Failure.self) {
            try await mirror.prompt("while closed", to: terminal.id, mentions: [], answer: false)
        }
        await #expect(throws: ApiRouter.Failure.self) { _ = try await mirror.reloadDiagram(edited.id) }
        easld.call("agent.prompt", .object(["target": .string(terminal.id), "text": "late delegated prompt"])) { _ in }
        try await eventually { easld.answers.count == 2 }
        #expect(easld.answers.last?["error"]?["code"] == .string("unavailable"))
        #expect(pasted == ["\(terminal.id): before close"])
        #expect(easld.prompts.count == 1)
        #expect(easld.attaches.count == 1)
        let reopened = registry.open(root: host.root)
        _ = try reopened.update(edited.id, props: .object(["markdown": "after reopen"]))
        try await eventually {
            mirror.availability == .open && mirror.attachment == .attached(client: "cli_1", version: 1)
                && board.objects[edited.id] == reopened.objects[edited.id] && mirror.drawingMachines == ["mch_01STUDIO"]
        }
        try await mirror.prompt("after reopen", to: terminal.id, mentions: [], answer: false)
        #expect(pasted == ["\(terminal.id): before close", "\(terminal.id): after reopen"])
        #expect(board.objects[edited.id]?.props["markdown"] == .string("after reopen"))
        #expect(board.objects.count == 2)
        #expect(availability == [.closed, .open])
        #expect(easld.attaches.count == 2)
        #expect(mirror.serving != nil && mirror.serving != served, "the reopened board is another incarnation")
        try await eventually { redraws == 1 }
    }

    @Test func aCloseDuringARefreshRejectsItsLateManifest() async throws {
        let edited = note("last seen")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.connection.state == .offline }
        _ = try host.update(edited.id, props: .object(["markdown": "stale refresh"]))
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let held = Locked(false)
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            if request["method"]?.string == "board.get", let reply,
               held.withLock({ value in
                   guard !value else { return false }
                   value = true
                   return true
               }) {
                pending.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            return reply
        }
        try server.start()
        try await eventually { pending.withLock { $0 != nil } }
        #expect(mirror.reading != nil)
        let final = try host.update(edited.id, props: .object(["markdown": "received before close"]))
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        pending.withLock { $0 }?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(mirror.availability == .closed)
        #expect(board.objects[edited.id] == final)
        let reopened = registry.open(root: host.root)
        _ = try reopened.update(edited.id, props: .object(["markdown": "fresh reopen"]))
        try await eventually { mirror.availability == .open && board.objects[edited.id] == reopened.objects[edited.id] }
        #expect(board.objects[edited.id]?.props["markdown"] == .string("fresh reopen"))
    }

    @Test func aCloseDuringHtmlExpansionDoesNotDeleteTheLastSeenPage() async throws {
        let page = host.create(type: .html, props: .object(["html": "<p>Last seen</p>"]))
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.connection.state == .offline }
        _ = try host.update(page.id, props: .object(["html": "<p>During refresh</p>"]))
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let held = Locked(false)
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "object.get",
               held.withLock({ value in
                   guard !value else { return false }
                   value = true
                   return true
               }) {
                let reply: JSONValue = .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                               "error": .object(["code": "not_found", "message": "board closed"])])
                pending.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        try await eventually { pending.withLock { $0 != nil } }
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        pending.withLock { $0 }?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(board.objects[page.id] == page)
        #expect(mirror.availability == .closed)
        let reopened = registry.open(root: host.root)
        _ = try reopened.update(page.id, props: .object(["html": "<p>Reopened whole</p>"]))
        try await eventually { mirror.availability == .open && board.objects[page.id] == reopened.objects[page.id] }
        #expect(board.objects[page.id]?.props["html"] == .string("<p>Reopened whole</p>"))
    }

    @Test(arguments: ["object.create", "object.update", "object.delete"])
    func aCloseDiscardsPendingWritesAndRejectsLateNotFound(_ method: String) async throws {
        let edited = note("last seen")
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let writes = Locked<[JSONValue]>([])
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == method {
                let first = writes.withLock { log in
                    log.append(request["params"] ?? .null)
                    return log.count == 1
                }
                if first {
                    let reply: JSONValue = .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                                   "error": .object(["code": "not_found", "message": "board closed"])])
                    pending.withLock { $0 = { connection.send(reply) } }
                    return nil
                }
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var provisional: ObjectID?
        switch method {
        case "object.create":
            let object = board.create(type: .note, props: .object(["markdown": "pending create"]))
            provisional = object.id
            _ = try board.update(object.id, props: .object(["markdown": "queued after create"]))
        case "object.update":
            _ = try board.update(edited.id, props: .object(["markdown": "pending update"]))
            _ = try board.update(edited.id, props: .object(["markdown": "queued update"]))
        default:
            try board.delete(edited.id)
        }
        try await eventually { pending.withLock { $0 != nil } }
        #expect(board.objects[edited.id] != edited || provisional != nil)
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        #expect(board.objects == [edited.id: edited])
        if let provisional { #expect(board.objects[provisional] == nil) }
        pending.withLock { $0 }?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(board.objects == [edited.id: edited])
        #expect(writes.withLock { $0.count } == 1)
        let reopened = registry.open(root: host.root)
        try await eventually { mirror.availability == .open }
        _ = try board.update(edited.id, props: .object(["markdown": "new lifetime write"]))
        try await eventually { reopened.objects[edited.id]?.props["markdown"] == .string("new lifetime write") }
        try await eventually { board.objects[edited.id] == reopened.objects[edited.id] }
        #expect(board.objects.count == 1)
    }

    @Test func closingDuringAttachCannotAcceptItsLateAnswerOrRefocus() async throws {
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)]))
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let attaches = Locked<[JSONValue]>([])
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            guard request["method"]?.string == "client.attach" else { return await router.handle(request, connection: connection) }
            let first = attaches.withLock { log in
                log.append(request["params"] ?? .null)
                return log.count == 1
            }
            let reply: JSONValue = .object(["id": request["id"] ?? .null, "ok": .bool(true),
                                           "result": .object(["client": "cli_1", "version": 1])])
            if first {
                pending.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            return reply
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        mirror.serve(window(), as: identity)
        try await eventually { pending.withLock { $0 != nil } }
        mirror.userFocused()
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        mirror.userFocused()
        pending.withLock { $0 }?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(mirror.attachment == .waiting)
        #expect(attaches.withLock { $0.count } == 1)
        #expect(board.objects[terminal.id] == terminal)
        _ = registry.open(root: host.root)
        try await eventually { mirror.availability == .open && mirror.attachment == .attached(client: "cli_1", version: 1) }
        try await mirror.prompt("after attachment recovered", to: terminal.id, mentions: [], answer: false)
        #expect(typed[terminal.id] == ["after attachment recovered"])
        #expect(attaches.withLock { $0.count } == 2)
        #expect(attaches.withLock { $0.last?["focused"] } == nil)
    }

    @Test(arguments: [true, false])
    func aClosedBoardRefreshesBeforeReattachingAfterConnectionLoss(_ reopenWhileOffline: Bool) async throws {
        let edited = note("last seen")
        let gone = note("removed after reopen", at: 400)
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)]))
        let easld = Easld()
        try serveEasld(easld)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var pasted: [String] = []
        mirror.serve(window(submit: { _, text in
            pasted.append("\(text): \(board.objects[edited.id]?.props["markdown"]?.string ?? "missing")")
            return true
        }), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        server.stop()
        try await eventually { mirror.connection.state == .offline }
        if !reopenWhileOffline {
            try serveEasld(easld)
            try await eventually { mirror.connection.state == .online && mirror.reading == nil }
            #expect(mirror.availability == .closed)
            #expect(mirror.attachment == .waiting)
            #expect(easld.attaches.count == 1)
        }
        let reopened = registry.open(root: host.root)
        _ = try reopened.update(edited.id, props: .object(["markdown": "fresh after reconnect"]))
        try reopened.delete(gone.id)
        let added = reopened.create(type: .note, props: .object(["markdown": "created after reopen"]))
        if reopenWhileOffline { try serveEasld(easld) }
        try await eventually {
            mirror.availability == .open && mirror.attachment == .attached(client: "cli_1", version: 1)
                && board.objects[edited.id] == reopened.objects[edited.id] && board.objects[gone.id] == nil
                && board.objects[added.id] == added
        }
        try await mirror.prompt("reconnected", to: terminal.id, mentions: [], answer: false)
        #expect(pasted == ["reconnected: fresh after reconnect"])
        #expect(board.objects.count == 3)
        #expect(easld.attaches.count == 2)
    }

    @Test func aLoadedBoardMissingAfterReconnectIsClosedButAnInitialMissThrows() async throws {
        let edited = note("last seen")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.connection.state == .offline }
        try registry.close(host.id)
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.connection.state == .online && mirror.availability == .closed }
        #expect(board.objects[edited.id] == edited)
        do {
            _ = try await self.mirror()
            Issue.record("an initial board.get not_found must fail load")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "not_found")
        }
        for unloaded in mirrors where unloaded.board == nil { unloaded.close() }
        let reopened = registry.open(root: host.root)
        _ = try reopened.update(edited.id, props: .object(["markdown": "present again"]))
        try await eventually { mirror.availability == .open && board.objects[edited.id] == reopened.objects[edited.id] }
        #expect(board.objects[edited.id]?.props["markdown"] == .string("present again"))
    }

    @Test(arguments: [true, false])
    func aWriteNotFoundDistinguishesAClosedBoardFromADeletedObject(_ closeBoard: Bool) async throws {
        let edited = note("last seen")
        let kept = note("kept", at: 400)
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)]))
        let once = Once()
        once.body = { [unowned self] in
            if closeBoard {
                try? registry.close(host.id)
            } else {
                try? host.delete(edited.id)
            }
        }
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "events.subscribe" {
                var params = request["params"]?.object ?? [:]
                params["events"] = .array(["board.opened", "object.created", "object.updated"])
                return await router.handle(request.merging(.object(["params": .object(params)])), connection: connection)
            }
            if request["method"]?.string == "object.update" { await once.run() }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        try await mirror.prompt("before refusal", to: terminal.id, mentions: [], answer: false)
        _ = try board.update(edited.id, props: .object(["markdown": "refused write"]))
        if closeBoard {
            try await eventually { mirror.availability == .closed }
            #expect(board.objects[edited.id] == edited)
            #expect(board.objects[kept.id] == kept)
            await #expect(throws: ApiRouter.Failure.self) {
                try await mirror.prompt("closed refusal", to: terminal.id, mentions: [], answer: false)
            }
        } else {
            try await eventually { board.objects[edited.id] == nil }
            #expect(mirror.availability == .open)
            #expect(board.objects[kept.id] == kept)
            try await mirror.prompt("after object deletion", to: terminal.id, mentions: [], answer: false)
            #expect(typed[terminal.id] == ["before refusal", "after object deletion"])
        }
        if closeBoard {
            #expect(typed[terminal.id] == ["before refusal"])
            let reopened = registry.open(root: host.root)
            _ = try reopened.update(edited.id, props: .object(["markdown": "restored lifetime"]))
            try await eventually { mirror.availability == .open && board.objects[edited.id] == reopened.objects[edited.id] }
            #expect(board.objects[edited.id]?.props["markdown"] == .string("restored lifetime"))
        }
    }

    @Test func aClosedHostWindowRemainsClosedAfterARefreshUntilItsHostReopensIt() async throws {
        let edited = note("last seen")
        let reads = Locked(0)
        let router = router
        server.stop()
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "board.get" { reads.withLock { $0 += 1 } }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        registry.setWindowOpen(false, board: host.id)
        try await eventually { mirror.availability == .closed }
        _ = try host.update(edited.id, props: .object(["markdown": "agent changed it while hidden"]))
        let before = reads.withLock { $0 }
        mirror.reconnect()
        try await eventually { reads.withLock { $0 > before } && mirror.reading == nil }
        #expect(mirror.availability == .closed)
        #expect(board.objects[edited.id] == edited)
        let initiallyClosed = BoardMirror(hostName: "home", board: host.id, connection: .unixSocket(socket), renders: .unixSocket(socket))
        defer { initiallyClosed.close() }
        await #expect(throws: ApiRouter.Failure.self) { _ = try await initiallyClosed.load() }
        _ = registry.open(root: host.root)
        try await eventually { mirror.availability == .open && board.objects[edited.id] == host.objects[edited.id] }
        #expect(board.objects[edited.id]?.props["markdown"] == "agent changed it while hidden")
    }

    @Test func aReopenedBoardsHtmlFailureOffersRefreshInsteadOfStayingClosed() async throws {
        let page = host.create(type: .html, props: .object(["html": "<p>Last seen</p>"]))
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)]))
        let failure = Locked<String?>(nil)
        let easld = Easld()
        try serveEasld(easld, refusingHtml: failure)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var pasted: [String] = []
        mirror.serve(window(submit: { _, text in pasted.append(text); return true }), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        failure.withLock { $0 = "HTML reopen failed" }
        let reopened = registry.open(root: host.root)
        _ = try reopened.update(page.id, props: .object(["html": "<p>Reopened</p>"]))
        try await eventually { mirror.reading == nil && mirror.problem != nil }
        #expect(mirror.availability == .open)
        #expect(mirror.state == .offline)
        mirror.reconnect()
        try await eventually { mirror.state == .online }
        #expect(board.objects[page.id] == reopened.objects[page.id])
        try await mirror.prompt("after retry", to: terminal.id, mentions: [], answer: false)
        #expect(pasted == ["after retry"])
    }

    @Test func reopeningWaitsForTheWholeReadAndReplaysChangesBeforeAttaching() async throws {
        let edited = note("last seen")
        let terminal = host.create(type: .terminal, props: .object(["cwd": .string(dir.path)]))
        let holdRead = Locked(false)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let attaches = Locked(0)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "client.attach" {
                attaches.withLock { $0 += 1 }
                return .object(["id": request["id"] ?? .null, "ok": .bool(true),
                                "result": .object(["client": "cli_1", "version": 1])])
            }
            let reply = await router.handle(request, connection: connection)
            if request["method"]?.string == "board.get", let reply,
               holdRead.withLock({ value in
                   defer { value = false }
                   return value
               }) {
                pending.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            return reply
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        mirror.serve(window(), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        holdRead.withLock { $0 = true }
        let reopened = registry.open(root: host.root)
        try await eventually { pending.withLock { $0 != nil } }
        _ = try reopened.update(edited.id, props: .object(["markdown": "changed during reopen read"]))
        #expect(mirror.availability == .closed)
        #expect(board.objects[edited.id] == edited)
        #expect(mirror.attachment == .waiting)
        #expect(attaches.withLock { $0 } == 1)
        await #expect(throws: ApiRouter.Failure.self) {
            try await mirror.prompt("before refresh", to: terminal.id, mentions: [], answer: false)
        }
        pending.withLock { $0 }?()
        try await eventually {
            mirror.availability == .open && mirror.attachment == .attached(client: "cli_1", version: 1)
                && board.objects[edited.id] == reopened.objects[edited.id]
        }
        try await mirror.prompt("after refresh", to: terminal.id, mentions: [], answer: false)
        #expect(board.objects[edited.id]?.props["markdown"] == .string("changed during reopen read"))
        #expect(typed[terminal.id] == ["after refresh"])
        #expect(attaches.withLock { $0 } == 2)
    }

    @Test func aCloseDuringAnUnfinishedReopenDiscardsHeldObjects() async throws {
        let edited = note("last seen")
        let holdRead = Locked(false)
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let attaches = Locked(0)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "client.attach" {
                attaches.withLock { $0 += 1 }
                return .object(["id": request["id"] ?? .null, "ok": .bool(true),
                                "result": .object(["client": "cli_1", "version": 1])])
            }
            let reply = await router.handle(request, connection: connection)
            if request["method"]?.string == "board.get", let reply,
               holdRead.withLock({ value in
                   defer { value = false }
                   return value
               }) {
                pending.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            return reply
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        mirror.serve(window(), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        var availability: [BoardMirror.Availability] = []
        mirror.onAvailability = { availability.append($0) }
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        let lastSeen = board.objects
        holdRead.withLock { $0 = true }
        let unfinished = registry.open(root: host.root)
        try await eventually { pending.withLock { $0 != nil } }
        #expect(mirror.reading != nil)
        let terminal = unfinished.create(type: .terminal, props: .object(["cwd": .string(dir.path)]))
        _ = try unfinished.update(edited.id, props: .object(["markdown": "unfinished reopen"]))
        try registry.close(unfinished.id)
        try await eventually { mirror.reading == nil }
        #expect(board.objects == lastSeen)
        #expect(board.objects == [edited.id: edited])
        #expect(mirror.availability == .closed)
        #expect(availability == [.closed])
        #expect(mirror.attachment == .waiting)
        #expect(attaches.withLock { $0 } == 1)
        pending.withLock { $0 }?()
        _ = try? await mirror.connection.request("board.get", .object(["board": .string(host.id)]))
        #expect(board.objects == lastSeen)
        #expect(availability == [.closed])
        #expect(mirror.attachment == .waiting)
        #expect(attaches.withLock { $0 } == 1)
        let reopened = registry.open(root: host.root)
        let fresh = try reopened.update(edited.id, props: .object(["markdown": "proper reopen"]))
        try await eventually {
            mirror.availability == .open && mirror.attachment == .attached(client: "cli_1", version: 1)
                && board.objects[edited.id]?.props == fresh.props && board.objects[terminal.id]?.props == terminal.props
        }
        #expect(Set(board.objects.keys) == Set([edited.id, terminal.id]))
        #expect(board.objects[terminal.id]?.type == .terminal)
        #expect(availability == [.closed, .open])
        #expect(attaches.withLock { $0 } == 2)
    }

    @Test func reopeningSupersedesAnOlderPendingBoardNotFound() async throws {
        let edited = note("last seen")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        server.stop()
        try await eventually { mirror.connection.state == .offline }
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let held = Locked(false)
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            if request["method"]?.string == "board.get", let reply,
               held.withLock({ value in
                   guard !value else { return false }
                   value = true
                   return true
               }) {
                pending.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            return reply
        }
        try server.start()
        try await eventually { pending.withLock { $0 != nil } }
        let reopened = registry.open(root: host.root)
        _ = try reopened.update(edited.id, props: .object(["markdown": "new lifetime"]))
        try await eventually { mirror.availability == .open && board.objects[edited.id] == reopened.objects[edited.id] }
        pending.withLock { $0 }?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(mirror.availability == .open)
        #expect(board.objects[edited.id]?.props["markdown"] == .string("new lifetime"))
    }

    @Test func aLegacyAddressHearsCanonicalReopeningAfterReconnectingWhileClosed() async throws {
        host.repo = RepoRecord(commonDir: dir.appendingPathComponent("root/.git").path, merged: ["brd_old"])
        let edited = note("last seen")
        let (mirror, board) = try await mirror(board: "brd_old")
        defer { mirror.close() }
        #expect(mirror.sessionBoardID == host.id)
        var availability: [BoardMirror.Availability] = []
        mirror.onAvailability = { availability.append($0) }
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed }
        server.stop()
        try await eventually { mirror.connection.state == .offline }
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.connection.state == .online && mirror.reading == nil }
        #expect(mirror.availability == .closed)
        #expect(board.objects[edited.id] == edited)
        let reopened = registry.open(root: host.root)
        _ = try reopened.update(edited.id, props: .object(["markdown": "canonical reopen"]))
        try await eventually { mirror.availability == .open && board.objects[edited.id] == reopened.objects[edited.id] }
        #expect(board.id == "brd_old")
        #expect(mirror.sessionBoardID == host.id)
        #expect(board.objects[edited.id]?.props["markdown"] == .string("canonical reopen"))
        #expect(availability == [.closed, .open])
    }

    @Test func anUnreadableBoardAfterAWriteNotFoundPreservesObjectsUntilRefresh() async throws {
        let edited = note("last seen")
        let kept = note("kept", at: 400)
        let once = Once()
        once.body = { [unowned self] in try? host.delete(edited.id) }
        let refuseRead = Locked(false)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"]?.string == "events.subscribe" {
                var params = request["params"]?.object ?? [:]
                params["events"] = .array(["board.closed", "board.opened", "object.created", "object.updated"])
                return await router.handle(request.merging(.object(["params": .object(params)])), connection: connection)
            }
            if request["method"]?.string == "object.update" {
                await once.run()
                refuseRead.withLock { $0 = true }
            }
            if request["method"]?.string == "board.get",
               refuseRead.withLock({ value in
                   defer { value = false }
                   return value
               }) {
                return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                "error": .object(["code": "unavailable", "message": "board read failed"])])
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        _ = try board.update(edited.id, props: .object(["markdown": "refused preview"]))
        try await eventually { notices.contains { $0.contains("board read failed") } }
        #expect(mirror.availability == .open)
        #expect(board.objects[edited.id] == edited)
        #expect(board.objects[kept.id] == kept)
        mirror.reconnect()
        try await eventually { mirror.reading == nil && board.objects[edited.id] == nil }
        #expect(mirror.availability == .open)
        #expect(board.objects[kept.id] == kept)
    }

    // MARK: The viewer as easld's client

    /// easld's side of the client protocol in front of the host's router: `client.attach`
    /// (accepted as easld accepts it, or else left to the router, which has no such method), and
    /// the composer's `agent.prompt` and, when `measuresWrites`, `object.update` sent on to the
    /// attached client and answered once it answers. Its answers are taken as they come, ahead of
    /// the link's requests, as easld's reader takes them. `client.list` answers `clients` as they
    /// were when it was asked, at once or once `answerLists`; `announce` sends `client.changed`;
    /// a page's address in `browser.report` lands as easld lands it, an update credited as reported.
    final class Easld: @unchecked Sendable {
        let accepts: Bool
        let measuresWrites: Bool
        private let lock = NSLock()
        private var client: SocketServer.Connection?
        private var sent = 0
        private var waiting: [String: @Sendable (JSONValue) async -> Void] = [:]
        private var attachLog: [JSONValue] = []
        private var promptLog: [JSONValue] = []
        private var answerLog: [JSONValue] = []
        private var listed: JSONValue = .array([])
        private var holdingLists = false
        private var heldLists: [@Sendable () -> Void] = []

        init(accepts: Bool = true, measuresWrites: Bool = false) {
            self.accepts = accepts
            self.measuresWrites = measuresWrites
        }

        /// Each `client.attach`'s params, in order.
        var attaches: [JSONValue] { lock.withLock { attachLog } }
        /// The viewer's own `agent.prompt`s' params.
        var prompts: [JSONValue] { lock.withLock { promptLog } }
        /// The client's answers to easld's calls, in order.
        var answers: [JSONValue] { lock.withLock { answerLog } }
        var clients: JSONValue {
            get { lock.withLock { listed } }
            set { lock.withLock { listed = newValue } }
        }
        var holdsLists: Bool {
            get { lock.withLock { holdingLists } }
            set { lock.withLock { holdingLists = newValue } }
        }
        var waitingLists: Int { lock.withLock { heldLists.count } }

        func attaching(_ params: JSONValue, on connection: SocketServer.Connection) {
            lock.withLock {
                attachLog.append(params)
                if accepts { client = connection }
            }
        }

        func prompted(_ params: JSONValue) {
            lock.withLock { promptLog.append(params) }
        }


        func list(_ id: JSONValue, on connection: SocketServer.Connection) -> JSONValue? {
            lock.withLock { () -> JSONValue? in
                let reply: JSONValue = .object(["id": id, "ok": .bool(true), "result": .object(["clients": listed])])
                guard holdingLists else { return reply }
                heldLists.append { connection.send(reply) }
                return nil
            }
        }

        func answerLists() {
            let held = lock.withLock { () -> [@Sendable () -> Void] in
                defer { heldLists = [] }
                return heldLists
            }
            for answer in held { answer() }
        }

        func announce(_ clients: JSONValue, board: BoardID) {
            let client = lock.withLock { self.client }
            client?.send(.object(["event": "client.changed", "board": .string(board), "data": .object(["clients": clients])]))
        }

        /// Sends the attached client `method`; `then` gets its answer.
        func call(_ method: String, _ params: JSONValue, then: @escaping @Sendable (JSONValue) async -> Void) {
            let (client, id) = lock.withLock { () -> (SocketServer.Connection?, String) in
                sent += 1
                waiting["easld-\(sent)"] = then
                return (self.client, "easld-\(sent)")
            }
            client?.send(.object(["id": .string(id), "method": .string(method), "params": params]))
        }

        func answered(_ answer: JSONValue) async {
            let then = lock.withLock { () -> (@Sendable (JSONValue) async -> Void)? in
                answerLog.append(answer)
                return answer["id"]?.string.flatMap { waiting.removeValue(forKey: $0) }
            }
            await then?(answer)
        }
    }

    @Test func easldOnAMacKeepsItsOwnSessionDirectoryAndNoAppLauncher() async throws {
        let easld = Easld()
        try serveEasld(easld)
        let (mirror, _) = try await mirror()
        for support in [nil, "/tmp/easl-guest-host"] as [String?] {
            let host = try #require(RemoteHost.parseDiscovery("os=Darwin\nhome=/Users/lume\ntmpdir=/var/folders/T/\n",
                                                            name: "guest", sshTarget: "guest", support: support))
            let identified = try await host.identified(on: mirror.connection)
            #expect(identified.server == .easld)
            #expect(identified.socketPath == host.socketPath)
            #expect(identified.tmpdir == host.tmpdir)
            #expect(identified.appBundle == nil)
            #expect(identified.startCommand == nil)
            #expect(identified.zmxDir == (support ?? "/Users/lume/Library/Application Support/Easl") + "/zmx")
        }
    }

    /// The host's socket served as `easld` fronts it from now on.
    func serveEasld(_ easld: Easld, refusingHtml failure: Locked<String?>? = nil,
                    browser: (@Sendable (JSONValue, SocketServer.Connection) -> JSONValue?)? = nil) throws {
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let id = request["id"] ?? .null
            let params = request["params"] ?? .object([:])
            switch request["method"]?.string {
            case nil:
                await easld.answered(request)
                return nil
            case "client.attach"?:
                easld.attaching(params, on: connection)
                guard easld.accepts else { return await router.handle(request, connection: connection) }
                return .object(["id": id, "ok": .bool(true), "result": .object(["client": "cli_1", "version": 1, "schema": .string(ApiParams.schemaHash)])])
            case "object.get"? where failure != nil:
                if let message = failure?.withLock({ value in
                    defer { value = nil }
                    return value
                }) {
                    return .object(["id": id, "ok": .bool(false),
                                    "error": .object(["code": .string("unavailable"), "message": .string(message)])])
                }
                return await router.handle(request, connection: connection)
            case "agent.prompt"?:
                easld.prompted(params)
                var forwarded = params.object ?? [:]
                forwarded["mentions"] = nil
                forwarded["staged"] = nil
                forwarded["viewer"] = nil
                easld.call("agent.prompt", .object(forwarded)) { answer in connection.send(answer.merging(.object(["id": id]))) }
                return nil
            case "object.update"? where easld.measuresWrites:
                let note: JSONValue = .object(["kind": "note", "text": params["props"]?["markdown"] ?? "", "width": 280, "root": "/home/tim/repo"])
                easld.call("text.measure", .object(["items": [note]])) { _ in
                    if let reply = await router.handle(request, connection: connection) { connection.send(reply) }
                }
                return nil
            case "client.list"?:
                return easld.list(id, on: connection)
            case "browser.call"? where browser != nil:
                return browser?(request, connection)
            case "browser.report"?:
                var update: [String: JSONValue] = ["id": params["id"] ?? .null, "props": .object(["url": params["url"] ?? .null])]
                if let caller = params["caller"] { update["caller"] = caller }
                return await router.handle(.object(["id": id, "method": "object.update", "params": .object(update)]), connection: connection)
            default:
                return await router.handle(request, connection: connection)
            }
        }
        try server.start()
    }

    let identity = ClientIdentity(app: "0.2.7", host: "studio", id: "mch_01STUDIO")

    /// A board's window for `serve`: key while `focused` says, its terminals typed into by `submit`.
    func window(focused: @escaping () -> Bool = { false }, submit: @escaping (ObjectID, String) async -> Bool = { _, _ in false }) -> ViewerWindow {
        ViewerWindow(focused: focused, viewState: { nil },
                     render: { _, _ in throw ApiRouter.Failure("unavailable", "nothing is drawn here") }, hostPicture: { _ in false },
                     measureHTML: { _, _ in throw ApiRouter.Failure("unavailable", "no page is laid out here") },
                     reload: { id, _, _ in throw ApiRouter.Failure("unavailable", "browser tile \(id) isn't shown here") },
                     browse: { id, _, _ in throw ApiRouter.Failure("unavailable", "browser tile \(id) isn't shown here") },
                     surface: { _, _, _ in throw ApiRouter.Failure("unavailable", "no browser page runs here") },
                     submit: submit, surfaceTail: { _, _ in nil },
                     block: { _, _ in throw ApiRouter.Failure("unavailable", "no command has finished") }, status: { _ in nil }, languages: { nil })
    }

    @Test func aFocusDuringAttachIsKeptAfterTheWindowResigns() async throws {
        let attaches = Locked<[JSONValue]>([])
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            guard request["method"]?.string == "client.attach" else { return await router.handle(request, connection: connection) }
            let first = attaches.withLock { log in
                log.append(request["params"] ?? .null)
                return log.count == 1
            }
            let response: JSONValue = .object(["id": request["id"] ?? .null, "ok": .bool(true),
                                               "result": .object(["client": "cli_1", "version": 1, "schema": .string(ApiParams.schemaHash)])])
            if first {
                pending.withLock { $0 = { connection.send(response) } }
                return nil
            }
            return response
        }
        try server.start()
        let (mirror, _) = try await mirror()
        defer { mirror.close() }
        var key = false
        mirror.serve(window(focused: { key }), as: identity)
        try await eventually { pending.withLock { $0 != nil } }
        key = true
        mirror.userFocused()
        key = false
        pending.withLock { $0 }?()
        try await eventually { attaches.withLock { $0.count == 2 } }
        try #require(attaches.withLock { $0.count } == 2)
        #expect(attaches.withLock { $0[0]["focused"] } == nil)
        #expect(attaches.withLock { $0[1]["focused"] } == .string(host.id))
    }

    @Test func theViewerAttachesOnceOnEachLinkAndAgainWhenTheUserFocusesTheBoard() async throws {
        let easld = Easld()
        try serveEasld(easld)
        let (mirror, _) = try await mirror()
        defer { mirror.close() }
        var key = false
        mirror.serve(window(focused: { key }), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        let attach: JSONValue = .object([
            "version": .number(Double(ApiParams.schemaVersion)), "schema": .string(ApiParams.schemaHash), "app": "0.2.7", "host": "studio", "identity": "mch_01STUDIO",
            "serves": ["view.get", "view.render", "agent.prompt", "agent.read", "object.reload", "object.measure", "text.measure", "browser.call",
                       "surface.stream", "surface.ack", "surface.progress", "surface.input", "surface.answer", "surface.stop"], "boards": [.string(host.id)],
        ])
        #expect(easld.attaches == [attach])
        key = true
        mirror.userFocused()
        try await eventually { easld.attaches.count == 2 }
        #expect(easld.attaches.last == attach.merging(.object(["focused": .string(host.id)])))
        server.stop()
        try await eventually { mirror.attachment == .waiting }
        try serveEasld(easld)
        try await eventually { easld.attaches.count == 3 && mirror.attachment == .attached(client: "cli_1", version: 1) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(easld.attaches.count == 3, "one attach on the new link: \(easld.attaches)")
        #expect(easld.attaches.last?["focused"] == .string(host.id))
    }

    /// An easl without the client protocol (the app's own router, as a Mac host's) refuses the
    /// attach: the board goes on as before, and only the next link asks again.
    @Test func aRefusedAttachLeavesTheBoardWorkingAndOnlyTheNextLinkAsksAgain() async throws {
        let easld = Easld(accepts: false)
        try serveEasld(easld)
        let edited = note("before")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        mirror.serve(window(focused: { true }), as: identity)
        try await eventually { mirror.attachment == .refused("unknown method client.attach") }
        _ = try host.update(edited.id, frame: Frame(x: 50, y: 60, w: 280, h: 200))
        try await eventually { board.objects[edited.id]?.frame.x == 50 }
        _ = try board.update(edited.id, props: .object(["markdown": "the viewer's"]))
        try await eventually { host.objects[edited.id]?.props["markdown"]?.string == "the viewer's" }
        mirror.userFocused()
        try await Task.sleep(for: .milliseconds(300))
        #expect(easld.attaches.count == 1, "a refused link asks nothing more")
        server.stop()
        try await eventually { mirror.attachment == .waiting }
        try serveEasld(easld)
        try await eventually { easld.attaches.count == 2 && mirror.attachment == .refused("unknown method client.attach") }
        try await Task.sleep(for: .milliseconds(300))
        #expect(easld.attaches.count == 2, "the next link asks once")
        #expect(mirror.state == .online)
    }

    /// On easld the composer's prompt comes back to this viewer, which types it into the
    /// terminal's surface and answers: asked once, typed once, never sent on again.
    @Test func theComposersPromptComesBackToThisViewerToTypeAndGoesOutOnce() async throws {
        let easld = Easld()
        try serveEasld(easld)
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": "worker"])).id
        try host.reportLifecycle(tile: agent, kind: "omp", state: .idle, message: nil, seq: 1, source: nil, protocol: 1, pid: Int(getpid()))
        let (mirror, _) = try await mirror()
        defer { mirror.close() }
        var pasted: [String] = []
        mirror.serve(window(submit: { id, text in
            pasted.append("\(id): \(text)")
            return true
        }), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        try await mirror.prompt("fix the build", to: agent, mentions: [], answer: false)
        #expect(pasted == ["\(agent): fix the build"])
        #expect(easld.prompts == [.object(["target": .string(agent), "text": "fix the build", "composer": .bool(true)])], "typing it asked the host nothing")
        #expect(easld.answers.count == 1)
        let result = try #require(easld.answers.first?["result"])
        #expect(result["delivery"] == .string("typed"))
        #expect(result["waitable"] == .bool(true))
        #expect(result["agent"]?["tile"] == .string(agent))
        // The pid the agent reported is the host's: the app names it only for a terminal of its own.
        #expect(result["agent"]?["pid"] == nil)
        #expect(router.agentEntry(try #require(host.objects[agent]), on: host)["pid"] == .number(Double(getpid())))
    }

    /// easld measures a note through this viewer while the viewer's own write waits on the same
    /// link: the measure is answered, and the write lands.
    @Test func aWriteEasldMeasuresThroughThisViewerLands() async throws {
        let easld = Easld(measuresWrites: true)
        try serveEasld(easld)
        let edited = note("before")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        mirror.serve(window(), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        let markdown = "# Plan\n\nShip the client protocol."
        _ = try board.update(edited.id, props: .object(["markdown": .string(markdown)]))
        try await eventually { host.objects[edited.id]?.props["markdown"]?.string == markdown }
        let size = try await ObjectMeasure.size(type: .note, props: .object(["markdown": .string(markdown)]), width: 280, root: dir)
        #expect(easld.answers.first == .object(["id": "easld-1", "ok": .bool(true), "result": .object(["sizes": [
            .object(["w": .number(size.width), "h": .number(size.height), "tableShortfall": 0]),
        ]])]))
    }


    func client(_ identity: String?, host: String? = nil, serving board: BoardID, serves: [String] = ["agent.prompt", "browser.call", "object.reload"]) -> JSONValue {
        var entry: [String: JSONValue] = ["id": "cli_2", "boards": [.string(board)], "serves": .array(serves.map(JSONValue.string))]
        if let identity { entry["identity"] = .string(identity) }
        if let host { entry["host"] = .string(host) }
        return .object(entry)
    }

    /// Each drawing Mac once, by its identity, named as it attached (its identity when it gave no
    /// name), sorted by name; what serves no browser calls, or another board, isn't one.
    @Test func theBoardsDrawingMacsFollowEasldsLatestSnapshot() async throws {
        let easld = Easld()
        easld.clients = [client("mch_01HOME", host: "home", serving: host.id)]
        easld.holdsLists = true
        try serveEasld(easld)
        let (mirror, _) = try await mirror()
        defer { mirror.close() }
        mirror.serve(window(), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) && easld.waitingLists == 1 }
        #expect(mirror.drawingMachineChoices == nil && mirror.drawingMachines == nil)
        easld.announce([
            client("mch_01STUDIO", host: "studio", serving: host.id),
            client("mch_01STUDIO", host: "studio", serving: host.id, serves: ["browser.call", "surface.stream"]),
            client("mch_01NAMELESS", serving: host.id),
            client("mch_01ATTIC", host: "attic", serving: host.id),
            client("mch_01OLDER", host: "older", serving: host.id, serves: ["agent.prompt", "object.reload"]),
            client(nil, host: "anonymous", serving: host.id),
            client("mch_01ELSEWHERE", host: "elsewhere", serving: "brd_elsewhere"),
        ], board: host.id)
        let heard = [DrawingMachine(id: "mch_01ATTIC", host: "attic"), DrawingMachine(id: "mch_01NAMELESS", host: "mch_01NAMELESS"),
                     DrawingMachine(id: "mch_01STUDIO", host: "studio")]
        try await eventually { mirror.drawingMachineChoices == heard }
        #expect(mirror.drawingMachines == ["mch_01ATTIC", "mch_01NAMELESS", "mch_01STUDIO"])
        easld.answerLists()
        try await Task.sleep(for: .milliseconds(300))
        #expect(mirror.drawingMachineChoices == heard, "the list asked before the snapshot is older")
        server.stop()
        try await eventually { mirror.drawingMachineChoices == nil && mirror.drawingMachines == nil }
        easld.holdsLists = false
        try serveEasld(easld)
        try await eventually { mirror.drawingMachineChoices == [DrawingMachine(id: "mch_01HOME", host: "home")] }
        #expect(mirror.drawingMachines == ["mch_01HOME"])
    }

    @Test(arguments: ["assignment", "destination", "incarnation", "online-read-failure", "offline-read-failure"])
    func aMoveCannotOutliveItsPageOrUseASavedURLAfterAFailedLiveRead(_ transition: String) async throws {
        let source = DrawingMachine(id: "mch_01SOURCE", host: "source")
        let destination = DrawingMachine(id: "mch_01DEST", host: "destination")
        let other = DrawingMachine(id: "mch_01OTHER", host: "other")
        let page = host.create(type: .browser, props: .object(["url": "https://page.example/saved", "drawingMachine": source.json]))
        let easld = Easld()
        easld.clients = [client(source.id, serving: host.id), client(destination.id, serving: host.id)]
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        let fails = transition.hasSuffix("read-failure")
        try serveEasld(easld, browser: { request, connection in
            let reply: JSONValue = fails
                ? .object(["id": request["id"] ?? .null, "ok": .bool(false), "error": .object(["code": "unavailable", "message": "read failed"])])
                : .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["url": "https://page.example/live"])])
            pending.withLock { $0 = { connection.send(reply) } }
            return nil
        })
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        mirror.serve(window(), as: identity)
        try await eventually { mirror.drawingMachines?.contains(source.id) == true }
        let move = try mirror.drawingMove(page.id, to: destination)
        let moving = Task { @MainActor () -> String? in
            do {
                try await mirror.moveDrawing(move)
                return nil
            } catch {
                return (error as? ApiRouter.Failure)?.code
            }
        }
        try await eventually { pending.withLock { $0 != nil } }
        switch transition {
        case "assignment":
            try host.update(page.id, props: .object(["drawingMachine": other.json]))
            try await eventually { DrawingMachine(board.objects[page.id]!.props) == other }
        case "destination":
            easld.announce([client(source.id, serving: host.id)], board: host.id)
            try await eventually { mirror.drawingMachines == [source.id] }
        case "incarnation":
            try registry.close(host.id)
            try await eventually { mirror.availability == .closed }
            _ = registry.open(root: host.root)
            try await eventually { mirror.availability == .open }
        case "offline-read-failure":
            easld.announce([client(destination.id, serving: host.id)], board: host.id)
            try await eventually { mirror.drawingMachines == [destination.id] }
        default: break
        }
        pending.withLock { $0 }?()
        #expect(await moving.value == (transition == "assignment" ? "conflict" : "unavailable"))
        #expect(host.objects[page.id]?.props["url"] == "https://page.example/saved")
        #expect(DrawingMachine(host.objects[page.id]!.props) == (transition == "assignment" ? other : source))
    }

    /// A delegated call that opens or drives a tile's page waits for the events easld sent before
    /// it, and fails with the board that closes meanwhile, or as gone for a tile deleted by then.
    @Test(arguments: ["browser.call", "object.reload", "surface.stream"])
    func closingAHostFailsBrowserCallsWaitingForEarlierEvents(_ method: String) async throws {
        let easld = Easld()
        let page = host.create(type: .browser, props: .object(["url": "https://page.example/"]))
        let pending = Locked<(@Sendable () -> Void)?>(nil)
        server.stop()
        let router = router
        server = SocketServer(path: socket) { request, connection in
            if request["method"] == nil {
                await easld.answered(request)
                return nil
            }
            if request["method"]?.string == "client.attach" {
                easld.attaching(request["params"] ?? .object([:]), on: connection)
                return .object(["id": request["id"] ?? .null, "ok": .bool(true),
                                "result": .object(["client": "cli_1", "version": 1])])
            }
            let reply = await router.handle(request, connection: connection)
            if request["method"]?.string == "object.create", let reply {
                pending.withLock { $0 = { connection.send(reply) } }
                return nil
            }
            return reply
        }
        try server.start()
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        defer { pending.withLock { $0 }?() }
        var dispatched: [ObjectID] = []
        var viewer = window()
        viewer.browse = { id, _, _ in
            dispatched.append(id)
            return .object(["url": "https://page.example/"])
        }
        viewer.reload = { id, _, _ in
            dispatched.append(id)
            return .object(["id": .string(id), "loaded": .bool(true)])
        }
        viewer.surface = { request, _, _ in
            if case .stream(let id, _, _) = request { dispatched.append(id) }
            return .object(["stream": "str_1", "size": .object(["w": 640, "h": 480]), "scale": 1])
        }
        mirror.serve(viewer, as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        let params: JSONValue = method == "browser.call"
            ? .object(["id": .string(page.id), "method": "browser.url.get", "params": .object([:])])
            : .object(["id": .string(page.id)])
        let initial = Locked<JSONValue?>(nil)
        easld.call(method, params) { reply in initial.withLock { $0 = reply } }
        try await eventually { initial.withLock { $0 != nil } }
        #expect(initial.withLock { $0?["ok"] } == .bool(true))
        #expect(dispatched == [page.id])

        let provisional = board.create(type: .note, props: .object(["markdown": "create still waiting"]))
        try await eventually { pending.withLock { $0 != nil } }
        let waiting = Locked<JSONValue?>(nil)
        easld.call(method, params) { reply in waiting.withLock { $0 = reply } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(waiting.withLock { $0 } == nil)
        try registry.close(host.id)
        try await eventually { mirror.availability == .closed && waiting.withLock { $0 != nil } }
        #expect(waiting.withLock { $0?["error"]?["code"] } == .string("unavailable"))
        #expect(dispatched == [page.id])
        #expect(board.objects[page.id] == page)
        #expect(board.objects[provisional.id] == nil)

        let reopened = registry.open(root: host.root)
        try reopened.delete(page.id)
        pending.withLock { answer in
            defer { answer = nil }
            return answer
        }?()
        try await eventually {
            mirror.availability == .open && mirror.attachment == .attached(client: "cli_1", version: 1)
                && board.objects[page.id] == nil
        }
        let deleted = Locked<JSONValue?>(nil)
        easld.call(method, params) { reply in deleted.withLock { $0 = reply } }
        try await eventually { deleted.withLock { $0 != nil } }
        #expect(deleted.withLock { $0?["error"]?["code"] } == .string("not_found"))
        #expect(dispatched == [page.id])
        #expect(board.objects == reopened.objects)
    }

    @Test func aBrowserDeletedBeforeItsDelegatedCallIsAdmittedFailsAsDeleted() async throws {
        let easld = Easld()
        try serveEasld(easld)
        let page = host.create(type: .browser, props: .object(["url": "about:blank"]))
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        mirror.serve(window(), as: identity)
        try await eventually { mirror.attachment == .attached(client: "cli_1", version: 1) }
        try host.delete(page.id)
        try await eventually { board.objects[page.id] == nil }
        let answer = Locked<JSONValue?>(nil)
        easld.call("browser.call", .object([
            "id": .string(page.id), "method": "browser.url.get", "params": .object([:]),
        ])) { reply in answer.withLock { $0 = reply } }
        try await eventually { answer.withLock { $0 != nil } }
        let reply = try #require(answer.withLock { $0 })
        #expect(reply["error"]?["code"] == "not_found")
    }

    @Test func aDrawingMacsPageReportsReachEasldInOrderWithTheirCredit() async throws {
        let easld = Easld()
        try serveEasld(easld)
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": "worker"])).id
        let page = host.create(type: .browser, props: .object(["url": "https://a.example/"])).id
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        try board.reportPage(page, .url("https://b.example/", by: .user))
        try board.reportPage(page, .url("https://c.example/", by: .system))
        try board.reportPage(page, .url("https://d.example/", by: .agent(agent)))
        try await eventually { host.objects[page]?.props["url"] == "https://d.example/" }
        try await eventually { board.objects[page] == host.objects[page] }
        #expect(host.objects[page]?.updatedBy == .agent(tile: agent))
    }

    @Test func aPageOpenedOnTheDrawingMacIsCreditedToItsAgent() async throws {
        registry.drawingMachine = DrawingMachine(id: "mch_01STUDIO", host: "studio")
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": "worker"])).id
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        let props: JSONValue = .object(["url": "https://example.com/login", "profile": "work", "drawingMachine": .object(["id": "mch_01STUDIO", "host": "studio"])])
        let opened = board.create(type: .browser, props: props, caller: agent)
        try await eventually { host.objects.values.contains { $0.type == .browser } }
        let created = try #require(host.objects.values.first { $0.type == .browser })
        #expect(created.createdBy == .agent(tile: agent))
        try await eventually { board.objects[created.id] != nil && board.objects[opened.id] == nil }
    }
}
