import Darwin
import Foundation
import Testing
@testable import CanvasCore

final class LanguageHost: @unchecked Sendable {
    let fixture: HostFileFixture
    let files: HostFiles
    let server: URL
    let record: URL
    let down: URL
    let holdAnswers: URL
    let holdCommands: URL

    init() throws {
        fixture = try HostFileFixture()
        server = fixture.directory.appendingPathComponent("fake-language-server")
        record = fixture.directory.appendingPathComponent("server.json")
        down = fixture.directory.appendingPathComponent("down")
        holdAnswers = fixture.directory.appendingPathComponent("hold-answers")
        holdCommands = fixture.directory.appendingPathComponent("hold-commands")
        let login = fixture.directory.appendingPathComponent("login-shell")
        try Self.executable(login, "#!/bin/sh\nexport EASL_LSP_FAKE=\(RemoteHost.quote(server.path))\neval \"$2\"\n")
        try Self.executable(server, Self.fakeServer)
        files = try fixture.reader(body: """
        if [ -e \(RemoteHost.quote(down.path)) ]; then echo 'ssh: connect to host fixture port 22: Connection refused' >&2; exit 255; fi
        if [ -e \(RemoteHost.quote(holdCommands.path)) ]; then
          : > \(RemoteHost.quote(holdCommands.path + ".held"))
          while [ -e \(RemoteHost.quote(holdCommands.path)) ]; do sleep 0.05; done
        fi
        SHELL=\(RemoteHost.quote(login.path)) /bin/sh -c "$command"
        """)
    }

    func config(_ mode: String = "plain") -> LanguageServerConfig {
        LanguageServerConfig(language: "fake", command: "fake-language-server", arguments: [record.path, mode, holdAnswers.path], languageIDs: ["fake": "fake"], rootMarkers: ["fake.toml"])
    }

    func recorded() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: record))
    }

    func reachable(_ up: Bool) throws {
        if up { try FileManager.default.removeItem(at: down) } else { try Data().write(to: down) }
    }

    func held(_ hold: URL) -> Bool {
        FileManager.default.fileExists(atPath: hold.path + ".held")
    }

    static func executable(_ url: URL, _ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static let fakeServer = #"""
    #!/usr/bin/python3
    import json, os, signal, sys, time
    record, mode, hold = sys.argv[1], sys.argv[2], sys.argv[3]
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    texts = {}
    if mode == "stubborn":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)

    def read():
        length = 0
        while True:
            line = stdin.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        return json.loads(stdin.read(length))

    def symbols(text):
        found = []
        for number, line in enumerate(text.split("\n")):
            if line.startswith("func "):
                span = {"start": {"line": number, "character": 5}, "end": {"line": number, "character": len(line)}}
                found.append({"name": line[5:].strip(), "kind": 12, "range": span, "selectionRange": span})
        return found

    while True:
        message = read()
        if message is None or message.get("method") == "exit":
            while mode == "stubborn":
                time.sleep(60)
            sys.exit(0)
        method, params = message.get("method"), message.get("params") or {}
        document = params.get("textDocument") or {}
        if method == "textDocument/didOpen":
            texts[document["uri"]] = document["text"]
        elif method == "textDocument/didChange":
            texts[document["uri"]] = params["contentChanges"][-1]["text"]
        elif method == "textDocument/didClose":
            texts.pop(document["uri"], None)
        if "id" not in message:
            continue
        result = None
        if method == "initialize":
            with open(record, "w") as out:
                json.dump({"pid": os.getpid(), "processId": params.get("processId")}, out)
            result = {"capabilities": {"documentSymbolProvider": True}}
        elif method == "textDocument/documentSymbol":
            if os.path.exists(hold):
                open(hold + ".held", "w").close()
                while os.path.exists(hold):
                    time.sleep(0.05)
            result = symbols(texts.get(document["uri"], ""))
        body = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}).encode()
        stdout.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        stdout.flush()
    """#
}

struct HostLanguageTests {
    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func eventually(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    @Test func aHostsServerIsFoundAndRunThereAndNamedByItsPidThere() async throws {
        let host = try LanguageHost()
        let board = host.fixture.root
        let file = board.appendingPathComponent("proj/main.fake")
        try write(board.appendingPathComponent("proj/fake.toml"), "")
        try write(file, "func alpha\n")
        let service = LanguageService(host: host.files, configs: [host.config()])
        #expect(service.hostName == "fixture")
        #expect(try await service.documentSymbols(file: file, boardRoot: board).map(\.name) == ["alpha"])
        let server = try #require(await service.existingServer(for: file, boardRoot: board))
        let record = try host.recorded()
        #expect(record["processId"] == .null, "this Mac's pid means nothing on the host")
        let pid = Int32(try #require(record["pid"]?.int))
        #expect(await server.status == .running(pid: pid), "the server's pid there, not its ssh's here")
        #expect(server.root.path == GitDiffEngine.realPath(board).path + "/proj", "the project the host's root marker names")
        await service.stopAll()
    }

    @Test func aServerTheHostLacksIsNamedWithTheHostAndNothingStarts() async throws {
        let host = try LanguageHost()
        let file = host.fixture.root.appendingPathComponent("main.fake")
        try write(file, "func alpha\n")
        let missing = LanguageServerConfig(language: "ghost", command: "canvas-no-such-language-server", languageIDs: ["fake": "ghost"], rootMarkers: [])
        let service = LanguageService(host: host.files, configs: [missing])
        do {
            _ = try await service.documentSymbols(file: file, boardRoot: host.fixture.root)
            Issue.record("A missing host server answered")
        } catch LSPError.unavailable(let message) {
            #expect(message.contains(missing.command))
            #expect(message.contains("fixture"))
        }
        #expect(service.liveProcessCount == 0)
    }

    @Test func resolvedHostLocationsStayRelativeToTheBoardsRootSpelling() async throws {
        let host = try LanguageHost()
        let alias = host.fixture.directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: host.fixture.root)
        let file = alias.appendingPathComponent("main.fake")
        try write(file, "func alpha\n")
        let service = LanguageService(host: host.files, configs: [host.config()])
        #expect(try await service.documentSymbols(file: file, boardRoot: alias).map(\.name) == ["alpha"])
        #expect(service.relativePath(GitDiffEngine.realPath(file).path, boardRoot: alias) == "main.fake")
        await service.stopAll()
    }

    @Test func theBoardsWorktreesAreReadOnTheHostAndASymlinkOutOfThemIsRefused() async throws {
        let host = try LanguageHost()
        let repo = try await TempRepo()
        let worktree = GitDiffEngine.realPath(FileManager.default.temporaryDirectory).appendingPathComponent("canvas-wt-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo.root)
            try? FileManager.default.removeItem(at: worktree)
        }
        try await repo.write("proj/fake.toml", "")
        try await repo.write("proj/main.fake", "func alpha\n")
        try await repo.commit("base")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        let theirs = worktree.appendingPathComponent("proj/main.fake")
        try write(theirs, "func beta\n")
        let outside = host.fixture.directory.appendingPathComponent("outside.fake")
        try write(outside, "func secret\n")
        let escape = repo.url("proj/escape.fake")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        let service = LanguageService(host: host.files, configs: [host.config()])

        #expect(try await service.text(file: theirs, boardRoot: repo.root) == "func beta\n")
        #expect(try await service.checkoutRoot(file: theirs, boardRoot: repo.root).path == worktree.path)
        #expect(try await service.checkoutRoot(file: repo.url("proj/main.fake"), boardRoot: repo.root) == repo.root)
        #expect(try await service.documentSymbols(file: theirs, boardRoot: repo.root).map(\.name) == ["beta"])
        #expect(await service.existingServer(for: theirs, boardRoot: repo.root)?.root.path == worktree.path + "/proj", "that checkout's own project")

        await #expect(throws: HostFileError.refused) { try await service.text(file: escape, boardRoot: repo.root) }
        await #expect(throws: LSPError.self) {
            try await service.documentSymbols(file: escape, boardRoot: repo.root)
        }
        await service.stopAll()
    }

    @Test func openDocumentsFollowTheHostAndAnUnreachableHostIsNoDeletion() async throws {
        let host = try LanguageHost()
        let board = host.fixture.root
        let file = board.appendingPathComponent("main.fake")
        try write(file, "func alpha\n")
        let service = LanguageService(host: host.files, configs: [host.config()])
        await service.retain(file: file, boardRoot: board)
        #expect(try await service.documentSymbols(file: file, boardRoot: board).map(\.name) == ["alpha"])
        let server = try #require(await service.existingServer(for: file, boardRoot: board))
        #expect(await server.openDocumentCount == 1)

        try write(file, "func alpha\nfunc beta\n")
        #expect(try await service.documentSymbols(file: file, boardRoot: board).map(\.name) == ["alpha", "beta"])

        try host.reachable(false)
        await #expect(throws: LSPError.self) {
            try await service.documentSymbols(file: file, boardRoot: board)
        }
        await #expect(throws: HostFileError.self) {
            try await service.text(file: file, boardRoot: board)
        }
        #expect(await server.openDocumentCount == 1, "an unreachable host is not a deleted file")

        try host.reachable(true)
        try FileManager.default.removeItem(at: file)
        await #expect(throws: HostFileError.notFound(commit: nil)) { try await service.text(file: file, boardRoot: board) }
        await #expect(throws: LSPError.self) {
            try await service.documentSymbols(file: file, boardRoot: board)
        }
        #expect(await server.openDocumentCount == 0)
        await service.release(file: file, boardRoot: board)
        await service.stopAll()
    }

    @Test func aRequestStillReadingKeepsItsDocumentOpenWhenAnotherRequestEnds() async throws {
        let host = try LanguageHost()
        let board = host.fixture.root
        let file = board.appendingPathComponent("main.fake")
        try write(file, "func alpha\n")
        let service = LanguageService(host: host.files, configs: [host.config()])
        defer {
            for hold in [host.holdAnswers, host.holdCommands] { try? FileManager.default.removeItem(at: hold) }
        }
        try Data().write(to: host.holdAnswers)
        let first = Task { try await service.documentSymbols(file: file, boardRoot: board).map(\.name) }
        try #require(await eventually(30) { host.held(host.holdAnswers) }, "the first request is waiting on the server")
        try Data().write(to: host.holdCommands)
        let second = Task { try await service.documentSymbols(file: file, boardRoot: board).map(\.name) }
        try #require(await eventually(10) { host.held(host.holdCommands) }, "the second request is reading over ssh")

        try FileManager.default.removeItem(at: host.holdAnswers)
        #expect(try await first.value == ["alpha"])
        try FileManager.default.removeItem(at: host.holdCommands)
        #expect(try await second.value == ["alpha"], "the first request's end did not close the document under the second's read")
        let server = try #require(await service.existingServer(for: file, boardRoot: board))
        #expect(await server.openDocumentCount == 0, "closed once neither request needs it")
        await service.stopAll()
    }

    @Test func unchangedDocumentsDoNotCrowdANewDocumentOutOfTheReadBudget() async throws {
        let host = try LanguageHost()
        let board = host.fixture.root
        let source = HostLanguageSource(files: host.files, configs: [host.config()])
        let text = String(repeating: " ", count: GitDiffEngine.maxFileSize)
        var requests: [DocumentRequest] = []
        for index in 0..<9 {
            let file = board.appendingPathComponent("\(index).fake")
            try write(file, text)
            let read = try await source.documents([DocumentRequest(file: file, boardRoot: board, stamp: nil)])
            guard case .text(let stamp, _)? = read[file] else {
                Issue.record("Initial host document was unreadable")
                return
            }
            requests.append(DocumentRequest(file: file, boardRoot: board, stamp: stamp))
        }
        let changed = board.appendingPathComponent("new.fake")
        try write(changed, "func beta\n")
        let read = try await source.documents(requests + [DocumentRequest(file: changed, boardRoot: board, stamp: nil)])
        for request in requests {
            guard case .unchanged? = read[request.file] else {
                Issue.record("An unchanged host document consumed the changed-document budget")
                continue
            }
        }
        guard case .text(_, let actual)? = read[changed] else {
            Issue.record("Unchanged documents crowded out a new host document")
            return
        }
        #expect(actual == "func beta\n")
    }

    @Test func stopAndQuitEndAServerThatOutlivesItsSsh() async throws {
        let host = try LanguageHost()
        let board = host.fixture.root
        let file = board.appendingPathComponent("main.fake")
        try write(file, "func alpha\n")
        for quitting in [false, true] {
            let service = LanguageService(host: host.files, configs: [host.config("stubborn")])
            #expect(try await service.documentSymbols(file: file, boardRoot: board).map(\.name) == ["alpha"])
            let pid = Int32(try #require(host.recorded()["pid"]?.int))
            if quitting {
                await service.terminateAll(grace: .milliseconds(500))
            } else {
                await service.stopAll()
            }
            #expect(await eventually(3) { kill(pid, 0) != 0 }, "ended on its host, not only its ssh here")
            #expect(service.liveProcessCount == 0)
        }
    }

    @Test func symbolSearchesAndListingsOnTheHostFindWhatTheyFindHere() async throws {
        let host = try LanguageHost()
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("a.fake", "x = spool.size\n")
        try await repo.write("b.fake", "func spool(n) {\n}\n")
        try await repo.write("c.fake", "spool = 1\n")
        try await repo.write("d.fake", "call(spool)\n")
        try await repo.commit("base")
        try await repo.write("e.fake", "func spool() {}\n")
        let here = LanguageService(configs: [host.config()])
        let there = LanguageService(host: host.files, configs: [host.config()])
        for service in [here, there] {
            #expect(try await service.mentioningFiles("spool", boardRoot: repo.root, scope: repo.root, limit: 3) == ["b.fake", "c.fake", "a.fake"])
            #expect(try await service.locate(symbol: "spool", boardRoot: repo.root, scope: repo.root) == "b.fake")
            #expect(try await service.files(boardRoot: repo.root).sorted() == ["a.fake", "b.fake", "c.fake", "d.fake", "e.fake"])
        }
    }
}
