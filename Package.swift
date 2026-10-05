// swift-tools-version: 6.0
import PackageDescription

// Command Line Tools ship swift-testing outside the default search and runtime paths, and
// `swift test`'s helper does not discover tests with it. Tests therefore build as an executable
// that calls swift-testing's entry point directly: `swift run CanvasCoreTests`.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

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
            swiftSettings: [.unsafeFlags(["-F", cltFrameworks])],
            linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltLibs])]
        ),
    ]
)
