import AppKit
import Markdown

/// What a remote board's window answers its easld with (`DelegatedCalls`): closures bound to that
/// window, as `ApiRouter`'s are bound to the app's own windows.
@MainActor
public struct ViewerWindow {
    /// The window is key: the user is looking at this board.
    public var focused: () -> Bool
    /// What the window shows (`view.get`); nil once it is gone.
    public var viewState: () -> ViewState?
    /// The window as shown, encoded in `format`, with the viewport it shows.
    public var snapshot: (_ format: ImageFormat) async -> (output: RenderOutput, viewport: Viewport)?
    /// Types text into a terminal tile's surface (bracketed paste) and presses Enter once the paste
    /// landed; false when the tile has no surface.
    public var submit: (ObjectID, _ text: String) async -> Bool
    /// The last `lines` lines of a terminal tile's text as its surface has it (its scrollback and
    /// screen, soft-wrapped rows joined); nil without a surface.
    public var surfaceTail: (ObjectID, _ lines: Int) -> TerminalTail.Tail?
    /// A terminal tile's finished command (`agent.read` `block`: -1 the last); throws `Failure`
    /// when there's none to read.
    public var block: (ObjectID, _ index: Int) throws -> (command: TerminalCommand, output: String)
    /// A terminal tile's title, last command and focus, as its tile knows them now; nil without it.
    public var status: (ObjectID) -> TerminalStatus?

    public init(focused: @escaping () -> Bool, viewState: @escaping () -> ViewState?,
                snapshot: @escaping (ImageFormat) async -> (output: RenderOutput, viewport: Viewport)?,
                submit: @escaping (ObjectID, String) async -> Bool, surfaceTail: @escaping (ObjectID, Int) -> TerminalTail.Tail?,
                block: @escaping (ObjectID, Int) throws -> (command: TerminalCommand, output: String), status: @escaping (ObjectID) -> TerminalStatus?) {
        self.focused = focused
        self.viewState = viewState
        self.snapshot = snapshot
        self.submit = submit
        self.surfaceTail = surfaceTail
        self.block = block
        self.status = status
    }
}

/// How this viewer names itself to easld (`client.attach` `app` and `host`).
public struct ClientIdentity: Equatable, Sendable {
    /// The app's version; nil outside an app bundle.
    public var app: String?
    public var host: String

    public init(app: String?, host: String) {
        self.app = app
        self.host = host
    }
}

/// A remote board's delegated calls from its easld (docs/design/next.md "The client protocol"),
/// answered from the board's window. easld checked each call as it checks its own (the board, the
/// target, a blocked agent) and queued a prompt's mentions itself, so nothing here checks them
/// again. It holds no link to the host: a call answered by asking the host would wait behind
/// itself on that link, or come straight back here (the composer's own prompt).
@MainActor
final class DelegatedCalls {
    /// What a viewer serves (`client.attach` `serves`). Never `view.render` or `object.reload`: the
    /// viewer has only the host's drawings of those tiles, and would ask the host to draw them.
    static let served = ["view.get", "view.snapshot", "agent.prompt", "agent.read", "text.measure"]

    let board: Board
    let window: ViewerWindow
    /// Surface positions restart when Ghostty trims scrollback, unlike zmx history's positions.
    private var promptMarks: [ObjectID: PromptMark] = [:]

    init(board: Board, window: ViewerWindow) {
        self.board = board
        self.window = window
    }

    /// `call`'s result, or why not as the app's own router words it. A param this build doesn't
    /// know fails just this call (docs/design/next.md "Versions").
    func answer(_ call: EaslConnection.Call) async -> Result<JSONValue, EaslConnection.Failure> {
        do {
            try ApiRouter.checkParams(call.method, call.params)
            let p = call.params
            switch call.method {
            case "view.get":
                guard let state = window.viewState() else { throw ApiRouter.Failure("unavailable", "board \(board.id) has no window") }
                return .success(ApiRouter.viewResult(state, board: board.id))
            case "view.snapshot": return .success(try await snapshot(p))
            case "agent.prompt": return .success(try await prompt(p))
            case "agent.read": return .success(try read(p))
            case "text.measure": return .success(try measure(p))
            default: throw ApiRouter.Failure("unsupported", "\(call.method) isn't served by this board's viewer")
            }
        } catch {
            let failure = ApiRouter.failure(for: error)
            return .failure(EaslConnection.Failure(failure.code, failure.message))
        }
    }

    /// The window's picture, saved on this Mac, whose path the answer names. A caller's `out` is a
    /// path on easld's machine, which this Mac can't write: refused, never written here.
    private func snapshot(_ p: JSONValue) async throws -> JSONValue {
        if let out = p["out"], out != .null {
            throw ApiRouter.Failure("unavailable", "nothing was written at \(out.string ?? "out"): this board's window is on another machine, "
                + "which can't write a file on this one; without out, view.snapshot saves the picture on that machine and answers its path there")
        }
        let (format, path) = try ApiRouter.imageDestination(p, name: "snapshot")
        guard let shot = await window.snapshot(format) else { throw ApiRouter.Failure("unavailable", "board \(board.id) has no window") }
        return try await ApiRouter.snapshotResult(shot, to: path)
    }

    /// Types the prompt into the terminal's surface, as the app's own `agent.prompt` does once its
    /// checks pass, remembering the terminal's text just before (`agent.read` `since: "prompt"`).
    private func prompt(_ p: JSONValue) async throws -> JSONValue {
        let terminal = try terminal(p)
        guard let text = p["text"]?.string else { throw ApiRouter.Failure("invalid_params", "missing text") }
        let before = window.surfaceTail(terminal.id, ApiRouter.promptMarkLines)
        guard await window.submit(terminal.id, text) else { throw ApiRouter.Failure("unavailable", "terminal \(terminal.id) has no attached surface") }
        promptMarks[terminal.id] = PromptMark(before ?? TerminalTail.Tail(rows: [], positions: []))
        let current = board.objects[terminal.id] ?? terminal
        return .object([
            "agent": agentEntry(current),
            "submittedAt": .string(Date().formatted(.iso8601)),
            "waitable": .bool(ApiRouter.waitable(current)),
            "delivery": .string("typed"),
        ])
    }

    /// `agent.read`'s screen modes from the terminal's surface (`final` is easld's own).
    private func read(_ p: JSONValue) throws -> JSONValue {
        let terminal = try terminal(p)
        let request = try ApiRouter.ReadRequest(p)
        var result: [String: JSONValue]
        if let block = request.block {
            result = ApiRouter.blockResult(try window.block(terminal.id, block), lines: request.lines)
        } else {
            var mark: PromptMark?
            if request.sincePrompt {
                guard let found = promptMarks[terminal.id] else {
                    throw ApiRouter.Failure("not_found", "no agent.prompt has reached terminal \(terminal.id) through this board's viewer since it attached; read with lines instead")
                }
                mark = found
            }
            guard let tail = window.surfaceTail(terminal.id, request.reading) else {
                throw ApiRouter.Failure("unavailable", "terminal \(terminal.id) has no attached surface")
            }
            let aligned = mark?.aligned(to: tail)
            let lost = mark != nil && aligned == nil
            result = request.shown(lost ? tail.suffix(request.lines) : tail, after: aligned)
            if lost { result["truncated"] = .bool(true) }
        }
        result["agent"] = agentEntry(board.objects[terminal.id] ?? terminal)
        return .object(result)
    }

    /// The terminal `target` names (easld resolved it to a tile id).
    private func terminal(_ p: JSONValue) throws -> CanvasObject {
        let id = p["target"]?.string ?? ""
        guard let terminal = board.objects[id], terminal.type == .terminal else {
            throw ApiRouter.Failure("not_found", "terminal \(id) isn't on this board's viewer")
        }
        return terminal
    }

    /// A terminal's `agent` entry: its address among this board alone, and no pid (its processes
    /// are the host's).
    private func agentEntry(_ terminal: CanvasObject) -> JSONValue {
        ApiRouter.agentEntry(terminal, on: board, among: [board], status: window.status(terminal.id))
    }

    private struct PromptMark {
        let tail: TerminalTail.Tail
        let prefix: [Int]

        init(_ tail: TerminalTail.Tail) {
            self.tail = tail
            var prefix = Array(repeating: 0, count: tail.rows.count)
            if tail.rows.count > 1 {
                for index in 1..<tail.rows.count {
                    var matched = prefix[index - 1]
                    while matched > 0, tail.rows[index] != tail.rows[matched] { matched = prefix[matched - 1] }
                    if tail.rows[index] == tail.rows[matched] { matched += 1 }
                    prefix[index] = matched
                }
            }
            self.prefix = prefix
        }

        /// Find retained context in linear time. Missing or ambiguous context cannot establish
        /// a complete reply, so the caller returns the available tail marked truncated.
        func aligned(to now: TerminalTail.Tail) -> TerminalTail.Tail? {
            guard !tail.rows.isEmpty else { return tail }
            var matched = 0, best = 0, end = 0
            var ambiguous = false
            for (index, row) in now.rows.enumerated() {
                while matched > 0, row != tail.rows[matched] { matched = prefix[matched - 1] }
                if row == tail.rows[matched] { matched += 1 }
                if matched > 0, now.positions[index - matched + 1] > tail.positions[0] { break }
                if matched > best {
                    best = matched
                    end = index
                    ambiguous = false
                } else if matched > 0, matched == best {
                    ambiguous = true
                }
                if matched == tail.rows.count { matched = prefix[matched - 1] }
            }
            guard best > 0, !ambiguous else { return nil }
            let shift = now.positions[end - best + 1] - tail.positions[0]
            guard tail.end + shift <= now.end else { return nil }
            return TerminalTail.Tail(rows: tail.rows, positions: tail.positions.map { $0 + shift })
        }
    }

    // MARK: text.measure

    /// One `text.measure` item (docs/design/next.md "Text measurement").
    @MainActor
    private enum TextItem {
        case note(Document, width: CGFloat?, root: String?)
        case text(String, textSize: CGFloat, width: CGFloat?)
        case label(String, width: CGFloat?)
        case arrowLabel(String)
        case caption(String)

        static let fields: Set<String> = ["kind", "text", "width", "textSize", "root"]

        init(_ json: JSONValue, at index: Int) throws {
            guard let item = json.object else { throw ApiRouter.Failure("invalid_params", "items[\(index)] must be {kind, text, width?, textSize?, root?}") }
            if let unknown = item.keys.sorted().first(where: { !Self.fields.contains($0) }) {
                throw ApiRouter.Failure("invalid_params", "items[\(index)]: unknown field \(unknown); an item takes kind, text, width, textSize, root")
            }
            guard let text = item["text"]?.string else { throw ApiRouter.Failure("invalid_params", "items[\(index)] needs its text") }
            let width = item["width"]?.number.map { CGFloat($0) }
            switch item["kind"]?.string {
            case "note": self = .note(NoteMarkdown.parse(text), width: width, root: item["root"]?.string)
            case "text": self = .text(text, textSize: CGFloat(item["textSize"]?.number ?? 1), width: width)
            case "label": self = .label(text, width: width)
            case "arrowLabel": self = .arrowLabel(text)
            case "caption": self = .caption(text)
            default: throw ApiRouter.Failure("invalid_params", "items[\(index)]: kind must be one of note, text, label, arrowLabel, caption")
            }
        }

        var size: JSONValue {
            let size: CGSize
            switch self {
            case .note(let document, let width, _):
                // No excerpts and no images: `measure` let through only notes without them.
                let note = ObjectMeasure.note(document, width: width, excerpts: [:], images: [:])
                return .object(["w": .number(note.size.width), "h": .number(note.size.height), "tableShortfall": .number(note.tableShortfall)])
            case .text(let text, let textSize, let width): size = ObjectMeasure.shapeTextBounds(text, textSize: textSize, width: width)
            case .label(let text, let width): size = ObjectMeasure.labelBounds(text, width: width)
            case .arrowLabel(let text): size = DrawingStyle.arrowLabel(ArrowSpec(from: .point(.zero), to: .point(.zero), label: text))?.size ?? .zero
            case .caption(let text): size = CGSize(width: ObjectMeasure.captionWidth(text), height: CodeMetrics.captionHeight)
            }
            return .object(["w": .number(size.width), "h": .number(size.height)])
        }
    }

    /// The items laid out as this Mac lays them out, at once: easld may hold its boards while it
    /// waits (docs/design/next.md "Framing"). A note's anchored fences and images are read under
    /// easld's `root`, on easld's machine, so a batch with one fails `unavailable` whole and easld
    /// measures it from its glyph table, reading them there. Nothing here reads a file.
    private func measure(_ p: JSONValue) throws -> JSONValue {
        guard let list = p["items"]?.array else { throw ApiRouter.Failure("invalid_params", "items must be a list of {kind, text, width?, textSize?, root?}") }
        let items = try list.enumerated().map { try TextItem($1, at: $0) }
        for case .note(let document, _, let root) in items where !NoteMarkdown.anchoredFences(in: document).isEmpty || !NoteImages.sources(in: document).isEmpty {
            throw ApiRouter.Failure("unavailable", "a note's fences and images are read on the board's host\(root.map { " (under \($0))" } ?? ""), which this Mac doesn't have")
        }
        return .object(["sizes": .array(items.map { $0.size })])
    }
}
