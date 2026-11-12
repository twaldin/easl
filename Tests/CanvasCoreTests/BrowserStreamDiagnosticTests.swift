import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct BrowserStreamDiagnosticTests {
    @Test func realSurfaceFailuresStayContentFreeAndDistinguishBackendFromTransport() async throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("bsd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        let router = ApiRouter(registry: registry)
        let path = dir.appendingPathComponent("s").path
        let server = SocketServer(path: path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        defer { server.stop() }
        let connection = EaslConnection.unixSocket(path)
        defer { connection.close() }
        let secret = "https://private.invalid/?token=DIAGNOSTIC_SECRET_é\nPRIVATE_LINE"
        let hostileID = "obj_" + secret
        let parser = try await surfaceFailure(hostileID, on: connection)
        #expect(parser.isHostResponse)
        #expect(parser.message.contains(secret))
        let validID = IDs.make("obj")
        let unavailable = try await surfaceFailure(validID, on: connection)
        #expect(unavailable.isHostResponse)
        connection.close()
        let transport = try await surfaceFailure(validID, on: connection)
        #expect(!transport.isHostResponse)

        let records = [parser, unavailable, transport].map {
            BrowserStreamDiagnostic.safeRecord(side: .viewer, event: .rejected, tile: hostileID,
                stream: "str_" + secret, local: "mch_" + secret, drawing: "mch_legacy",
                route: .relay, failure: $0, drawingLabel: secret)
        }
        #expect(records.map(\.reason) == [.invalid_request, .app_surface_unavailable, .transport_unavailable])
        #expect(records.map(\.origin) == ["backend", "backend", "transport"])
        #expect(records.map(\.code) == ["invalid_params", "unavailable", "unavailable"])
        for record in records {
            #expect(record.tile == "redacted" && record.stream == "redacted")
            #expect(record.local == "redacted" && record.drawing == "redacted")
            #expect(!record.line.contains(secret))
            #expect(!record.line.contains("DIAGNOSTIC_SECRET"))
            #expect(!record.line.contains("é") && !record.line.contains("\n"))
        }
    }

    @Test func unknownErrorsAndAlmostKnownReasonsCannotRetainMetadata() {
        let secret = "PRIVATE_DETAIL_é\nhttps://private.invalid/token"
        let tile = IDs.make("obj"), stream = IDs.make("str"), machine = IDs.make("mch")
        let failures: [any Error] = [
            EaslConnection.Failure(secret, "draws on \(secret), which is offline" + secret,
                data: .object([secret: .string(secret)]), isHostResponse: true),
            ApiRouter.Failure(secret, secret, data: .object([secret: .string(secret)])),
            NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret]),
        ]
        for (index, failure) in failures.enumerated() {
            let record = BrowserStreamDiagnostic.safeRecord(side: .viewer, event: .failed,
                tile: tile, stream: stream, local: machine, route: .socket, failure: failure, drawingLabel: secret)
            #expect(record.reason == (index == 2 ? .unknown_error : .backend_unclassified))
            #expect(record.code == "unknown")
            #expect(record.tile == tile && record.stream == stream && record.local == machine)
            #expect(record.drawing == "none")
            #expect(!record.line.contains(secret) && !record.line.contains("PRIVATE_DETAIL"))
        }
        let known = EaslConnection.Failure("unavailable", "draws on \(secret), which is offline", isHostResponse: true)
        let record = BrowserStreamDiagnostic.safeRecord(side: .viewer, event: .rejected,
            tile: tile, route: .relay, failure: known, drawingLabel: secret)
        #expect(record.reason == .drawing_offline)
        #expect(!record.line.contains(secret))
        #expect(BrowserStreamDiagnostic.closeReason("drawing moved") == .drawing_moved)
        #expect(BrowserStreamDiagnostic.closeReason("drawing moved" + secret) == .close_unclassified)
        for invalid in ["obj_short", "obj_0123456789abcdefgh", "obj_0123456789ABCDEé", "obj_0123456789ABCDEFGH\n"] {
            let record = BrowserStreamDiagnostic.safeRecord(side: .viewer, event: .admitted, tile: invalid, route: .relay)
            #expect(record.tile == "redacted")
        }
    }

    @Test func relayAdmissionReasonsDoNotRetainClientMetadata() {
        let secret = "PRIVATE_CLIENT_é\nhttps://private.invalid/token"
        let tile = IDs.make("obj"), machine = IDs.make("mch")
        let name = "easl 0.3.9 on \(secret) (client \(IDs.make("cli")))"
        let cases = [
            ("\(name) didn't answer surface.stream within 12 s", "drawing_timeout"),
            ("\(name) disconnected before answering surface.stream", "drawing_disconnected"),
            ("\(name) no longer draws \(machine)'s pages on board brd_0123456789abcdef0123", "tile_changed"),
            ("\(tile)'s stream ended as it opened: drawing moved", "drawing_moved"),
            ("browser tile \(tile) is not open in a window", "tile_unavailable"),
            ("browser tile \(tile)'s page doesn't run on this Mac", "drawing_unavailable"),
            ("browser tile \(tile) closed while its stream opened", "tile_changed"),
            ("browser tile \(tile) has no page area to stream", "page_area_unavailable"),
        ]
        for (message, expected) in cases {
            let failure = EaslConnection.Failure("unavailable", message,
                data: .object(["detail": .string(secret)]), isHostResponse: true)
            let record = BrowserStreamDiagnostic.safeRecord(side: .viewer, event: .rejected,
                tile: tile, drawing: machine, route: .relay, failure: failure)
            #expect(record.reason.rawValue == expected)
            #expect(!record.line.contains(secret) && !record.line.contains("PRIVATE_CLIENT"))
            let unknown = EaslConnection.Failure("unavailable", message + secret, isHostResponse: true)
            #expect(BrowserStreamDiagnostic.safeRecord(side: .viewer, event: .rejected,
                tile: tile, drawing: machine, route: .relay, failure: unknown).reason == .backend_unclassified)
        }
    }

    private func surfaceFailure(_ tile: String, on connection: EaslConnection) async throws -> EaslConnection.Failure {
        var failure: EaslConnection.Failure?
        do {
            _ = try await connection.request("surface.stream", .object(["id": .string(tile)]), timeout: .seconds(5))
        } catch {
            failure = try #require(error as? EaslConnection.Failure)
        }
        return try #require(failure)
    }
}
