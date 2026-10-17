import Darwin
import Foundation
import Testing
import CanvasCore

/// A second app instance on one support dir finds the lock taken and hands its root over.
final class InstanceLockTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    var lock: String { dir.appendingPathComponent("instance.lock").path }
    var socket: String { dir.appendingPathComponent("s").path }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test func aSecondAcquireFailsUntilTheHolderReleases() throws {
        let first = try #require(InstanceLock.acquire(at: lock))
        #expect(InstanceLock.acquire(at: lock) == nil)
        #expect(InstanceLock.holder(at: lock) == getpid())
        first.release()
        let second = try #require(InstanceLock.acquire(at: lock))
        second.release()
    }

    @Test func aCrashedHoldersLockAndStalePidDontBlockTheNextLaunch() throws {
        // Another process takes the lock and records its pid, as a holder does, then dies without releasing it.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl, os, sys, time\nfd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)\nfcntl.flock(fd, fcntl.LOCK_EX)\nos.write(fd, b'%d\\n' % os.getpid())\nprint('held', flush=True)\ntime.sleep(60)", lock]
        let output = Pipe()
        holder.standardOutput = output
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try holder.run()
        #expect(output.fileHandleForReading.availableData == Data("held\n".utf8))
        #expect(InstanceLock.acquire(at: lock) == nil)
        #expect(InstanceLock.holder(at: lock) == holder.processIdentifier)
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        let next = try #require(InstanceLock.acquire(at: lock))
        #expect(InstanceLock.holder(at: lock) == getpid())
        next.release()
    }

    @Test func programsTheHolderStartsDontInheritTheLock() throws {
        // A terminal's zmx attach outlives a crashed app; holding the lock, it would block every
        // next launch. Spawned keeping every descriptor not marked close-on-exec, as a plain fork
        // and exec does (Foundation's Process closes them all, so it can't tell).
        let held = try #require(InstanceLock.acquire(at: lock))
        defer { held.release() }
        var child: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&child, "/bin/sleep", nil, nil, argv, environ) == 0)
        defer { kill(child, SIGKILL); waitpid(child, nil, 0) }
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-p", "\(child)", lock]
        lsof.standardOutput = FileHandle.nullDevice
        lsof.standardError = FileHandle.nullDevice
        try lsof.run()
        lsof.waitUntilExit()
        #expect(lsof.terminationStatus != 0, "the child has the lock file open")
    }

    @Test func forwardAsksTheRunningInstanceToOpenAndShowTheRoot() async throws {
        let server = SocketServer(path: socket) { request, _ in .object(["request": request]) }
        try server.start()
        defer { server.stop() }
        let socket = socket
        let reply = try await offPool { Result { try InstanceLock.forward(root: "/tmp/repo", to: socket) } }.get()
        let request = reply["request"]
        #expect(request?["method"] == .string("board.open"))
        #expect(request?["params"] == .object(["root": .string("/tmp/repo"), "select": .bool(true)]))
    }

    @Test func forwardWaitsForAnInstanceThatIsStillStarting() async throws {
        let server = SocketServer(path: socket) { _, _ in .string("up") }
        defer { server.stop() }
        let socket = socket
        async let reply = offPool { Result { try InstanceLock.forward(root: "/tmp/repo", to: socket) } }
        // A delayed global-queue job can starve behind other fixtures' blocking subprocesses.
        let started: Result<Void, Error> = await withCheckedContinuation { done in
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.5)
                done.resume(returning: Result { try server.start() })
            }
        }
        let response = await reply
        try started.get()
        #expect(try response.get() == .string("up"))
    }
}
