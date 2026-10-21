import AppKit
import Foundation
import ImageIO
import Testing
@testable import CanvasCore

@MainActor
struct ReleaseCompatibilityTests {
    private struct SavedJourney: Codable {
        let board: BoardID
        let note: ObjectID
        let image: ObjectID
        let question: ObjectID
        let browser: ObjectID
        let terminal: ObjectID
    }

    private struct GateFailure: Error, CustomStringConvertible {
        let description: String
    }

    private func eventually(_ message: String, _ ready: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if try await ready() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GateFailure(description: message)
    }

    private func objects(_ connection: EaslConnection, board: BoardID) async throws -> [CanvasObject] {
        let reply = try await connection.request("board.get", .object(["board": .string(board)]))
        return try #require(reply["objects"]?.array).map { try $0.decode(CanvasObject.self) }
    }

    private func object(_ connection: EaslConnection, id: ObjectID) async throws -> CanvasObject {
        let reply = try await connection.request("object.get", .object(["id": .string(id)]))
        return try #require(reply["object"]).decode(CanvasObject.self)
    }

    private func create(_ type: ObjectType, props: JSONValue, on board: Board, using connection: EaslConnection) async throws -> CanvasObject {
        _ = board.create(type: type, props: props, frame: Frame(x: 0, y: 0, w: 640, h: 320))
        var canonical: CanvasObject?
        try await eventually("\(type.rawValue) create did not persist through BoardMirror") {
            canonical = try await objects(connection, board: board.id).first { object in
                object.type == type && (props.object ?? [:]).allSatisfy { object.props[$0.key] == $0.value }
            }
            guard let canonical else { return false }
            return board.objects[canonical.id] == canonical
        }
        return try #require(canonical)
    }

    private func imageBytes() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 320,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 640 * 4, bitsPerPixel: 32))
        let pixels = try #require(rep.bitmapData)
        for index in 0..<(640 * 320) {
            pixels[index * 4] = 0x12
            pixels[index * 4 + 1] = 0x80
            pixels[index * 4 + 2] = 0xe0
            pixels[index * 4 + 3] = 0xff
        }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func checkImage(_ id: ObjectID, files: HostFiles, root: URL) async throws {
        let original = try Data(contentsOf: root.appendingPathComponent("compat image.png"))
        for maxPixels in [64, 256, 1024] {
            let data: Data
            if let preview = try await files.imagePreview(object: id, maxPixels: maxPixels) {
                #expect(preview.naturalWidth == 640 && preview.naturalHeight == 320)
                #expect(preview.width <= maxPixels && preview.height <= maxPixels)
                #expect(preview.width == preview.height * 2)
                data = preview.data
            } else {
                let file = try await files.read(HostFileRequest(source: .directory(root.path), policy: .boardImage("compat image.png")))
                #expect(file.data == original)
                data = file.data
            }
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width > 0 && decoded.height > 0)
            #expect(decoded.width == decoded.height * 2)
        }
        let actual = try await files.read(HostFileRequest(source: .directory(root.path), policy: .boardImage("compat image.png")))
        #expect(actual.data == original)
        let source = try #require(CGImageSourceCreateWithData(actual.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 640 && decoded.height == 320)
    }

    private func window(submissions: @escaping (ObjectID, String) -> Void) -> ViewerWindow {
        ViewerWindow(focused: { true }, viewState: { nil },
            render: { _, _ in throw GateFailure(description: "unexpected delegated rendering") },
            measureHTML: { _, _ in throw GateFailure(description: "unexpected delegated HTML measurement") },
            reload: { _, _, _ in throw GateFailure(description: "unexpected delegated reload") },
            browse: { _, _, _ in throw GateFailure(description: "unexpected delegated browser command") },
            surface: { _, _, _ in throw GateFailure(description: "unexpected delegated browser stream") },
            submit: { id, text in
                submissions(id, text)
                do {
                    let result = try await RemoteHost.run("/bin/sh", ["-c", text], timeout: 5)
                    #expect(result.status == 0, "terminal command failed: \(result.output)")
                    return result.status == 0
                } catch {
                    Issue.record("terminal command failed: \(error)")
                    return false
                }
            },
            surfaceTail: { _, _ in nil },
            block: { _, _ in throw GateFailure(description: "unexpected delegated terminal block") },
            status: { _ in nil }, languages: { nil })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EASL_RELEASE_COMPATIBILITY"] == "1"))
    func realReleasedDaemonJourney() async throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(env["EASL_COMPAT_DIRECTORY"]))
        let root = directory.appendingPathComponent("root")
        let socket = try #require(env["EASL_COMPAT_SOCKET"])
        let connection = EaslConnection.unixSocket(socket)
        defer { connection.close() }
        let opened = try await connection.request("board.open", .object(["root": .string(root.path)]))
        let boardID = try #require(opened["board"]?.string)
        let mirror = BoardMirror(hostName: "released-daemon", board: boardID,
            connection: .unixSocket(socket), diagrams: .unixSocket(socket))
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        let board = try await mirror.load()
        #expect(board.root.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        let files = HostFiles(hostName: "released-daemon",
            route: HostRoute(target: "local-test-transport", controlPath: directory.appendingPathComponent("unused-control").path,
                             executable: directory.appendingPathComponent("local-ssh").path),
            temps: [directory.path], imagePreviews: HostImagePreviews { .unixSocket(socket) })
        let manifest = directory.appendingPathComponent("journey.json")
        let output = directory.appendingPathComponent("terminal-output")

        if env["EASL_COMPAT_PHASE"] == "reopen" {
            let saved = try JSONDecoder().decode(SavedJourney.self, from: Data(contentsOf: manifest))
            #expect(board.id == saved.board)
            #expect(board.objects.count == 5)
            #expect(board.objects[saved.note]?.props["markdown"] == "edited through remote Core")
            #expect(board.objects[saved.note]?.frame.x == 240)
            #expect(board.objects[saved.note]?.frame.y == 80)
            #expect(board.objects[saved.image]?.props["path"] == "compat image.png")
            #expect(board.objects[saved.question]?.props["status"] == "answered")
            #expect(board.objects[saved.question]?.props["answer"]?["option"] == "ship")
            #expect(board.objects[saved.question]?.props["answer"]?["note"] == "compatibility verified")
            #expect(board.objects[saved.browser]?.props["url"] == "https://example.com/release-compatibility")
            #expect(board.objects[saved.terminal]?.props["cwd"]?.string == root.path)
            #expect(try String(contentsOf: output, encoding: .utf8) == "composer-once\nanswer-once\n")
            try await checkImage(saved.image, files: files, root: root)
            #expect(notices.isEmpty, "remote client errors: \(notices)")
            #expect(mirror.problem == nil)
            return
        }

        let note = try await create(.note, props: .object(["markdown": "created through remote Core"]), on: board, using: connection)
        _ = try board.update(note.id, frame: Frame(x: 240, y: 80, w: 640, h: 320), props: .object(["markdown": "edited through remote Core"]))
        try await eventually("remote edit did not persist") {
            let stored = try await object(connection, id: note.id)
            return stored.props["markdown"] == "edited through remote Core" && stored.frame.x == 240 && board.objects[note.id] == stored
        }
        _ = await mirror.undo(redo: false).value
        try await eventually("remote undo did not persist") {
            let stored = try await object(connection, id: note.id)
            return stored.props["markdown"] == "created through remote Core" && stored.frame.x == 0 && board.objects[note.id] == stored
        }
        _ = await mirror.undo(redo: true).value
        try await eventually("remote redo did not persist") {
            let stored = try await object(connection, id: note.id)
            return stored.props["markdown"] == "edited through remote Core" && stored.frame.x == 240 && board.objects[note.id] == stored
        }

        try imageBytes().write(to: root.appendingPathComponent("compat image.png"))
        let image = try await create(.image, props: .object(["path": "compat image.png"]), on: board, using: connection)
        try await checkImage(image.id, files: files, root: root)

        let terminal = try await create(.terminal, props: .object(["cwd": .string(root.path)]), on: board, using: connection)
        var submissions: [(ObjectID, String)] = []
        mirror.serve(window { submissions.append(($0, $1)) },
                     as: ClientIdentity(app: "release-compatibility", host: "ci-mac", id: "mch_COMPATIBILITY"))
        try await eventually("released daemon refused the Core viewer attachment") {
            if case .attached? = mirror.attachment { return true }
            if case .refused(let reason)? = mirror.attachment { throw GateFailure(description: reason) }
            return false
        }
        let prompt = "printf '%s\\n' composer-once >> \(RemoteHost.quote(output.path))"
        let answer = "printf '%s\\n' answer-once >> \(RemoteHost.quote(output.path))"
        try await mirror.prompt(prompt, to: terminal.id, mentions: [], answer: false)
        try await mirror.prompt(answer, to: terminal.id, mentions: [], answer: true)
        #expect(submissions.map { $0.0 } == [terminal.id, terminal.id])
        #expect(submissions.map { $0.1 } == [prompt, answer])
        #expect(try String(contentsOf: output, encoding: .utf8) == "composer-once\nanswer-once\n")

        let props = try board.questionToCreate(.object([
            "question": "Ship this release?", "options": .array([.object(["id": "ship", "label": "Ship"])]),
            "asker": .object(["name": "release compatibility"]), "archiveAfter": 86400,
        ]), caller: nil)
        let question = try await create(.question, props: props, on: board, using: connection)
        try board.answerQuestion(question.id, option: "ship", note: "compatibility verified")
        try await eventually("remote question answer did not persist") {
            let stored = try await object(connection, id: question.id)
            return stored.props["status"] == "answered" && stored.props["answer"]?["option"] == "ship"
                && stored.props["answer"]?["note"] == "compatibility verified" && board.objects[question.id] == stored
        }
        let browser = try await create(.browser, props: .object(["url": "https://example.com/release-compatibility"]), on: board, using: connection)
        #expect(browser.props["url"] == "https://example.com/release-compatibility")
        #expect(try await objects(connection, board: board.id).count == 5)
        #expect(notices.isEmpty, "remote client errors: \(notices)")
        #expect(mirror.problem == nil)
        try JSONEncoder().encode(SavedJourney(board: board.id, note: note.id, image: image.id,
            question: question.id, browser: browser.id, terminal: terminal.id)).write(to: manifest)
    }
}
