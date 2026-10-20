import AppKit
import CanvasCore

/// One viewer's stream of a browser tile, owned by the connection that opened it (`owner`).
@MainActor
final class SurfaceStream {
    /// Input batches a stream may have waiting before more is refused.
    static let maxQueued = 32
    private static let maxOpeningEvents = 32
    private static let maxOpeningEventBytes = 256 * 1024

    let id: String
    /// Where the stream was opened from: whether it lasts, and what its viewer hears.
    let peer: any SurfacePeer
    let owner: SurfaceOwner
    let board: BoardID
    let surface: BrowserSurface
    let scale: Double
    let format: SurfaceFormat
    private var flow: SurfaceFrameFlow
    /// The highest seq accepted into the queue.
    private(set) var accepted = 0
    /// The highest seq WebKit handed the page (`BrowserSurface.native`).
    private(set) var delivered = 0
    var mousePending = false
    var keyPending = false
    /// The last frame's delivered input and full page state.
    private(set) var fence = 0
    private var lastSent: SurfaceEvent.Frame?
    private let encoder = SurfaceImageEncoder()
    private let inputRevision = SurfaceInputRevision()
    private let delivery = DispatchQueue(label: "easl.surface.frames", qos: .userInitiated)
    private var refinementTransfer: SurfaceRefreshTransmission?
    /// When it last accepted input (system uptime): the page's dialogs go to the latest.
    private(set) var lastInput: TimeInterval = 0
    var closed = false {
        didSet {
            if closed {
                inputRevision.advance()
                refinementTransfer = nil
            }
        }
    }
    /// Where the viewer's button is down, in web view points, and the keys it holds.
    var heldButton: NSPoint?
    weak var mouseTarget: NSView?
    var heldKeys: [UInt16: (chars: String, plain: String)] = [:]
    private var pipeline: Task<Void, Never>?
    private var queued = 0
    // Ack 0 proves the viewer has its stream id and easld has registered its private route.
    private var started = false
    private var pendingEvents: [EventLine] = []
    private var pendingEventBytes = 0

    init(id: String, peer: any SurfacePeer, board: BoardID, surface: BrowserSurface, scale: Double, format: SurfaceFormat) {
        self.id = id
        self.peer = peer
        owner = peer.owner
        self.board = board
        self.surface = surface
        self.scale = scale
        self.format = format
        flow = SurfaceFrameFlow(adaptive: format == .h264)
        RemoteUpdateActivity.shared.begin(session: id, kind: .browser, board: board, tile: surface.tile?.objectID)
    }

    /// The seq the next frame takes, while one may go.
    var next: Int? { flow.next }

    var captureFormat: SurfaceFormat { format == .h264 && flow.mode == .jpeg ? .jpeg : format }

    var holdsInput: Bool { heldButton != nil || !heldKeys.isEmpty }

    func markDelivered(_ seq: Int) {
        guard !mousePending, !keyPending else { return }
        delivered = max(delivered, seq)
    }

    /// Input accepted that hasn't reached the page yet.
    var pending: Bool { queued > 0 }

    func encode(_ image: CGImage, width: Int, height: Int, forceState: Bool, at now: TimeInterval) async throws -> (SurfaceImageEncoding?, TimeInterval) {
        let mode = flow.mode
        let active = pending || delivered > fence || now - lastInput < 0.35
        let lastInput = lastInput
        let encoder = encoder, revision = inputRevision
        let result = await offPool {
            Result {
                let frame = try encoder.capture(image, width: width, height: height, mode: mode, inputActive: active,
                    lastInput: lastInput, forceState: mode == .probing || forceState, revision: revision, at: now)
                return (frame, encoder.captureDelay)
            }
        }
        return try result.get()
    }

    /// The outstanding frame acknowledged grants exactly one more; an older ack changes nothing.
    func ack(_ frame: Int) throws {
        switch flow.acknowledge(frame, at: ProcessInfo.processInfo.systemUptime) {
        case .invalid:
            throw ApiRouter.Failure("invalid_params", "frame \(frame) wasn't sent")
        case .stale:
            return
        case .granted:
            encoder.acknowledgeFrame()
            refinementTransfer = nil
            if !started {
                started = true
                for line in pendingEvents { owner.send(line) }
                pendingEvents.removeAll()
                pendingEventBytes = 0
                surface.inputArrived()
            }
            surface.pump()
        }
    }

    /// Queues the batch's new events (seq past `accepted`; the rest were accepted before) and
    /// answers once they are queued, not delivered: frames report delivery (`fence`). A copy
    /// waits up to `BrowserSurface.selectionWait` for the selected text.
    func input(_ events: [SurfaceInputEvent]) async throws -> JSONValue {
        let fresh = events.drop(while: { $0.seq <= accepted })
        guard let last = fresh.last else { return .object(["accepted": .number(0)]) }
        guard surface.tile != nil else { throw ApiRouter.Failure("unavailable", "the streamed tile closed") }
        guard queued < Self.maxQueued else {
            throw ApiRouter.Failure("unavailable", "this Mac hasn't delivered the stream's last \(queued) batches yet (a menu or drag here holds its event queue); nothing in this batch was accepted")
        }
        accepted = last.seq
        recordInput()
        inputRevision.advance()
        _ = flow.supersedeRefinement()
        refinementTransfer = nil
        let batch = enqueue(fresh)
        surface.inputArrived()
        var result: [String: JSONValue] = ["accepted": .number(Double(fresh.count))]
        if fresh.contains(where: \.readsSelection) {
            let read = await BrowserSurface.bounded(BrowserSurface.selectionWait) { (done: @escaping @MainActor (String?) -> Void) in
                Task { done(await batch.value) }
            }
            guard let read, let text = read else {
                throw ApiRouter.Failure("unavailable", "the page's selection couldn't be read within \(Int(BrowserSurface.selectionWait)) s; the batch's input was accepted")
            }
            result["text"] = .string(text)
        }
        return .object(result)
    }

    func recordInput() {
        lastInput = ProcessInfo.processInfo.systemUptime
        RemoteUpdateActivity.shared.record(session: id, kind: .browser, board: board,
                                           tile: surface.tile?.objectID, now: lastInput)
    }

    /// Batches reach the page one after another, each once the one before is through.
    private func enqueue(_ events: ArraySlice<SurfaceInputEvent>) -> Task<String?, Never> {
        let previous = pipeline
        queued += 1
        let batch = Task { () -> String? in
            await previous?.value
            defer { self.queued -= 1 }
            guard !self.closed else { return nil }
            return await self.surface.deliver(events, for: self)
        }
        pipeline = Task { _ = await batch.value }
        return batch
    }

    /// Until the accepted input has reached the page, or `limit` passes.
    func settle(within limit: TimeInterval) async {
        guard let pipeline else { return }
        _ = await BrowserSurface.bounded(limit) { (done: @escaping @MainActor (Bool) -> Void) in
            Task {
                await pipeline.value
                done(true)
            }
        }
    }

    func pageStateChanged(_ frame: SurfaceEvent.Frame) -> Bool {
        frame.input != fence || (lastSent.map { !samePageState(frame, $0) } ?? true)
    }

    private func samePageState(_ frame: SurfaceEvent.Frame, _ last: SurfaceEvent.Frame) -> Bool {
        frame.size == last.size && frame.scale == last.scale &&
        frame.back == last.back && frame.forward == last.forward && frame.loading == last.loading
    }

    private func sameState(_ frame: SurfaceEvent.Frame, _ last: SurfaceEvent.Frame) -> Bool {
        samePageState(frame, last) && frame.input == last.input &&
        frame.width == last.width && frame.height == last.height && frame.format == last.format
    }

    func send(_ source: SurfaceEvent.Frame) -> Bool {
        var frame = source
        if format != .h264, let last = lastSent, sameState(frame, last), frame.data == last.data { return false }
        frame.supersedes = flow.publish(frame.seq, refinement: frame.refresh, at: ProcessInfo.processInfo.systemUptime)
        fence = frame.input
        lastSent = frame
        Metrics.shared.record("surface.frame", bytes: frame.data.count)
        if frame.refresh {
            do {
                var transfer = try SurfaceRefreshTransmission(frame: frame)
                let parts = transfer.start()
                refinementTransfer = transfer
                parts.forEach(deliver)
            } catch {
                surface.end(self, "surface encoding failed")
                return false
            }
        } else {
            refinementTransfer = nil
            deliver(frame)
        }
        return true
    }

    func progress(_ frame: Int, offset: Int) throws {
        guard let lastSent, frame <= lastSent.seq else {
            throw ApiRouter.Failure("invalid_params", "refresh frame wasn't sent")
        }
        guard frame == lastSent.seq, var transfer = refinementTransfer else { return }
        let parts: [SurfaceEvent.Frame]
        do {
            parts = try transfer.progress(offset: offset)
        } catch {
            throw ApiRouter.Failure("invalid_params", "refresh part wasn't sent")
        }
        refinementTransfer = transfer
        parts.forEach(deliver)
    }

    private func deliver(_ frame: SurfaceEvent.Frame) {
        let owner = owner, board = board, revision = inputRevision
        let ticket = revision.value
        delivery.async { [weak self] in
            guard !frame.refresh || revision.value == ticket,
                  let line = try? EventLine("surface.frame", board: board, frame.json),
                  !frame.refresh || revision.value == ticket else { return }
            let whileCurrent: (@Sendable () -> Bool)?
            if frame.refresh { whileCurrent = { revision.value == ticket } }
            else { whileCurrent = nil }
            if owner.send(line, whileCurrent: whileCurrent) {
                let sentAt = ProcessInfo.processInfo.systemUptime
                Metrics.shared.record("surface.frameWire", bytes: line.data.count)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.closed, self.peer.isOpen else { return }
                        RemoteUpdateActivity.shared.record(session: self.id, kind: .browser, board: self.board,
                                                           tile: self.surface.tile?.objectID, now: sentAt)
                    }
                }
            }
        }
    }

    /// Whether the stream's viewer hears `event` on the stream's board.
    func hears(_ event: String) -> Bool {
        peer.hears(event, on: board)
    }

    /// A dialog or notice, to this stream's own connection only, once its viewer hears it.
    func push(_ event: String, _ data: JSONValue) {
        guard !closed, hears(event), let line = try? EventLine(event, board: board, data) else { return }
        guard started else {
            guard pendingEvents.count < Self.maxOpeningEvents, line.data.count <= Self.maxOpeningEventBytes - pendingEventBytes else {
                started = true
                pendingEvents.removeAll()
                pendingEventBytes = 0
                surface.end(self, "stream setup exceeded its private event budget")
                return
            }
            pendingEventBytes += line.data.count
            pendingEvents.append(line)
            return
        }
        owner.send(line)
    }
}
