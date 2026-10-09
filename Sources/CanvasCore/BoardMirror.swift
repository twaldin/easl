import CoreGraphics
import Foundation

/// A user's write to a remote board, already applied there as a preview, for its host.
public enum RemoteWrite: Equatable, Sendable {
    /// A provisional object (its id is this board's own until the host answers with its id).
    case create(CanvasObject)
    /// `seen`: the object's revision as the board showed it when the user made the change.
    case update(ObjectID, seen: Int?, frame: Frame?, z: Double?, props: JSONValue?)
    case delete(ObjectID)

    /// The object written, by its id on this board.
    var object: ObjectID {
        switch self {
        case .create(let object): object.id
        case .update(let id, _, _, _, _), .delete(let id): id
        }
    }
}

/// Where a remote board (`Board.isRemote`) sends the user's writes.
@MainActor
protocol BoardHost: AnyObject {
    func send(_ write: RemoteWrite)
}

/// A board another easl hosts, mirrored over that easl's API (docs/design.md "Client mode").
///
/// `load` subscribes to the board's events, then reads it (`board.get`, and `object.get` for the
/// notes it cut), into a `Board` marked remote that nothing stores. The host's events replace
/// objects with the host's (`rev` included) unless a newer host revision is already here. The
/// user's writes on that board are previews sent here (`send`): one at a time per object, a props
/// write carrying the host `rev` the user's change was based on; while an object has writes in
/// flight its events wait, and once the last is answered the board shows the newest host version,
/// so a failed write puts the host's object back (and says why in `onNotice`). A created object
/// takes the host's id when its create is answered (`Board.rekeyHost`). Back online after a drop,
/// the board is read again and the difference applied; the host's events wait while it is read
/// and follow it, so none is undone by the read. Once both links are back, `onRedraw` tells the
/// tiles that show the host's drawings to ask for new ones.
@MainActor
public final class BoardMirror: BoardHost {
    /// The host as the user knows it, for titles and notices.
    public let hostName: String
    public let boardID: BoardID
    /// Subscriptions, reads, writes and prompts.
    public let connection: EaslConnection
    /// `view.render`'s own link: the host answers one link's requests in order, and a render may
    /// wait seconds for a page. `queue` keeps one request on it at a time.
    private let renders: EaslConnection
    /// Nil until `load` succeeded.
    public private(set) var board: Board?
    public private(set) var state: EaslConnection.State = .connecting
    /// Each state change, after the board was loaded.
    public var onState: ((EaslConnection.State) -> Void)?
    /// Something to tell the user (a write the host refused, a create that failed).
    public var onNotice: ((String) -> Void)?
    /// A link dropped and is back, the board has been read again, and the render link is online:
    /// the tiles that show the host's drawing of an object ask for a fresh one (once). The read
    /// announces only objects that changed, so a drawing that failed or went stale while a link
    /// was down would otherwise stay as it is until the object changes.
    public var onRedraw: (() -> Void)?

    /// The host's objects as last heard (a reply, an event, a read), by host id.
    private var known: [ObjectID: CanvasObject] = [:]
    /// Writes not answered yet, by the written object's id here, oldest first (the first is in flight).
    private var queues: [ObjectID: [RemoteWrite]] = [:]
    /// A provisional object's id here → the host's id for it, once its create is answered.
    private var hostIDs: [ObjectID: ObjectID] = [:]

    /// A read of the whole board in progress (`load`, `reread`), which may predate the host's
    /// events that arrive meanwhile (they wait: `held`). `created` and `deleted` are what this
    /// viewer's answered writes made or removed meanwhile.
    struct Reading {
        var created: Set<ObjectID> = []
        var deleted: Set<ObjectID> = []
    }

    /// Nil unless the board is being read (from the start: events before the first read wait).
    private(set) var reading: Reading? = Reading()
    /// Creates sent and not answered yet: the created object's event comes ahead of the answer
    /// that says it is the user's provisional one, so events wait until then.
    private var creating = 0
    /// The host's events that arrived while the board was being read or a create was in flight,
    /// applied in order once neither is (`release`), so nothing they say is undone or doubled.
    private var held: [EaslConnection.Event] = []
    /// The tiles' drawings may be stale or failed: a link dropped after the board loaded, or the
    /// render link was offline when it did, and `onRedraw` hasn't been told since.
    private var redrawDue = false
    /// `renders`' state as last heard (the board's own link is `state`). It starts as the first
    /// connect's, `connecting`, whether or not that was heard yet.
    private(set) var rendersState: EaslConnection.State = .connecting
    /// The link went down after the board loaded: read it again once back online.
    private var stale = false
    /// How many times the link went down after the board loaded (a read that spans one reads again).
    private var drops = 0
    private var listeners: [Task<Void, Never>] = []
    /// The tiles' asks for the host's drawings, sent on `renders` one request at a time.
    private lazy var queue = RenderQueue(link: renders, board: boardID, hostName: hostName, timeout: renderTimeout) { [weak self] in
        (self?.board?.objects.mapValues(\.frame) ?? [:], self?.board?.viewport())
    }
    /// How long a `view.render` may take, from when it is sent, before it fails `timeout`.
    private let renderTimeout: Duration

    public init(hostName: String, board: BoardID, connection: EaslConnection, renders: EaslConnection, renderTimeout: Duration = .seconds(30)) {
        self.hostName = hostName
        boardID = board
        self.connection = connection
        self.renders = renders
        self.renderTimeout = renderTimeout
    }

    /// Subscribes, reads the board and returns it; throws the host's failure (`not_found`: no such
    /// board there; `unavailable`: the host can't be reached).
    public func load() async throws -> Board {
        connection.subscribe(board: boardID)
        listen()
        let manifest: JSONValue
        let objects: [CanvasObject]
        do {
            manifest = try await connection.request("board.get", .object(["board": .string(boardID)]))
            objects = try await whole(manifest["objects"])
        } catch let failure as EaslConnection.Failure {
            throw ApiRouter.Failure(failure.code, failure.message)
        }
        let board = Board(remote: boardID, root: URL(fileURLWithPath: manifest["root"]?.string ?? "/"), host: self)
        self.board = board
        install(objects, on: board)
        reading = nil
        // The tiles are made now: they ask over a render link that is offline and fail at once, and
        // that is a drawing to ask for again. (A drop heard before the board was read is no debt.)
        redrawDue = rendersState == .offline
        release()
        return board
    }

    /// Ends both links; the board stays as last seen. Asks for drawings not sent yet are answered
    /// `unavailable`.
    public func close() {
        for task in listeners { task.cancel() }
        listeners = []
        connection.close()
        renders.close()
        queue.close()
    }

    private func listen() {
        let events = connection.events(), states = connection.states(), renderStates = renders.states()
        listeners.append(Task { @MainActor [weak self] in
            for await event in events { self?.received(event) }
        })
        listeners.append(Task { @MainActor [weak self] in
            for await state in states { self?.changed(state) }
        })
        listeners.append(Task { @MainActor [weak self] in
            for await state in renderStates { self?.rendersChanged(state) }
        })
    }

    private func changed(_ state: EaslConnection.State) {
        guard state != self.state else { return }
        self.state = state
        guard board != nil else { return }
        if state != .online {
            stale = true
            drops += 1
            redrawDue = true
        }
        onState?(state)
        if state == .online, stale { Task { await reread() } }
    }

    /// The render link's next state. Only `offline` is a drop (a link that went down, or an attempt
    /// that failed: drawings asked for meanwhile failed, or came from before); `connecting` is the
    /// first connect, or the next attempt after a drop, and heard late it is no reason to draw
    /// again. Internal for the tests, which hear it where the stream would.
    func rendersChanged(_ state: EaslConnection.State) {
        guard state != rendersState else { return }
        rendersState = state
        if state == .offline { redrawDue = true }
        drawAgainIfDue()
    }

    /// Tells `onRedraw` once both links are online and the board is as the host has it: after a
    /// read, or when the render link is the last to come back.
    private func drawAgainIfDue() {
        guard redrawDue, board != nil, reading == nil, !stale, state == .online, rendersState == .online else { return }
        redrawDue = false
        onRedraw?()
    }

    /// Why the link isn't online, for the user (ssh's reason); nil while online.
    public var problem: String? { connection.problem }

    /// Tries the host again now (the user started easl there).
    public func reconnect() {
        connection.reconnect()
        renders.reconnect()
    }

    // MARK: The host's changes

    private func received(_ event: EaslConnection.Event) {
        if reading != nil || creating > 0 { return held.append(event) }
        guard event.board == nil || event.board == boardID else { return }
        switch event.name {
        case "object.created", "object.updated":
            guard let object = try? event.data.decode(CanvasObject.self) else { return }
            hostChanged(object)
        case "object.deleted":
            guard let id = event.data["id"]?.string else { return }
            hostDeleted(id)
        case "attention.changed":
            guard let id = event.data["id"]?.string else { return }
            let marker = event.data["active"]?.bool == true
                ? Attention(object: id, message: event.data["message"]?.string, raisedBy: event.data["raisedBy"]?.string, raisedAt: Date()) : nil
            board?.applyHostAttention(marker, on: id)
        default:
            // The tray is the viewer's own; a terminal's lifecycle arrives in its props.
            break
        }
    }

    /// Keeps `object` unless a newer host revision is here; a revision equal to it is taken (the
    /// host's bookkeeping, a page title, changes props without a new `rev`).
    private func learn(_ object: CanvasObject) {
        if let current = known[object.id], object.rev < current.rev { return }
        known[object.id] = object
    }

    private func hostChanged(_ object: CanvasObject) {
        learn(object)
        guard !busy(object.id), let current = known[object.id] else { return }
        board?.applyHost(current)
    }

    private func hostDeleted(_ id: ObjectID) {
        known.removeValue(forKey: id)
        guard !busy(id) else { return }
        board?.removeHost(id)
    }

    /// Writes to `id` (by its host id) are in flight.
    private func busy(_ id: ObjectID) -> Bool {
        queues.contains { key, writes in !writes.isEmpty && (key == id || hostIDs[key] == id) }
    }

    /// The board shows the host's `id` as last heard: after its writes were answered.
    private func settle(_ id: ObjectID) {
        guard let board else { return }
        if let current = known[id] {
            board.applyHost(current)
        } else {
            board.removeHost(id)
        }
    }

    /// Reads the board again after the link came back (one read at a time: one that a drop
    /// interrupted or outlasted reads again), then applies the events that arrived meanwhile.
    private func reread() async {
        guard let board, reading == nil else { return }
        reading = Reading()
        var again: Bool
        repeat {
            let before = drops
            stale = false
            do {
                let manifest = try await connection.request("board.get", .object(["board": .string(boardID)]))
                install(try await whole(manifest["objects"]), on: board)
            } catch {
                // Down again: the next `online` reads it.
                stale = true
            }
            again = drops != before && state == .online
        } while again
        reading = nil
        release()
        drawAgainIfDue()
    }

    /// Applies a read of the whole board: what the read has, unless newer is here already
    /// (`learn`), the object has writes in flight, or this viewer deleted it since the read began;
    /// what the read lacks leaves, unless it has writes in flight or this viewer created it since.
    private func install(_ objects: [CanvasObject], on board: Board) {
        let read = reading ?? Reading()
        let present = Set(objects.map(\.id))
        for id in Set(board.objects.keys).union(known.keys).sorted()
        where !present.contains(id) && !read.created.contains(id) && !busy(id) && queues[id] == nil {
            known.removeValue(forKey: id)
            board.removeHost(id)
        }
        for object in objects where !read.deleted.contains(object.id) {
            learn(object)
            if !busy(object.id), let current = known[object.id] { board.applyHost(current) }
        }
    }

    /// The events that waited (`held`), in the order they came, once nothing holds them.
    private func release() {
        guard reading == nil, creating == 0, !held.isEmpty else { return }
        let waiting = held
        held = []
        for event in waiting { received(event) }
    }

    /// `board.get`'s objects whole: a note it cut at 400 characters is read with `object.get`.
    private func whole(_ objects: JSONValue?) async throws -> [CanvasObject] {
        var result: [CanvasObject] = []
        for value in objects?.array ?? [] {
            var object = try value.decode(CanvasObject.self)
            if object.type == .note, let markdown = object.props["markdown"]?.string, markdown.count == 401, markdown.hasSuffix("…"),
               let full = try? await connection.request("object.get", .object(["id": .string(object.id)]))["object"]?.decode(CanvasObject.self) {
                object = full
            }
            result.append(object)
        }
        return result
    }

    // MARK: The user's writes

    func send(_ write: RemoteWrite) {
        let key = queue(for: write.object)
        queues[key, default: []].append(write)
        if queues[key]?.count == 1 { Task { await pump(key) } }
    }

    /// The queue a write to `id` joins: its own, or a created object's while the writes queued
    /// behind its create (by its provisional id) are still going.
    private func queue(for id: ObjectID) -> ObjectID {
        if queues[id] != nil { return id }
        return hostIDs.first { $0.value == id && queues[$0.key] != nil }?.key ?? id
    }

    /// Sends `key`'s writes one at a time, then shows the host's version of what they touched.
    /// The first is based on the revision the user saw (`seen`); each later one, made on the
    /// preview of those before it, on the revision this viewer's write before it left, when the
    /// host answered that one exactly one revision on (nothing else changed the object between).
    /// Otherwise the base stays put, so an edit of the host's that crossed the user's (or one that
    /// made the host refuse an earlier write) stays a conflict for the writes after it.
    private func pump(_ key: ObjectID) async {
        var touched: Set<ObjectID> = [key]
        var base: Int?
        if case .update(_, let seen, _, _, _) = queues[key]?.first { base = seen }
        while let write = queues[key]?.first {
            let done = await perform(write, base: base)
            if let target = done.target { touched.insert(target) }
            if let rev = done.rev, base.map({ rev == $0 + 1 }) ?? true { base = rev }
            queues[key]?.removeFirst()
        }
        queues.removeValue(forKey: key)
        for id in touched.sorted() where !busy(id) { settle(id) }
    }

    /// The host's id for an object written here; nil for a provisional object whose create failed.
    /// A provisional object's later writes queue behind its create, so it is answered by then.
    private func target(_ id: ObjectID) -> ObjectID? {
        if let host = hostIDs[id] { return host }
        return failedCreates.contains(id) ? nil : id
    }

    /// Provisional ids whose create failed (nothing on the host has them).
    private var failedCreates: Set<ObjectID> = []

    /// Sends one write, a props write with `rev` `base`; returns the host id it touched and, when
    /// the host made the change, the object's revision after it.
    private func perform(_ write: RemoteWrite, base: Int?) async -> (target: ObjectID?, rev: Int?) {
        switch write {
        case .create(let provisional):
            var params: [String: JSONValue] = [
                "board": .string(boardID), "type": .string(provisional.type.rawValue), "props": provisional.props,
                "frame": RenderMath.json(provisional.frame),
            ]
            if let parent = provisional.parent { params["parent"] = .string(parent) }
            // Its object's event, ahead of the answer, waits for it (`creating`).
            creating += 1
            defer {
                creating -= 1
                release()
            }
            do {
                let object = try await request("object.create", params)
                hostIDs[provisional.id] = object.id
                reading?.created.insert(object.id)
                learn(object)
                board?.rekeyHost(provisional.id, as: object)
                return (object.id, object.rev)
            } catch {
                failedCreates.insert(provisional.id)
                notice("Not created on \(hostName): \(Self.reason(error))")
                return (nil, nil)
            }
        case .update(let id, _, let frame, _, let props):
            guard let target = target(id) else { return (nil, nil) }
            // The API sets no z: a restack isn't sent, and the host's version puts it back.
            guard frame != nil || props != nil else { return (target, nil) }
            var params: [String: JSONValue] = ["id": .string(target)]
            if let frame { params["frame"] = RenderMath.json(frame) }
            if let props {
                params["props"] = props
                if let base { params["rev"] = .number(Double(base)) }
            }
            do {
                let object = try await request("object.update", params)
                learn(object)
                return (target, object.rev)
            } catch {
                await refused(target, error, doing: "changed")
                return (target, nil)
            }
        case .delete(let id):
            guard let target = target(id) else { return (nil, nil) }
            do {
                _ = try await connection.request("object.delete", .object(["id": .string(target)]))
                known.removeValue(forKey: target)
                reading?.deleted.insert(target)
            } catch {
                await refused(target, error, doing: "deleted")
            }
            return (target, nil)
        }
    }

    private func request(_ method: String, _ params: [String: JSONValue]) async throws -> CanvasObject {
        let result = try await connection.request(method, .object(params))
        guard let object = try result["object"]?.decode(CanvasObject.self) else {
            throw EaslConnection.Failure("unavailable", "\(method) answered without an object")
        }
        return object
    }

    /// The host refused a write: what it has now is read again where it changed (`conflict`) or
    /// is gone (`not_found`), and the user is told.
    private func refused(_ id: ObjectID, _ error: Error, doing verb: String) async {
        let code = (error as? EaslConnection.Failure)?.code
        let name = board?.objects[id].map(ActivityLog.describe) ?? id
        switch code {
        case "conflict":
            if let current = try? await request("object.get", ["id": .string(id)]) { learn(current) }
            notice("Not \(verb): \(name) changed on \(hostName) meanwhile")
        case "not_found":
            known.removeValue(forKey: id)
            reading?.deleted.insert(id)
            notice("Not \(verb): \(name) is gone from \(hostName)")
        case "unavailable" where state != .online:
            notice("Not \(verb): \(hostName) is offline")
        default:
            notice("Not \(verb) on \(hostName): \(Self.reason(error))")
        }
    }

    private func notice(_ text: String) {
        onNotice?(text)
    }

    /// What a failure says to the user: the host's message, else the error.
    public static func reason(_ error: Error) -> String {
        (error as? EaslConnection.Failure)?.message ?? (error as? ApiRouter.Failure)?.message ?? String(describing: error)
    }

    // MARK: Prompts and renders

    /// The composer's send to one terminal on the host: `agent.prompt` with `composer` (the host
    /// sends it as its own composer would). Throws `ApiRouter.Failure` with the host's reason.
    public func prompt(_ text: String, to terminal: ObjectID, mentions: [Mention], answer: Bool) async throws {
        var params: [String: JSONValue] = ["target": .string(terminal), "text": .string(text), "composer": .bool(true)]
        if answer {
            params["answer"] = .bool(true)
        } else {
            let attached = Self.promptMentions(mentions.map(\.target))
            if !attached.isEmpty { params["mentions"] = .array(attached) }
        }
        do {
            _ = try await connection.request("agent.prompt", .object(params), timeout: .seconds(30))
        } catch let failure as EaslConnection.Failure {
            throw ApiRouter.Failure(failure.code, failure.message)
        }
    }

    /// What `agent.prompt` can attach of the composer's mentions (`PromptMention`): an object, a
    /// code tile's lines, an image tile's pixel; any other target as the objects it is on.
    static func promptMentions(_ targets: [MentionTarget]) -> [JSONValue] {
        var result: [JSONValue] = []
        func add(_ value: JSONValue) { if !result.contains(value) { result.append(value) } }
        for target in targets {
            switch target {
            case .code(let object, _, let lines, _, _, _, _):
                add(.object(["object": .string(object), "lines": .object(["start": .number(Double(lines.start)), "end": .number(Double(lines.end))])]))
            case .image(let object, _, let x, let y):
                add(.object(["object": .string(object), "point": .object(["x": .number(Double(x)), "y": .number(Double(y))])]))
            default:
                for object in target.objectIDs { add(.object(["object": .string(object)])) }
            }
        }
        return result
    }

    /// An object as the host draws it (`view.render` `inline`): its whole frame, title bar on top,
    /// cut from the host's picture where the host had the object when it drew it (a move here
    /// meanwhile doesn't change what the image shows), top-left origin.
    public struct Render {
        public var image: CGImage
        /// Pixels per point the host drew at.
        public var scale: Double
    }

    /// Asks the host for `id`'s drawing at `scale`; it goes with the other waiting asks nearest
    /// the view (`RenderQueue`). `answer` is called once, on the main actor, unless the ticket is
    /// taken back first: the drawing, or why not (offline, the host's refusal, a picture this Mac
    /// can't read).
    public func render(_ id: ObjectID, scale: Double, answer: @escaping @MainActor (Result<Render, Error>) -> Void) -> RenderTicket {
        queue.add(id, scale: scale, answer: answer)
    }
}
