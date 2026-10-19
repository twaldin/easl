import Foundation
import Testing
@testable import CanvasCore

private final class SnapshotPeer: Sendable {
    struct Call: Sendable {
        let target: String
        let id: JSONValue
        let connection: SocketServer.Connection
    }

    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("hbs-\(UUID().uuidString.prefix(8))")
    let server: SocketServer
    private let calls = Locked<[Call]>([])
    var executable: String { directory.appendingPathComponent("ssh").path }
    var targets: [String] { calls.withLock { $0.map(\.target) } }
    var host: RemoteHost {
        RemoteHost(name: "fixture", sshTarget: "fixture", socketPath: "/unused", tmpdir: "/tmp", easlBin: "easl")
    }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("socket").path
        let calls = calls
        server = SocketServer(path: path) { request, connection in
            if request["method"]?.string == "system.ping" {
                return .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object([:])])
            }
            guard request["method"]?.string == "view.render", let target = request["params"]?["target"]?.string else {
                return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                "error": .object(["code": "invalid_params", "message": "expected view.render"])])
            }
            calls.withLock { $0.append(Call(target: target, id: request["id"] ?? .null, connection: connection)) }
            return nil
        }
        try "#!/bin/sh\nexec /usr/bin/nc -U \(RemoteHost.quote(path))\n".write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForCalls(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while targets.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(targets.count >= count)
    }

    @discardableResult
    func finish(_ target: String) throws -> Bool {
        let call = try #require(calls.withLock { $0.first { $0.target == target } })
        return call.connection.send(.object(["id": call.id, "ok": .bool(true), "result": .object(["captured": .bool(true)])]))
    }
}

@MainActor
struct HostBrowserSnapshotsTests {
    private func start(_ target: String, pool: HostBrowserSnapshots, peer: SnapshotPeer,
                       priority: HostReadPriority = .interactive,
                       deadline: ContinuousClock.Instant = .now + .seconds(20)) async -> Task<JSONValue, Error> {
        let (began, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            signal.yield()
            signal.finish()
            return try await pool.render(host: peer.host, board: "brd_snapshots", browser: target,
                                         scale: 0.4, priority: priority, deadline: deadline)
        }
        for await _ in began { break }
        return task
    }

    @Test func boundedSnapshotLinksAdmitInteractiveThenVisibleThenBackground() async throws {
        let peer = try SnapshotPeer()
        let pool = HostBrowserSnapshots(executable: peer.executable)
        let first = await start("obj_first", pool: pool, peer: peer)
        defer { first.cancel() }
        try await peer.waitForCalls(1)
        let second = await start("obj_second", pool: pool, peer: peer)
        defer { second.cancel() }
        try await peer.waitForCalls(2)
        let background = await start("obj_background", pool: pool, peer: peer, priority: .background)
        let visible = await start("obj_visible", pool: pool, peer: peer, priority: .visible)
        let interactive = await start("obj_interactive", pool: pool, peer: peer)
        defer { background.cancel(); visible.cancel(); interactive.cancel() }
        #expect(peer.targets == ["obj_first", "obj_second"])
        try peer.finish("obj_first")
        _ = try await first.value
        try await peer.waitForCalls(3)
        #expect(peer.targets.last == "obj_interactive")
        try peer.finish("obj_second")
        _ = try await second.value
        try await peer.waitForCalls(4)
        #expect(peer.targets.last == "obj_visible")
        try peer.finish("obj_interactive")
        _ = try await interactive.value
        try await peer.waitForCalls(5)
        #expect(peer.targets.last == "obj_background")
        try peer.finish("obj_visible")
        try peer.finish("obj_background")
        _ = try await visible.value
        _ = try await background.value
    }

    @Test func cancellingAnActiveSnapshotPreservesItsSiblingAndReleasesItsSlot() async throws {
        let peer = try SnapshotPeer()
        let pool = HostBrowserSnapshots(executable: peer.executable)
        let cancelled = await start("obj_cancelled", pool: pool, peer: peer)
        defer { cancelled.cancel() }
        let sibling = await start("obj_sibling", pool: pool, peer: peer)
        defer { sibling.cancel() }
        try await peer.waitForCalls(2)
        let queued = await start("obj_queued", pool: pool, peer: peer)
        defer { queued.cancel() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await peer.waitForCalls(3)
        #expect(peer.targets.last == "obj_queued")
        #expect(try peer.finish("obj_sibling"))
        _ = try await sibling.value
        try peer.finish("obj_queued")
        _ = try await queued.value
    }

    @Test func queuedCancellationAndDeadlineDoNotOpenLinksOrConsumeSlots() async throws {
        let peer = try SnapshotPeer()
        let pool = HostBrowserSnapshots(executable: peer.executable)
        let first = await start("obj_first", pool: pool, peer: peer)
        defer { first.cancel() }
        let second = await start("obj_second", pool: pool, peer: peer)
        defer { second.cancel() }
        try await peer.waitForCalls(2)
        let cancelled = await start("obj_cancelled", pool: pool, peer: peer)
        defer { cancelled.cancel() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let expired = await start("obj_expired", pool: pool, peer: peer, deadline: .now + .milliseconds(50))
        defer { expired.cancel() }
        do {
            _ = try await expired.value
            Issue.record("a queued snapshot exceeded its deadline")
        } catch let error as EaslConnection.Failure {
            #expect(error.code == "timeout")
        }
        #expect(Set(peer.targets) == ["obj_first", "obj_second"])
        let next = await start("obj_next", pool: pool, peer: peer)
        defer { next.cancel() }
        try peer.finish("obj_first")
        _ = try await first.value
        try await peer.waitForCalls(3)
        #expect(peer.targets.last == "obj_next")
        try peer.finish("obj_second")
        try peer.finish("obj_next")
        _ = try await second.value
        _ = try await next.value
    }
}
