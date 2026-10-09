import CoreGraphics
import Foundation
import ImageIO

/// A host-drawn tile's ask for its object's drawing (`BoardMirror.render`), from the ask to its
/// answer. Its tile keeps it until it is answered, and `withdraw` takes it back if it hasn't left.
@MainActor
public final class RenderTicket {
    enum State {
        /// In `RenderQueue`, not sent: it may still be taken back.
        case waiting
        /// In the `view.render` on the link: its answer will come.
        case sent
        /// Answered, or taken back while waiting.
        case done
    }

    let id: ObjectID
    let scale: Double
    fileprivate(set) var state = State.waiting
    /// The host refused a list holding it (a target deleted there that the viewer hasn't heard
    /// of yet): it goes by itself from then on.
    fileprivate var alone = false
    private let answer: @MainActor (Result<BoardMirror.Render, Error>) -> Void

    fileprivate init(id: ObjectID, scale: Double, answer: @escaping @MainActor (Result<BoardMirror.Render, Error>) -> Void) {
        self.id = id
        self.scale = scale
        self.answer = answer
    }

    /// It hasn't left: when it leaves, it asks for the object as the host has it then.
    public var isWaiting: Bool { state == .waiting }

    /// Takes the ask back if it hasn't left. True: it hadn't, and no answer will come.
    @discardableResult
    public func withdraw() -> Bool {
        guard state == .waiting else { return false }
        state = .done
        return true
    }

    fileprivate func finish(_ outcome: Result<BoardMirror.Render, Error>) {
        guard state != .done else { return }
        state = .done
        answer(outcome)
    }
}

/// A remote board's asks for drawings (docs/design.md "Client mode"). The host answers a link's
/// requests one at a time, and a request's timeout runs from when it is sent, so asks wait here
/// and the render link carries one `view.render` at a time: its timeout then counts that
/// request's own drawing, never a queue of others ahead of it on the host. Each request is one
/// list target of the waiting tiles nearest the user's view, which the host draws at once.
@MainActor
final class RenderQueue {
    /// Tiles in one request. The host loads a list's pages at once: 20 HTML cards took 0.95 s
    /// together and 0.29 s each one by one.
    static let listLimit = 20
    /// The host draws only the targets: the viewer draws notes, shapes, arrows and groups itself,
    /// and a list's region would otherwise have the host draw every other tile under it again.
    /// These are the types every host that answers `inline` (0.2.0 on) knows: a type it doesn't
    /// know fails the request.
    static let excluded: [JSONValue] = ["terminal", "browser", "code", "note", "html", "changes", "image", "diagram", "question", "shape", "arrow", "group"].map(JSONValue.string)

    private let link: EaslConnection
    private let board: BoardID
    private let hostName: String
    private let timeout: Duration
    /// Each object's frame on the mirror's board (absent: not on it), and what the user sees.
    private let layout: @MainActor () -> (frames: [ObjectID: Frame], view: Frame?)
    /// Arrival order. Taken-back tickets are dropped at the next flush.
    private var waiting: [RenderTicket] = []
    private var sending = false
    private var flushDue = false
    private var closed = false

    init(link: EaslConnection, board: BoardID, hostName: String, timeout: Duration,
         layout: @escaping @MainActor () -> (frames: [ObjectID: Frame], view: Frame?)) {
        self.link = link
        self.board = board
        self.hostName = hostName
        self.timeout = timeout
        self.layout = layout
    }

    /// Queues an ask. `answer` is called once, on the main actor, unless the ticket is taken back
    /// first; never before this returns.
    func add(_ id: ObjectID, scale: Double, answer: @escaping @MainActor (Result<BoardMirror.Render, Error>) -> Void) -> RenderTicket {
        let ticket = RenderTicket(id: id, scale: min(4, max(0.1, scale)), answer: answer)
        waiting.append(ticket)
        scheduleFlush()
        return ticket
    }

    /// The mirror closed: waiting asks are answered `unavailable`; a sent one fails with its link.
    func close() {
        closed = true
        scheduleFlush()
    }

    /// After the current turn, so every ask one liveness pass makes is in one plan.
    private func scheduleFlush() {
        guard !flushDue else { return }
        flushDue = true
        Task { @MainActor [weak self] in await self?.flush() }
    }

    private func flush() async {
        flushDue = false
        guard !sending else { return }
        waiting.removeAll { $0.state != .waiting }
        if closed {
            let gone = waiting
            waiting = []
            for ticket in gone { ticket.finish(.failure(ApiRouter.Failure("unavailable", "the connection to \(hostName) was closed"))) }
            return
        }
        let layout = layout()
        // A deleted object's tile is gone: nothing asks for it, and a list naming it would be refused.
        let deleted = waiting.filter { layout.frames[$0.id] == nil }
        waiting.removeAll { layout.frames[$0.id] == nil }
        for ticket in deleted { ticket.finish(.failure(ApiRouter.Failure("not_found", "no longer on \(hostName)'s board"))) }
        guard !waiting.isEmpty else { return }
        let picked = Self.next(waiting.map { (id: $0.id, scale: $0.scale, alone: $0.alone) }, frames: layout.frames, view: layout.view)
        let batch = picked.map { waiting[$0] }
        let sent = Set(picked)
        waiting = waiting.indices.filter { !sent.contains($0) }.map { waiting[$0] }
        for ticket in batch { ticket.state = .sent }
        sending = true
        let ids = batch.map(\.id), scale = batch[0].scale
        do {
            let result = try await link.request("view.render", params(ids, scale: scale), timeout: timeout)
            let drawings = await Self.split(result, ids: ids, scale: scale, hostName: hostName)
            for ticket in batch { ticket.finish(drawings[ticket.id] ?? .failure(ApiRouter.Failure("unavailable", "\(hostName) didn't draw it"))) }
        } catch let failure as EaslConnection.Failure where batch.count > 1 && failure.code == "not_found" {
            for ticket in batch {
                ticket.state = .waiting
                ticket.alone = true
            }
            waiting.insert(contentsOf: batch, at: 0)
        } catch let failure as EaslConnection.Failure {
            for ticket in batch { ticket.finish(.failure(ApiRouter.Failure(failure.code, failure.message))) }
        } catch {
            for ticket in batch { ticket.finish(.failure(error)) }
        }
        sending = false
        if !waiting.isEmpty || closed { scheduleFlush() }
    }

    private func params(_ ids: [ObjectID], scale: Double) -> JSONValue {
        .object([
            "board": .string(board), "target": ids.count == 1 ? .string(ids[0]) : .array(ids.map(JSONValue.string)),
            "inline": .bool(true), "scale": .number(scale), "timeoutMs": .number(8000), "exclude": .array(Self.excluded),
        ])
    }

    /// Which waiting asks (indices into `asks`) the next request carries: nearest the user first,
    /// those in `view` before the rest, each by the distance from the view's centre to theirs,
    /// then by arrival (by arrival alone without a view). The first, and those after it of its
    /// scale and on its side of the view's edge, up to `listLimit`: tiles out of view never hold
    /// up the ones in it. An ask the host refused in a list goes by itself.
    private static func next(_ asks: [(id: ObjectID, scale: Double, alone: Bool)], frames: [ObjectID: Frame], view: Frame?) -> [Int] {
        func rank(_ index: Int) -> (Int, Double, Int) {
            guard let view, let frame = frames[asks[index].id] else { return (0, 0, index) }
            let dx = frame.x + frame.w / 2 - (view.x + view.w / 2), dy = frame.y + frame.h / 2 - (view.y + view.h / 2)
            return (frame.intersects(view) ? 0 : 1, dx * dx + dy * dy, index)
        }
        let ranks = asks.indices.map(rank)
        let ranked = asks.indices.sorted { ranks[$0] < ranks[$1] }
        guard let lead = ranked.first else { return [] }
        if asks[lead].alone { return [lead] }
        return Array(ranked.filter { !asks[$0].alone && asks[$0].scale == asks[lead].scale && ranks[$0].0 == ranks[lead].0 }.prefix(listLimit))
    }

    /// One reply as each target's drawing, or why not. The picture is decoded once, off the main
    /// thread, and each target cut out by its `objects[].pixelRect` into a bitmap of its own, so a
    /// tile never keeps the whole picture. A lone target the host placed nowhere is the whole picture.
    private static func split(_ result: JSONValue, ids: [ObjectID], scale: Double, hostName: String) async -> [ObjectID: Result<BoardMirror.Render, Error>] {
        guard let data = result["data"]?.string.flatMap({ Data(base64Encoded: $0) }) else {
            return failing(ids, "\(hostName) sent no image (an easl without view.render inline)")
        }
        var placed: [ObjectID: CGRect] = [:]
        for object in result["objects"]?.array ?? [] {
            guard let id = object["id"]?.string, let rect = object["pixelRect"].flatMap({ try? $0.decode(Frame.self) }) else { continue }
            placed[id] = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        }
        let rects = placed, lone = ids.count == 1
        let cut = await offPool { () -> [ObjectID: Pixels]? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let picture = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            let whole = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
            var cut: [ObjectID: Pixels] = [:]
            for id in ids {
                guard let rect = rects[id] ?? (lone ? whole : nil) else { continue }
                if let image = own(picture, rect.integral.intersection(whole)) { cut[id] = Pixels(image: image) }
            }
            return cut
        }
        guard let cut else { return failing(ids, "\(hostName) sent an image this Mac can't read") }
        let drawn = result["scale"]?.number ?? scale
        var out: [ObjectID: Result<BoardMirror.Render, Error>] = [:]
        for id in ids {
            out[id] = cut[id].map { .success(BoardMirror.Render(image: $0.image, scale: drawn)) } ?? .failure(ApiRouter.Failure("unavailable", "\(hostName) didn't draw it"))
        }
        return out
    }

    private static func failing(_ ids: [ObjectID], _ message: String) -> [ObjectID: Result<BoardMirror.Render, Error>] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, .failure(ApiRouter.Failure("unavailable", message))) })
    }

    /// `rect` of `picture` in a bitmap of its own (a crop alone would keep the picture's pixels).
    private nonisolated static func own(_ picture: CGImage, _ rect: CGRect) -> CGImage? {
        guard !rect.isEmpty, let crop = picture.cropping(to: rect) else { return nil }
        let space = crop.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage()
    }

    /// Decoded pixels, immutable, handed from the pool to the main actor.
    private struct Pixels: @unchecked Sendable {
        let image: CGImage
    }
}
