import Foundation

/// The `surface.*` methods (schema/easl-api.json): another Mac's viewer streams a browser tile's
/// existing page and drives it with native input. A request is parsed whole here, so nothing
/// acts on a batch until every event in it is valid.
public enum SurfaceRequest: Sendable, Equatable {
    case stream(tile: ObjectID, scale: Double, format: SurfaceFormat, refinement: SurfaceRefinement)
    case ack(stream: String, frame: Int)
    case progress(stream: String, frame: Int, offset: Int)
    case input(stream: String, events: [SurfaceInputEvent])
    case answer(stream: String, dialog: String, SurfaceAnswer)
    case stop(stream: String)

    public static let maxBatch = 128
    public static let maxScale = 2.0
    /// Integers a JSON number carries exactly.
    static let maxInteger = 1 << 53

    static let methods: Set<String> = ["surface.stream", "surface.ack", "surface.progress", "surface.input", "surface.answer", "surface.stop"]

    /// Nil for a method that isn't one of these; throws `invalid_params` for a malformed request.
    public init?(method: String, params: JSONValue) throws {
        guard Self.methods.contains(method) else { return nil }
        let p = try Fields(params, "params")
        switch method {
        case "surface.stream":
            let tile = try p.string("id")
            guard tile.range(of: "^obj_[0-9A-Za-z]+$", options: .regularExpression) != nil else { throw Self.invalid("id \(tile) is not an object id") }
            let scale = try p.number("scale") ?? 1
            guard scale > 0, scale <= Self.maxScale else { throw Self.invalid("scale must be above 0 and at most \(Self.maxScale)") }
            let format = try p.string("format", optional: true).map { name in
                guard let parsed = SurfaceFormat(rawValue: name) else { throw Self.invalid("format must be jpeg, png or h264") }
                return parsed
            } ?? .jpeg
            let refinement = try p.string("refinement", optional: true).map { name in
                guard let parsed = SurfaceRefinement(rawValue: name) else { throw Self.invalid("refinement must be independent or retained") }
                return parsed
            } ?? .independent
            self = .stream(tile: tile, scale: scale, format: format, refinement: refinement)
        case "surface.ack":
            self = .ack(stream: try p.stream(), frame: try p.integer("frame", 0...Self.maxInteger))
        case "surface.progress":
            let offset = try p.integer("offset", 0...(SurfaceRefreshTransmission.maximumBytes - 1))
            guard offset.isMultiple(of: SurfaceRefreshTransmission.chunkBytes) else { throw Self.invalid("offset must be aligned to 16384 bytes") }
            self = .progress(stream: try p.stream(), frame: try p.integer("frame", 1...Self.maxInteger), offset: offset)
        case "surface.input":
            guard let list = p.values["events"]?.array else { throw Self.invalid("events must be an array") }
            guard (1...Self.maxBatch).contains(list.count) else { throw Self.invalid("events must hold 1 to \(Self.maxBatch) events") }
            var events: [SurfaceInputEvent] = []
            for (index, value) in list.enumerated() {
                let event = try SurfaceInputEvent(value, at: index)
                if let last = events.last, event.seq <= last.seq {
                    throw Self.invalid("events[\(index)].seq \(event.seq) must be above the previous event's \(last.seq)")
                }
                events.append(event)
            }
            self = .input(stream: try p.stream(), events: events)
        case "surface.answer":
            let answer = SurfaceAnswer(accept: try p.bool("accept"), text: try p.string("text", optional: true),
                                       user: try p.string("user", optional: true), password: try p.string("password", optional: true),
                                       choice: try p.integer("choice", 0...Self.maxInteger, optional: true),
                                       files: try SurfaceFile.parse(p.values["files"]))
            self = .answer(stream: try p.stream(), dialog: try p.string("dialog"), answer)
        case "surface.stop":
            self = .stop(stream: try p.stream())
        default:
            return nil
        }
    }

    static func invalid(_ message: String) -> ApiRouter.Failure {
        ApiRouter.Failure("invalid_params", message)
    }
}

public enum SurfaceFormat: String, Sendable, Equatable {
    case jpeg, png
    case h264 = "h264"
}

public enum SurfaceRefinement: String, Sendable, Equatable {
    case independent, retained
}

/// One `SurfaceInputEvent`: its sequence number on its stream and what it does.
public struct SurfaceInputEvent: Sendable, Equatable {
    public let seq: Int
    public let action: SurfaceAction

    public init(seq: Int, action: SurfaceAction) {
        self.seq = seq
        self.action = action
    }

    init(_ value: JSONValue, at index: Int) throws {
        let f = try Fields(value, "events[\(index)]")
        let kind = try f.string("kind")
        let keys: Set<String>
        switch kind {
        case "mouse":
            keys = ["action", "x", "y", "button", "clicks", "mods"]
            guard let phase = SurfaceMouse.Phase(rawValue: try f.string("action")) else { throw f.invalid("action must be down, up, drag or move") }
            if let button = try f.string("button", optional: true), button != "left" { throw f.invalid("button must be left") }
            action = .mouse(SurfaceMouse(phase: phase, x: try f.coordinate("x"), y: try f.coordinate("y"),
                                         clicks: try f.integer("clicks", 1...SurfaceRequest.maxInteger, optional: true) ?? 1, mods: try f.mods()))
        case "scroll":
            keys = ["x", "y", "dx", "dy", "precise", "phase", "momentum", "mods"]
            action = .scroll(SurfaceScroll(x: try f.coordinate("x"), y: try f.coordinate("y"), dx: try f.coordinate("dx"), dy: try f.coordinate("dy"),
                                           precise: try f.bool("precise", optional: true) ?? true,
                                           phase: UInt(try f.integer("phase", 0...SurfaceRequest.maxInteger, optional: true) ?? 0),
                                           momentum: UInt(try f.integer("momentum", 0...SurfaceRequest.maxInteger, optional: true) ?? 0), mods: try f.mods()))
        case "key":
            keys = ["action", "code", "chars", "plain", "repeat", "mods"]
            let down: Bool
            switch try f.string("action") {
            case "down": down = true
            case "up": down = false
            default: throw f.invalid("action must be down or up")
            }
            action = .key(SurfaceKey(down: down, code: UInt16(try f.integer("code", 0...Int(UInt16.max))), chars: try f.string("chars"),
                                     plain: try f.string("plain"), isRepeat: try f.bool("repeat", optional: true) ?? false, mods: try f.mods()))
        case "text":
            keys = ["text"]
            action = .text(try f.string("text"))
        case "compose":
            keys = ["text", "start", "length"]
            action = .compose(text: try f.string("text"), start: try f.integer("start", 0...SurfaceRequest.maxInteger),
                              length: try f.integer("length", 0...SurfaceRequest.maxInteger))
        case "unmark":
            keys = []
            action = .unmark
        case "focus":
            keys = ["on"]
            action = .focus(try f.bool("on"))
        case "command":
            keys = ["name", "text"]
            let text = try f.string("text", optional: true)
            let name = try f.string("name")
            if text != nil, name != "paste" { throw f.invalid("text goes with paste only") }
            switch name {
            case "copy": action = .command(.copy)
            case "paste":
                // Pasting this Mac's clipboard into a page another Mac watches would show it there.
                guard let text else { throw f.invalid("paste needs its text") }
                action = .command(.paste(text))
            case "selectAll": action = .command(.selectAll)
            case "back": action = .command(.back)
            case "forward": action = .command(.forward)
            case "reload": action = .command(.reload)
            case "stop": action = .command(.stop)
            default: throw f.invalid("unknown command \(name)")
            }
        case "navigate":
            keys = ["url"]
            let address = try f.string("url")
            guard let url = BrowserURL.normalize(address) else { throw f.invalid("url \(address) is not an address") }
            action = .navigate(url)
        default:
            throw f.invalid("unknown kind \(kind)")
        }
        seq = try f.integer("seq", 1...SurfaceRequest.maxInteger)
        try f.only(keys.union(["kind", "seq"]))
    }

    /// Whether WebKit queues it as a mouse or key event before the page sees it.
    public var queuedAsMouse: Bool {
        if case .mouse = action { return true }
        return false
    }

    public var queuedAsKey: Bool {
        if case .key = action { return true }
        return false
    }

    /// A copy, whose result carries the page's selected text.
    public var readsSelection: Bool {
        if case .command(let command) = action { return command.readsSelection }
        return false
    }
}

public enum SurfaceAction: Sendable, Equatable {
    case mouse(SurfaceMouse)
    case scroll(SurfaceScroll)
    case key(SurfaceKey)
    /// Committed text, as an input method commits it.
    case text(String)
    /// Marked (still composing) text with its selection.
    case compose(text: String, start: Int, length: Int)
    case unmark
    case focus(Bool)
    case command(SurfaceCommand)
    case navigate(URL)
}

/// Left button only: the viewer keeps context menus local, and a host menu would hold this
/// Mac's event queue until someone at it dismissed the menu.
public struct SurfaceMouse: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case down, up, drag, move
    }

    public let phase: Phase
    /// Host web view points, top-left origin.
    public let x: Double
    public let y: Double
    public let clicks: Int
    /// Raw `NSEvent.ModifierFlags`.
    public let mods: UInt
}

public struct SurfaceScroll: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let dx: Double
    public let dy: Double
    /// Pixel deltas (a trackpad's); else wheel lines.
    public let precise: Bool
    /// Raw `NSEvent.Phase` values.
    public let phase: UInt
    public let momentum: UInt
    public let mods: UInt
}

public struct SurfaceKey: Sendable, Equatable {
    public let down: Bool
    public let code: UInt16
    public let chars: String
    public let plain: String
    public let isRepeat: Bool
    public let mods: UInt
}

public enum SurfaceCommand: Sendable, Equatable {
    case copy, selectAll, back, forward, reload, stop
    case paste(String)

    /// Whether the result carries the page's selected text.
    public var readsSelection: Bool { self == .copy }
}

/// `surface.answer`'s reply to a dialog; which fields count depends on the dialog's kind.
public struct SurfaceAnswer: Sendable, Equatable {
    public let accept: Bool
    public let text: String?
    public let user: String?
    public let password: String?
    public let choice: Int?
    public let files: [SurfaceFile]?
}

/// What a viewer receives (`SurfaceEvent`), sent only to its stream's own connection.
public enum SurfaceEvent {
    public struct Frame: Sendable, Equatable {
        public static let maxPixels: Int = 4_000_000

        /// Fits positive source dimensions at a finite positive relative ratio within the coded frame budget.
        public static func fittedPixels(width: Int, height: Int, ratio: Double, format: SurfaceFormat) -> (width: Int, height: Int) {
            let minimum = format == .h264 ? 16 : 1
            let w = Double(width), h = Double(height), budget = Double(maxPixels)
            // Single-axis caps include the codec's minimum size on the other axis.
            let axisBudget = budget / Double(minimum)
            let scale = min(ratio, (budget / w / h).squareRoot(), axisBudget / w, axisBudget / h)
            var fittedWidth = max(1, Int(min(axisBudget, (w * scale).rounded(.down))))
            var fittedHeight = max(1, Int(min(axisBudget, (h * scale).rounded(.down))))
            fittedWidth = min(fittedWidth, maxPixels / fittedHeight)
            // Preserve native pixels unless codec padding would exceed the budget.
            if format == .h264,
               max(16, (fittedWidth + 1) / 2 * 2) > maxPixels / max(16, (fittedHeight + 1) / 2 * 2) {
                fittedWidth = max(1, fittedWidth / 2 * 2)
                fittedHeight = max(1, fittedHeight / 2 * 2)
            }
            return (fittedWidth, fittedHeight)
        }

        public var stream: String
        public var seq: Int
        /// The highest input seq WebKit had processed before the page presented this image.
        public var input: Int
        /// The web view's size in points, which input coordinates are in.
        public var size: CGSize
        /// Image pixels per point, as `surface.stream` answered it.
        public var scale: Double
        public var format: SurfaceFormat
        public var data: Data
        public var width: Int
        public var height: Int
        public var back: Bool
        public var forward: Bool
        public var loading: Bool
        public var refresh = false
        public var supersedes: Int?
        public var canvas: CGSize?
        public var offset: Int?
        public var total: Int?

        public init(stream: String, seq: Int, input: Int, size: CGSize, scale: Double, format: SurfaceFormat, data: Data, width: Int, height: Int,
                    back: Bool, forward: Bool, loading: Bool) {
            (self.stream, self.seq, self.input, self.size, self.scale, self.format, self.data) = (stream, seq, input, size, scale, format, data)
            (self.width, self.height, self.back, self.forward, self.loading) = (width, height, back, forward, loading)
        }

        public var json: JSONValue {
            var value: [String: JSONValue] = [
                "stream": .string(stream), "seq": .number(Double(seq)), "input": .number(Double(input)),
                "size": SurfaceEvent.size(size), "scale": .number(scale), "format": .string(format.rawValue),
                "data": .string(data.base64EncodedString()), "width": .number(Double(width)), "height": .number(Double(height)),
                "back": .bool(back), "forward": .bool(forward), "loading": .bool(loading),
            ]
            if refresh { value["refresh"] = .bool(true) }
            if let supersedes { value["supersedes"] = .number(Double(supersedes)) }
            if let canvas { value["canvas"] = SurfaceEvent.size(canvas) }
            if let offset { value["offset"] = .number(Double(offset)) }
            if let total { value["total"] = .number(Double(total)) }
            return .object(value)
        }
    }

    public enum DialogKind: String, Sendable {
        case alert, confirm, prompt, login, select, file
    }

    public enum NoticeKind: String, Sendable {
        case closed, dialogClosed, download, refused
    }

    public static func size(_ size: CGSize) -> JSONValue {
        .object(["w": .number(size.width), "h": .number(size.height)])
    }

    public static func dialog(stream: String, dialog: String, kind: DialogKind, origin: String, message: String? = nil, text: String? = nil,
                              choices: [String]? = nil, selected: Int? = nil, multiple: Bool? = nil, accept: [String]? = nil) -> JSONValue {
        var data: [String: JSONValue] = ["stream": .string(stream), "dialog": .string(dialog), "kind": .string(kind.rawValue), "origin": .string(origin)]
        if let message { data["message"] = .string(message) }
        if let text { data["text"] = .string(text) }
        if let choices { data["choices"] = .array(choices.map(JSONValue.string)) }
        if let selected { data["selected"] = .number(Double(selected)) }
        if let multiple { data["multiple"] = .bool(multiple) }
        if let accept { data["accept"] = .array(accept.map(JSONValue.string)) }
        return .object(data)
    }

    public static func notice(stream: String, kind: NoticeKind, reason: String? = nil, name: String? = nil, state: String? = nil,
                              dialog: String? = nil) -> JSONValue {
        var data: [String: JSONValue] = ["stream": .string(stream), "kind": .string(kind.rawValue)]
        if let reason { data["reason"] = .string(reason) }
        if let name { data["name"] = .string(name) }
        if let state { data["state"] = .string(state) }
        if let dialog { data["dialog"] = .string(dialog) }
        return .object(data)
    }
}

/// One private surface event (`SurfaceEvent`) as the line that carries it,
/// `{"event":…,"board":…,"data":…}`, encoded once for a direct viewer's socket and for the easld
/// link a relayed stream was opened on alike. `event` comes first: easld takes a client's line
/// that starts `{"event":` as an event of a stream that client serves, never as a request.
public struct EventLine: Sendable {
    /// The line and its newline.
    public let data: Data

    public init(_ event: String, board: BoardID, _ payload: JSONValue) throws {
        let encoder = JSONEncoder()
        let name = try encoder.encode(event), id = try encoder.encode(board), body = try encoder.encode(payload)
        let head = Array(#"{"event":"#.utf8), boardKey = Array(#","board":"#.utf8), dataKey = Array(#","data":"#.utf8)
        var line = Data(capacity: head.count + name.count + boardKey.count + id.count + dataKey.count + body.count + 2)
        line.append(contentsOf: head)
        line.append(name)
        line.append(contentsOf: boardKey)
        line.append(id)
        line.append(contentsOf: dataKey)
        line.append(body)
        line.append(contentsOf: [UInt8(ascii: "}"), 0x0A])
        data = line
    }

    /// The line without its newline, sharing its bytes.
    public var line: Data { data.dropLast() }
}

/// A closed JSON object's fields, read with the schema's types.
private struct Fields {
    let values: [String: JSONValue]
    let path: String

    init(_ value: JSONValue, _ path: String) throws {
        guard let values = value.object else { throw SurfaceRequest.invalid("\(path) must be an object") }
        self.values = values
        self.path = path
    }

    func invalid(_ message: String) -> ApiRouter.Failure {
        SurfaceRequest.invalid("\(path): \(message)")
    }

    func only(_ keys: Set<String>) throws {
        let unknown = values.keys.filter { !keys.contains($0) }.sorted()
        guard unknown.isEmpty else { throw invalid("unknown field\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", "))") }
    }

    private func present(_ key: String, optional: Bool) throws -> JSONValue? {
        guard let value = values[key] else {
            if optional { return nil }
            throw invalid("missing \(key)")
        }
        return value
    }

    func string(_ key: String) throws -> String {
        try string(key, optional: false)!
    }

    func string(_ key: String, optional: Bool) throws -> String? {
        guard let value = try present(key, optional: optional) else { return nil }
        guard let string = value.string else { throw invalid("\(key) must be a string") }
        return string
    }

    func bool(_ key: String) throws -> Bool {
        try bool(key, optional: false)!
    }

    func bool(_ key: String, optional: Bool) throws -> Bool? {
        guard let value = try present(key, optional: optional) else { return nil }
        guard let bool = value.bool else { throw invalid("\(key) must be a boolean") }
        return bool
    }

    func number(_ key: String) throws -> Double? {
        guard let value = try present(key, optional: true) else { return nil }
        guard case .number(let number) = value, number.isFinite else { throw invalid("\(key) must be a number") }
        return number
    }

    func coordinate(_ key: String) throws -> Double {
        guard let number = try number(key) else { throw invalid("missing \(key)") }
        return number
    }

    func integer(_ key: String, _ range: ClosedRange<Int>) throws -> Int {
        try integer(key, range, optional: false)!
    }

    func integer(_ key: String, _ range: ClosedRange<Int>, optional: Bool) throws -> Int? {
        guard let value = try present(key, optional: optional) else { return nil }
        guard case .number(let number) = value, number.rounded() == number,
              number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            throw invalid("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(number)
    }

    func mods() throws -> UInt {
        UInt(try integer("mods", 0...Int(UInt32.max), optional: true) ?? 0)
    }

    func stream() throws -> String {
        let stream = try string("stream")
        guard stream.range(of: "^str_[0-9A-Za-z]+$", options: .regularExpression) != nil else { throw invalid("stream \(stream) is not a stream id") }
        return stream
    }
}
