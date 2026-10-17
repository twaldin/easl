import Foundation
import Testing

// See Package.swift: run with `swift run CanvasCoreTests [--filter <name>]`.
Thread.detachNewThread {
    let started = ProcessInfo.processInfo.systemUptime
    let pid = ProcessInfo.processInfo.processIdentifier
    for point in [5.0, 10.0, 20.0] {
        Thread.sleep(forTimeInterval: max(0, point - (ProcessInfo.processInfo.systemUptime - started)))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("easl-ci-sample-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(pid)", "1", "-file", file.path]
        do {
            try process.run()
            process.waitUntilExit()
            FileHandle.standardError.write(Data("EASL_SAMPLE_BEGIN \(point)\n".utf8))
            FileHandle.standardError.write(try Data(contentsOf: file))
            FileHandle.standardError.write(Data("EASL_SAMPLE_END \(point)\n".utf8))
            try? FileManager.default.removeItem(at: file)
        } catch {
            FileHandle.standardError.write(Data("EASL_SAMPLE_ERROR \(point) \(error)\n".utf8))
        }
    }
}
exit(await Testing.__swiftPMEntryPoint() as CInt)
