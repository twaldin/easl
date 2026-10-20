import Foundation

/// A user's write to a remote board, already applied there as a preview, for its host.
/// `step` identifies a recorded viewer gesture; nil writes never enter the host's undo history.
public enum RemoteWrite: Equatable, Sendable {
    /// A provisional object (its id is this board's own until the host answers with its id).
    case create(CanvasObject, step: Int?)
    /// `seen`: the object's revision as the board showed it when the user made the change.
    case update(ObjectID, step: Int?, seen: Int?, frame: Frame?, z: Double?, props: JSONValue?, expires: ObjectExpiryPatch = .unchanged)
    case delete(ObjectID, step: Int?)
    /// A browser tile's page as this Mac runs it (`Board.reportPage`): the one write-back of the
    /// app's own that a remote board sends to its host.
    case page(ObjectID, BrowserReport)
    /// A look the user took. Follows that object's writes and records no history step.
    case seen(ObjectID, rev: Int?, marker: SeenMarker?)
    /// The object written, by its id on this board.
    var object: ObjectID {
        switch self {
        case .create(let object, _): object.id
        case .update(let id, _, _, _, _, _, _), .delete(let id, _), .page(let id, _), .seen(let id, _, _): id
        }
    }
}

/// What a browser tile's drawing Mac reports of its page (`browser.report`): an address it
/// committed, credited to whoever drove the page there, or the page's own title (nil: none).
public enum BrowserReport: Equatable, Sendable {
    case url(String, by: ActivityActor)
    case title(String?)

    func params(_ id: ObjectID) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["id": .string(id)]
        switch self {
        case .url(let url, let actor):
            params["url"] = .string(url)
            switch actor {
            case .agent(let tile): params["caller"] = .string(tile)
            case .user: params["actor"] = .string("user")
            case .system: params["actor"] = .string("system")
            }
        case .title(let title):
            params["pageTitle"] = title.map(JSONValue.string) ?? .null
        }
        return params
    }
}

/// Where a remote board (`Board.isRemote`) sends the user's writes.
@MainActor
protocol BoardHost: AnyObject {
    func send(_ write: RemoteWrite)
    /// Why the host can't keep this viewer's history (its undo and restacking): an easl older than
    /// this app's API there. Nil when it can, or while that isn't known yet.
    var historyUnavailable: String? { get }
}

/// A board another easl hosts, mirrored over that easl's API (docs/design.md "Client mode").
///
/// `load` subscribes to the board's events, then reads it (`board.get`, and `object.get` for the
/// HTML and notes it cut), into a `Board` marked remote that nothing stores. The host's events replace
/// objects with the host's (`rev` included) unless a newer host revision is already here. The
/// user's writes on that board are previews sent here (`send`): one at a time per object, a props
/// write carrying the host `rev` the user's change was based on; while an object has writes in
/// flight its events wait, and once the last is answered the board shows the newest host version,
/// so a failed write puts the host's object back (and says why in `onNotice`). A created object
/// takes the host's id when its create is answered (`Board.rekeyHost`). Back online after a drop,
/// the board is read again and the difference applied; the host's events wait while it is read
/// and follow it, so none is undone by the read. Once both links are back, `onRedraw` refreshes
/// diagram graphs. On an easld host the board's window answers easld's delegated calls,
/// attached as its client on the board's link (`serve`).
@MainActor
public final class BoardMirror: BoardHost {
    /// The host as the user knows it, for titles and notices.
    public let hostName: String
    public let boardID: BoardID
    /// This window's id. Undo and composer returns share it.
    public let viewer = IDs.make("vw") as String
    /// The canonical owner of sessions and events; `boardID` remains the requested window address.
    public private(set) var sessionBoardID: BoardID
    var hostSpeaksQueue: Bool { (connection.schemaVersion ?? 0) >= 2 }
    public private(set) var mergedBoards: [BoardID] = []
    /// Subscriptions, reads, writes and prompts.
    public let connection: EaslConnection
    private let diagrams: EaslConnection
    /// Nil until `load` succeeded.
    public private(set) var board: Board?
    public enum Availability: Equatable, Sendable {
        case open, closed
    }
    public private(set) var availability: Availability = .open
    public var onAvailability: ((Availability) -> Void)?
    public var state: EaslConnection.State {
        refreshFailure != nil && linkState == .online ? .offline : linkState
    }
    private var linkState: EaslConnection.State = .connecting
    private var refreshFailure: String?
    /// The board's availability or refresh problem changed, after it loaded.
    public var onState: ((EaslConnection.State) -> Void)?
    /// Something to tell the user (a write the host refused, a create that failed).
    public var onNotice: ((String) -> Void)?
    public enum PromptDelivery: Equatable, Sendable {
        case checking, unknown, delivered, notDelivered
    }
    public struct PromptOutcomeUnknown: Error {}
    public var onPromptDelivery: ((String, ObjectID, PromptDelivery) -> Void)?
    /// Refresh diagram graphs after reconnect, including objects unchanged by the board read.
    public var onRedraw: (() -> Void)?
    /// This viewer as the board's easld's client (docs/design/next.md "The client protocol");
    /// nil until `serve`, and on an app server, which answers those calls itself.
    public private(set) var attachment: Attachment?
    /// The Macs attached to the board that run its browser tiles' pages (`client.list`, then each
    /// `client.changed`): attached as easld's clients serving the board and `browser.call`, one per
    /// machine identity, named as it attached, sorted by name. What a tile can be moved to draw on.
    /// Nil until heard after `serve`, and while the link is down; never stored.
    public private(set) var drawingMachineChoices: [DrawingMachine]?
    /// The machine identities of `drawingMachineChoices`.
    public var drawingMachines: Set<String>? { drawingMachineChoices.map { Set($0.map(\.id)) } }
    /// `drawingMachineChoices` changed: the tiles that say where their page runs say it again.
    public var onDrawingMachines: (() -> Void)?
    private var presenceHeard = 0

    /// A confirmed move belongs to this board incarnation and this browser assignment.
    public struct DrawingMove {
        fileprivate let board: Board
        fileprivate let generation: Int
        fileprivate let object: CanvasObject
        fileprivate let destination: DrawingMachine
        public let sourceOffline: Bool
    }

    public func drawingMove(_ id: ObjectID, to destination: DrawingMachine) throws -> DrawingMove {
        guard !ended, availability == .open, let board, let object = board.objects[id], object.type == .browser else {
            throw ApiRouter.Failure("unavailable", "This browser's board is no longer open.")
        }
        guard let machines = drawingMachines, machines.contains(destination.id) else {
            throw ApiRouter.Failure("unavailable", "\(destination.host) is no longer attached to this board.")
        }
        let sourceOffline = DrawingMachine(object.props).map { !machines.contains($0.id) } ?? true
        return DrawingMove(board: board, generation: generation, object: object, destination: destination, sourceOffline: sourceOffline)
    }

    /// Reads the drawing Mac once, then moves the page and its explicit URL in one normal write.
    public func moveDrawing(_ move: DrawingMove) async throws {
        func current() throws -> CanvasObject {
            try requireCurrent(move.generation)
            guard availability == .open, board === move.board,
                  let object = board?.objects[move.object.id], object.type == .browser,
                  object.createdAt == move.object.createdAt, object.rev == move.object.rev,
                  DrawingMachine(object.props)?.id == DrawingMachine(move.object.props)?.id else {
                throw ApiRouter.Failure("conflict", "The browser changed while this move was being confirmed.")
            }
            guard drawingMachines?.contains(move.destination.id) == true else {
                throw ApiRouter.Failure("unavailable", "\(move.destination.host) is no longer attached to this board.")
            }
            return object
        }
        let object = try current()
        let source = DrawingMachine(object.props)
        let sourceOnline = source.map { drawingMachines?.contains($0.id) == true } ?? false
        let url: String
        if sourceOnline {
            let result: JSONValue
            do {
                result = try await connection.request("browser.call", .object([
                    "id": .string(object.id), "method": .string("browser.url.get"), "params": .object([:]),
                ]))
            } catch {
                _ = try current()
                if let source, drawingMachines?.contains(source.id) == false {
                    throw ApiRouter.Failure("unavailable", "The drawing Mac went offline. Choose Move again to reload the last saved URL.")
                }
                throw ApiRouter.Failure("unavailable", "Could not read the page's current URL. \(Self.reason(error))")
            }
            _ = try current()
            guard let liveURL = result["url"]?.string, !liveURL.isEmpty else {
                throw ApiRouter.Failure("unavailable", "The drawing Mac returned no current URL.")
            }
            url = liveURL
        } else {
            guard move.sourceOffline else {
                throw ApiRouter.Failure("unavailable", "The drawing Mac went offline. Choose Move again to reload the last saved URL.")
            }
            guard let savedURL = object.props["url"]?.string else {
                throw ApiRouter.Failure("unavailable", "This browser has no saved URL to reload.")
            }
            url = savedURL
        }
        _ = try current()
        _ = try move.board.update(object.id, props: .object([
            "url": .string(url), "drawingMachine": move.destination.json,
        ]))
    }

    /// Where this viewer's `client.attach` stands on the board's link.
    public enum Attachment: Equatable, Sendable {
        /// The link isn't online: the next one attaches.
        case waiting
        /// Sent on this link and not answered yet.
        case attaching
        /// easld's name for this viewer and the schema version easld speaks.
        case attached(client: String, version: Int)
        /// easld refused it on this link (one without the client protocol, a newer schema version,
        /// a board it closed): the board works as it did before, and only the next link asks again.
        case refused(String)
    }

    /// The board's delegated calls, answered from its window; nil until `serve`.
    private var calls: DelegatedCalls?
    private var identity: ClientIdentity?
    private var receivedEventSequence: UInt64 = 0
    private var awaitingEvents: [(through: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    /// The latest attach's number: an older one's answer changes nothing.
    private var attaches = 0
    /// The user focused the board while an attach was out: once it is accepted, attach again.
    private var refocused = false

    /// The host's objects as last heard (a reply, an event, a read), by host id.
    private var known: [ObjectID: CanvasObject] = [:]
    /// Writes not answered yet, by the written object's id here, oldest first (the first is in flight).
    private var queues: [ObjectID: [RemoteWrite]] = [:]
    private var pumps: [ObjectID: Task<Void, Never>] = [:]
    /// A provisional object's id here → the host's id for it, once its create is answered.
    private var hostIDs: [ObjectID: ObjectID] = [:]
    private var pendingAttention: [ObjectID: SeenMarker] = [:]

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
    private var deferredObjects: Set<ObjectID> = []
    /// The host's events that arrived while the board was being read or a create was in flight,
    /// applied in order once neither is (`release`), so nothing they say is undone or doubled.
    private var held: [EaslConnection.Event] = []
    private var redrawDue = false
    private var diagramsState: EaslConnection.State = .connecting
    /// The link went down after the board loaded: read it again once back online.
    private var stale = false
    /// How many times the link went down after the board loaded (a read that spans one reads again).
    private var drops = 0
    private var listeners: [Task<Void, Never>] = []
    private var generation = 0
    private var ended = false
    private var lastHostAvailability: Availability = .open
    private var lifecycleBoards: Set<BoardID> = []
    private var activitySupported = true
    private var pendingActivity: Set<ObjectID?> = []
    private var activityTask: Task<Void, Never>?

    public init(hostName: String, board: BoardID, connection: EaslConnection, diagrams: EaslConnection) {
        self.hostName = hostName
        boardID = board
        sessionBoardID = board
        self.connection = connection
        self.diagrams = diagrams
    }

    /// Subscribes, reads the board and returns it; throws the host's failure (`not_found`: no such
    /// board there; `unavailable`: the host can't be reached).
    public func load() async throws -> Board {
        guard !ended else { throw ApiRouter.Failure("unavailable", "this board's window closed") }
        let generation = generation
        connection.subscribe(board: boardID)
        listen()
        let manifest: JSONValue
        let objects: [CanvasObject]
        do {
            manifest = try await self.manifest()
            try requireCurrent(generation)
            identify(manifest)
            guard manifest["closed"]?.bool != true else {
                throw ApiRouter.Failure("not_found", "board \(boardID) is closed on \(hostName)")
            }
            objects = try await whole(manifest["objects"], generation: generation)
        } catch let failure as EaslConnection.Failure {
            throw ApiRouter.Failure(failure.code, failure.message)
        }
        try requireCurrent(generation)
        lastHostAvailability = .open
        let board = Board(remote: boardID, root: URL(fileURLWithPath: manifest["root"]?.string ?? "/"), host: self)
        self.board = board
        mergedBoards = manifest["merged"]?.array?.compactMap(\.string).filter(ApiRouter.isBoardID) ?? []
        install(objects, on: board)
        installAttention(manifest["attention"], on: board)
        installComposerReceipts(manifest["composerReceipts"])
        reading = nil
        redrawDue = diagramsState == .offline
        release()
        registerActivity()
        return board
    }
    private func manifest() async throws -> JSONValue {
        await handshake()
        var params: [String: JSONValue] = ["board": .string(boardID)]
        if hostSpeaksQueue { params["viewer"] = .string(viewer) }
        return try await connection.request("board.get", .object(params))
    }


    private func identify(_ manifest: JSONValue) {
        guard let current = manifest["board"]?.string, ApiRouter.isBoardID(current) else { return }
        sessionBoardID = current
        if current != boardID, lifecycleBoards.insert(current).inserted {
            connection.subscribe(board: current, events: ["board.closed", "board.opened"])
        }
    }

    /// Ends both links and this viewer's attachment; the board stays as last seen.
    public func close() {
        guard !ended else { return }
        ended = true
        cancelActivity()
        invalidate()
        for task in listeners { task.cancel() }
        listeners = []
        calls = nil
        attachment = nil
        identity = nil
        replays.stopPromptReconciliation()
        connection.serve(nil)
        connection.close()
        diagrams.close()
    }

    private func listen() {
        let events = connection.events(), states = connection.states(), diagramStates = diagrams.states()
        listeners.append(Task { @MainActor [weak self] in
            for await event in events { self?.received(event) }
        })
        listeners.append(Task { @MainActor [weak self] in
            for await state in states { self?.changed(state) }
        })
        listeners.append(Task { @MainActor [weak self] in
            for await state in diagramStates { self?.diagramsChanged(state) }
        })
    }

    private func changed(_ state: EaslConnection.State) {
        guard !ended else { return }
        guard state != linkState else { return }
        let previous = self.state
        linkState = state
        if state != .online { refreshFailure = nil }
        if state == .online { activitySupported = true }
        replays.promptConnectionChanged(state)
        guard board != nil else { return }
        if state != .online {
            cancelActivity()
            failAwaitingEvents(ApiRouter.Failure("unavailable", "\(hostName) disconnected before applying the browser target"))
            stale = true
            drops += 1
            redrawDue = true
        }
        if calls != nil {
            if state == .online {
                if !stale {
                    attach()
                    listClients()
                }
            } else {
                attaches += 1
                refocused = false
                attachment = .waiting
                setDrawingMachines(nil)
            }
        }
        if self.state != previous { onState?(self.state) }
        if state == .online, stale { Task { await reread() } }
    }

    private func diagramsChanged(_ state: EaslConnection.State) {
        guard !ended else { return }
        guard state != diagramsState else { return }
        diagramsState = state
        if state == .offline { redrawDue = true }
        drawAgainIfDue()
    }

    private func drawAgainIfDue() {
        guard !ended, availability == .open, redrawDue, board != nil, reading == nil, !stale, state == .online, diagramsState == .online else { return }
        redrawDue = false
        onRedraw?()
    }

    /// Why the board isn't current: a failed refresh, else ssh's reason.
    public var problem: String? { refreshFailure ?? connection.problem }

    /// Tries the host again now (the user started easl there).
    public func reconnect() {
        guard !ended else { return }
        if linkState == .online, stale {
            Task { await reread() }
        } else {
            connection.reconnect()
        }
        diagrams.reconnect()
    }

    // MARK: The client protocol

    /// Answers the board's delegated calls from `window` (`DelegatedCalls`) and attaches to the
    /// board's easld as its client: now if the link is online, then once on each link after, and
    /// again when the user focuses the board (`userFocused`). Only for an easld host (an app server
    /// answers those calls itself), once the board is loaded and its window shows it.
    public func serve(_ window: ViewerWindow, as identity: ClientIdentity) {
        guard !ended, let board else { return }
        let calls = DelegatedCalls(board: board, window: window)
        self.calls = calls
        self.identity = identity
        connection.serve { [weak self] call in
            guard let self else {
                return .failure(EaslConnection.Failure("unavailable", "\(call.method): this board's window closed"))
            }
            return await self.answer(call)
        }
        if linkState == .online, availability == .open, reading == nil {
            attach()
            listClients()
        } else {
            attachment = .waiting
        }
    }

    /// The board's incarnation while its window answers easld's calls for it; nil once the board
    /// closed or the window let it go. A browser stream opened for one of those calls lasts only
    /// while this stays the same, so a board closed and opened again on the host ends it.
    public var serving: Int? { !ended && availability == .open && calls != nil ? generation : nil }

    private func answer(_ call: EaslConnection.Call) async -> Result<JSONValue, EaslConnection.Failure> {
        guard !ended, availability == .open, let calls else {
            return .failure(EaslConnection.Failure("unavailable", "board \(boardID) is closed"))
        }
        let generation = generation
        do {
            if call.method == "browser.call" || call.method == "surface.stream" || (call.method == "object.reload" && call.params["_diagram"] == nil) {
                try await admit(through: call.eventsThrough)
            }
            try requireCurrent(generation)
            let result = await calls.answer(call)
            try requireCurrent(generation)
            return result
        } catch {
            let failure = ApiRouter.failure(for: error)
            return .failure(EaslConnection.Failure(failure.code, failure.message))
        }
    }

    /// Apply the events preceding the call, not an unseen creation that may already be deleted.
    private func admit(through sequence: UInt64) async throws {
        guard !ended, availability == .open else {
            throw ApiRouter.Failure("unavailable", "board \(boardID) is closed")
        }
        guard linkState == .online, calls != nil else {
            throw ApiRouter.Failure("unavailable", "\(hostName) is not connected")
        }
        if !admitted(through: sequence) {
            try await withCheckedThrowingContinuation {
                awaitingEvents.append((sequence, $0))
            }
        }
        guard !ended, availability == .open, linkState == .online, calls != nil else {
            throw ApiRouter.Failure("unavailable", "\(hostName) is not connected")
        }
        guard !stale else {
            throw ApiRouter.Failure("unavailable", "\(hostName) has not refreshed this board")
        }
    }

    private func admitted(through sequence: UInt64) -> Bool {
        reading == nil && deferredObjects.isEmpty && receivedEventSequence >= sequence
            && !held.contains { $0.sequence <= sequence }
    }

    private func releaseAdmissions() {
        awaitingEvents.removeAll { waiting in
            guard admitted(through: waiting.through) else { return false }
            waiting.continuation.resume()
            return true
        }
    }

    private func failAwaitingEvents(_ failure: ApiRouter.Failure) {
        for waiting in awaitingEvents { waiting.continuation.resume(throwing: failure) }
        awaitingEvents.removeAll(keepingCapacity: true)
    }


    /// The user is looking at this board (its window became key): an accepted attach goes again
    /// naming it, one still out goes again once it is accepted. A refused link asks nothing.
    public func userFocused() {
        guard !ended, availability == .open else { return }
        switch attachment {
        case .attached?: attach(focused: true)
        case .attaching?: refocused = true
        default: break
        }
    }

    /// Called only for viewer input, including keys sent through a terminal's SSH attachment.
    public func userInput(terminal: ObjectID? = nil) {
        guard !ended, availability == .open, connection.state == .online, activitySupported else { return }
        if let terminal, board?.objects[terminal]?.type != .terminal { return }
        pendingActivity.insert(terminal)
        guard activityTask == nil else { return }
        activityTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, !self.pendingActivity.isEmpty {
                let pending = self.pendingActivity
                self.pendingActivity.removeAll(keepingCapacity: true)
                for terminal in pending {
                    await self.reportActivity(terminal: terminal, input: true)
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            self?.activityTask = nil
        }
    }

    private func registerActivity() {
        Task { @MainActor [weak self] in
            guard let self, self.board != nil else { return }
            await self.reportActivity(terminal: nil, input: false)
        }
    }

    private func reportActivity(terminal: ObjectID?, input: Bool) async {
        guard !ended, availability == .open, connection.state == .online, activitySupported else { return }
        var params: [String: JSONValue] = ["board": .string(sessionBoardID), "input": .bool(input)]
        if let terminal { params["terminal"] = .string(terminal) }
        let before = drops
        do {
            _ = try await connection.request("viewer.activity", .object(params))
        } catch let failure as EaslConnection.Failure where failure.code == "unsupported" || failure.message == "unknown method viewer.activity" {
            guard drops == before else { return }
            activitySupported = false
            pendingActivity.removeAll()
        } catch {
            // Optional reports must never interrupt editing or terminal input on an older host.
        }
    }

    private func cancelActivity() {
        activityTask?.cancel()
        activityTask = nil
        pendingActivity.removeAll(keepingCapacity: true)
    }

    /// `client.attach` on the board's link, preserving a focus event even if the user has
    /// already moved to another window while the previous attach was outstanding.
    private func attach(focused: Bool = false) {
        guard !ended, availability == .open, linkState == .online, reading == nil, let calls, let identity else { return }
        attaches += 1
        refocused = false
        let number = attaches
        attachment = .attaching
        var fields: [String: JSONValue] = [
            "version": .number(Double(ApiParams.schemaVersion)), "schema": .string(ApiParams.schemaHash),
            "host": .string(identity.host), "serves": .array(DelegatedCalls.served.map(JSONValue.string)),
            "boards": .array([.string(boardID)]),
        ]
        if let app = identity.app { fields["app"] = .string(app) }
        if let id = identity.id { fields["identity"] = .string(id) }
        if focused || calls.window.focused() { fields["focused"] = .string(boardID) }
        let params = JSONValue.object(fields)
        Task {
            do {
                let reply = try await connection.request("client.attach", params)
                guard number == attaches, attachment == .attaching else { return }
                let client = reply["client"]?.string ?? "", version = reply["version"]?.int ?? ApiParams.schemaVersion
                attachment = .attached(client: client, version: version)
                if refocused { attach(focused: true) }
            } catch {
                // A link that dropped refused nothing (the next one attaches); nor did a closed one.
                guard number == attaches, attachment == .attaching, connection.state == .online else { return }
                let reason = Self.reason(error)
                attachment = .refused(reason)
                let code = (error as? EaslConnection.Failure)?.code ?? "unavailable"
                NSLog("easl: %@ refused this viewer as a client (%@)", hostName, code)
            }
        }
    }

    private func listClients() {
        guard !ended, availability == .open, linkState == .online, calls != nil else { return }
        let heard = presenceHeard, drop = drops, generation = generation
        Task {
            guard let reply = try? await connection.request("client.list") else { return }
            guard !ended, generation == self.generation, availability == .open,
                  heard == presenceHeard, drop == drops, linkState == .online, calls != nil else { return }
            setDrawingMachines(drawingMachines(in: reply["clients"]))
        }
    }

    private func clientsChanged(_ event: EaslConnection.Event) {
        guard !ended, availability == .open, linkState == .online, calls != nil,
              event.board == nil || event.board == sessionBoardID || event.board == boardID else { return }
        presenceHeard += 1
        setDrawingMachines(drawingMachines(in: event.data["clients"]))
    }

    private func drawingMachines(in clients: JSONValue?) -> [DrawingMachine] {
        let boards: Set<BoardID> = [boardID, sessionBoardID]
        var seen: Set<String> = []
        return (clients?.array ?? []).compactMap { entry -> DrawingMachine? in
            guard let identity = entry["identity"]?.string, entry["serves"]?.array?.contains(.string("browser.call")) == true,
                  entry["boards"]?.array?.contains(where: { $0.string.map { boards.contains($0) } == true }) == true else { return nil }
            return DrawingMachine(id: identity, host: entry["host"]?.string ?? identity)
        }
        .sorted { ($0.host, $0.id) < ($1.host, $1.id) }
        .filter { seen.insert($0.id).inserted }
    }

    private func setDrawingMachines(_ machines: [DrawingMachine]?) {
        guard machines != drawingMachineChoices else { return }
        drawingMachineChoices = machines
        onDrawingMachines?()
    }

    // MARK: The host's changes

    private func received(_ event: EaslConnection.Event) {
        guard !ended else { return }
        receivedEventSequence = max(receivedEventSequence, event.sequence)
        defer { releaseAdmissions() }
        let matches = event.board == nil || event.board == sessionBoardID || event.board == boardID
        if matches, event.name == "attention.changed", let id = event.data["id"]?.string {
            for local in pendingAttention.keys where local == id || hostIDs[local] == id {
                pendingAttention.removeValue(forKey: local)
            }
        }
        if matches, event.name == "composer.returned" || event.name == "composer.submitted" {
            applyComposerReceipt(event.data, event: event.name)
            return
        }
        if matches, event.name == "board.closed" {
            guard lastHostAvailability != .closed else { return }
            markClosed()
            return
        }
        if matches, event.name == "board.opened" {
            guard lastHostAvailability != .open else { return }
            lastHostAvailability = .open
            invalidate()
            stale = true
            redrawDue = true
            Task { await reread() }
            return
        }
        if event.name == "client.changed" { return clientsChanged(event) }
        if reading != nil || creating > 0 { return held.append(event) }
        guard availability == .open else { return }
        applyHostEvent(event)
    }

    private func applyHostEvent(_ event: EaslConnection.Event) {
        guard event.board == nil || event.board == sessionBoardID else { return }
        switch event.name {
        case "object.created", "object.updated":
            guard let object = try? event.data.decode(CanvasObject.self) else { return }
            replayEvents?.insert(object.id)
            hostChanged(object)
        case "object.deleted":
            guard let id = event.data["id"]?.string else { return }
            replayEvents?.insert(id)
            hostDeleted(id)
        case "attention.changed":
            guard let id = event.data["id"]?.string else { return }
            let marker: Attention?
            if event.data["active"]?.bool == true, let stamp = event.data["raisedAt"]?.string, !stamp.isEmpty {
                marker = Attention(object: id, message: event.data["message"]?.string, raisedBy: event.data["raisedBy"]?.string, raisedAt: Date(), stamp: stamp)
            } else if event.data["active"]?.bool == true {
                marker = Attention(object: id, message: event.data["message"]?.string, raisedBy: event.data["raisedBy"]?.string, raisedAt: Date())
            } else {
                marker = nil
            }
            board?.applyHostAttention(marker, on: id)
        default:
            break
        }
    }

    private func invalidate() {
        cancelActivity()
        let written = Array(queues.keys) + replays.discardWrites().map(\.object)
        let touched = Set(written).union(written.compactMap { hostIDs[$0] })
        generation += 1
        failAwaitingEvents(ApiRouter.Failure("unavailable", "board \(boardID) closed during the request"))
        setDrawingMachines(nil)
        attaches += 1
        refocused = false
        if calls != nil { attachment = .waiting }
        for task in pumps.values { task.cancel() }
        pumps = [:]
        queues = [:]
        pendingAttention.removeAll()
        board?.seenForwarded.removeAll()
        hostIDs = [:]
        failedCreates = []
        creating = 0
        reading = nil
        held = []
        deferredObjects.removeAll(keepingCapacity: true)
        for id in touched.sorted() { settle(id) }
    }

    private func markClosed() {
        let pending = availability == .open ? held : []
        lastHostAvailability = .closed
        let previous = state
        invalidate()
        for event in pending { applyHostEvent(event) }
        stale = true
        redrawDue = true
        refreshFailure = nil
        let changed = availability != .closed
        availability = .closed
        if changed { onAvailability?(.closed) }
        if state != previous { onState?(state) }
    }

    private func requireCurrent(_ generation: Int) throws {
        guard !ended, generation == self.generation else {
            throw ApiRouter.Failure("unavailable", "board \(boardID) closed during the request")
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

    private func busy(_ id: ObjectID) -> Bool {
        queues.contains { key, writes in !writes.isEmpty && (key == id || hostIDs[key] == id) }
            || replays.containsWrite { $0.object == id || hostIDs[$0.object] == id }
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
        guard !ended, let board, reading == nil, linkState == .online else { return }
        let generation = generation
        reading = Reading()
        var again: Bool
        repeat {
            let before = drops
            stale = false
            var receivedManifest = false
            do {
                let manifest = try await self.manifest()
                try requireCurrent(generation)
                identify(manifest)
                if manifest["closed"]?.bool == true {
                    markClosed()
                    return
                }
                receivedManifest = true
                lastHostAvailability = .open
                let objects = try await whole(manifest["objects"], generation: generation)
                try requireCurrent(generation)
                mergedBoards = manifest["merged"]?.array?.compactMap(\.string).filter(ApiRouter.isBoardID) ?? []
                install(objects, on: board)
                installAttention(manifest["attention"], on: board)
                installComposerReceipts(manifest["composerReceipts"])
                setRefreshFailure(nil)
                if availability != .open {
                    let previous = state
                    availability = .open
                    onAvailability?(.open)
                    if state != previous { onState?(state) }
                }
            } catch {
                guard !ended, generation == self.generation else { return }
                if !receivedManifest, (error as? EaslConnection.Failure)?.code == "not_found" {
                    markClosed()
                    return
                }
                setRefreshFailure("Couldn't refresh \(hostName): \(Self.reason(error))")
                stale = true
                if receivedManifest, availability == .closed {
                    availability = .open
                    onAvailability?(.open)
                }
            }
            again = drops != before && linkState == .online
        } while again
        reading = nil
        release()
        if attachment == .waiting {
            attach()
            listClients()
        }
        if !stale, availability == .open { registerActivity() }
        drawAgainIfDue()
    }

    private func setRefreshFailure(_ failure: String?) {
        guard refreshFailure != failure else { return }
        refreshFailure = failure
        onState?(state)
    }

    /// Applies a read of the whole board: what the read has, unless newer is here already
    /// (`learn`), the object has writes in flight, or this viewer deleted it since the read began;
    /// what the read lacks leaves, unless it has writes in flight or this viewer created it since.
    private func install(_ objects: [CanvasObject], on board: Board) {
        board.seenForwarded.removeAll()
        let read = reading ?? Reading()
        let present = Set(objects.map(\.id))
        for id in Set(board.objects.keys).union(known.keys).sorted()
        where !present.contains(id) && !read.created.contains(id) && !busy(id) && queues[id] == nil {
            known.removeValue(forKey: id)
            board.removeHost(id)
        }
        for object in objects where !read.deleted.contains(object.id) {
            learn(object)
            // A reread can learn a create before its answer. Keep the provisional view until rekey.
            if creating > 0, board.objects[object.id] == nil {
                deferredObjects.insert(object.id)
            } else if !busy(object.id), let current = known[object.id] {
                board.applyHost(current)
            }
        }
    }

    /// The events that waited (`held`), in the order they came, once nothing holds them.
    private func release() {
        defer { releaseAdmissions() }
        guard reading == nil, creating == 0 else { return }
        for id in deferredObjects.sorted() where !busy(id) {
            if let object = known[id] { board?.applyHost(object) }
        }
        deferredObjects.removeAll(keepingCapacity: true)
        guard !held.isEmpty else { return }
        let waiting = held
        held = []
        for event in waiting { received(event) }
    }

    /// `board.get` summarizes every HTML page and cuts long notes; read their content whole.
    private func whole(_ objects: JSONValue?, generation: Int) async throws -> [CanvasObject] {
        var result: [CanvasObject] = []
        for value in objects?.array ?? [] {
            var object = try value.decode(CanvasObject.self)
            if object.type == .html {
                do {
                    let full = try await connection.request("object.get", .object(["id": .string(object.id)]))
                    try requireCurrent(generation)
                    guard let value = full["object"] else {
                        throw EaslConnection.Failure("unavailable", "the host returned no HTML object")
                    }
                    object = try value.decode(CanvasObject.self)
                } catch let failure as EaslConnection.Failure where failure.code == "not_found" {
                    try requireCurrent(generation)
                    continue
                }
            }
            if object.type == .note, let markdown = object.props["markdown"]?.string, markdown.count == 401, markdown.hasSuffix("…"),
               let full = try? await connection.request("object.get", .object(["id": .string(object.id)]))["object"]?.decode(CanvasObject.self) {
                object = full
            }
            try requireCurrent(generation)
            result.append(object)
        }
        return result
    }

    // MARK: The user's writes

    func send(_ write: RemoteWrite) {
        if case .seen(let id, _, let marker?) = write { pendingAttention[id] = marker }
        if !ended, availability == .open, replays.hold(write) { return }
        enqueue(write)
    }

    private func enqueue(_ write: RemoteWrite) {
        guard !ended, availability == .open else {
            if case .seen = write {
                discardSeen(write)
                return
            }
            settle(write.object)
            return
        }
        let key = queue(for: write.object)
        queues[key, default: []].append(write)
        if queues[key]?.count == 1 {
            let generation = generation
            pumps[key] = Task { await pump(key, generation: generation) }
        }
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
    private func pump(_ key: ObjectID, generation: Int) async {
        var touched: Set<ObjectID> = [key]
        var base: Int?
        while let write = queues[key]?.first {
            guard !ended, generation == self.generation, availability == .open else { return }
            if base == nil, case .update(_, _, let seen, _, _, _, _) = write { base = seen }
            let done = await perform(write, base: base, generation: generation)
            guard !ended, generation == self.generation else { return }
            if let target = done.target { touched.insert(target) }
            if let rev = done.rev, base.map({ rev == $0 + 1 }) ?? true { base = rev }
            queues[key]?.removeFirst()
        }
        queues.removeValue(forKey: key)
        pumps.removeValue(forKey: key)
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
    private func perform(_ write: RemoteWrite, base: Int?, generation: Int) async -> (target: ObjectID?, rev: Int?) {
        await handshake()
        guard !ended, generation == self.generation, availability == .open else { return (nil, nil) }
        switch write {
        case .create(let provisional, let step):
            var params: [String: JSONValue] = [
                "board": .string(boardID), "type": .string(provisional.type.rawValue), "props": provisional.props,
                "frame": RenderMath.json(provisional.frame),
            ]
            if let parent = provisional.parent { params["parent"] = .string(parent) }
            if let expires = provisional.expires { params["expires"] = .string(expires.stamp) }
            if provisional.type == .browser, case .agent(let tile) = provisional.createdBy { params["caller"] = .string(tile) }
            mark(&params, step: step)
            // Its object's event, ahead of the answer, waits for it (`creating`).
            creating += 1
            defer {
                if generation == self.generation {
                    creating -= 1
                    release()
                }
            }
            do {
                let object = try await request("object.create", params, generation: generation)
                hostIDs[provisional.id] = object.id
                reading?.created.insert(object.id)
                learn(object)
                board?.rekeyHost(provisional.id, as: object)
                return (object.id, object.rev)
            } catch {
                guard !ended, generation == self.generation else { return (nil, nil) }
                failedCreates.insert(provisional.id)
                notice("Not created on \(hostName): \(Self.reason(error))")
                return (nil, nil)
            }
        case .update(let id, let step, _, let frame, let z, let props, let expires):
            guard let target = target(id) else { return (nil, nil) }
            let z = hostSpeaksQueue ? z : nil
            guard frame != nil || z != nil || props != nil || expires != .unchanged else { return (target, nil) }
            var params: [String: JSONValue] = ["id": .string(target)]
            if let frame { params["frame"] = RenderMath.json(frame) }
            if let z { params["z"] = .number(z) }
            if let props {
                params["props"] = props
                if let base { params["rev"] = .number(Double(base)) }
            }
            if case .set(let deadline) = expires {
                params["expires"] = deadline.map { .string($0.stamp) } ?? .null
                if let base { params["rev"] = .number(Double(base)) }
            }
            mark(&params, step: step)
            do {
                let object = try await request("object.update", params, generation: generation)
                learn(object)
                return (target, object.rev)
            } catch {
                await refused(target, error, doing: "changed", generation: generation)
                return (target, nil)
            }
        case .delete(let id, let step):
            guard let target = target(id) else { return (nil, nil) }
            var params: [String: JSONValue] = ["id": .string(target)]
            mark(&params, step: step)
            do {
                _ = try await connection.request("object.delete", .object(params))
                try requireCurrent(generation)
                known.removeValue(forKey: target)
                reading?.deleted.insert(target)
            } catch {
                await refused(target, error, doing: "deleted", generation: generation)
            }
            return (target, nil)
        case .page(let id, let report):
            guard let target = target(id) else { return (nil, nil) }
            do {
                let object = try await request("browser.report", report.params(target), generation: generation)
                learn(object)
                return (target, object.rev)
            } catch {
                guard !ended, generation == self.generation else { return (nil, nil) }
                NSLog("easl: %@ took no page report for browser tile %@ (%@)", hostName, target, (error as? EaslConnection.Failure)?.code ?? "unavailable")
                return (target, nil)
            }
        case .seen(let id, let rev, let marker):
            guard hostSpeaksQueue, let target = target(id) else {
                discardSeen(write)
                return (nil, nil)
            }
            var params: [String: JSONValue] = ["id": .string(target)]
            if let rev { params["rev"] = .number(Double(rev)) }
            if let marker { params["marker"] = marker.json }
            do {
                let result = try await connection.request("view.seen", .object(params))
                try requireCurrent(generation)
                if pendingAttention[id] == marker { pendingAttention.removeValue(forKey: id) }
                if let object = try result["object"]?.decode(CanvasObject.self) {
                    learn(object)
                    return (target, object.rev)
                }
            } catch {
                guard !ended, generation == self.generation else { return (target, nil) }
                discardSeen(write, restoringMarker: (error as? EaslConnection.Failure)?.code != "not_found")
                if (error as? EaslConnection.Failure)?.code != "not_found" {
                    notice("Not acknowledged on \(hostName): \(Self.reason(error))")
                }
            }
            return (target, nil)
        }
    }
    private func discardSeen(_ write: RemoteWrite, restoringMarker: Bool = false) {
        guard case .seen(let id, let rev, let marker) = write else { return }
        if let rev, board?.seenForwarded[id] == rev { board?.seenForwarded.removeValue(forKey: id) }
        guard let marker, pendingAttention[id] == marker else { return }
        pendingAttention.removeValue(forKey: id)
        guard restoringMarker, let board, board.attention[id] == nil else { return }
        board.applyHostAttention(Attention(object: id, message: marker.message, raisedBy: marker.raisedBy, raisedAt: Date(), stamp: marker.raisedAt), on: id)
    }


    private func handshake() async {
        guard connection.state == .connecting else { return }
        for await state in connection.states() where state != .connecting { break }
    }

    private func request(_ method: String, _ params: [String: JSONValue], generation: Int) async throws -> CanvasObject {
        let result = try await connection.request(method, .object(params))
        try requireCurrent(generation)
        guard let object = try result["object"]?.decode(CanvasObject.self) else {
            throw EaslConnection.Failure("unavailable", "\(method) answered without an object")
        }
        return object
    }

    /// The host refused a write: what it has now is read again where it changed (`conflict`) or
    /// is gone (`not_found`), and the user is told.
    private func refused(_ id: ObjectID, _ error: Error, doing verb: String, generation: Int) async {
        guard !ended, generation == self.generation else { return }
        let code = (error as? EaslConnection.Failure)?.code
        let name = board?.objects[id].map(ActivityLog.describe) ?? id
        switch code {
        case "conflict":
            if let current = try? await request("object.get", ["id": .string(id)], generation: generation) { learn(current) }
            guard !ended, generation == self.generation else { return }
            notice("Not \(verb): \(name) changed on \(hostName) meanwhile")
        case "not_found":
            do {
                let manifest = try await self.manifest()
                try requireCurrent(generation)
                if manifest["closed"]?.bool == true {
                    markClosed()
                    return
                }
            } catch {
                guard !ended, generation == self.generation else { return }
                if (error as? EaslConnection.Failure)?.code == "not_found" {
                    markClosed()
                } else {
                    stale = true
                    notice("Not \(verb) on \(hostName): \(Self.reason(error))")
                }
                return
            }
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


    private let replays = RemoteReplayQueue()
    private var replayEvents: Set<ObjectID>?

    var historyUnavailable: String? {
        guard let version = connection.schemaVersion, version < 2 else { return nil }
        return "Undo and restacking on this board need a newer easl on \(hostName)"
    }

    private func mark(_ params: inout [String: JSONValue], step: Int?) {
        guard hostSpeaksQueue, let step else { return }
        params["viewer"] = .string(viewer)
        params["step"] = .number(Double(step))
    }

    /// ⌘Z (⇧⌘Z when `redo`): the board's latest step made before now. A step of the viewer's own
    /// (the tray's chips Hyper-V pasted) is undone here, online or not. A step that changed the
    /// board is the host's to revert (`board.undo`): it goes after every write made before it,
    /// writes made after it wait for its answer, and replays go one at a time. The local history
    /// then follows what the host did, by step id; offline or refused, it stays as it was. The
    /// task's value is the notice to show.
    @discardableResult
    public func undo(redo: Bool) -> Task<String?, Never> {
        replays.enqueue(on: board, redo: redo, hostName: hostName, perform: { step in
            await self.replay(step, redo: redo)
        }, release: { writes in
            for write in writes { self.enqueue(write) }
        })
    }

    private func replay(_ step: UndoHistory.Step, redo: Bool) async -> RemoteReplayQueue.Outcome {
        guard !ended, let board else { return .interrupted }
        let verb = redo ? "redo" : "undo"
        if !step.changesBoard, step.noteRecoveries.isEmpty {
            return .applied(ViewerReplay(step: step.id, pushed: true))
        }
        for pump in Array(pumps.values) { await pump.value }
        guard !ended, availability == .open, linkState == .online, !stale else { return .refused("Couldn't \(verb): \(hostName) is offline") }
        guard reading == nil else { return .refused("Couldn't \(verb) while \(hostName)'s board is read again") }
        if let recovery = step.noteRecoveries.first {
            guard let id = target(recovery.objectID), let current = known[id], current.type == .note else {
                return .refused("Couldn't \(verb): the note changed on \(hostName) since the text was saved")
            }
            let wanted = redo ? recovery.theirs : recovery.yours
            let text = current.props["markdown"]?.string ?? ""
            if text == wanted { return .applied(ViewerReplay(step: step.id, pushed: true)) }
            guard text == (redo ? recovery.yours : recovery.theirs) else {
                return .refused("Couldn't \(verb): the note changed on \(hostName) since the text was saved")
            }
            let generation = generation
            replayEvents = []
            defer { replayEvents = nil }
            do {
                let object = try await request("object.update", [
                    "id": .string(id), "rev": .number(Double(current.rev)),
                    "props": .object(["markdown": .string(wanted)]),
                ], generation: generation)
                if object.rev == current.rev + 1 { replays.rebase(id, from: current.rev, to: object.rev, target: target) }
                if replayEvents?.contains(id) != true { learn(object) }
                if !busy(id) { settle(id) }
                return .applied(ViewerReplay(step: step.id, pushed: true))
            } catch {
                guard !ended, generation == self.generation else { return .interrupted }
                if (error as? EaslConnection.Failure)?.code == "conflict",
                   let object = try? await request("object.get", ["id": .string(id)], generation: generation) {
                    learn(object)
                }
                if (error as? EaslConnection.Failure)?.code == "not_found" { known.removeValue(forKey: id) }
                if !busy(id) { settle(id) }
                return .refused("Couldn't \(verb) on \(hostName): \(Self.reason(error))")
            }
        }
        guard hostSpeaksQueue else { return .refused("\(redo ? "Redo" : "Undo") on this board needs a newer easl on \(hostName)") }
        let generation = generation
        let candidates = redo ? [step] : board.history.undoSteps.filter { $0.id <= step.id }
        var revisions: [ObjectID: Int] = [:]
        for candidate in candidates {
            for id in ViewerHistory.touched(candidate.changes) {
                if let id = target(id), let object = known[id] { revisions[id] = object.rev }
            }
        }
        replayEvents = []
        defer { replayEvents = nil }
        let reply: ViewerReplay
        do {
            let params: JSONValue = .object(["board": .string(boardID), "viewer": .string(viewer), "step": .number(Double(step.id))])
            let result = try await connection.request(redo ? "board.redo" : "board.undo", params)
            try requireCurrent(generation)
            reply = try ViewerReplay(reply: result)
        } catch let failure as EaslConnection.Failure where failure.code == "conflict" {
            guard !ended, generation == self.generation else { return .interrupted }
            return .expired
        } catch {
            guard !ended, generation == self.generation else { return .interrupted }
            return .refused("Couldn't \(verb) on \(hostName): \(Self.reason(error))")
        }
        for object in reply.changed {
            if let before = revisions[object.id], object.rev == before + 1 {
                replays.rebase(object.id, from: before, to: object.rev, target: target)
            }
            if replayEvents?.contains(object.id) != true { learn(object) }
        }
        for id in reply.deleted where replayEvents?.contains(id) != true { known.removeValue(forKey: id) }
        for id in reply.changed.map(\.id) + reply.deleted where !busy(id) { settle(id) }
        return .applied(reply)
    }

    /// The composer's send to one terminal on the host: `agent.prompt` with `composer` (the host
    /// sends it as its own composer would). Throws `ApiRouter.Failure` with the host's reason.
    public func prompt(_ text: String, to terminal: ObjectID, mentions: [Mention], answer: Bool) async throws {
        guard !ended, availability == .open else { throw ApiRouter.Failure("unavailable", "board \(boardID) is closed") }
        let generation = generation
        await handshake()
        try requireCurrent(generation)
        guard connection.state == .online, connection.schemaVersion != nil else {
            throw ApiRouter.Failure("unavailable", "\(hostName) is offline (agent.prompt was not sent)")
        }
        let ping: JSONValue
        do {
            ping = try await connection.request("agent.prompt_epoch", .object([:]), timeout: .seconds(10))
        } catch let failure as EaslConnection.Failure where failure.isHostResponse && failure.code == "invalid_params" {
            throw ApiRouter.Failure("unavailable", "Update easl on \(hostName) before sending prompts safely (agent.prompt was not sent)")
        } catch {
            throw ApiRouter.Failure("unavailable", "\(hostName) could not confirm safe prompt delivery (agent.prompt was not sent)")
        }
        try requireCurrent(generation)
        guard let epoch = ping["promptEpoch"]?.string, !epoch.isEmpty, epoch.utf8.count <= 80 else {
            throw ApiRouter.Failure("unavailable", "Update easl on \(hostName) before sending prompts safely (agent.prompt was not sent)")
        }
        let submission = "sub_\(UUID().uuidString)"
        var params: [String: JSONValue] = [
            "target": .string(terminal), "text": .string(text), "composer": .bool(true),
            "submission": .object([
                "id": .string(submission), "epoch": .string(epoch),
                "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
            ]),
        ]
        if answer { params["answer"] = .bool(true) }
        let staged = !answer && !mentions.isEmpty
        var wireMentions: [Mention] = []
        if staged {
            guard hostSpeaksQueue else {
                throw ApiRouter.Failure("unavailable", "this host is an older easl and cannot take staged mentions; update it")
            }
            wireMentions = composerOrigins.hold(mentions, for: terminal)
            params["viewer"] = .string(viewer)
        }
        do {
            if staged { params["staged"] = try JSONValue.encode(wireMentions) }
        } catch {
            composerOrigins.release(wireMentions.map(\.id), for: terminal)
            throw error
        }
        userInput(terminal: terminal)
        do {
            let result: JSONValue
            do {
                result = try await connection.request("agent.prompt", .object(params), timeout: .seconds(30))
            } catch let failure as EaslConnection.Failure where failure.isHostResponse {
                throw ApiRouter.Failure(failure.code, failure.message)
            } catch {
                try await reconcilePrompt(params, submission: submission, terminal: terminal)
                return
            }
            switch result["delivery"]?.string {
            case "typed", "message":
                break
            case "not-delivered":
                throw ApiRouter.Failure(
                    result["error"]?["code"]?.string ?? "not_delivered",
                    result["error"]?["message"]?.string ?? "The host confirmed this prompt was not delivered.")
            default:
                try await reconcilePrompt(params, submission: submission, terminal: terminal)
            }
        } catch {
            if !(error is PromptOutcomeUnknown) {
                composerOrigins.release(wireMentions.map(\.id), for: terminal)
            }
            throw error
        }
    }

    private func reconcilePrompt(_ params: [String: JSONValue], submission: String, terminal: ObjectID) async throws {
        try await replays.reconcilePrompt(params, connection: connection) { [weak self] delivery in
            self?.onPromptDelivery?(submission, terminal, delivery)
        }
    }

    private var composerOrigins = RemoteComposerOrigins()

    private func installComposerReceipts(_ raw: JSONValue?) {
        for receipt in raw?.array ?? [] { applyComposerReceipt(receipt) }
    }

    private func applyComposerReceipt(_ raw: JSONValue, event: String? = nil) {
        guard let returned = composerOrigins.consume(raw, event: event, viewer: viewer) else { return }
        board?.returnComposerMentions(returned.mentions, from: returned.terminal)
    }

    private func installAttention(_ raw: JSONValue?, on board: Board) {
        guard hostSpeaksQueue else { return }
        let markers = raw?.array?.compactMap(SeenMarker.init) ?? []
        for (id, marker) in pendingAttention where !markers.contains(where: { $0.id == (hostIDs[id] ?? id) && $0.raisedAt == marker.raisedAt }) {
            pendingAttention.removeValue(forKey: id)
        }
        board.replaceHostAttention(markers, skipping: busy)
    }

    static let diagramReloadDeadline: Duration = .seconds(15)

    /// Asks the host to compute diagram `id`'s graph afresh (`object.reload`), as it has the
    /// diagram once this viewer's writes to it are answered, so a reload the user's expansion
    /// started computes that expansion. The host writes the graph, which arrives as the object's
    /// update: the answer comes once the computation started (`loaded` false), and the
    /// computation goes on there however long it takes. Sent on `diagrams`, as the host answers a
    /// link's requests one at a time: the board's own link never waits behind it. Throws
    /// `ApiRouter.Failure` with the host's reason (`unavailable`: easld has no client to compute it).
    public func reloadDiagram(_ id: ObjectID) async throws -> JSONValue {
        guard !ended, availability == .open else { throw ApiRouter.Failure("unavailable", "board \(boardID) is closed") }
        let generation = generation
        if let lastReplay = replays.last { _ = await lastReplay.value }
        while let writes = pumps[queue(for: id)] { await writes.value }
        try requireCurrent(generation)
        guard let target = target(id) else { throw ApiRouter.Failure("not_found", "\(id) isn't on \(hostName)") }
        do {
            let result = try await diagrams.request("object.reload", .object(["id": .string(target), "timeoutMs": .number(0)]), timeout: Self.diagramReloadDeadline)
            try requireCurrent(generation)
            return result
        } catch let failure as EaslConnection.Failure {
            throw ApiRouter.Failure(failure.code, failure.message)
        }
    }
}
