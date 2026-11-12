import Foundation
import os

public enum BrowserStreamDiagnostic {
    public enum Side: String, Sendable { case host, viewer }
    public enum Event: String, Sendable { case admitted, rejected, usable, closed, failed, transport_lost, discarded }
    public enum Route: String, Sendable { case relay, socket }
    public enum Operation: String, Sendable { case resolve, driven, stream, ack, progress, input, frame, link, close }
    public enum Reason: String, Sendable {
        case none, peer_closed, window_closed, tile_missing, tile_not_browser, drawn_elsewhere, tile_unmounted
        case frame_subscription_missing, page_helper_unsupported, tile_remounted, board_changed, tile_off_window
        case webview_missing, page_area_unavailable, app_surface_unavailable, peer_stream_unsupported
        case drawing_unassigned, drawing_offline, drawing_surface_unsupported
        case invalid_request, backend_unclassified, transport_timeout, transport_unavailable, unknown_error
        case invalid_reply, invalid_frame, superseded, reconnecting, offline, requested_stop
        case tile_closed, board_closed, drawing_moved, page_input_unavailable, encoding_failed, frame_too_large
        case setup_budget_exceeded, viewer_left, close_unclassified
        case drawing_timeout, drawing_disconnected, tile_changed, tile_unavailable, drawing_unavailable
        case frame_overflow, frame_gap, frame_assembly_failed, decode_failed, input_queue_full
    }
    public struct Record: Sendable {
        public let side: Side, event: Event, reason: Reason, route: Route, operation: Operation
        public let code: String, tile: String, stream: String, local: String, drawing: String, origin: String
        public var line: String {
            "side=\(side.rawValue) event=\(event.rawValue) reason=\(reason.rawValue) code=\(code) tile=\(tile) stream=\(stream) local=\(local) drawing=\(drawing) route=\(route.rawValue) operation=\(operation.rawValue) origin=\(origin)"
        }
        fileprivate init(side: Side, event: Event, reason: Reason, route: Route, operation: Operation,
                         code: String, tile: String, stream: String, local: String, drawing: String, origin: String) {
            self.side = side; self.event = event; self.reason = reason; self.route = route; self.operation = operation
            self.code = code; self.tile = tile; self.stream = stream; self.local = local; self.drawing = drawing; self.origin = origin
        }
    }
    private static let logger = Logger(subsystem: "net.waldin.easl", category: "browser-stream")

    public static func safeRecord(side: Side, event: Event, reason: Reason = .none, tile: String?, stream: String? = nil,
                                  local: String? = nil, drawing: String? = nil, route: Route, operation: Operation = .stream,
                                  failure: (any Error)? = nil, drawingLabel: String? = nil) -> Record {
        var reason = reason, code = "none", origin = "none"
        if let failure {
            let rawCode: String
            if let error = failure as? EaslConnection.Failure {
                rawCode = error.code
                origin = error.isHostResponse ? "backend" : "transport"
                if reason == .none {
                    reason = error.isHostResponse ? backendReason(error.message, code: error.code, tile: tile, drawingLabel: drawingLabel)
                        : (error.code == "timeout" ? .transport_timeout : .transport_unavailable)
                }
            } else if let error = failure as? ApiRouter.Failure {
                rawCode = error.code
                origin = "backend"
                if reason == .none { reason = backendReason(error.message, code: error.code, tile: tile, drawingLabel: drawingLabel) }
            } else {
                rawCode = ""
                origin = "local"
                if reason == .none { reason = .unknown_error }
            }
            switch rawCode {
            case "not_found", "invalid_params", "unsupported", "unavailable", "timeout", "internal": code = rawCode
            default: code = "unknown"
            }
        }
        return Record(side: side, event: event, reason: reason, route: route, operation: operation, code: code,
                      tile: safeID(tile, prefix: "obj"), stream: safeID(stream, prefix: "str"),
                      local: safeID(local, prefix: "mch"), drawing: safeID(drawing, prefix: "mch"), origin: origin)
    }

    public static func log(_ record: Record) {
        switch record.event {
        case .rejected, .failed, .transport_lost: logger.error("\(record.line, privacy: .public)")
        default: logger.notice("\(record.line, privacy: .public)")
        }
    }

    public static func closeReason(_ reason: String?) -> Reason {
        switch reason {
        case "tile closed": .tile_closed
        case "board closed": .board_closed
        case "window closed": .window_closed
        case "drawing moved": .drawing_moved
        case "drawing machine offline": .drawing_offline
        case "page input unavailable": .page_input_unavailable
        case "surface encoding failed": .encoding_failed
        case "frame too large": .frame_too_large
        case "stream setup exceeded its private event budget": .setup_budget_exceeded
        case "its viewer left": .viewer_left
        default: .close_unclassified
        }
    }

    private static func backendReason(_ message: String, code: String, tile: String?, drawingLabel: String?) -> Reason {
        switch message {
        case "browser surfaces need the easl app": return .app_surface_unavailable
        case "this connection can't carry a browser stream": return .peer_stream_unsupported
        case "this board's window closed": return .window_closed
        case "this Mac's WebKit can't run the browser relay's page helper without acting as a user gesture": return .page_helper_unsupported
        default: break
        }
        if let tile {
            switch message {
            case "\(tile) has no drawing Mac yet": return .drawing_unassigned
            case "browser tile \(tile) is not open in a window": return .tile_unavailable
            case "browser tile \(tile)'s page doesn't run on this Mac": return .drawing_unavailable
            case "browser tile \(tile) closed while its stream opened": return .tile_changed
            case "browser tile \(tile) has no page area to stream": return .page_area_unavailable
            default: break
            }
            let prefix = "\(tile)'s stream ended as it opened: "
            if message.hasPrefix(prefix) {
                let ending = closeReason(String(message.dropFirst(prefix.count)))
                if ending != .close_unclassified { return ending }
            }
        }
        if let drawingLabel {
            if message == "draws on \(drawingLabel), which is offline" { return .drawing_offline }
            if message == "draws on \(drawingLabel), which does not serve surface.stream" { return .drawing_surface_unsupported }
        }
        if clientResponse(message, suffix: " didn't answer surface.stream within 12 s") { return .drawing_timeout }
        if clientResponse(message, suffix: " disconnected before answering surface.stream") { return .drawing_disconnected }
        if let boundary = message.range(of: " no longer draws ", options: .backwards),
           clientName(message[..<boundary.lowerBound]) {
            let fields = message[boundary.upperBound...].split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            if fields.count == 5, fields[0].hasSuffix("'s"), validID(fields[0].dropLast(2), prefix: "mch"),
               fields[1] == "pages", fields[2] == "on", fields[3] == "board",
               fields[4].hasPrefix("brd_"), fields[4].utf8.count == 24,
               fields[4].utf8.dropFirst(4).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                return .tile_changed
            }
        }
        return code == "invalid_params" ? .invalid_request : .backend_unclassified
    }

    private static func clientResponse(_ message: String, suffix: String) -> Bool {
        message.hasSuffix(suffix) && clientName(message.dropLast(suffix.count))
    }

    private static func clientName(_ name: Substring) -> Bool {
        if name.hasPrefix("client ") { return validID(name.dropFirst(7), prefix: "cli") }
        guard name.hasPrefix("easl ") || name.hasPrefix("a client on "), name.last == ")",
              let opening = name.lastIndex(of: "("), name[..<opening].last == " " else { return false }
        let token = name[name.index(after: opening)..<name.index(before: name.endIndex)]
        return token.hasPrefix("client ") && validID(token.dropFirst(7), prefix: "cli")
    }

    private static func validID(_ value: some StringProtocol, prefix: String) -> Bool {
        value.utf8.count == prefix.utf8.count + 19 && value.hasPrefix(prefix + "_") &&
            value.utf8.dropFirst(prefix.utf8.count + 1).allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8.contains($0) }
    }

    private static func safeID(_ value: String?, prefix: String) -> String {
        guard let value else { return "none" }
        guard validID(value, prefix: prefix) else { return "redacted" }
        return value
    }
}
