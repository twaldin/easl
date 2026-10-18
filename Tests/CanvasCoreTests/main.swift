import Foundation
import Testing
import CanvasCore

if CommandLine.arguments.dropFirst().first == "--update-swap" {
    guard CommandLine.arguments.count == 4 else { exit(2) }
    do {
        try AppUpdate.swapBundles(installed: URL(fileURLWithPath: CommandLine.arguments[2]),
                                  incoming: URL(fileURLWithPath: CommandLine.arguments[3]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// See Package.swift: run with `swift run CanvasCoreTests [--filter <name>]`.
exit(await Testing.__swiftPMEntryPoint() as CInt)
