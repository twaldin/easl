import Foundation
import Testing
import CanvasCore

struct GroupViewTooltipTests {
    @Test func authorTooltipKeepsItsOwnerAndReturnsTheCurrentAuthor() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let result = await offPool {
            Result {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", root.appendingPathComponent("Tests/GroupViewTooltip/run.py").path, "--bin-path", build.path]
                process.currentDirectoryURL = root
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
    }
}
