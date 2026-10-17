import Foundation
import Testing
import CanvasCore

func runIsolatedTestIfParallel(_ name: String) async throws -> Bool {
    guard !CommandLine.arguments.contains("--no-parallel") else { return false }
    let executable = CommandLine.arguments[0]
    let result = await offPool {
        Result {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
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
    }
    let (status, output) = try result.get()
    #expect(status == 0, "\(output)")
    return true
}
