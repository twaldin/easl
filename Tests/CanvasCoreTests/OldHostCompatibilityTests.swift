import AppKit
import Darwin
import Foundation
import Testing
@testable import CanvasCore

private final class CompatibilityPeer: Sendable {
    struct Call: Sendable {
        let request: JSONValue
        let connection: SocketServer.Connection
    }

    let directory: URL
    let server: SocketServer
    let calls = Locked<[Call]>([])
    let links = Locked<[EaslConnection]>([])
    var path: String { directory.appendingPathComponent("s").path }

    init(reply: @escaping @Sendable (JSONValue, SocketServer.Connection) async -> JSONValue?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID().uuidString.prefix(8))")
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calls = calls
        server = SocketServer(path: directory.appendingPathComponent("s").path) { request, connection in
            calls.withLock { $0.append(Call(request: request, connection: connection)) }
            return await reply(request, connection)
        }
        try server.start()
    }

    deinit {
        links.withLock { $0 }.forEach { $0.close() }
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func link() -> EaslConnection {
        let link = EaslConnection.unixSocket(path, backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))
        links.withLock { $0.append(link) }
        return link
    }

    func requests(_ method: String) -> [Call] {
        calls.withLock { $0.filter { $0.request["method"]?.string == method } }
    }

    static func success(_ request: JSONValue, _ result: JSONValue = .object([:])) -> JSONValue {
        .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": result])
    }

    static func failure(_ request: JSONValue, code: String = "invalid_params", message: String) -> JSONValue {
        .object(["id": request["id"] ?? .null, "ok": .bool(false),
                 "error": .object(["code": .string(code), "message": .string(message)])])
    }
}

@MainActor
struct OldHostCompatibilityTests {
    private func eventually(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(ready())
    }

    private func files(_ peer: CompatibilityPeer) -> HostFiles {
        HostFiles(hostName: "old", route: HostRoute(target: "unused", controlPath: "/unused"), temps: [],
                  imagePreviews: HostImagePreviews { peer.link() })
    }

    @Test func missingPreviewFallsBackForActiveQueuedAndLaterTilesAndReprobesAfterReconnect() async throws {
        let upgraded = Locked(false)
        let peer = try CompatibilityPeer { request, _ in
            if request["method"]?.string == "image.preview", !upgraded.withLock({ $0 }) { return nil }
            return CompatibilityPeer.success(request, .object(["kind": "original"]))
        }
        let files = files(peer)
        #expect(peer.links.withLock { $0.isEmpty })
        let first = Task { try await files.imagePreview(object: "obj_first", maxPixels: 64) }
        defer { first.cancel() }
        try await eventually { peer.requests("image.preview").count == 1 }
        let queued = Task { try await files.imagePreview(object: "obj_queued", maxPixels: 64) }
        defer { queued.cancel() }
        await Task.yield()
        let call = try #require(peer.requests("image.preview").first)
        #expect(call.connection.send(CompatibilityPeer.failure(call.request, message: "unknown method image.preview")))
        #expect(try await first.value == nil)
        #expect(try await queued.value == nil)
        #expect(try await files.imagePreview(object: "obj_later", maxPixels: 64) == nil)
        #expect(peer.requests("image.preview").count == 1)
        let link = try #require(peer.links.withLock { $0.first })
        upgraded.withLock { $0 = true }
        shutdown(call.connection.fd, SHUT_RDWR)
        try await eventually { peer.requests("system.ping").count >= 2 && link.state == .online }
        #expect(try await files.imagePreview(object: "obj_upgraded", maxPixels: 64) == nil)
        #expect(peer.requests("image.preview").count == 2)
        #expect(peer.links.withLock { $0.count } == 1)
    }

    @Test(arguments: ["invalid_params", "unavailable", "unreadable"])
    func realPreviewErrorsDoNotDisableTheEndpoint(code: String) async throws {
        let peer = try CompatibilityPeer { request, _ in
            if request["method"]?.string == "image.preview" {
                return CompatibilityPeer.failure(request, code: code, message: "host rejected this image")
            }
            return CompatibilityPeer.success(request)
        }
        let files = files(peer)
        for object in ["obj_first", "obj_second"] {
            do {
                _ = try await files.imagePreview(object: object, maxPixels: 64)
                Issue.record("a real preview error must remain an error")
            } catch let failure as EaslConnection.Failure {
                #expect(failure.isHostResponse && failure.code == code)
            } catch let failure as HostFileError {
                #expect(code == "unreadable" && failure == .unreadable)
            }
        }
        #expect(peer.requests("image.preview").count == 2)
    }

    @Test func modernPreviewStillReturnsDecodedImage() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 256, bitsPerPixel: 32))
        let pixels = try #require(bitmap.bitmapData)
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = try #require(bitmap.cgImage)
        let preview = HostImagePreview(data: data, image: image, naturalWidth: 640, naturalHeight: 320,
            width: 64, height: 32, version: HostFileVersion(root: "/board", path: "/board/image.png", stamp: "1:2:100000:4:5"))
        let reply = preview.json
        let peer = try CompatibilityPeer { request, _ in CompatibilityPeer.success(request, reply) }
        let result = try #require(try await files(peer).imagePreview(object: "obj_image", maxPixels: 64))
        #expect(result.data == data && result.width == 64 && result.height == 32)
        #expect(result.naturalWidth == 640 && result.naturalHeight == 320)
        #expect(result.version == preview.version)
    }

    private func mirror(_ peer: CompatibilityPeer) async throws -> BoardMirror {
        let mirror = BoardMirror(hostName: "old", board: "brd_compat", connection: peer.link(), diagrams: peer.link())
        _ = try await mirror.load()
        return mirror
    }

    nonisolated private static func baseReply(_ request: JSONValue) -> JSONValue {
        switch request["method"]?.string {
        case "system.ping":
            return CompatibilityPeer.success(request, .object(["version": 2]))
        case "board.get":
            return CompatibilityPeer.success(request, .object(["board": "brd_compat", "root": "/board", "objects": .array([])]))
        default:
            return CompatibilityPeer.success(request)
        }
    }

    @Test func legacyPromptsSendOnceWithoutModernFieldsAndPreserveStagedMentions() async throws {
        let peer = try CompatibilityPeer { request, _ in
            if request["method"]?.string == "agent.prompt_epoch" {
                return CompatibilityPeer.failure(request, message: "unknown method agent.prompt_epoch")
            }
            return Self.baseReply(request)
        }
        let mirror = try await mirror(peer)
        defer { mirror.close() }
        let view = try #require(mirror.board)
        let note = view.create(type: .note, props: .object(["markdown": "context"]))
        let mention = try view.stage(.object(note.id))
        try await mirror.prompt("review [1]", to: "obj_terminal", mentions: [mention], answer: false)
        try await mirror.prompt("answer", to: "obj_terminal", mentions: [], answer: true)
        let prompts = peer.requests("agent.prompt").compactMap { $0.request["params"]?.object }
        #expect(prompts.count == 2)
        #expect(prompts.first?["viewer"] == .string(mirror.viewer))
        #expect(prompts.first?["staged"]?.array?.count == 1)
        #expect(prompts.last == ["target": .string("obj_terminal"), "text": .string("answer"), "composer": .bool(true), "answer": .bool(true)])
        #expect(prompts.allSatisfy { $0["submission"] == nil && $0["reconcile"] == nil })
        #expect(peer.requests("agent.prompt_epoch").count == 1)
    }

    @Test(arguments: [false, true])
    func legacyPromptErrorsAndLostRepliesNeverReplay(drop: Bool) async throws {
        let peer = try CompatibilityPeer { request, connection in
            switch request["method"]?.string {
            case "agent.prompt_epoch":
                return CompatibilityPeer.failure(request, message: "unknown method agent.prompt_epoch")
            case "agent.prompt":
                if drop {
                    shutdown(connection.fd, SHUT_RDWR)
                    return nil
                }
                return CompatibilityPeer.failure(request, code: "refused", message: "terminal refused prompt")
            default:
                return Self.baseReply(request)
            }
        }
        let mirror = try await mirror(peer)
        defer { mirror.close() }
        var deliveries: [BoardMirror.PromptDelivery] = []
        mirror.onPromptDelivery = { _, _, delivery in deliveries.append(delivery) }
        do {
            try await mirror.prompt("once", to: "obj_terminal", mentions: [], answer: false)
            Issue.record("a failed legacy prompt must return its failure")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == (drop ? "unavailable" : "refused"))
        }
        if drop {
            try await eventually { peer.requests("system.ping").count >= 3 && mirror.connection.state == .online }
        }
        #expect(peer.requests("agent.prompt").count == 1)
        #expect(deliveries.isEmpty)
    }

    @Test func confirmedLegacyDeliveryAfterBoardClosureKeepsTheNextDraft() async throws {
        let host = Board(id: "brd_compat", root: URL(fileURLWithPath: "/board"))
        let terminal = host.create(type: .terminal, props: .object([:]))
        let objects = try JSONValue.encode([terminal])
        let peer = try CompatibilityPeer { request, _ in
            switch request["method"]?.string {
            case "agent.prompt_epoch":
                return CompatibilityPeer.failure(request, message: "unknown method agent.prompt_epoch")
            case "agent.prompt":
                return nil
            case "board.get":
                return CompatibilityPeer.success(request, .object(["board": "brd_compat", "root": "/board", "objects": objects]))
            default:
                return Self.baseReply(request)
            }
        }
        let mirror = try await mirror(peer)
        defer { mirror.close() }
        let view = try #require(mirror.board)
        let outgoing = try #require(ComposerSend.begin(ComposerDraft(text: "confirmed prompt"), targets: [terminal.id], on: view)).send
        let send = Task {
            do {
                try await mirror.prompt(outgoing.draft.prompt, to: terminal.id, mentions: [], answer: false)
                return true
            } catch { return false }
        }
        try await eventually { peer.requests("agent.prompt").count == 1 }
        let request = try #require(peer.requests("agent.prompt").first)
        #expect(request.connection.send(.object(["event": .string("board.closed"), "board": .string("brd_compat"), "data": .object([:])])))
        try await eventually { mirror.availability == .closed }
        #expect(request.connection.send(CompatibilityPeer.success(request.request, .object(["delivery": "typed"]))))
        let reached: Set<ObjectID> = await send.value ? [terminal.id] : []
        let settled = outgoing.settle(reached: reached, into: ComposerDraft(text: "next draft"), on: view)
        #expect(settled.sent && settled.draft.text == "next draft")
        #expect(peer.requests("agent.prompt").count == 1)
        #expect(peer.requests("agent.prompt").first?.request["params"]?["reconcile"] == nil)
    }

    @Test func upgradedPromptConnectionUsesModernDeliveryAgain() async throws {
        let upgraded = Locked(false)
        let peer = try CompatibilityPeer { request, _ in
            if request["method"]?.string == "agent.prompt_epoch" {
                if upgraded.withLock({ $0 }) {
                    return CompatibilityPeer.success(request, .object(["promptEpoch": "upgraded-epoch"]))
                }
                return CompatibilityPeer.failure(request, message: "unknown method agent.prompt_epoch")
            }
            if request["method"]?.string == "agent.prompt" {
                return CompatibilityPeer.success(request, .object(["delivery": "typed"]))
            }
            return Self.baseReply(request)
        }
        let mirror = try await mirror(peer)
        defer { mirror.close() }
        try await mirror.prompt("legacy", to: "obj_terminal", mentions: [], answer: false)
        let original = try #require(peer.requests("agent.prompt").first)
        #expect(original.request["params"]?["submission"] == nil)
        upgraded.withLock { $0 = true }
        shutdown(original.connection.fd, SHUT_RDWR)
        try await eventually { peer.requests("system.ping").count >= 3 && mirror.connection.state == .online }
        try await mirror.prompt("modern", to: "obj_terminal", mentions: [], answer: false)
        #expect(peer.requests("agent.prompt_epoch").count == 2)
        #expect(peer.requests("agent.prompt").last?.request["params"]?["submission"]?["epoch"] == "upgraded-epoch")
    }

    @Test func modernPromptKeepsSubmissionAndAnswer() async throws {
        let peer = try CompatibilityPeer { request, _ in
            switch request["method"]?.string {
            case "agent.prompt_epoch": return CompatibilityPeer.success(request, .object(["promptEpoch": "modern-epoch"]))
            case "agent.prompt": return CompatibilityPeer.success(request, .object(["delivery": "typed"]))
            default: return Self.baseReply(request)
            }
        }
        let mirror = try await mirror(peer)
        defer { mirror.close() }
        try await mirror.prompt("answer", to: "obj_terminal", mentions: [], answer: true)
        let params = try #require(peer.requests("agent.prompt").first?.request["params"])
        #expect(params["submission"]?["epoch"] == "modern-epoch")
        #expect(params["submission"]?["id"]?.string?.hasPrefix("sub_") == true)
        #expect(params["answer"] == .bool(true) && params["reconcile"] == nil)
    }

    @Test func arbitraryEpochInvalidParamsDoesNotSendALegacyPrompt() async throws {
        let peer = try CompatibilityPeer { request, _ in
            if request["method"]?.string == "agent.prompt_epoch" {
                return CompatibilityPeer.failure(request, message: "invalid epoch request")
            }
            return Self.baseReply(request)
        }
        let mirror = try await mirror(peer)
        defer { mirror.close() }
        await #expect(throws: ApiRouter.Failure.self) {
            try await mirror.prompt("never", to: "obj_terminal", mentions: [], answer: false)
        }
        #expect(peer.requests("agent.prompt").isEmpty)
    }
}
