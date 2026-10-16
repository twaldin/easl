import Foundation
import Testing

do {
    let applications = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)
    for application in applications.sorted(by: { $0.path < $1.path })
        where application.lastPathComponent.hasPrefix("Xcode") && application.pathExtension == "app" {
        let compiler = application.appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
        guard FileManager.default.isExecutableFile(atPath: compiler.path) else { continue }
        let process = Process()
        let output = Pipe()
        process.executableURL = compiler
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        print("Toolchain candidate \(compiler.path), exit \(process.terminationStatus): \(String(decoding: data, as: UTF8.self))")
    }
} catch {
    print("Toolchain inventory failed: \(error)")
}

// See Package.swift: run with `swift run CanvasCoreTests [--filter <name>]`.
exit(await Testing.__swiftPMEntryPoint() as CInt)
