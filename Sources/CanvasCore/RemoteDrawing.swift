import Foundation

/// One host-drawn tile's requests for its drawing (docs/design.md "Client mode"): the host's
/// `view.render` of the object (`BoardMirror.render`), one at a time whoever asks. A request made
/// while one is out runs after it (once, however many asked); a burst of the host's changes
/// (`changed`: a page loading, an agent writing) draws once, after it settles. `RemoteImageTile`
/// shows what it answers; the requests themselves are here, where tests count them.
@MainActor
public final class RemoteDrawing {
    public typealias Outcome = Result<BoardMirror.Render, Error>

    /// How long the host's changes to the object settle before it is drawn again.
    public static let settle: TimeInterval = 0.4

    private let object: ObjectID
    private let mirror: BoardMirror
    private let scale: @MainActor () -> Double
    private let busy: @MainActor (Bool) -> Void
    private let drawn: @MainActor (Outcome) -> Void
    private let settleTime: TimeInterval
    private var scheduled: DispatchWorkItem?
    /// A request is wanted or out: from `draw` until its answer is handed to `drawn`.
    private var rendering = false
    /// The request has been handed to the render link (the task that sends it has started).
    private var sent = false
    /// Asked again while one was out: one more once it is answered.
    private var again = false

    /// `scale`: the screen's backing scale, read when a request is made. `busy`: a request is
    /// out (true) or answered (false). `drawn`: each answer, the host's drawing or why not.
    public init(object: ObjectID, mirror: BoardMirror, settle: TimeInterval = RemoteDrawing.settle,
                scale: @escaping @MainActor () -> Double, busy: @escaping @MainActor (Bool) -> Void = { _ in },
                drawn: @escaping @MainActor (Outcome) -> Void) {
        self.object = object
        self.mirror = mirror
        settleTime = settle
        self.scale = scale
        self.busy = busy
        self.drawn = drawn
    }

    /// Asks the host for the drawing now (the tile was made, or the user pressed ↻).
    public func draw() {
        scheduled?.cancel()
        scheduled = nil
        guard !rendering else {
            again = true
            return
        }
        rendering = true
        sent = false
        busy(true)
        let id = object, scale = scale()
        Task { @MainActor [weak self] in
            guard let self else { return }
            sent = true
            let outcome: Outcome
            do {
                outcome = .success(try await mirror.render(id, scale: scale))
            } catch {
                outcome = .failure(error)
            }
            rendering = false
            busy(false)
            drawn(outcome)
            if again {
                again = false
                draw()
            }
        }
    }

    /// The host changed the object: draws once its changes have settled.
    public func changed() {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.draw() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleTime, execute: work)
    }

    /// The link to the host dropped and is back (`BoardMirror.onRedraw`): the drawing may have
    /// failed or gone stale meanwhile, and the host's read announces only objects that changed.
    /// A request not sent yet (a tile made while the board was read again) leaves on the link as it
    /// is now, so it already is the fresh one; one sent before gets one more behind it.
    public func redraw() {
        scheduled?.cancel()
        scheduled = nil
        if rendering, !sent { return }
        draw()
    }
}
