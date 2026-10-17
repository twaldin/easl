import Foundation
import Testing
@testable import CanvasCore

@MainActor
final class DrawingMachineTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("dm-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let server: SocketServer
    let board: Board
    let home = DrawingMachine(id: "mch_01HOME", host: "home")

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        board = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        client.send(String(decoding: try JSONEncoder().encode(JSONValue.object(["id": "1", "method": .string(method), "params": params])), as: UTF8.self))
        return try await client.next()
    }


    @Test func anIdentityIsMadeOnceAndKeptAcrossLaunches() throws {
        let file = dir.appendingPathComponent("home/client-id")
        let made = try MachineIdentity.load(from: file)
        #expect(made.hasPrefix("mch_"))
        #expect(IDs.isID(made))
        #expect(try String(contentsOf: file, encoding: .utf8) == made + "\n")
        #expect(try MachineIdentity.load(from: file) == made, "the next launch reads the same identity")
    }

    @Test func aFileHoldingNoIdentityFailsAndIsLeftAsItIs() throws {
        let file = dir.appendingPathComponent("client-id")
        try "my mac\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: MachineIdentity.Failure(description: "\(file.path) holds no machine identity")) { try MachineIdentity.load(from: file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "my mac\n")
    }

    @Test func aHomeThatCantKeepAnIdentityFailsWithoutOne() throws {
        let readOnly = dir.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        let file = readOnly.appendingPathComponent("client-id")
        let error = try #require(throws: MachineIdentity.Failure.self) { try MachineIdentity.load(from: file) }
        #expect(error.description.hasPrefix("couldn't keep a machine identity in \(file.path): "))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }



    @Test func aMacHostPersistsItsDefaultOnExistingAndNewBrowserTiles() async throws {
        let earlier = board.create(type: .browser, props: .object(["url": "https://example.com/"]))
        registry.drawingMachine = home
        let read = try await call("object.get", .object(["id": .string(earlier.id)]))
        #expect(read["result"]?["object"]?["props"]?["drawingMachine"] == home.json)
        #expect(read["result"]?["object"]?["rev"] == .number(1))

        let created = try await call("object.create", .object(["board": .string(board.id), "type": "browser", "props": .object(["url": "https://example.org/"])]))
        #expect(created["result"]?["object"]?["props"]?["drawingMachine"] == home.json)

    }

    @Test func theMacsOwnApiRefusesAMalformedDrawingMachineAndBrowserCalls() async throws {
        let page = board.create(type: .browser, props: .object(["url": "https://example.com/"]))
        let malformed = try await call("object.update", .object(["id": .string(page.id), "props": .object(["drawingMachine": .object(["id": "home"])])]))
        #expect(malformed["error"]?["code"] == "invalid_params")
        #expect(malformed["error"]?["message"] == "drawingMachine must be {id, host}: a Mac's machine identity (its client.attach identity) and its name")
        #expect(board.objects[page.id]?.props["drawingMachine"] == nil)
        let browse = try await call("browser.call", .object(["id": .string(page.id), "method": "browser.url.get", "params": .object([:])]))
        #expect(browse["error"]?["code"] == "unsupported")
        let report = try await call("browser.report", .object(["id": .string(page.id), "url": "https://example.org/"]))
        #expect(report["error"]?["code"] == "unsupported")
        #expect(board.objects[page.id]?.props["url"] == "https://example.com/")
    }
}
