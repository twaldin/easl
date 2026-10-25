import Foundation
import Testing
import CanvasCore

func runIsolatedTestIfParallel(_ name: String) async throws -> Bool {
    guard !CommandLine.arguments.contains("--no-parallel") else { return false }
    let result = await offPool {
        Result { try isolatedCoreTest(name) }
    }
    let (status, output) = try result.get()
    #expect(status == 0, "\(output)")
    return true
}

func runIsolatedTestIfParallelNow(_ name: String) throws -> Bool {
    guard !CommandLine.arguments.contains("--no-parallel") else { return false }
    let (status, output) = try isolatedCoreTest(name)
    #expect(status == 0, "\(output)")
    return true
}

private func isolatedCoreTest(_ name: String) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--filter", name, "--no-parallel"]
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    Run6Trace.event("child.spawn.begin", "selector=\(name)")
    try process.run()
    Run6Trace.event("child.spawned", "selector=\(name) child_pid=\(process.processIdentifier)")
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    Run6Trace.event("child.exited", "selector=\(name) child_pid=\(process.processIdentifier) status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
    let text = String(decoding: data, as: UTF8.self)
    // Child output stays captured for the existing assertion. Replay only bounded trace records.
    for line in text.split(separator: "\n") where line.hasPrefix("RUN6_TRACE ") && line.utf8.count < 1024 {
        Run6Trace.emit(String(line))
    }
    return (process.terminationStatus, text)
}
