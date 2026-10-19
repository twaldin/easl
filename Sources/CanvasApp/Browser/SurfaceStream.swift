import AppKit
import CanvasCore

/// One viewer's stream of a browser tile, owned by the connection that opened it (`owner`).
@MainActor
final class SurfaceStream {
    enum Credit {
        /// Frame `seq` was sent (0: the stream just opened) and isn't acknowledged yet.
        case outstanding(Int)
        /// The viewer acknowledged the last frame: frame `next` may go.
        case granted(next: Int)
    }

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
    private(set) var credit = Credit.outstanding(0)
    /// The highest seq accepted into the queue.
    private(set) var accepted = 0
    /// The highest seq WebKit handed the page (`BrowserSurface.native`).
    private(set) var delivered = 0
    var mousePending = false
    var keyPending = false
    /// The last frame's delivered input and full page state.
    private(set) var fence = 0
    private var lastSent: SurfaceEvent.Frame?
    /// When it last accepted input (system uptime): the page's dialogs go to the latest.
    private(set) var lastInput: TimeInterval = 0
    var closed = false
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
    }

    /// The seq the next frame takes, while one may go.
    var next: Int? {
        if case .granted(let next) = credit { return next }
        return nil
    }

    var holdsInput: Bool { heldButton != nil || !heldKeys.isEmpty }

    func markDelivered(_ seq: Int) {
        guard !mousePending, !keyPending else { return }
        delivered = max(delivered, seq)
    }

    /// Input accepted that hasn't reached the page yet.
    var pending: Bool { queued > 0 }

    /// The outstanding frame acknowledged grants exactly one more; an older ack changes nothing.
    func ack(_ frame: Int) throws {
        switch credit {
        case .outstanding(let sent):
            guard frame <= sent else { throw ApiRouter.Failure("invalid_params", "frame \(frame) wasn't sent; the latest is \(sent)") }
            guard frame == sent else { return }
            if !started {
                started = true
                for line in pendingEvents { owner.send(line) }
                pendingEvents.removeAll()
                pendingEventBytes = 0
            }
            credit = .granted(next: sent + 1)
            surface.pump()
        case .granted(let next):
            guard frame < next else { throw ApiRouter.Failure("invalid_params", "frame \(frame) wasn't sent; the latest is \(next - 1)") }
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
        lastInput = ProcessInfo.processInfo.systemUptime
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

    func send(_ frame: SurfaceEvent.Frame) -> Bool {
        if let last = lastSent,
           frame.input == last.input, frame.size == last.size, frame.scale == last.scale,
           frame.width == last.width, frame.height == last.height, frame.format == last.format,
           frame.back == last.back, frame.forward == last.forward, frame.loading == last.loading,
           frame.data == last.data { return false }
        credit = .outstanding(frame.seq)
        fence = frame.input
        lastSent = frame
        Metrics.shared.record("surface.frame", bytes: frame.data.count)
        let owner = owner, board = board
        // Base64 and JSON of a whole page image take milliseconds: off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let line = try? EventLine("surface.frame", board: board, frame.json) else { return }
            if owner.send(line) {
                Metrics.shared.record("surface.frameWire", bytes: line.data.count)
            }
        }
        return true
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
