import Foundation

/// One host-drawn tile's asks for its drawing (docs/design.md "Client mode"): the host's
/// `view.render` of the object (`BoardMirror.render`), one at a time whoever asks, and only while
/// the tile is near the view. An ask that hasn't left already is the fresh one; one made while an
/// ask is out runs after it (once, however many asked); a burst of the host's changes (`changed`:
/// a page loading, an agent writing) draws once, after it settles; one made while the tile isn't
/// near the view waits until it is, since its card wouldn't show the drawing. `RemoteImageTile`
/// shows what it answers; the asks are here, where tests count them.
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
    /// The ask out, waiting in the mirror or sent, until it is answered or taken back.
    private var ticket: RenderTicket?
    /// Asked again while the ask was sent: one more once it is answered.
    private var again = false
    /// The tile is near the view (`setLive`). A tile starts so, as `TileFrameView` starts its
    /// content; one made out of view is set otherwise in the same turn (`startAsCard`), before its
    /// first ask leaves.
    private var live = true
    /// A drawing was wanted while the tile wasn't near the view: asked for once it is.
    private var owed = false

    /// `scale`: the screen's backing scale, read when an ask is made. `busy`: an ask is out
    /// (true) or answered or taken back (false). `drawn`: each answer, the host's drawing or why not.
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

    /// Asks the host for the drawing: the tile was made, the user pressed ↻, the host's changes
    /// settled, or the link to the host dropped and is back (`BoardMirror.onRedraw`, whose read
    /// announces only objects that changed). An ask that hasn't left goes out as things are on the
    /// host when it leaves, so it already is the fresh one; one that has gets one more behind it.
    public func draw() {
        scheduled?.cancel()
        scheduled = nil
        guard live else {
            owed = true
            return
        }
        if let ticket {
            if !ticket.isWaiting { again = true }
            return
        }
        busy(true)
        ticket = mirror.render(object, scale: scale()) { [weak self] outcome in self?.answered(outcome) }
    }

    /// The host changed the object: draws once its changes have settled.
    public func changed() {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.draw() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleTime, execute: work)
    }

    /// The tile came near the view or left it (`TileContent.setLive`). Leaving takes back an ask
    /// that hasn't left, and coming back asks for what was missed meanwhile.
    public func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        if live {
            guard owed else { return }
            owed = false
            draw()
        } else if let ticket, ticket.withdraw() {
            self.ticket = nil
            owed = true
            busy(false)
        }
    }

    private func answered(_ outcome: Outcome) {
        ticket = nil
        busy(false)
        drawn(outcome)
        guard again else { return }
        again = false
        draw()
    }
}
