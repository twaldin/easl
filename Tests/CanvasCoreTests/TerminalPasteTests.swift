import Foundation
import Testing
import CanvasCore

struct TerminalPasteTests {
    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString) with space")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func run(_ directory: URL, _ arguments: [String], input: Data? = nil, base: URL? = nil, script: String = TerminalPaste.script) async throws -> (status: Int32, output: String, errors: String) {
        let environment = ["TMPDIR=\(directory.path)", "EASL_PASTE_BASE=\(base?.path ?? "")"]
        return try await RemoteHost.run("/usr/bin/env", environment + ["/bin/sh", "-c", script, "easl"] + arguments,
                                       input: input, timeout: 10)
    }

    func stage(_ directory: URL, instance: String = "mac-1234", session: String = "canvas-obj_1", name: String = "image.png", bytes: Data) async throws -> String {
        let result = try await run(directory, TerminalPaste.stageArguments(instance: instance, session: session, name: name, size: bytes.count), input: bytes)
        #expect(result.status == 0, "\(result.errors)")
        return try #require(TerminalPaste.stagedPath(result.output))
    }

    @Test func stagedBytesArePrivateAndSessionCleanupIsIsolated() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0, 255, 13, 10])
        let first = try await stage(directory, bytes: bytes)
        let second = try await stage(directory, session: "canvas-obj_2", bytes: bytes)
        let otherInstance = try await stage(directory, instance: "dev-5678", bytes: bytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == bytes)
        let fileMode = try FileManager.default.attributesOfItem(atPath: first)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
        var folder = URL(fileURLWithPath: first).deletingLastPathComponent()
        for _ in 0..<3 {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700)
            folder.deleteLastPathComponent()
        }
        let discarded = try await run(directory, TerminalPaste.discardArguments(instance: "mac-1234", session: "canvas-obj_1"))
        #expect(discarded.status == 0)
        #expect(!FileManager.default.fileExists(atPath: first))
        #expect(try Data(contentsOf: URL(fileURLWithPath: second)) == bytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: otherInstance)) == bytes)
        #expect(try await run(directory, TerminalPaste.discardArguments(instance: "mac-1234", session: "canvas-obj_1")).status == 0)
    }

    @Test func incompleteTransfersAndCollisionsNeverPublishOrOverwrite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await stage(directory, bytes: Data([1, 2, 3]))
        let incomplete = try await run(directory, TerminalPaste.stageArguments(instance: "mac-1234", session: "canvas-obj_1", name: "short.png", size: 8), input: Data([4]))
        #expect(incomplete.status == 2)
        #expect(incomplete.output == "")
        let collision = try await run(directory, TerminalPaste.stageArguments(instance: "mac-1234", session: "canvas-obj_1", name: "image.png", size: 1), input: Data([9]))
        #expect(collision.status == 2)
        #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == Data([1, 2, 3]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: (first as NSString).deletingLastPathComponent) == ["image.png"])
    }

    @Test func concurrentStagesKeepTheirOwnBytesAndNames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstBytes = Data(repeating: 1, count: 256 * 1024)
        let secondBytes = Data(repeating: 2, count: 256 * 1024)
        async let first = stage(directory, name: "first.png", bytes: firstBytes)
        async let second = stage(directory, name: "second.png", bytes: secondBytes)
        let paths = try await [first, second]
        #expect(paths[0] != paths[1])
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == firstBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[1])) == secondBytes)
    }

    @Test func symlinkedRootsParentsSessionsAndDestinationsAreRejected() async throws {
        for level in 0..<4 {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let outside = directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let suffix = ["mac-1234/canvas-obj_1/private.png", "canvas-obj_1/private.png", "private.png", "private.png"][level]
            let kept = outside.appendingPathComponent(suffix)
            try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([8]).write(to: kept)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: kept.path)
            let root = directory.appendingPathComponent("easl-paste-\(getuid())")
            let instance = root.appendingPathComponent("mac-1234")
            let session = instance.appendingPathComponent("canvas-obj_1")
            let target = [root, instance, session, session.appendingPathComponent("image.png")][level]
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            let result = try await run(directory, TerminalPaste.stageArguments(instance: "mac-1234", session: "canvas-obj_1", name: "image.png", size: 1), input: Data([1]))
            #expect(result.status == 2)
            #expect(result.output == "")
            let swept = try await run(directory, ["sweep"])
            #expect(swept.status == (level == 0 ? 2 : 0))
            #expect(try Data(contentsOf: kept) == Data([8]))
            if level < 3 {
                let discard = try await run(directory, TerminalPaste.discardArguments(instance: "mac-1234", session: "canvas-obj_1"))
                #expect(discard.status == 2)
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == outside.path)
            }
        }
    }

    @Test func traversalAndRelativeTemporaryDirectoriesAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [TerminalPaste.stageArguments(instance: "../escape", session: "s", name: "a.png", size: 1),
                     TerminalPaste.stageArguments(instance: "i", session: "..", name: "a.png", size: 1),
                     TerminalPaste.stageArguments(instance: "i", session: "s", name: "../a.png", size: 1)] {
            #expect(try await run(directory, args, input: Data([1])).status == 2)
        }
        let result = try await RemoteHost.run("/usr/bin/env", ["TMPDIR=relative", "/bin/sh", "-c", TerminalPaste.script, "easl"] + TerminalPaste.stageArguments(instance: "i", session: "s", name: "a.png", size: 1), input: Data([1]), timeout: 10)
        #expect(result.status == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [])
    }

    @Test func pruningRemovesOldFilesWithoutFollowingSymlinks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([1, 2])
        let old = try await stage(directory, session: "old", bytes: bytes)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: old)
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appendingPathComponent("private.png")
        try bytes.write(to: kept)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: kept.path)
        let root = directory.appendingPathComponent("easl-paste-\(getuid())")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("foreign-link"), withDestinationURL: outside)
        let fresh = try await stage(directory, session: "fresh", bytes: bytes)
        let expired = try await stage(directory, instance: "other-instance", session: "unwatched", bytes: bytes)
        let boundary = try await stage(directory, session: "not-yet-expired", bytes: bytes)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7 * 86400 + 60)], ofItemAtPath: boundary)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7 * 86400 - 1)], ofItemAtPath: expired)
        let swept = try await run(directory, ["sweep"])
        #expect(swept.status == 0)
        #expect(!FileManager.default.fileExists(atPath: expired))
        #expect(try Data(contentsOf: URL(fileURLWithPath: boundary)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(try Data(contentsOf: kept) == bytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fresh)) == bytes)
    }

    @Test func hostedStorageAndOwnerSweepIgnorePrivateTemporaryNamespaces() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("owner home")
        let privateTmp = directory.appendingPathComponent("private tmp")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privateTmp, withIntermediateDirectories: true)
        let arguments = TerminalPaste.stageArguments(instance: "remote-mac", session: "canvas-unwatched", name: "image.png", size: 3)
        let result = try await run(privateTmp, arguments, input: Data([1, 2, 3]), base: home, script: TerminalPaste.hostScript)
        #expect(result.status == 0, "\(result.errors)")
        let staged = try #require(TerminalPaste.stagedPath(result.output))
        #expect(try Data(contentsOf: URL(fileURLWithPath: staged)) == Data([1, 2, 3]))
        let local = try await stage(privateTmp, bytes: Data([9]))
        let old = Date(timeIntervalSinceNow: -8 * 86400)
        for path in [staged, local] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        let swept = try await run(directory, ["sweep"], base: home)
        #expect(swept.status == 0)
        #expect(!FileManager.default.fileExists(atPath: staged))
        #expect(try Data(contentsOf: URL(fileURLWithPath: local)) == Data([9]))
    }

    @Test func ownerTimerExpiresWithoutInputAndStopsUntilRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startup = try await stage(directory, session: "startup", bytes: Data([1]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: startup)
        let owner = TerminalPaste.Maintenance(baseDirectories: [directory], interval: 0.02)
        defer { owner.stop() }
        for _ in 0..<500 where FileManager.default.fileExists(atPath: startup) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: startup))
        let periodic = try await stage(directory, session: "periodic", bytes: Data([2]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: periodic)
        for _ in 0..<500 where FileManager.default.fileExists(atPath: periodic) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: periodic))
        owner.stop()
        let stopped = try await stage(directory, session: "stopped", bytes: Data([3]))
        let fresh = try await stage(directory, session: "fresh", bytes: Data([4]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86400)], ofItemAtPath: stopped)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: URL(fileURLWithPath: stopped)) == Data([3]))
        let restarted = TerminalPaste.Maintenance(baseDirectories: [directory], interval: 3600)
        defer { restarted.stop() }
        for _ in 0..<500 where FileManager.default.fileExists(atPath: stopped) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: stopped))
        #expect(try Data(contentsOf: URL(fileURLWithPath: fresh)) == Data([4]))
    }

    @Test func onlyOneAbsoluteProtocolPathIsAcceptedAndPathsQuoteAsShellWords() async throws {
        let path = "/tmp/a space/easl-paste-501/mac-1234/canvas-obj_1/image.png"
        #expect(TerminalPaste.stagedPath(path + "\n") == path)
        for bad in ["welcome\n" + path, path + "\nextra\n", path + "\n\n", "tmp/easl-paste-1/i/s/a.png", "/tmp/easl-paste-x/i/s/a.png", "/tmp/../easl-paste-1/i/s/a.png", "/tmp/easl-paste-1/i/s/.part", "/tmp/easl-paste-1/i/s/a\r.png"] {
            #expect(TerminalPaste.stagedPath(bad) == nil)
        }
        let text = TerminalPaste.text(paths: [path, "/tmp/it's.png"])
        let result = try await RemoteHost.run("/bin/sh", ["-c", "printf '%s\\n' \(text)"], timeout: 5)
        #expect(result.output == path + "\n/tmp/it's.png\n")
    }

    @Test func stdinStreamsWhileBothOutputPipesDrain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("bytes")
        let input = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let result = try await RemoteHost.run("/bin/sh", ["-c", "dd if=/dev/zero bs=65536 count=16 2>/dev/null; dd if=/dev/zero bs=65536 count=16 >&2 2>/dev/null; cat > \"$1\"", "easl", destination.path], input: input, timeout: 15)
        #expect(result.status == 0)
        #expect(result.output.utf8.count == 1024 * 1024)
        #expect(result.errors.utf8.count == 1024 * 1024)
        #expect(try Data(contentsOf: destination) == input)
    }

    @Test func earlyExitWithLargeStdinDoesNotHangOrSignalTheApp() async throws {
        let started = Date()
        let result = try await RemoteHost.run("/bin/sh", ["-c", "printf rejected >&2; exit 23"], input: Data(repeating: 1, count: 4 * 1024 * 1024), timeout: 10)
        #expect(result.status == 23)
        #expect(result.errors == "rejected")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func cancellingBlockedStdinEndsAndReapsTheChild() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pid")
        let task = Task {
            try await RemoteHost.run("/bin/sh", ["-c", "echo $$ > \"$1\"; exec sleep 60", "easl", marker.path], input: Data(repeating: 0, count: 4 * 1024 * 1024), timeout: 120)
        }
        defer { task.cancel() }
        var child: Int32?
        for _ in 0..<3000 {
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                child = pid
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(child)
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func timeoutKillsAChildIgnoringTerminationAndUnblocksStdin() async throws {
        let started = Date()
        let result = try await RemoteHost.run("/bin/sh", ["-c", "trap '' TERM; exec sleep 60"], input: Data(repeating: 0, count: 4 * 1024 * 1024), timeout: 0.5)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func remoteScriptKeepsArgumentsAndTemporaryDirectoryLiteral() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmpdir = directory.path + "/it's $(not-a-command)"
        let host = RemoteHost(name: "display", sshTarget: "user@exact-target", socketPath: "/unused", tmpdir: tmpdir, easlBin: "easl")
        let args = host.scriptArguments("printf '%s\\n' \"$TMPDIR\" \"$1\"", ["a ' literal $argument"])
        #expect(args.contains("BatchMode=yes"))
        let target = try #require(args.firstIndex(of: "user@exact-target"))
        let result = try await RemoteHost.run("/bin/sh", ["-c", args[(target + 1)...].joined(separator: " ")], timeout: 5)
        #expect(result.status == 0)
        #expect(result.output == tmpdir + "\na ' literal $argument\n")
    }
}
