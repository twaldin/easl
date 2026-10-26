import Foundation

/// Carries out validated HTML tile messages against the board. The only native capabilities a
/// page has: read board files as excerpts, open code tiles, keep its own `props.state`, and hand
/// the agent terminal that created it a JSON message (`canvasKit.send`).
@MainActor
public enum HtmlChannel {
    public static let maxStateBytes = 256 * 1024

    /// A page's paths resolve against its tile's link root (`Board.linkRoot`). `tile` need only
    /// be on `board` for state messages: a local page measured before its tile exists
    /// (`HtmlTile.measure`, on a scratch board rooted at the page's link root) reads excerpts
    /// against the board's root; a remote one is on a scratch board of its own (`Board.measuring`).
    /// A page with a `ref` reads its excerpts where the ref is now (`Board.linkSource`): the live
    /// worktree, else git objects at the ref's commit.
    public static func handle(_ message: HtmlMessage, tile: ObjectID, board: Board, files: HostFiles? = nil, mayStartTurn: Bool = false, now: Date = Date()) async throws -> JSONValue {
        let object = board.objects[tile]
        if board.isRemote {
            // A page's messages are queued on this mirror, whose queue the host's integrations
            // never drain: nothing here can hand one to a terminal on the board's host.
            if case .send = message { throw HtmlError.unavailable("canvasKit.send is unsupported on remote boards") }
            if files == nil { throw HtmlError.unavailable("host file reader is unavailable") }
        }
        switch message {
        case .excerpt(let path, let lines, let symbol):
            if let files {
                let relative = try HtmlKit.boardRelative(path)
                let excerpt = try await hostExcerpt(path: relative, lines: lines, symbol: symbol, source: board.hostSource(props: object?.props ?? .object([:]), objects: true), files: files)
                try Task.checkCancellation()
                return try JSONValue.encode(excerpt)
            }
            let reading = await localReading(object: object, board: board)
            let root = reading.root
            let file = try HtmlKit.boardFile(path, root: root)
            let excerpt: SourceExcerpt
            if let commit = reading.commit {
                do {
                    let text = try await reading.read(file.relative)
                    excerpt = await offMain { SourceExcerpt.resolve(text: text, path: file.relative, lines: lines, symbol: symbol) }
                } catch {
                    let reason = reading.failure?.reason ?? "\(file.relative) not found at \(commit.prefix(7))"
                    excerpt = SourceExcerpt(path: file.relative, start: 0, end: 0, lines: [], symbol: symbol, language: SourceExcerpt.language(for: file.relative), stale: true, reason: reason, truncated: false)
                }
            } else {
                excerpt = await offMain { SourceExcerpt.load(url: file.url, path: file.relative, lines: lines, symbol: symbol) }
            }
            try Task.checkCancellation()
            return try JSONValue.encode(excerpt)

        case .openCode(let path, let lines, let symbol):
            if let files {
                return try await hostOpen(path: path, lines: lines, symbol: symbol, object: object, tile: tile, board: board, files: files)
            }
            let reading = await localReading(object: object, board: board)
            let root = reading.root
            let file = try HtmlKit.boardFile(path, root: root)
            let ref = object.flatMap { RefSource.ref(of: $0.props) }
            if ref != nil, reading.commit != nil {
                // The ref's objects: the code tile opens at the same ref and finds the symbol itself.
                return openCode(path: board.boardPath(file.relative, linkRoot: root), range: lines, symbol: symbol, ref: ref, beside: tile, on: board)
            }
            var range = lines
            if range == nil, let symbol {
                range = await offMain { () -> LineRange? in
                    let excerpt = SourceExcerpt.load(url: file.url, path: file.relative, lines: nil, symbol: symbol)
                    return excerpt.stale ? nil : LineRange(start: excerpt.start, end: excerpt.end)
                }
                try Task.checkCancellation()
            }
            guard FileManager.default.fileExists(atPath: file.url.path) else { throw HtmlError.notFound(file.relative) }
            return openCode(path: board.boardPath(file.relative, linkRoot: root), range: range, symbol: symbol, ref: ref, beside: tile, on: board)

        case .getState(let key):
            return state(try board.object(tile).props, key: key)

        case .setState(let key, let value):
            var state = try board.object(tile).props["state"]?.object ?? [:]
            if value == .null { state.removeValue(forKey: key) } else { state[key] = value }
            let size = (try? JSONEncoder().encode(state).count) ?? Int.max
            guard size <= maxStateBytes else { throw HtmlError.tooLarge(size, limit: maxStateBytes) }
            try board.update(tile, props: .object(["state": .object(state)]))
            return .object([:])

        case .rendered:
            return .object([:])

        case .send(let payload):
            return try send(payload, tile: tile, board: board, mayStartTurn: mayStartTurn, now: now)
        }
    }

    /// `canvasKit.send`: the page's JSON payload goes to the agent terminal that created the
    /// tile, out of band, so nothing is typed into its terminal. The text is the payload alone.
    /// The tile id and title travel in `from`, which easl fills, not in the page's bytes.
    private static func send(_ payload: JSONValue, tile: ObjectID, board: Board, mayStartTurn: Bool, now: Date) throws -> JSONValue {
        try HtmlMessage.checkPayload(payload)
        let object = try board.object(tile)
        guard case .agent(let creator) = object.createdBy else {
            throw HtmlError.unavailable("this tile was made by the user, so canvasKit.send has no agent terminal to send to")
        }
        guard let creatorTile = board.objects[creator] else {
            throw HtmlError.unavailable("the terminal that created this page (\(creator)) is gone")
        }
        guard creatorTile.type == .terminal else {
            throw HtmlError.unavailable("the tile that created this page (\(creator)) is not a terminal")
        }
        guard !board.agentExited(creator) else {
            throw HtmlError.unavailable("the agent in terminal \(creator) that created this page exited: nothing takes its messages until an agent reports there again")
        }
        guard PromptTarget.takesMessages(creatorTile) else {
            throw HtmlError.unavailable("the agent in terminal \(creator) that created this page takes no messages: it needs an integration that takes them (agent.report protocol ≥ 1)")
        }
        guard PromptTarget.takesPageMessages(creatorTile) else {
            throw HtmlError.unavailable("the agent in terminal \(creator) that created this page does not take page messages: it needs an integration at protocol ≥ 3")
        }
        guard let text = HtmlSendBudget.payloadText(payload) else { throw HtmlError.malformed("the payload is not JSON") }
        let message = AgentMessage(text: text, from: nil, html: tile, label: nil, when: .now, mentions: [], mayStartTurn: mayStartTurn)
        try board.queueHtmlMessage(message, to: creator, now: now)
        return .object(["terminal": .string(creator), "message": .string(message.id)])
    }

    static func title(of tile: CanvasObject) -> String {
        tile.props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "HTML"
    }

    private static func localReading(object: CanvasObject?, board: Board) async -> LinkReading {
        if let object, RefSource.ref(of: object.props) != nil { return await board.linkSource(of: object) }
        return LinkReading(root: object.map(board.linkRoot(of:)) ?? board.root)
    }

    private static func hostExcerpt(path: String, lines: LineRange?, symbol: String?, source: HostFileRequest.Source, files: HostFiles) async throws -> SourceExcerpt {
        do {
            let file = try await files.read(HostFileRequest(source: source, policy: .boardFile(path)))
            return await offMain { SourceExcerpt.from(file, path: path, lines: lines, symbol: symbol) }
        } catch let error as HostFileError {
            let reason: String
            switch error {
            case .refused: throw HtmlError.outsideRoot(path)
            case .notFound(let commit): reason = "\(path) not found" + (commit.map { " at \($0.prefix(7))" } ?? "")
            case .tooLarge(let limit): reason = "\(path) is larger than \(limit / 1024 / 1024) MB"
            case .unreadable: reason = "\(path) is unreadable"
            case .ref(let why): reason = why
            case .unavailable(let why): reason = "couldn't read \(path) on \(files.hostName): \(why)"
            }
            return SourceExcerpt.failed(path: path, symbol: symbol, reason: reason)
        }
    }

    private static func hostOpen(path: String, lines: LineRange?, symbol: String?, object: CanvasObject?, tile: ObjectID, board: Board, files: HostFiles) async throws -> JSONValue {
        let relative = try HtmlKit.boardRelative(path)
        let props = object?.props ?? .object([:])
        let source = board.hostSource(props: props, objects: true)
        let ref = RefSource.ref(of: props)
        let checked: HostFile
        do {
            checked = try await files.read(HostFileRequest(source: source, policy: .boardFile(relative), bytes: false))
        } catch let error as HostFileError {
            switch error {
            case .refused: throw HtmlError.outsideRoot(path)
            case .ref where ref != nil:
                try Task.checkCancellation()
                return openCode(path: board.boardPath(relative, linkRoot: board.root), range: lines, symbol: symbol, ref: ref, beside: tile, on: board)
            case .unavailable(let reason): throw HtmlError.unavailable("couldn't read \(relative) on \(files.hostName): \(reason)")
            default: throw HtmlError.notFound(relative)
            }
        }
        var range = lines
        if checked.commit == nil, range == nil, let symbol {
            let excerpt = try await hostExcerpt(path: relative, lines: nil, symbol: symbol, source: source, files: files)
            if !excerpt.stale { range = LineRange(start: excerpt.start, end: excerpt.end) }
        }
        try Task.checkCancellation()
        return openCode(path: board.boardPath(relative, linkRoot: URL(fileURLWithPath: checked.root)), range: range, symbol: symbol, ref: ref, beside: tile, on: board)
    }

    /// The `state.get` reply for a tile with `props`: one key's value, or the whole state.
    public static func state(_ props: JSONValue, key: String?) -> JSONValue {
        let state = props["state"] ?? .object([:])
        return .object(["value": key.map { state[$0] ?? .null } ?? state])
    }

    /// File reads run off the main actor and stop early when the requesting page goes away.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// The user's navigation to code from the HTML tile (`Board.openForNavigation`): a tile
    /// already showing the lines anywhere (`existing`, a walkthrough's stop), else a plain code
    /// tile in view showing `path` re-aimed, else a new one to the right of the HTML tile.
    static func openCode(path: String, range: LineRange?, symbol: String?, ref: String?, beside tile: ObjectID, on board: Board) -> JSONValue {
        let opened = board.openForNavigation(CodeAim(path: path, range: range, symbol: symbol, ref: ref), from: tile)
        return .object(["tile": .string(opened.id), "created": .bool(opened.created), "existing": .bool(opened.existing)])
    }
}

extension Board {
    /// Where `page`, an HTML page measured before its tile exists on remote board `board`, runs:
    /// a remote board of its own, rooted where `board` is and holding just `page`, so the page
    /// reads `board`'s host files under its own `root`, `ref` and `refSha` as its tile will. A
    /// page measured offscreen never writes (`HtmlTile.handle`); whatever this board would send
    /// its host goes nowhere, never to `board`'s.
    public static func measuring(_ page: CanvasObject, on board: Board) -> Board {
        let scratch = Board(remote: IDs.make("brd"), root: board.root, host: nil)
        scratch.applyHost(page)
        return scratch
    }
}
