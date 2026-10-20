import Foundation
import Testing
@testable import CanvasCore

private final class PreviewQueuePeer: Sendable {
    struct Call: Sendable {
        let object: String
        let id: JSONValue
        let connection: SocketServer.Connection
    }

    let directory: URL
    let server: SocketServer
    private let calls = Locked<[Call]>([])
    let links = Locked<[EaslConnection]>([])
    var path: String { directory.appendingPathComponent("s").path }
    var objects: [String] { calls.withLock { $0.map(\.object) } }

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preview-queue-\(UUID().uuidString.prefix(8))")
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calls = calls
        server = SocketServer(path: directory.appendingPathComponent("s").path) { request, connection in
            let id = request["id"] ?? .null
            if request["method"]?.string == "system.ping" {
                return .object(["id": id, "ok": .bool(true), "result": .object([:])])
            }
            guard request["method"]?.string == "image.preview", let object = request["params"]?["id"]?.string else {
                return .object(["id": id, "ok": .bool(false), "error": .object(["code": "invalid_params", "message": "expected image.preview"])])
            }
            calls.withLock { $0.append(Call(object: object, id: id, connection: connection)) }
            return nil
        }
        try server.start()
    }

    deinit {
        links.withLock { $0 }.forEach { $0.close() }
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func pool() -> HostImagePreviews {
        let path = path
        let links = links
        return HostImagePreviews {
            let link = EaslConnection.unixSocket(path)
            links.withLock { $0.append(link) }
            return link
        }
    }

    func waitForCalls(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while objects.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(objects.count >= count)
    }

    func finish(_ object: String, result: JSONValue = .object(["kind": "original"])) throws {
        let call = try #require(calls.withLock { $0.first { $0.object == object } })
        #expect(call.connection.send(.object(["id": call.id, "ok": .bool(true), "result": result])))
    }

    func markReplyConsumed(_ object: String) throws {
        let call = try #require(calls.withLock { $0.first { $0.object == object } })
        #expect(call.connection.send(.object(["event": "preview.reply-consumed", "board": "brd_preview", "data": .null])))
    }
}

private extension HostImagePreviews {
    func holdConsumer(entered: DispatchSemaphore, release: DispatchSemaphore) -> Bool {
        entered.signal()
        return release.wait(timeout: .now() + 10) == .success
    }
}

@MainActor
struct HostImagePreviewSchedulingTests {
    private func start(_ object: String, pool: HostImagePreviews, priority: HostReadPriority = .visible,
                       deadline: ContinuousClock.Instant = .now + .seconds(20)) async -> Task<HostImagePreview?, Error> {
        let (began, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            signal.yield()
            signal.finish()
            return try await pool.read(object: object, maxPixels: 64, priority: priority, deadline: deadline)
        }
        for await _ in began { break }
        return task
    }

    @Test func oneWireRequestAdmitsPriorityThenFIFOAndReusesTheConnection() async throws {
        let peer = try PreviewQueuePeer()
        let pool = peer.pool()
        let active = await start("active", pool: pool)
        defer { active.cancel() }
        try await peer.waitForCalls(1)
        let backgroundFirst = await start("background-first", pool: pool, priority: .background)
        let visibleFirst = await start("visible-first", pool: pool)
        let interactiveFirst = await start("interactive-first", pool: pool, priority: .interactive)
        let backgroundSecond = await start("background-second", pool: pool, priority: .background)
        let interactiveSecond = await start("interactive-second", pool: pool, priority: .interactive)
        let visibleSecond = await start("visible-second", pool: pool)
        let ordered = [("active", active), ("interactive-first", interactiveFirst), ("interactive-second", interactiveSecond),
                       ("visible-first", visibleFirst), ("visible-second", visibleSecond),
                       ("background-first", backgroundFirst), ("background-second", backgroundSecond)]
        defer { ordered.forEach { $0.1.cancel() } }
        #expect(peer.objects == ["active"])
        for (index, entry) in ordered.enumerated() {
            try await peer.waitForCalls(index + 1)
            #expect(peer.objects == ordered.prefix(index + 1).map { $0.0 })
            try peer.finish(entry.0)
            #expect(try await entry.1.value == nil)
        }
        #expect(peer.links.withLock { $0.count } == 1)
    }

    @Test func queuedCancellationAndExpiryNeverReachTheHostOrStealTheNextSlot() async throws {
        let peer = try PreviewQueuePeer()
        let pool = peer.pool()
        let active = await start("active", pool: pool)
        defer { active.cancel() }
        try await peer.waitForCalls(1)
        let cancelled = await start("cancelled", pool: pool, priority: .interactive)
        defer { cancelled.cancel() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let expired = await start("expired", pool: pool, priority: .interactive, deadline: .now + .milliseconds(100))
        defer { expired.cancel() }
        await #expect(throws: HostFileError.unavailable("host image preview timed out")) { try await expired.value }
        #expect(peer.objects == ["active"])
        #expect(peer.links.withLock { $0.count } == 1)
        let next = await start("next", pool: pool, priority: .background)
        defer { next.cancel() }
        try peer.finish("active")
        _ = try await active.value
        try await peer.waitForCalls(2)
        #expect(peer.objects == ["active", "next"])
        try peer.finish("next")
        #expect(try await next.value == nil)
        #expect(peer.links.withLock { $0.count } == 1)
    }

    @Test func activeCancellationClosesTheBusyWireAndAdmitsTheQueuedReadOnANewConnection() async throws {
        let peer = try PreviewQueuePeer()
        let pool = peer.pool()
        let cancelled = await start("cancelled", pool: pool)
        defer { cancelled.cancel() }
        try await peer.waitForCalls(1)
        let oldLink = try #require(peer.links.withLock { $0.first })
        let next = await start("next", pool: pool)
        defer { next.cancel() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await peer.waitForCalls(2)
        #expect(peer.objects == ["cancelled", "next"])
        let deadline = ContinuousClock.now + .seconds(5)
        while oldLink.problem != "closed", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(oldLink.problem == "closed")
        #expect(peer.links.withLock { $0.count } == 2)
        try peer.finish("next")
        #expect(try await next.value == nil)
        let reused = await start("reused", pool: pool)
        defer { reused.cancel() }
        try await peer.waitForCalls(3)
        try peer.finish("reused")
        #expect(try await reused.value == nil)
        #expect(peer.links.withLock { $0.count } == 2)
    }

    @Test func wireTimeoutUsesOnlyTheDeadlineRemainingAfterQueueing() async throws {
        let peer = try PreviewQueuePeer()
        let pool = peer.pool()
        let active = await start("active", pool: pool)
        defer { active.cancel() }
        try await peer.waitForCalls(1)
        let began = ContinuousClock.now
        let deadline = began + .seconds(2)
        let expires = await start("expires", pool: pool, deadline: deadline)
        defer { expires.cancel() }
        try await Task.sleep(until: began + .seconds(1), clock: .continuous)
        try peer.finish("active")
        _ = try await active.value
        try await peer.waitForCalls(2)
        #expect(peer.objects == ["active", "expires"])
        do {
            _ = try await expires.value
            Issue.record("an unanswered image preview succeeded")
        } catch let error as HostFileError {
            guard case .unavailable = error else { throw error }
        }
        #expect(ContinuousClock.now < deadline + .milliseconds(500))
        let next = await start("next", pool: pool)
        defer { next.cancel() }
        try await peer.waitForCalls(3)
        try peer.finish("next")
        #expect(try await next.value == nil)
        #expect(peer.links.withLock { $0.count } == 2)
    }

    @Test func malformedCompletedReplyReleasesTheSlotWithoutClosingTheCleanConnection() async throws {
        let peer = try PreviewQueuePeer()
        let pool = peer.pool()
        let invalid = await start("invalid", pool: pool)
        defer { invalid.cancel() }
        try await peer.waitForCalls(1)
        let next = await start("next", pool: pool)
        defer { next.cancel() }
        try peer.finish("invalid", result: .object(["kind": "preview", "data": "not a PNG"]))
        await #expect(throws: HostFileError.self) { try await invalid.value }
        try await peer.waitForCalls(2)
        try peer.finish("next")
        #expect(try await next.value == nil)
        #expect(peer.links.withLock { $0.count } == 1)
    }

    @Test func cancellationAfterTheWireReplyPreservesTheConnectionForTheNextRead() async throws {
        let peer = try PreviewQueuePeer()
        let pool = peer.pool()
        let cancelled = await start("cancelled", pool: pool)
        defer { cancelled.cancel() }
        try await peer.waitForCalls(1)
        let link = try #require(peer.links.withLock { $0.first })
        let events = link.events()
        #expect(link.state == .online)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached { await pool.holdConsumer(entered: entered, release: release) }
        defer { release.signal() }
        let didEnter = await offPool { entered.wait(timeout: .now() + 5) == .success }
        try #require(didEnter)
        let marker = Task { await events.first { $0.name == "preview.reply-consumed" } }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            marker.cancel()
        }
        defer { timeout.cancel(); marker.cancel() }
        try peer.finish("cancelled")
        try peer.markReplyConsumed("cancelled")
        try #require(await marker.value != nil)
        cancelled.cancel()
        release.signal()
        #expect(await holding.value)
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let next = await start("next", pool: pool)
        defer { next.cancel() }
        try await peer.waitForCalls(2)
        try peer.finish("next")
        #expect(try await next.value == nil)
        #expect(peer.links.withLock { $0.count } == 1)
        #expect(link.state == .online)
    }

    @Test func pooledLanguageFilesDoNotRetainTheBoardsPreviewConnection() async throws {
        let peer = try PreviewQueuePeer()
        let path = peer.path
        let links = peer.links
        var files: HostFiles? = HostFiles(hostName: "preview", route: HostRoute(target: "unused", controlPath: "/unused"), temps: [],
            imagePreviews: HostImagePreviews {
                let link = EaslConnection.unixSocket(path)
                links.withLock { $0.append(link) }
                return link
            })
        let languageFiles = try #require(files).withoutImagePreviews
        let service = LanguageService(host: languageFiles)
        let read = Task { [files] in try await files?.imagePreview(object: "board", maxPixels: 64) }
        defer { read.cancel() }
        try await peer.waitForCalls(1)
        try peer.finish("board")
        _ = try await read.value
        files = nil
        let link = try #require(links.withLock { $0.first })
        let deadline = ContinuousClock.now + .seconds(5)
        while link.problem != "closed", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(link.problem == "closed")
        #expect(service.hostName == "preview")
        await #expect(throws: HostFileError.unavailable("this host has no image preview endpoint")) {
            try await languageFiles.imagePreview(object: "language", maxPixels: 64)
        }
        #expect(peer.objects == ["board"])
        #expect(links.withLock { $0.count } == 1)
    }
}
