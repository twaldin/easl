import Darwin
import Foundation
import Testing
import CanvasCore

struct LSPFramerTests {
    func framed(_ json: String) -> Data { LSPFramer.frame(Data(json.utf8)) }

    @Test func messagesSplitAcrossReadsAreReassembled() throws {
        var framer = LSPFramer()
        let message = framed(#"{"jsonrpc":"2.0","id":1,"result":"héllo"}"#)
        var bodies: [Data] = []
        for byte in message { bodies += try framer.append(Data([byte])) }
        #expect(bodies.map { String(decoding: $0, as: UTF8.self) } == [#"{"jsonrpc":"2.0","id":1,"result":"héllo"}"#])
    }

    @Test func concatenatedMessagesComeOutInOrderAndAPartialTailWaits() throws {
        var framer = LSPFramer()
        let third = framed(#"{"id":3}"#)
        var chunk = framed(#"{"id":1}"#) + framed(#"{"id":2}"#)
        chunk.append(third.prefix(10))
        #expect(try framer.append(chunk).map { String(decoding: $0, as: UTF8.self) } == [#"{"id":1}"#, #"{"id":2}"#])
        #expect(try framer.append(third.dropFirst(10)).map { String(decoding: $0, as: UTF8.self) } == [#"{"id":3}"#])
    }

    @Test func contentLengthCountsBytesAndExtraHeadersAreIgnored() throws {
        var framer = LSPFramer()
        let body = #"{"s":"→✓"}"#
        let wire = "content-length: \(body.utf8.count)\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n\(body)"
        #expect(try framer.append(Data(wire.utf8)).map { String(decoding: $0, as: UTF8.self) } == [body])
    }

    @Test func aHeaderWithoutContentLengthIsAnError() {
        var framer = LSPFramer()
        #expect(throws: LSPFramer.FramingError.self) { try framer.append(Data("Content-Type: x\r\n\r\n{}".utf8)) }
    }
}

struct HoverMarkdownTests {
    @Test func fencesHeadingsRulesAndParagraphsBecomeBlocks() {
        let markdown = "## Multiple results\n\n```swift\npublic struct Model\n```\n\n---\n\nThe *area*\nin points.\n\nSecond paragraph.\n~~~\nunterminated"
        #expect(HoverMarkdown.blocks(markdown) == [
            .heading([.init("Multiple results")]),
            .code(language: "swift", text: "public struct Model"),
            .rule,
            .prose([.init("The "), .init("area", emphasis: true), .init("\nin points.")]),
            .prose([.init("Second paragraph.")]),
            .code(language: nil, text: "unterminated"),
        ])
    }

    /// Each block as it reads: a heading's or paragraph's spans joined, code as is.
    func read(_ markdown: String) -> [String] {
        HoverMarkdown.blocks(markdown).map { block in
            switch block {
            case .heading(let spans), .prose(let spans): spans.map(\.text).joined()
            case .code(_, let text): text
            case .rule: "---"
            }
        }
    }

    @Test func escapedPunctuationReadsWithoutItsBackslash() {
        // What sourcekit-lsp passes through from a doc comment, and pyright writes for a docstring.
        #expect(read("# Discussion of max\\_depth and \\*args\n\nLoad the \\_\\_init\\_\\_ config for \\*user\\_name\\* from \\[path\\] \\# not a heading, a\\\\b &amp; c") == [
            "Discussion of max_depth and *args",
            "Load the __init__ config for *user_name* from [path] # not a heading, a\\b & c",
        ])
    }

    @Test func backslashesInCodeStay() {
        #expect(HoverMarkdown.blocks("See `snake_case\\path` or `a\\_b`.") == [
            .prose([.init("See "), .init("snake_case\\path", code: true), .init(" or "), .init("a\\_b", code: true), .init(".")]),
        ])
        #expect(HoverMarkdown.blocks("## The `a\\_b` key") == [.heading([.init("The "), .init("a\\_b", code: true), .init(" key")])])
        #expect(read("```\nre.sub(r\"\\_\", x)\n```") == ["re.sub(r\"\\_\", x)"])
    }

    @Test func indentedCodeIsCodeUnlessItContinuesAParagraph() {
        // String's doc comment, as sourcekit-lsp passes it: the interpolation's backslash stays.
        let markdown = "Prefixed by a\nbackslash.\n\n    let name = \"Rosa\"\n    let greeting = \"Welcome, \\(name)!\"\n\n        print(2 * n * m)\n\nThen\n    more of the paragraph."
        #expect(HoverMarkdown.blocks(markdown) == [
            .prose([.init("Prefixed by a\nbackslash.")]),
            .code(language: nil, text: "let name = \"Rosa\"\nlet greeting = \"Welcome, \\(name)!\"\n\n    print(2 * n * m)"),
            .prose([.init("Then\n    more of the paragraph.")]),
        ])
    }

    @Test func anUnderlinedParagraphIsAHeadingAndARuleNeedsABlankLineBefore() {
        #expect(HoverMarkdown.blocks("Accessing a String's\nUnicode Representation\n=====\n\nText\n---\n\n---\n\nEnd") == [
            .heading([.init("Accessing a String's\nUnicode Representation")]),
            .heading([.init("Text")]),
            .rule,
            .prose([.init("End")]),
        ])
    }
}

struct LSPRangeTests {
    let identifier = LSPRange(start: LSPPosition(line: 2, character: 4), end: LSPPosition(line: 2, character: 9))

    @Test func theEndIsExclusive() {
        #expect(identifier.contains(LSPPosition(line: 2, character: 4)))
        #expect(identifier.contains(LSPPosition(line: 2, character: 8)))
        #expect(!identifier.contains(LSPPosition(line: 2, character: 9)))
        #expect(!identifier.contains(LSPPosition(line: 2, character: 3)))
    }

    @Test func boardLinesAreOneBasedInclusiveAndDropAnEndAtColumnZero() {
        #expect(identifier.lines == LineRange(start: 3, end: 3))
        let wholeLines = LSPRange(start: LSPPosition(line: 4, character: 0), end: LSPPosition(line: 7, character: 0))
        #expect(wholeLines.lines == LineRange(start: 5, end: 7))
        let intoLastLine = LSPRange(start: LSPPosition(line: 4, character: 2), end: LSPPosition(line: 7, character: 1))
        #expect(intoLastLine.lines == LineRange(start: 5, end: 8))
        let empty = LSPRange(start: LSPPosition(line: 4, character: 0), end: LSPPosition(line: 4, character: 0))
        #expect(empty.lines == LineRange(start: 5, end: 5))
    }
}

/// Shells with misbehaving startup files, written as scripts that stand in for `$SHELL`.
final class LoginShellTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-shell-\(UUID().uuidString.prefix(8))")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func shell(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("shell-\(UUID().uuidString.prefix(4))")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // The bounds leave room for a loaded CI runner (spawning a login shell there takes up to ~5 s)
    // and still fail a real stall: the stand-in shells' children sleep 60 s.

    @Test func aChildHoldingTheOutputOpenDoesNotStallTheLookup() async throws {
        // Reading until the child's EOF would wait for the deadline: 30 s, three times the bound.
        let deadline: Duration = .seconds(30)
        let login = LoginShell(shell: try shell("sleep 60 &\neval \"$2\""), timeout: deadline)
        let start = ContinuousClock.now
        #expect(await offPool { login.resolve("ls") } == URL(fileURLWithPath: "/bin/ls"))
        #expect(start.duration(to: .now) < deadline / 3)
    }

    @Test func aHangingShellIsKilledAtTheDeadline() async throws {
        // Not killed at the deadline, it would hang for the shell's 60 s.
        let deadline: Duration = .seconds(1)
        let login = LoginShell(shell: try shell("sleep 60"), timeout: deadline)
        let start = ContinuousClock.now
        #expect(await offPool { login.resolve("ls") } == nil)
        #expect(start.duration(to: .now) < deadline + .seconds(9))
    }

    /// The rust study: rust-analyzer installed by nvim's mason, not on the login PATH, was
    /// "not installed", and the hint's rustup fix wouldn't have put it on PATH either.
    @Test func serversAreFoundByTheVariableThenPathThenInstallDirectoriesThenLocators() async throws {
        func tool(_ directory: String) throws -> String {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = directory + "/fake-ls"
            try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let home = dir.path + "/home"
        let mason = try tool(home + "/.local/share/nvim/mason/bin")
        let onPath = try tool(dir.path + "/bin")
        let named = try tool(dir.path + "/elsewhere")
        let located = try tool(dir.path + "/toolchain")
        let config = LanguageServerConfig(language: "fake", command: "fake-ls", languageIDs: [:], rootMarkers: [], locators: ["echo \(located)"])
        func locate(path: String, variable: String? = nil, home: String = home, _ config: LanguageServerConfig = config) async throws -> String? {
            let exported = variable.map { "export EASL_LSP_FAKE=\($0)\n" } ?? ""
            let login = LoginShell(shell: try shell("PATH=\(path)\n\(exported)eval \"$2\""), home: home)
            return await offPool { login.locate(config) }?.path
        }
        let system = "/usr/bin:/bin"
        #expect(try await locate(path: "\(dir.path)/bin:\(system)") == onPath)
        #expect(try await locate(path: "\(dir.path)/bin:\(system)", variable: named) == named, "the variable wins over PATH")
        #expect(try await locate(path: system) == mason, "mason's bin when PATH lacks it")
        #expect(try await locate(path: system, home: "/nonexistent") == located, "the locator last")
        var bare = config
        bare.locators = []
        #expect(try await locate(path: system, home: "/nonexistent", bare) == nil)
    }
}

/// Temp projects driven through the real language servers installed on this machine. Not on the
/// main actor: other suites keep it busy, and timing checks (idle shutdown) must not wait on it.
final class LanguageServiceTests: Sendable {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-lsp-\(UUID().uuidString.prefix(8))")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func pid(_ service: LanguageService, _ file: URL) async -> Int32? {
        guard case .running(let pid)? = await service.existingServer(for: file, boardRoot: dir)?.status else { return nil }
        return pid
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Polls a condition that depends on another process (exit, indexing) with a deadline.
    func eventually(_ seconds: Double, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return try await condition()
    }

    func lines(_ locations: [LSPLocation]) -> [String] {
        locations.map { "\($0.url.resolvingSymlinksInPath().lastPathComponent):\($0.range.start.line)" }.sorted()
    }

    // MARK: sourcekit-lsp

    @Test func swiftPackageHoverDefinitionReferencesAndSymbols() async throws {
        try write("Package.swift", """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Lib", targets: [.target(name: "Lib")])
        """)
        let model = try write("Sources/Lib/Model.swift", """
        public struct Model {
            public var width: Int
            public var height: Int

            public func area() -> Int {
                width * height
            }
        }
        """)
        let use = try write("Sources/Lib/Use.swift", """
        func makeModel() -> Model {
            let model = Model(width: 2, height: 3)
            _ = model.area()
            return model
        }

        func total(_ models: [Model]) -> Int {
            models.map { $0.area() }.reduce(0, +)
        }
        """)
        // easl turns sourcekit-lsp's background indexing off; the index comes from the user's
        // own build, as it would for a repo someone works in.
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        build.arguments = ["build", "-j", "2", "--package-path", dir.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        let buildStatus = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            build.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try build.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(buildStatus == 0)

        let service = LanguageService()
        let area = LSPPosition(line: 2, character: 14)

        // Until SwiftPM has produced build settings, sourcekit-lsp answers from fallback settings
        // that can't see other files, so cross-file answers appear once the package is loaded.
        var hover: LSPHover?
        _ = try await eventually(180) {
            hover = try await service.hover(file: use, boardRoot: dir, at: area)
            return hover != nil
        }
        #expect(hover?.markdown.contains("func area() -> Int") == true)
        #expect(hover?.range?.contains(area) == true)

        let definition = try await service.definition(file: use, boardRoot: dir, at: area)
        #expect(lines(definition) == ["Model.swift:4"])

        // The index store from that build is read as sourcekit-lsp starts up.
        var references: [LSPLocation] = []
        _ = try await eventually(180) {
            references = try await service.references(file: use, boardRoot: dir, at: area)
            return !references.isEmpty
        }
        #expect(lines(references) == ["Model.swift:4", "Use.swift:2", "Use.swift:7"])

        let symbols = try await service.documentSymbols(file: model, boardRoot: dir)
        #expect(symbols.map(\.name) == ["Model"])
        #expect(symbols.first?.children.map(\.name) == ["width", "height", "area()"])

        // The file changes on disk; the next request re-syncs it before asking.
        try write("Sources/Lib/Use.swift", "func buildModel() -> Model { Model(width: 1, height: 1) }\n")
        #expect(try await service.documentSymbols(file: use, boardRoot: dir).map(\.name) == ["buildModel()"])
        await service.stopAll()
        // Opening the package never made sourcekit-lsp build it (background indexing is off).
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".build/index-build").path))
    }

    /// A loose Swift file (no package) gets sourcekit-lsp's fallback settings: cheap, no indexing.
    func looseSwiftFile() throws -> URL {
        try write("loose/Shapes.swift", "struct Circle {\n    var radius: Double\n}\n\nfunc unit() -> Circle { Circle(radius: 1) }\n")
    }

    @Test func idleServerIsShutDown() async throws {
        let file = try looseSwiftFile()
        let service = LanguageService(idleTimeout: .seconds(3))
        #expect(try await service.documentSymbols(file: file, boardRoot: dir).map(\.name) == ["Circle", "unit()"])
        let pid = try #require(await pid(service, file))
        #expect(Self.isAlive(pid))
        #expect(await eventually(10) { !Self.isAlive(pid) })
        #expect(await service.existingServer(for: file, boardRoot: dir) == nil)
        // The next request starts a fresh server.
        #expect(try await service.documentSymbols(file: file, boardRoot: dir).map(\.name) == ["Circle", "unit()"])
        await service.stopAll()
    }

    @Test func crashedServerReportsItAndRestartsOnTheNextRequest() async throws {
        let file = try looseSwiftFile()
        let service = LanguageService()
        _ = try await service.documentSymbols(file: file, boardRoot: dir)
        let first = try #require(await pid(service, file))
        kill(first, SIGKILL)
        let crashed = await eventually(10) {
            if case .crashed(let reason)? = await service.existingServer(for: file, boardRoot: dir)?.status { return reason.contains("sourcekit-lsp exited") }
            return false
        }
        #expect(crashed)
        #expect(try await service.documentSymbols(file: file, boardRoot: dir).map(\.name) == ["Circle", "unit()"])
        let second = try #require(await pid(service, file))
        #expect(second != first)
        await service.stopAll()
        #expect(!Self.isAlive(second))
    }

    @Test func cancelledRequestThrowsAndTheServerKeepsAnswering() async throws {
        let file = try looseSwiftFile()
        let service = LanguageService()
        let superseded = Task { try await service.hover(file: file, boardRoot: dir, at: LSPPosition(line: 4, character: 25)) }
        superseded.cancel()
        await #expect(throws: CancellationError.self) { try await superseded.value }
        let hover = try await service.hover(file: file, boardRoot: dir, at: LSPPosition(line: 4, character: 25))
        #expect(hover?.markdown.contains("Circle") == true)
        await service.stopAll()
    }

    @Test func missingServerBinaryIsReportedUnavailable() async throws {
        let file = try write("main.swift", "let x = 1\n")
        let config = LanguageServerConfig(language: "swift", command: "canvas-no-such-language-server", languageIDs: ["swift": "swift"], rootMarkers: [])
        let service = LanguageService(configs: [config])
        await #expect(throws: LSPError.unavailable(config.notFound)) {
            try await service.hover(file: file, boardRoot: dir, at: LSPPosition(line: 0, character: 4))
        }
        await #expect(throws: LSPError.unsupportedLanguage(".txt files")) {
            try await service.hover(file: dir.appendingPathComponent("notes.txt"), boardRoot: dir, at: LSPPosition(line: 0, character: 0))
        }
    }

    // MARK: Lifecycle with stand-in servers

    /// A server that never answers initialize (and never reads its input). With `ignoringSIGTERM`,
    /// it creates that file once its SIGTERM trap is installed, so a test can wait for it.
    func silentServer(_ language: String, ignoringSIGTERM ready: URL? = nil) -> LanguageServerConfig {
        let arguments = ready.map { ["-c", "trap '' TERM; : > \"$1\"; exec /usr/bin/tail -f /dev/null", "sh", $0.path] }
            ?? ["-c", "exec /usr/bin/tail -f /dev/null"]
        return LanguageServerConfig(language: language, command: "/bin/sh", arguments: arguments, languageIDs: [language: language], rootMarkers: [])
    }

    func startingPid(_ service: LanguageService, _ file: URL) async -> Int32? {
        var pid: Int32?
        _ = await eventually(10) {
            pid = await service.existingServer(for: file, boardRoot: dir)?.pid
            return pid != nil
        }
        return pid
    }

    @Test func stoppingAServerThatIsStillStartingKillsIt() async throws {
        let file = try write("a.hang", "x\n")
        let service = LanguageService(configs: [silentServer("hang")])
        let request = Task { try await service.hover(file: file, boardRoot: dir, at: LSPPosition(line: 0, character: 0)) }
        let pid = try #require(await startingPid(service, file))
        await service.stopAll()
        #expect(!Self.isAlive(pid))
        await #expect(throws: LSPError.self) { try await request.value }
        #expect(await service.existingServer(for: file, boardRoot: dir) == nil)
        #expect(service.liveProcessCount == 0)
    }

    @Test func evictingAServerThatIsStillStartingKillsItAndKeepsItOut() async throws {
        let first = try write("a.one", "x\n")
        let second = try write("b.two", "x\n")
        let service = LanguageService(configs: [silentServer("one"), silentServer("two")], maxRunning: 1)
        let firstRequest = Task { try await service.hover(file: first, boardRoot: dir, at: LSPPosition(line: 0, character: 0)) }
        let firstPid = try #require(await startingPid(service, first))
        let secondRequest = Task { try await service.hover(file: second, boardRoot: dir, at: LSPPosition(line: 0, character: 0)) }
        _ = try #require(await startingPid(service, second))
        #expect(await eventually(10) { !Self.isAlive(firstPid) })
        await #expect(throws: LSPError.self) { try await firstRequest.value }
        #expect(await service.existingServer(for: first, boardRoot: dir) == nil)
        await service.stopAll()
        await #expect(throws: LSPError.self) { try await secondRequest.value }
        #expect(service.liveProcessCount == 0)
    }

    @Test func quitKillsAServerThatIgnoresSIGTERM() async throws {
        let file = try write("a.hang", "x\n")
        let trapped = dir.appendingPathComponent("hang-trapped")
        let service = LanguageService(configs: [silentServer("hang", ignoringSIGTERM: trapped)])
        let request = Task { try await service.hover(file: file, boardRoot: dir, at: LSPPosition(line: 0, character: 0)) }
        let pid = try #require(await startingPid(service, file))
        // SIGTERM sent before the shell installs its trap would end it by SIGTERM, not SIGKILL.
        #expect(await eventually(10) { FileManager.default.fileExists(atPath: trapped.path) })
        await service.terminateAll(grace: .milliseconds(500))
        #expect(!Self.isAlive(pid))
        #expect(service.liveProcessCount == 0)
        // It ignored SIGTERM, so it ended by SIGKILL: Process reports the signal as its status.
        let error = await #expect(throws: LSPError.self) { try await request.value }
        guard case .serverExited(let reason)? = error else {
            Issue.record("\(String(describing: error)) is not serverExited")
            return
        }
        #expect(reason.hasSuffix("exited with status \(SIGKILL)"), "\(reason)")
    }

    @Test func aServerThatDiesDuringInitializeLeavesNothingBehind() async throws {
        let file = try write("a.dead", "x\n")
        let config = LanguageServerConfig(language: "dead", command: "/usr/bin/false", languageIDs: ["dead": "dead"], rootMarkers: [])
        let service = LanguageService(configs: [config])
        await #expect(throws: LSPError.self) { try await service.hover(file: file, boardRoot: dir, at: LSPPosition(line: 0, character: 0)) }
        #expect(service.liveProcessCount == 0)
        if case .crashed? = await service.existingServer(for: file, boardRoot: dir)?.status {} else {
            Issue.record("a failed start is reported as crashed")
        }
    }

    /// Answers initialize, then never reads its input again.
    func deafServer() throws -> LanguageServerConfig {
        let script = try write("deaf.py", """
        import sys, json
        stdin = sys.stdin.buffer
        length = 0
        while True:
            line = stdin.readline().strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        request = json.loads(stdin.read(length))
        body = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"capabilities": {}}}).encode()
        sys.stdout.buffer.write(b"Content-Length: %d\\r\\n\\r\\n" % len(body) + body)
        sys.stdout.buffer.flush()
        import time
        time.sleep(600)
        """)
        return LanguageServerConfig(language: "deaf", command: "/usr/bin/python3", arguments: [script.path], languageIDs: ["deaf": "deaf"], rootMarkers: [])
    }

    @Test func aServerThatStopsReadingCannotBlockCancellation() async throws {
        // Far more than a pipe buffer: the didOpen can't be written while the server isn't reading.
        let file = try write("big.deaf", String(repeating: "let value = 1\n", count: 400_000))
        let service = LanguageService(configs: [try deafServer()])
        let request = Task { try await service.hover(file: file, boardRoot: dir, at: LSPPosition(line: 0, character: 0)) }
        _ = try #require(await startingPid(service, file))
        #expect(await eventually(10) {
            if case .running? = await service.existingServer(for: file, boardRoot: dir)?.status { return true }
            return false
        })
        let start = ContinuousClock.now
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(start.duration(to: .now) < .seconds(2))
        // The registry isn't stuck behind the pending write either.
        await service.stopAll()
        #expect(service.liveProcessCount == 0)
    }

    // MARK: pyright

    /// Evaluated per test through GCD (the login-shell lookup blocks); cached by LoginShell.
    nonisolated static let hasPyright: ConditionTrait = .enabled("pyright-langserver is installed") {
        await offPool { LoginShell.shared.resolve("pyright-langserver") != nil }
    }

    func pythonProject() throws -> (shapes: URL, use: URL) {
        try write("py/pyproject.toml", "[project]\nname = \"shapes\"\n")
        let shapes = try write("py/shapes.py", "class Shape:\n    def area(self) -> int:\n        return 1\n")
        let use = try write("py/use.py", "from shapes import Shape\n\ndef total(items: list[Shape]) -> int:\n    s = Shape()\n    return s.area() + sum(i.area() for i in items)\n")
        return (shapes, use)
    }

    @Test(hasPyright) func pythonHoverDefinitionReferencesAndSymbols() async throws {
        let (_, use) = try pythonProject()
        let service = LanguageService()
        let shape = LSPPosition(line: 3, character: 9)
        #expect(try await service.hover(file: use, boardRoot: dir, at: shape)?.markdown.contains("class Shape") == true)
        #expect(lines(try await service.definition(file: use, boardRoot: dir, at: shape)) == ["shapes.py:0"])
        #expect(lines(try await service.references(file: use, boardRoot: dir, at: shape)) == ["shapes.py:0", "use.py:0", "use.py:2", "use.py:3"])
        #expect(try await service.documentSymbols(file: use, boardRoot: dir).map(\.name) == ["total"])
        await service.stopAll()
    }

    @Test(hasPyright) func openDocumentsFollowDiskAndCloseWhenReleased() async throws {
        let (shapes, use) = try pythonProject()
        let service = LanguageService()
        let shape = LSPPosition(line: 3, character: 9)
        await service.retain(file: shapes, boardRoot: dir)
        #expect(try await service.documentSymbols(file: shapes, boardRoot: dir).map(\.name) == ["Shape"])
        let server = try #require(await service.existingServer(for: shapes, boardRoot: dir))
        // Only the retained file stays open; the request's own document closes after it.
        #expect(await server.openDocumentCount == 1)

        // shapes.py changes on disk while a request is about another file.
        try write("py/shapes.py", "\n\n\nclass Shape:\n    def area(self) -> int:\n        return 1\n")
        #expect(lines(try await service.definition(file: use, boardRoot: dir, at: shape)) == ["shapes.py:3"])

        await service.release(file: shapes, boardRoot: dir)
        #expect(await server.openDocumentCount == 0)
        await service.stopAll()
    }

    @Test(hasPyright) func startingAServerBeyondTheCapStopsTheLeastRecentlyUsed() async throws {
        let swift = try looseSwiftFile()
        let (_, use) = try pythonProject()
        let service = LanguageService(maxRunning: 1)
        _ = try await service.documentSymbols(file: swift, boardRoot: dir)
        let swiftPid = try #require(await pid(service, swift))
        #expect(try await service.documentSymbols(file: use, boardRoot: dir).map(\.name) == ["total"])
        #expect(await service.existingServer(for: swift, boardRoot: dir) == nil)
        #expect(await eventually(10) { !Self.isAlive(swiftPid) })
        await service.stopAll()
    }
}
