// swift-tools-version: 6.0
import PackageDescription
import Foundation

func toolOutput(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    do {
        try process.run()
    } catch {
        fatalError("Cannot run \(executable): \(error)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        fatalError("\(executable) \(arguments.joined(separator: " ")) failed: \(text)")
    }
    return text
}

// CLT does not discover these suites through `swift test`, so keep an executable runner.
// Resolve Testing and its macros from the same selected Apple compiler.
let swiftCompiler = URL(fileURLWithPath:
    Context.environment["SWIFT_EXEC"] ?? toolOutput("/usr/bin/xcrun", ["--find", "swiftc"])
).resolvingSymlinksInPath()
let toolchain = swiftCompiler.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let testingFrameworks = toolchain.pathExtension == "xctoolchain"
    ? toolchain.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Platforms/MacOSX.platform/Developer/Library/Frameworks")
    : toolchain.appendingPathComponent("Library/Developer/Frameworks")
let testingLibraries = toolchain.pathExtension == "xctoolchain"
    ? testingFrameworks.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("usr/lib")
    : toolchain.appendingPathComponent("Library/Developer/usr/lib")
let testingMacros = toolchain.appendingPathComponent("usr/lib/swift/host/plugins/testing/libTestingMacros.dylib")

// Temporary CI inventory. Remove after the CLT 27 macro-loading run.
print("Testing compiler: \(swiftCompiler.path)")
print("Testing compiler version: \(toolOutput(swiftCompiler.path, ["--version"]))")
print("Testing SDK: \(toolOutput("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"]))")
print("Testing frameworks: \(testingFrameworks.path)")
print("Testing runtime libraries: \(testingLibraries.path)")
print("Testing macro plugin: \(testingMacros.path)")
let applications = try FileManager.default.contentsOfDirectory(
    at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil
)
for application in applications.sorted(by: { $0.path < $1.path })
    where application.lastPathComponent.hasPrefix("Xcode") && application.pathExtension == "app" {
    let compiler = application.appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
    if FileManager.default.isExecutableFile(atPath: compiler.path) {
        print("Testing candidate \(compiler.path): \(toolOutput(compiler.path, ["--version"]))")
    }
}

for requiredPath in [
    testingFrameworks.appendingPathComponent("Testing.framework"),
    testingLibraries,
    testingMacros,
] {
    guard FileManager.default.fileExists(atPath: requiredPath.path) else {
        fatalError("Selected Swift compiler \(swiftCompiler.path) is missing \(requiredPath.path)")
    }
}

let package = Package(
    name: "Easl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Easl", targets: ["CanvasApp"]),
    ],
    dependencies: [
        // Vendored at 1.6.20260922 with two patches (Vendor/libghostty-spm/CANVAS-PATCH.md).
        // Binary, headers and wrapper must move together (docs/design.md).
        .package(path: "Vendor/libghostty-spm"),
        // Note tiles: CommonMark + GFM (tables, strikethrough, task lists) AST. Apache-2.0.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
        // Syntax trees for code tiles. Grammar versions are the newest whose manifests depend on
        // ChimeHQ/SwiftTreeSitter, so the graph holds a single SwiftTreeSitter.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.23.3"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
    ],
    targets: [
        .target(
            name: "CanvasCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
            ]
        ),
        .executableTarget(
            name: "CanvasApp",
            dependencies: [
                "CanvasCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                // The C API: validating the user's Ghostty config, reading a terminal's text.
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .executableTarget(
            name: "CanvasCoreTests",
            dependencies: ["CanvasCore", .product(name: "Markdown", package: "swift-markdown")],
            path: "Tests/CanvasCoreTests",
            // Recorded language-server answers the tests replay, read from the checkout.
            exclude: ["Fixtures"],
            swiftSettings: [.unsafeFlags([
                "-F", testingFrameworks.path,
                "-load-plugin-library", testingMacros.path,
            ])],
            linkerSettings: [.unsafeFlags([
                "-F", testingFrameworks.path, "-framework", "Testing",
                "-Xlinker", "-rpath", "-Xlinker", testingFrameworks.path,
                "-Xlinker", "-rpath", "-Xlinker", testingLibraries.path,
            ])]
        ),
    ]
)
