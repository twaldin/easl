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
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
