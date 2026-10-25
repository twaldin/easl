import Darwin
import Foundation
import Testing
import CanvasCore

// The reference fixture reuses this executable so its two-second zmx bound excludes a new script's startup.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "list" {
    do {
        guard let temporary = getenv("TMPDIR") else { exit(2) }
        let listing = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent("zmx-listing")
        FileHandle.standardOutput.write(try Data(contentsOf: listing))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.dropFirst().first == "--update-swap" {
    guard CommandLine.arguments.count == 4 else { exit(2) }
    do {
        try AppUpdate.swapBundles(installed: URL(fileURLWithPath: CommandLine.arguments[2]),
                                  incoming: URL(fileURLWithPath: CommandLine.arguments[3]))
        if ProcessInfo.processInfo.environment["EASL_TEST_EXIT_AFTER_UPDATE_SWAP"] == "1" { _exit(1) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.dropFirst().first == "--update-lease-owner" {
    guard CommandLine.arguments.count == 5,
          ["normal", "forced198"].contains(CommandLine.arguments[4]) else { exit(2) }
    do {
        let force198 = CommandLine.arguments[4] == "forced198"
        var fillers: [Int32] = []
        defer { fillers.forEach { close($0) } }
        if force198 {
            while true {
                let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                if fd >= 198 {
                    close(fd)
                    guard fd == 198 else { throw POSIXError(.EBUSY) }
                    break
                }
                fillers.append(fd)
            }
        }
        let lease = try AppUpdate.StagingLease(incoming: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard force198 ? lease.descriptor == 198 : lease.descriptor != 198 else { throw POSIXError(.EBUSY) }
        fillers.forEach { close($0) }
        fillers.removeAll()
        var actions: posix_spawn_file_actions_t?
        let initialized = posix_spawn_file_actions_init(&actions)
        guard initialized == 0 else { throw POSIXError(.init(rawValue: initialized) ?? .EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        try lease.inherit(in: &actions)
        var attributes: posix_spawnattr_t?
        let attributed = posix_spawnattr_init(&attributes)
        guard attributed == 0 else { throw POSIXError(.init(rawValue: attributed) ?? .EIO) }
        defer { posix_spawnattr_destroy(&attributes) }
        let flagged = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard flagged == 0 else { throw POSIXError(.init(rawValue: flagged) ?? .EIO) }
        let words: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup("exec /bin/sleep 30"), nil]
        defer { words.forEach { free($0) } }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, "/bin/sh", &actions, &attributes, words, environ)
        guard spawned == 0 else { throw POSIXError(.init(rawValue: spawned) ?? .EIO) }
        do {
            try Data("\(child)".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        } catch {
            kill(child, SIGKILL)
            throw error
        }
        withExtendedLifetime(lease) {}
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// See Package.swift: run with `swift run CanvasCoreTests [--filter <name>]`.
let run6FilterIndex = CommandLine.arguments.firstIndex(of: "--filter")
let run6Selector = run6FilterIndex.flatMap { index in
    CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
} ?? "all"
Run6Trace.event("runner.enter", "selector=\(run6Selector) no_parallel=\(CommandLine.arguments.contains("--no-parallel"))")
let run6Status = await Testing.__swiftPMEntryPoint() as CInt
Run6Trace.event("runner.exit", "selector=\(run6Selector) status=\(run6Status)")
exit(run6Status)
