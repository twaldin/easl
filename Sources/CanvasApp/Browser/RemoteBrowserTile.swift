import AppKit
import CanvasCore
import UniformTypeIdentifiers

/// A remote board's browser tile whose page this Mac doesn't run. The Mac that runs it keeps the
/// WKWebView: a Mac host, or on an easld board the tile's `drawingMachine`, whose stream easld
/// relays. This view holds one memory image and forwards native input on its own SSH link to the
/// board's server (`remote.host.connection()`), never through `BoardMirror` and never by
/// constructing WebKit.
///
/// One connection per live period. It listens for `surface.frame`, `surface.dialog` and
/// `surface.notice` on the canonical board before `surface.stream`. The page's Mac holds frame 0
/// until `surface.ack` 0, then one frame is outstanding. A dropped link or stream opens a new
/// stream and does not replay input. The last image stays up. On easld a stream also ends when
/// its drawing Mac goes offline or the page moves to another Mac; the tile says so and opens again
/// once that Mac is back, or on the new one.
@MainActor
final class RemoteBrowserTile: NSView, TileContent, @preconcurrency NSTextInputClient {
    private var object: CanvasObject
    private let remote: RemoteSource
    private let chrome = BrowserChrome()
    private let picture = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let owned = OwnedLink()

    /// Live as the tile frame last asked. Starts true because `TileFrameView` does not call
    /// `setLive(true)` for a tile that is born on screen.
    private var wantsLive = true
    private var linkEpoch = 0
    private var streamEpoch = 0
    private var subscribedBoard: BoardID?
    private var linkTasks: [Task<Void, Never>] = []
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var retry: Task<Void, Never>?
    private var retryDelay: Double = 1
    private var opening = false

    private var streamID: String?
    private var credit: Credit = .idle
    private var stashed: [HostFrame] = []
    private var lastAcked = 0
    private var video = SurfaceVideoDecoder()
    private let decoding = DispatchQueue(label: "easl.surface.decode", qos: .userInitiated)
    private var refreshAssembly = SurfaceRefreshAssembly()
    private var assemblingRefinement: Int?
    private var abandonedRefinement = 0
    private var decodingRefinement: Int?
    private var pageSize: CGSize?
    private var image: NSImage?
    private var linkStatus: String?
    private var noticeText: String?
    private var readyWaiters: [@MainActor () -> Void] = []

    private var nextSeq = 0
    private var outbound: [Queued] = []
    private var inputWait: CheckedContinuation<Void, Never>?
    private var mouseIsDown = false
    private var keysDown: Set<UInt16> = []
    private var focusSent = false
    private var lastPointer: NSPoint?
    private var lastHost: (x: Double, y: Double)?
    private var tracking: NSTrackingArea?
    private var keyDownEvent: NSEvent?
    private var keyHandled = false
    private var sentKeyDown = false
    private var marked: MarkedText?
    private var dialogs: [String: Bool] = [:]
    private var dialogSheets: [String: (parent: NSWindow, sheet: NSWindow)] = [:]
    private var clicks: [ClickSample] = []
    private let clock = ContinuousClock()

    /// Ack 0, then one granted frame. A second frame is ignored until that one is installed and acked.
    private enum Credit: Equatable {
        case idle
        case owingZero
        case waiting
        case decoding(Int)
    }

    private struct Queued {
        var seq: Int
        var event: SurfaceInput
    }

    private struct MarkedText {
        var text: String
        var selection: NSRange
    }

    private struct ClickSample {
        var seq: Int
        var started: ContinuousClock.Instant
    }

    init(object: CanvasObject, remote: RemoteSource) {
        self.object = object
        self.remote = remote
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        chrome.onBack = { [weak self] in self?.sendCommand(.back) }
        chrome.onForward = { [weak self] in self?.sendCommand(.forward) }
        chrome.onReload = { [weak self] in self?.reloadOrStop() }
        chrome.onSubmit = { [weak self] text in self?.submitAddress(text) }
        chrome.onEscape = { [weak self] in
            guard let self else { return }
            (self.enclosingScrollView as? CanvasView)?.leaveTile(self.object.id)
        }
        chrome.setAddress(object.props["url"]?.string ?? "")
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignCenter
        picture.imageFrameStyle = .none
        status.drawsBackground = true
        status.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        status.alignment = .center
        status.isEditable = false
        status.isSelectable = false
        status.isBezeled = false
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 3
        status.isHidden = true
        addSubview(chrome)
        addSubview(picture)
        addSubview(status)
        layoutParts()
        refreshStatus()
    }

    private var relayed: Bool { remote.host.server == .easld }

    private var drawingStatus: String { DrawingMachine.status(of: object.props, attached: remote.mirror.drawingMachines) }

    /// An easld tile no attached Mac can stream now: it has no drawing Mac, or presence says that
    /// Mac isn't attached.
    private var drawingOffline: Bool {
        guard relayed else { return false }
        guard let machine = DrawingMachine(object.props) else { return true }
        return remote.mirror.drawingMachines.map { !$0.contains(machine.id) } ?? false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    private var zoom: CGFloat { CGFloat(object.zoom) }

    private var chromeExtent: CGFloat { BrowserTile.chromeHeight / zoom }

    private var pageFrame: NSRect {
        NSRect(x: 0, y: chromeExtent, width: bounds.width, height: max(0, bounds.height - chromeExtent))
    }

    /// Host page aspect, fitted inside the page area. Pointers map through this rectangle, not the letterbox.
    private var imageRect: NSRect {
        let page = pageFrame
        guard let size = pageSize, size.width > 0, size.height > 0, page.width > 0, page.height > 0 else { return page }
        let scale = min(page.width / size.width, page.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: page.minX + (page.width - fitted.width) / 2, y: page.minY + (page.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutParts() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    private func layoutParts() {
        chrome.frame = NSRect(x: 0, y: 0, width: bounds.width, height: chromeExtent)
        let chromeBounds = NSSize(width: bounds.width * zoom, height: BrowserTile.chromeHeight)
        if chrome.bounds.size != chromeBounds {
            chrome.setBoundsSize(chromeBounds)
            chrome.resizeSubviews(withOldSize: chrome.frame.size)
        }
        picture.frame = imageRect
        let width = min(pageFrame.width - 16, 420)
        status.frame = NSRect(x: pageFrame.midX - width / 2, y: pageFrame.maxY - 52, width: max(0, width), height: 44)
        updateTracking()
    }

    private func updateTracking() {
        tracking.map(removeTrackingArea)
        let area = NSTrackingArea(rect: pageFrame, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if chrome.frame.contains(local) { return chrome.hitTest(local) }
        return pageFrame.contains(local) ? self : nil
    }

    // MARK: Link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else {
            endLink()
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
        if wantsLive { startLink() }
    }

    @objc private func windowWillClose() { endLink() }

    func hostBoardAvailabilityChanged() {
        if remote.mirror.availability == .closed {
            endLink()
        } else if wantsLive {
            startLink()
        }
    }

    func setLive(_ live: Bool) {
        guard live != wantsLive else { return }
        wantsLive = live
        if live {
            startLink()
        } else {
            endLink()
            setLinkStatus("Not streaming")
        }
    }

    /// Subscribe and start the event consumer before any `surface.stream`. A second call while
    /// the link is up does nothing.
    private func startLink() {
        guard wantsLive, remote.mirror.availability == .open, window != nil, owned.current() == nil else { return }
        let board = remote.mirror.sessionBoardID
        guard !board.isEmpty else {
            setLinkStatus("No canonical board")
            return
        }
        let connection = remote.host.connection()
        owned.store(connection)
        subscribedBoard = board
        linkEpoch += 1
        let epoch = linkEpoch
        let events = connection.events()
        let states = connection.states()
        connection.subscribe(board: board, events: ["surface.frame", "surface.dialog", "surface.notice"])
        linkTasks.append(Task { [weak self] in await self?.watchEvents(events, epoch: epoch) })
        linkTasks.append(Task { [weak self] in await self?.watchStates(states, epoch: epoch) })
        linkTasks.append(Task { [weak self] in await self?.pump(epoch: epoch) })
        setLinkStatus("Connecting to \(remote.host.name)…")
    }

    /// Stop the stream, release held buttons when the link can still take a request, and close SSH.
    /// Input waiting in the local buffer is dropped, not resent on the next stream.
    private func endLink() {
        linkEpoch += 1
        let connection = owned.take()
        let stream = streamID
        let release = releaseEvents()
        dropStreamState()
        retry?.cancel()
        retry = nil
        linkTasks.forEach { $0.cancel() }
        linkTasks.removeAll()
        subscribedBoard = nil
        guard let connection else { return }
        Task {
            if let stream {
                if !release.isEmpty {
                    _ = try? await connection.request("surface.input", .object(["stream": .string(stream), "events": .array(release)]), timeout: .seconds(2))
                }
                _ = try? await connection.request("surface.stop", .object(["stream": .string(stream)]), timeout: .seconds(2))
            }
            connection.close()
        }
    }

    private func dropStream(reason: String) {
        dropStreamState()
        setLinkStatus(reason)
    }

    private func dropStreamState() {
        streamEpoch += 1
        streamTasks.values.forEach { $0.cancel() }
        streamTasks.removeAll()
        streamID = nil
        credit = .idle
        stashed.removeAll()
        lastAcked = 0
        video = SurfaceVideoDecoder()
        refreshAssembly.reset()
        assemblingRefinement = nil
        abandonedRefinement = 0
        decodingRefinement = nil
        nextSeq = 0
        opening = false
        outbound.removeAll()
        clicks.removeAll()
        dialogs.keys.forEach { dialogs[$0] = true }
        let sheets = Array(dialogSheets.values)
        dialogSheets.removeAll()
        for dialog in sheets { dialog.parent.endSheet(dialog.sheet, returnCode: .cancel) }
        dialogs.removeAll()
        mouseIsDown = false
        keysDown.removeAll()
        focusSent = false
        wakeInput()
    }

    private func watchStates(_ states: AsyncStream<EaslConnection.State>, epoch: Int) async {
        var online = false
        var reached = false
        for await state in states {
            guard epoch == linkEpoch else { return }
            switch state {
            case .online:
                reached = true
                online = true
                guard wantsLive, window != nil else { continue }
                openStream()
            case .connecting:
                if online || streamID != nil {
                    online = false
                    dropStream(reason: "Reconnecting to \(remote.host.name)…")
                } else {
                    setLinkStatus((reached ? "Reconnecting to " : "Connecting to ") + "\(remote.host.name)…")
                }
            case .offline:
                online = false
                var reason = "\(remote.host.name) is offline"
                if let problem = owned.current()?.problem, !problem.isEmpty { reason += " (\(problem))" }
                dropStream(reason: reason)
            }
        }
    }

    private func watchEvents(_ events: AsyncStream<EaslConnection.Event>, epoch: Int) async {
        for await event in events {
            guard epoch == linkEpoch else { return }
            guard event.board == subscribedBoard else { continue }
            switch event.name {
            case "surface.frame":
                if let frame = SurfaceWire.frame(event.data) {
                    receive(frame)
                } else if streamID != nil, event.data["stream"]?.string == streamID {
                    restartStream(reason: "Couldn't read a frame from \(remote.host.name)")
                }
            case "surface.dialog":
                if let dialog = SurfaceWire.dialog(event.data) { receive(dialog) }
            case "surface.notice":
                if let notice = SurfaceWire.notice(event.data) { receive(notice) }
            default:
                break
            }
        }
    }

    private func runStreamTask(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        streamTasks[id] = Task { [weak self] in
            defer { self?.streamTasks[id] = nil }
            await operation()
        }
    }

    private func openStream() {
        guard wantsLive, window != nil, streamID == nil, !opening, let connection = owned.current() else { return }
        if remote.mirror.sessionBoardID != subscribedBoard {
            endLink()
            startLink()
            return
        }
        opening = true
        retry?.cancel()
        retry = nil
        let generation = streamEpoch
        let id = object.id
        let scale = min(2, max(0.25, Double(window?.backingScaleFactor ?? 2)))
        runStreamTask { [weak self] in
            do {
                let result = try await connection.request("surface.stream", .object([
                    "id": .string(id),
                    "scale": .number(scale),
                    "format": .string(SurfaceFormat.h264.rawValue),
                ]), timeout: .seconds(15))
                guard let self else {
                    if let stream = result["stream"]?.string {
                        _ = try? await connection.request("surface.stop", .object(["stream": .string(stream)]), timeout: .seconds(2))
                    }
                    return
                }
                self.opening = false
                guard generation == self.streamEpoch, self.wantsLive, self.owned.current() === connection else {
                    if let stream = result["stream"]?.string {
                        _ = try? await connection.request("surface.stop", .object(["stream": .string(stream)]), timeout: .seconds(2))
                    }
                    return
                }
                guard let stream = result["stream"]?.string, stream.hasPrefix("str_"),
                      let w = result["size"]?["w"]?.number, let h = result["size"]?["h"]?.number, w > 0, h > 0 else {
                    self.failOpen("invalid_params")
                    return
                }
                self.streamID = stream
                self.pageSize = CGSize(width: w, height: h)
                self.credit = .owingZero
                self.lastAcked = 0
                self.layoutParts()
                if self.window?.firstResponder === self { self.enqueue(.focus(true)) }
                self.wakeInput()
                self.sendAck(0, stream: stream, connection: connection, generation: generation)
            } catch is CancellationError {
                self?.opening = false
            } catch let failure as EaslConnection.Failure where failure.code == "unavailable" {
                guard let self, generation == self.streamEpoch else { return }
                self.opening = false
                if connection.state == .online { self.failOpen(failure.code) }
            } catch let failure as EaslConnection.Failure {
                self?.opening = false
                guard let self, generation == self.streamEpoch else { return }
                self.failOpen(failure.code)
            } catch {
                self?.opening = false
                guard let self, generation == self.streamEpoch else { return }
                self.failOpen("unavailable")
            }
        }
    }

    private func failOpen(_ code: String) {
        setLinkStatus("Stream failed (\(code))")
        if retryDelay == 1 { NSLog("easl: remote browser stream %@", code) }
        if code != "unsupported", code != "invalid_params" { scheduleRetry() }
    }

    private func scheduleRetry() {
        retry?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        let epoch = linkEpoch
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, epoch == self.linkEpoch, self.wantsLive, self.window != nil, self.streamID == nil else { return }
            self.openStream()
        }
    }

    private func sendAck(_ frame: Int, stream: String, connection: EaslConnection, generation: Int) {
        runStreamTask { [weak self] in
            guard let self else { return }
            do {
                _ = try await connection.request("surface.ack", .object([
                    "stream": .string(stream),
                    "frame": .number(Double(frame)),
                ]), timeout: .seconds(8))
                guard generation == self.streamEpoch, self.streamID == stream else { return }
                if frame == 0 { self.ackZeroAccepted() }
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.streamEpoch, self.streamID == stream else { return }
                self.endLink()
                self.setLinkStatus("Frame credit failed")
                self.startLink()
            }
        }
    }

    private func ackZeroAccepted() {
        guard credit == .owingZero else { return }
        credit = .waiting
        let waiting = stashed
        stashed.removeAll()
        waiting.forEach(receive)
    }

    // MARK: Frames
    private func restartStream(reason: String) {
        let stream = streamID
        let connection = owned.current()
        dropStream(reason: reason)
        if let stream, let connection {
            Task { _ = try? await connection.request("surface.stop", .object(["stream": .string(stream)]), timeout: .seconds(2)) }
        }
        scheduleRetry()
    }


    private func receive(_ frame: HostFrame) {
        guard frame.stream == streamID else { return }
        if frame.refresh, frame.seq <= abandonedRefinement { return }
        switch credit {
        case .owingZero:
            guard stashed.count < 2 else {
                restartStream(reason: "Too many frames from \(remote.host.name)")
                return
            }
            stashed.append(frame)
        case .waiting where frame.seq == lastAcked + 1:
            accept(frame)
        case .waiting where frame.supersedes.map({ $0 <= lastAcked + 1 }) == true && frame.seq > lastAcked + 1:
            accept(frame)
        case .waiting where frame.seq > lastAcked + 1:
            restartStream(reason: "Missed a frame from \(remote.host.name)")
        case .decoding(let seq) where decodingRefinement == seq && frame.supersedes.map({ $0 <= seq }) == true && frame.seq > seq:
            accept(frame)
        case .decoding(let seq) where frame.seq > seq:
            restartStream(reason: "Missed a frame from \(remote.host.name)")
        case .waiting, .decoding, .idle:
            break
        }
    }

    private func accept(_ frame: HostFrame) {
        if frame.supersedes != nil, frame.offset == nil || frame.offset == 0 {
            video = SurfaceVideoDecoder()
        }
        guard let offset = frame.offset else {
            refreshAssembly.reset()
            assemblingRefinement = nil
            beginDecode(frame)
            return
        }
        if case .decoding = credit {
            credit = .waiting
            decodingRefinement = nil
        }
        do {
            let completed = try refreshAssembly.append(frame: frame)
            assemblingRefinement = completed == nil ? frame.seq : nil
            if let connection = owned.current() {
                sendProgress(frame.seq, offset: offset, stream: frame.stream, connection: connection, generation: streamEpoch)
            }
            if let completed { beginDecode(completed) }
        } catch {
            restartStream(reason: "Couldn't assemble a frame from \(remote.host.name)")
        }
    }

    private func sendProgress(_ frame: Int, offset: Int, stream: String, connection: EaslConnection, generation: Int) {
        runStreamTask { [weak self] in
            do {
                _ = try await connection.request("surface.progress", .object([
                    "stream": .string(stream), "frame": .number(Double(frame)), "offset": .number(Double(offset)),
                ]), timeout: .seconds(8))
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.streamEpoch, self.streamID == stream else { return }
                self.endLink()
                self.setLinkStatus("Refresh transfer failed")
                self.startLink()
            }
        }
    }

    private func beginDecode(_ frame: HostFrame) {
        credit = .decoding(frame.seq)
        decodingRefinement = frame.refresh ? frame.seq : nil
        let generation = streamEpoch
        let stream = frame.stream
        let video = video
        let decoding = decoding
        runStreamTask { [weak self] in
            let decoded = await withCheckedContinuation { continuation in
                decoding.async {
                    continuation.resume(returning: DecodedFrame(frame, video: video))
                }
            }
            guard let self, generation == self.streamEpoch, self.streamID == stream else { return }
            self.finishDecode(frame, decoded)
        }
    }

    private func finishDecode(_ frame: HostFrame, _ decoded: DecodedFrame) {
        guard case .decoding(frame.seq) = credit, frame.stream == streamID else { return }
        guard let cg = decoded.image else {
            restartStream(reason: "Couldn't read a frame from \(remote.host.name)")
            return
        }
        decodingRefinement = nil
        let sizeChanged = pageSize != frame.size
        pageSize = frame.size
        if chrome.canGoBack != frame.back { chrome.canGoBack = frame.back }
        if chrome.canGoForward != frame.forward { chrome.canGoForward = frame.forward }
        if chrome.isLoading != frame.loading { chrome.isLoading = frame.loading }
        linkStatus = nil
        let shown = NSImage(cgImage: cg, size: frame.size)
        image = shown
        retryDelay = 1
        picture.image = shown
        if sizeChanged { layoutParts() }
        Metrics.shared.record("surface.frameAccepted", bytes: decoded.bytes)
        recordClicks(coveredBy: frame.input)
        refreshStatus()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0() }
        credit = .waiting
        lastAcked = frame.seq
        guard let connection = owned.current(), let stream = streamID else { return }
        sendAck(frame.seq, stream: stream, connection: connection, generation: streamEpoch)
    }

    /// One sample per mouse-up. `input` is the delivered fence, not the input reply.
    /// A sample still in the outbound buffer has not been sent, so a frame cannot cover it yet.
    private func recordClicks(coveredBy input: Int) {
        let now = clock.now
        let pending = Set(outbound.map(\.seq))
        let covered = clicks.filter { input >= $0.seq && !pending.contains($0.seq) }
        guard !covered.isEmpty else { return }
        clicks.removeAll { input >= $0.seq && !pending.contains($0.seq) }
        for sample in covered {
            Metrics.shared.record("surface.inputToFrame", ms: sample.started.duration(to: now) / Duration.milliseconds(1))
        }
    }

    // MARK: Input

    @discardableResult
    private func enqueue(_ event: SurfaceInput) -> Int? {
        guard streamID != nil else { return nil }
        if decodingRefinement != nil || assemblingRefinement != nil {
            video = SurfaceVideoDecoder()
        }
        if let decodingRefinement {
            abandonedRefinement = max(abandonedRefinement, decodingRefinement)
            self.decodingRefinement = nil
            credit = .waiting
        }
        if let assemblingRefinement {
            abandonedRefinement = max(abandonedRefinement, assemblingRefinement)
            refreshAssembly.reset()
            self.assemblingRefinement = nil
        }
        if coalesce(event) { return outbound.last?.seq }
        while outbound.count >= 128, dropOldestMotion() {}
        guard outbound.count < 128 else {
            endLink()
            setLinkStatus("Input queue full. Reopen the tile to continue.")
            return nil
        }
        nextSeq += 1
        outbound.append(Queued(seq: nextSeq, event: event))
        if case .focus(let focused) = event { focusSent = focused }
        switch event {
        case .mouse(.move, _, _, _, _), .focus: break
        default:
            if noticeText != nil {
                noticeText = nil
                refreshStatus()
            }
        }
        wakeInput()
        return nextSeq
    }

    private func coalesce(_ event: SurfaceInput) -> Bool {
        guard let index = outbound.indices.last else { return false }
        switch (outbound[index].event, event) {
        case (.mouse(.move, _, _, _, _), .mouse(.move, let x, let y, let clicks, let mods)):
            outbound[index].event = .mouse(.move, x: x, y: y, clicks: clicks, mods: mods)
            return true
        case (.scroll(_, _, let dx, let dy, let precise, _), .scroll(let x, let y, let ndx, let ndy, let nprecise, let mods)) where precise == nprecise:
            outbound[index].event = .scroll(x: x, y: y, dx: dx + ndx, dy: dy + ndy, precise: precise, mods: mods)
            return true
        default:
            return false
        }
    }

    private func dropOldestMotion() -> Bool {
        guard let index = outbound.firstIndex(where: {
            if case .mouse(.move, _, _, _, _) = $0.event { return true }
            if case .scroll = $0.event { return true }
            return false
        }) else { return false }
        outbound.remove(at: index)
        return true
    }

    private func wakeInput() {
        inputWait?.resume()
        inputWait = nil
    }

    private func waitInput() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if streamID != nil, !outbound.isEmpty {
                cont.resume()
            } else {
                inputWait = cont
            }
        }
    }

    private func pump(epoch: Int) async {
        while epoch == linkEpoch, !Task.isCancelled {
            guard streamID != nil, !outbound.isEmpty, let connection = owned.current(), let stream = streamID else {
                await waitInput()
                continue
            }
            let batch = Array(outbound.prefix(128))
            outbound.removeFirst(batch.count)
            let wantsText = batch.contains { $0.event.readsSelection }
            do {
                let result = try await connection.request("surface.input", .object([
                    "stream": .string(stream),
                    "events": .array(batch.map { $0.event.json(seq: $0.seq) }),
                ]), timeout: .seconds(8))
                guard epoch == linkEpoch else { return }
                guard streamID == stream else { continue }
                if wantsText, let text = result["text"]?.string {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clear(privately: true)
                    pasteboard.setString(text, forType: .string)
                }
            } catch is CancellationError {
                return
            } catch {
                guard epoch == linkEpoch else { return }
                let code = (error as? EaslConnection.Failure)?.code ?? "unavailable"
                let message = "Input interrupted (\(code)). Check the page before repeating it."
                guard streamID == stream else {
                    setNotice(message)
                    continue
                }
                endLink()
                setNotice(message)
                startLink()
                return
            }
        }
    }

    private func releaseEvents() -> [JSONValue] {
        var events: [SurfaceInput] = []
        if mouseIsDown, let point = lastHost {
            events.append(.mouse(.up, x: point.x, y: point.y, clicks: 1, mods: 0))
        }
        for code in keysDown.sorted() {
            events.append(.key(.up, code: Int(code), chars: "", plain: "", repeating: false, mods: 0))
        }
        if focusSent { events.append(.focus(false)) }
        mouseIsDown = false
        keysDown.removeAll()
        focusSent = false
        return events.map { event in
            nextSeq += 1
            return event.json(seq: nextSeq)
        }
    }

    private func hostPoint(_ local: NSPoint, clamp: Bool) -> (x: Double, y: Double)? {
        guard let size = pageSize, size.width > 0, size.height > 0 else { return nil }
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        var point = local
        if clamp {
            point.x = min(max(point.x, rect.minX), rect.maxX)
            point.y = min(max(point.y, rect.minY), rect.maxY)
        } else if !rect.contains(point) {
            return nil
        }
        let x = Double((point.x - rect.minX) / rect.width * size.width)
        let y = Double((point.y - rect.minY) / rect.height * size.height)
        guard x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }

    private func mods(_ event: NSEvent) -> Int { Int(event.modifierFlags.rawValue) }

    private func sendCommand(_ name: SurfaceInput.Command, text: String? = nil) {
        enqueue(.command(name, text: text))
    }

    private func reloadOrStop() {
        sendCommand(chrome.isLoading ? .stop : .reload)
    }

    private func submitAddress(_ text: String) {
        guard let url = BrowserURL.normalize(text) else { return NSSound.beep() }
        enqueue(.navigate(url.absoluteString))
        window?.makeFirstResponder(self)
    }

    // MARK: Pointer and keys

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { enqueue(.focus(true)) }
        return ok
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { enqueue(.focus(false)) }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is the other way AppKit opens a context menu. Forwarding it would
        // start a host menu tracking loop and stall every later input event.
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        guard event.buttonNumber == 0 else { return }
        window?.makeFirstResponder(self)
        sendMouse(.down, event, clamp: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown else { return }
        sendMouse(.drag, event, clamp: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseIsDown else { return }
        mouseIsDown = false
        let seq = sendMouse(.up, event, clamp: true) ?? lastHost.flatMap {
            enqueue(.mouse(.up, x: $0.x, y: $0.y, clicks: max(1, event.clickCount), mods: mods(event)))
        }
        guard let seq else { return }
        clicks.append(ClickSample(seq: seq, started: clock.now))
        if clicks.count > 64 { clicks.removeFirst(clicks.count - 64) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !mouseIsDown else { return }
        _ = sendMouse(.move, event, clamp: false)
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }

    override func rightMouseDragged(with event: NSEvent) {}

    override func rightMouseUp(with event: NSEvent) {}

    /// The wire has no middle button. Mapping it to left would be a false click.
    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseDragged(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {}

    @discardableResult
    private func sendMouse(_ action: SurfaceInput.MouseAction, _ event: NSEvent, clamp: Bool) -> Int? {
        let local = convert(event.locationInWindow, from: nil)
        lastPointer = local
        guard let point = hostPoint(local, clamp: clamp) else { return nil }
        lastHost = point
        if action == .down { mouseIsDown = true }
        return enqueue(.mouse(action, x: point.x, y: point.y, clicks: max(1, event.clickCount), mods: mods(event)))
    }

    override func scrollWheel(with event: NSEvent) {
        let at: NSPoint
        if event.window == nil, let cg = event.cgEvent, let window {
            let screen = NSPoint(x: cg.location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - cg.location.y)
            at = window.convertPoint(fromScreen: screen)
        } else {
            at = event.locationInWindow
        }
        let local = convert(at, from: nil)
        lastPointer = local
        guard let point = hostPoint(local, clamp: true) else { return }
        lastHost = point
        // Phaseless. `precise` false is a mouse-wheel line delta. Omitting it would default to pixels.
        enqueue(.scroll(x: point.x, y: point.y, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                        precise: event.hasPreciseScrollingDeltas, mods: mods(event)))
    }

    /// Page pinch, rotate, and swipe are not on the wire. Forward them so the canvas can still zoom.
    override func magnify(with event: NSEvent) { nextResponder?.magnify(with: event) }

    override func rotate(with event: NSEvent) { nextResponder?.rotate(with: event) }

    override func swipe(with event: NSEvent) { nextResponder?.swipe(with: event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if CanvasWindowController.menuItem(for: event, in: NSApp.mainMenu)?.action == #selector(AppDelegate.deleteSelection(_:)) {
            sendKey(.down, event)
            return true
        }
        return claimShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if claimShortcut(event) { return }
        if event.modifierFlags.contains(.command) {
            sendKey(.down, event)
            return
        }
        keyDownEvent = event
        keyHandled = false
        sentKeyDown = false
        interpretKeyEvents([event])
        if !keyHandled { sendKey(.down, event) }
        keyDownEvent = nil
    }

    override func keyUp(with event: NSEvent) {
        guard keysDown.remove(event.keyCode) != nil else { return }
        sendKey(.up, event)
    }

    /// Menu shortcuts are commands, not keys. Command-V as a key would paste the host clipboard.
    private func claimShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch key {
        case "c": copy(nil); return true
        case "x": setNotice("Cut is unavailable remotely. Copy, then delete instead."); return true
        case "v": paste(nil); return true
        default: break
        }
        guard mods == .command else { return false }
        switch key {
        case "a": selectAll(nil)
        case "r": reloadOrStop()
        case "l": chrome.focusAddress()
        case "[": sendCommand(.back)
        case "]": sendCommand(.forward)
        case ".": sendCommand(.stop)
        default: return false
        }
        return true
    }

    private func sendKey(_ action: SurfaceInput.KeyAction, _ event: NSEvent) {
        if action == .down {
            // insertText and doCommand can both run for one key. Send that down once.
            if sentKeyDown, keyDownEvent != nil { return }
            sentKeyDown = true
            keysDown.insert(event.keyCode)
        }
        enqueue(.key(action, code: Int(event.keyCode), chars: event.characters ?? "", plain: event.charactersIgnoringModifiers ?? "",
                     repeating: event.isARepeat, mods: mods(event)))
    }

    override func menu(for event: NSEvent) -> NSMenu? { viewerMenu() }

    private func showMenu(for event: NSEvent) {
        NSMenu.popUpContextMenu(viewerMenu(), with: event, for: self)
    }

    private func viewerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Back", #selector(goBack(_:)), chrome.canGoBack))
        menu.addItem(menuItem("Forward", #selector(goForward(_:)), chrome.canGoForward))
        menu.addItem(menuItem(chrome.isLoading ? "Stop" : "Reload", #selector(reloadPage(_:)), true))
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy", #selector(copy(_:)), true))
        menu.addItem(menuItem("Paste", #selector(paste(_:)), true))
        menu.addItem(menuItem("Select All", #selector(selectAll(_:)), true))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, _ enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func goBack(_ sender: Any?) { sendCommand(.back) }
    @objc private func goForward(_ sender: Any?) { sendCommand(.forward) }
    @objc private func reloadPage(_ sender: Any?) { reloadOrStop() }

    @objc func copy(_ sender: Any?) { enqueue(.command(.copy, text: nil)) }
    override func selectAll(_ sender: Any?) { enqueue(.command(.selectAll, text: nil)) }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return NSSound.beep() }
        enqueue(.command(.paste, text: text))
    }

    // MARK: Text input

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = SurfaceWire.plain(string)
        let matchesKey = marked == nil && keyDownEvent.map { text == ($0.characters ?? "") } == true
        marked = nil
        keyHandled = true
        if matchesKey, let event = keyDownEvent {
            sendKey(.down, event)
            return
        }
        guard !text.isEmpty else { return }
        enqueue(.text(text))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        keyHandled = true
        let text = SurfaceWire.plain(string)
        guard !text.isEmpty else {
            marked = nil
            enqueue(.unmark)
            return
        }
        let utf16 = (text as NSString).length
        let start = min(max(0, selectedRange.location), utf16)
        let length = min(max(0, selectedRange.length), utf16 - start)
        marked = MarkedText(text: text, selection: NSRange(location: start, length: length))
        enqueue(.compose(text, start: start, length: length))
    }

    func unmarkText() {
        keyHandled = true
        guard marked != nil else { return }
        marked = nil
        enqueue(.unmark)
    }

    func selectedRange() -> NSRange {
        marked?.selection ?? NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard let marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: (marked.text as NSString).length)
    }

    func hasMarkedText() -> Bool { marked != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let marked else { return nil }
        let full = NSRange(location: 0, length: (marked.text as NSString).length)
        let clipped = NSIntersectionRange(range, full)
        guard clipped.location != NSNotFound, clipped.length > 0 else { return nil }
        actualRange?.pointee = clipped
        return NSAttributedString(string: (marked.text as NSString).substring(with: clipped))
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let local = lastPointer ?? imageRect.origin
        let rect = NSRect(origin: convert(local, to: nil), size: NSSize(width: 1, height: 16))
        return window?.convertToScreen(rect) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment]
    }

    override func doCommand(by selector: Selector) {
        keyHandled = true
        guard let event = keyDownEvent, event.type == .keyDown else { return }
        sendKey(.down, event)
    }

    // MARK: Dialogs and notices

    private func receive(_ dialog: HostDialog) {
        guard dialog.stream == streamID, dialogs[dialog.id] == nil else { return }
        dialogs[dialog.id] = false
        guard let window else {
            complete(dialog, accept: false)
            return
        }
        if dialog.kind == "file" {
            chooseFiles(dialog, in: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = dialog.origin.isEmpty ? "This page says" : dialog.origin
        alert.informativeText = dialog.message ?? ""
        switch dialog.kind {
        case "alert":
            alert.addButton(withTitle: "OK")
            sheet(alert, window, dialog.id) { [weak self] _ in self?.complete(dialog, accept: true) }
        case "confirm":
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            sheet(alert, window, dialog.id) { [weak self] response in
                self?.complete(dialog, accept: response == .alertFirstButtonReturn)
            }
        case "prompt":
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = dialog.text ?? ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            sheet(alert, window, dialog.id) { [weak self] response in
                let accepted = response == .alertFirstButtonReturn
                self?.complete(dialog, accept: accepted, text: accepted ? field.stringValue : nil)
            }
        case "login":
            let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
            user.placeholderString = "User name"
            user.stringValue = dialog.text ?? ""
            let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            password.placeholderString = "Password"
            let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
            fields.addSubview(user)
            fields.addSubview(password)
            user.nextKeyView = password
            alert.accessoryView = fields
            alert.window.initialFirstResponder = user
            alert.addButton(withTitle: "Log In")
            alert.addButton(withTitle: "Cancel")
            sheet(alert, window, dialog.id) { [weak self] response in
                guard response == .alertFirstButtonReturn else {
                    self?.complete(dialog, accept: false)
                    return
                }
                self?.complete(dialog, accept: true, user: user.stringValue, password: password.stringValue)
            }
        case "select":
            let choices = dialog.choices ?? []
            guard !choices.isEmpty else {
                alert.addButton(withTitle: "Cancel")
                sheet(alert, window, dialog.id) { [weak self] _ in self?.complete(dialog, accept: false) }
                return
            }
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
            choices.forEach { popup.addItem(withTitle: $0) }
            if let selected = dialog.selected, choices.indices.contains(selected) { popup.selectItem(at: selected) }
            alert.accessoryView = popup
            alert.window.initialFirstResponder = popup
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            sheet(alert, window, dialog.id) { [weak self] response in
                guard response == .alertFirstButtonReturn else {
                    self?.complete(dialog, accept: false)
                    return
                }
                let choice = popup.indexOfSelectedItem
                guard choices.indices.contains(choice) else {
                    self?.reopen(dialog)
                    return
                }
                self?.complete(dialog, accept: true, choice: choice)
            }
        default:
            setNotice("Unsupported dialog (\(dialog.kind))")
            complete(dialog, accept: false)
        }
    }

    private func sheet(_ alert: NSAlert, _ window: NSWindow, _ id: String, _ done: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        dialogSheets[id] = (parent: window, sheet: alert.window)
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.dialogSheets[id] = nil
            done(response)
        }
    }

    private func chooseFiles(_ dialog: HostDialog, in window: NSWindow) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = dialog.multiple == true
        let types = (dialog.accept ?? []).compactMap { hint -> UTType? in
            if hint.hasPrefix(".") { return UTType(filenameExtension: String(hint.dropFirst())) }
            switch hint {
            case "image/*": return .image
            case "audio/*": return .audio
            case "video/*": return .movie
            default: return UTType(mimeType: hint)
            }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.allowsOtherFileTypes = true
        panel.message = "Choose files from this Mac to upload to \(dialog.origin). Up to 8 MiB total."
        panel.prompt = "Upload"
        dialogSheets[dialog.id] = (parent: window, sheet: panel)
        let generation = streamEpoch
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.dialogSheets[dialog.id] = nil
            guard generation == self.streamEpoch, dialog.stream == self.streamID, self.dialogs[dialog.id] == false else { return }
            guard response == .OK else { return self.complete(dialog, accept: false) }
            let urls = DevInput.chosen(in: panel)
            self.runStreamTask { [weak self] in
                guard self?.streamEpoch == generation, self?.streamID == dialog.stream, self?.dialogs[dialog.id] == false else { return }
                do {
                    let files = try await Task.detached(priority: .userInitiated) { try Self.readFiles(urls) }.value
                    guard let self, generation == self.streamEpoch, dialog.stream == self.streamID, self.dialogs[dialog.id] == false else { return }
                    self.complete(dialog, accept: true, files: files)
                } catch {
                    guard let self, generation == self.streamEpoch, dialog.stream == self.streamID, self.dialogs[dialog.id] == false else { return }
                    self.complete(dialog, accept: false)
                    self.setNotice("Upload cancelled. \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated private static func readFiles(_ urls: [URL]) throws -> [SurfaceFile] {
        guard !urls.isEmpty, urls.count <= SurfaceFile.maxCount else {
            throw EaslConnection.Failure("invalid_params", "Choose 1 to 32 files.")
        }
        var remaining = SurfaceFile.maxBytes
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { throw EaslConnection.Failure("invalid_params", "Choose regular files, not folders.") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var bytes = Data()
            while let chunk = try handle.read(upToCount: min(65_536, remaining - bytes.count + 1)), !chunk.isEmpty {
                guard chunk.count <= remaining - bytes.count else {
                    throw EaslConnection.Failure("invalid_params", "The files exceed the 8 MiB upload limit.")
                }
                bytes.append(chunk)
            }
            remaining -= bytes.count
            return try SurfaceFile(name: url.lastPathComponent, type: values.contentType?.preferredMIMEType ?? "application/octet-stream",
                                   modified: values.contentModificationDate.map { $0.timeIntervalSince1970 * 1000 }, bytes: bytes)
        }
    }

    private func complete(_ dialog: HostDialog, accept: Bool, text: String? = nil, user: String? = nil, password: String? = nil, choice: Int? = nil,
                          files: [SurfaceFile]? = nil) {
        guard dialogs[dialog.id] == false, dialog.stream == streamID, let connection = owned.current() else { return }
        guard let params = answerFields(dialog, accept: accept, text: text, user: user, password: password, choice: choice, files: files) else {
            return reopen(dialog)
        }
        let generation = streamEpoch
        runStreamTask { [weak self] in
            guard let self, generation == self.streamEpoch, dialog.stream == self.streamID, self.dialogs[dialog.id] == false else { return }
            do {
                _ = try await connection.request("surface.answer", params, timeout: .seconds(8))
                guard generation == self.streamEpoch, dialog.stream == self.streamID, self.dialogs[dialog.id] == false else { return }
                self.dialogs[dialog.id] = true
            } catch let failure as EaslConnection.Failure where failure.code == "invalid_params" {
                guard generation == self.streamEpoch, dialog.stream == self.streamID, self.dialogs[dialog.id] == false else { return }
                self.reopen(dialog)
            } catch {
                guard generation == self.streamEpoch, dialog.stream == self.streamID, self.dialogs[dialog.id] == false else { return }
                if dialog.kind == "file" { self.setNotice("Upload was not completed. Check the page before trying again.") }
                self.dialogs[dialog.id] = true
            }
        }
    }

    /// Extra fields are invalid_params and leave the host dialog open. Cancel sends accept only.
    private func answerFields(_ dialog: HostDialog, accept: Bool, text: String?, user: String?, password: String?, choice: Int?, files: [SurfaceFile]?) -> JSONValue? {
        var params: [String: JSONValue] = [
            "stream": .string(dialog.stream),
            "dialog": .string(dialog.id),
            "accept": .bool(accept),
        ]
        guard accept else { return .object(params) }
        switch dialog.kind {
        case "alert", "confirm":
            return .object(params)
        case "prompt":
            params["text"] = .string(text ?? "")
            return .object(params)
        case "login":
            params["user"] = .string(user ?? "")
            params["password"] = .string(password ?? "")
            return .object(params)
        case "select":
            let count = dialog.choices?.count ?? 0
            guard let choice, choice >= 0, choice < count else { return nil }
            params["choice"] = .number(Double(choice))
            return .object(params)
        case "file":
            guard let files, !files.isEmpty, dialog.multiple == true || files.count == 1 else { return nil }
            params["files"] = .array(files.map(\.json))
            return .object(params)
        default:
            return .object(params)
        }
    }

    private func reopen(_ dialog: HostDialog) {
        guard dialogs[dialog.id] == false else { return }
        dialogs.removeValue(forKey: dialog.id)
        receive(dialog)
    }

    private func receive(_ notice: HostNotice) {
        guard notice.stream == streamID || notice.stream == stashed.first?.stream else { return }
        switch notice.kind {
        case "dialogClosed":
            guard notice.stream == streamID, let id = notice.dialog, dialogs[id] == false else { return }
            dialogs[id] = true
            if let dialog = dialogSheets.removeValue(forKey: id) {
                dialog.parent.endSheet(dialog.sheet, returnCode: .cancel)
            }
        case "download":
            setNotice(downloadLine(notice))
        case "refused":
            setNotice(Self.refusedLine(notice.reason))
        case "closed":
            guard notice.stream == streamID else { return }
            dropStream(reason: closedLine(notice.reason))
            // Reopen transient failures without replaying accepted input.
            if notice.reason == "drawing machine offline" || notice.reason == "drawing moved" ||
               notice.reason == "page input unavailable" || notice.reason == "surface encoding failed" { scheduleRetry() }
        default:
            setNotice("Host notice (\(notice.kind))")
        }
    }

    private func downloadLine(_ notice: HostNotice) -> String {
        let named = notice.name.map { ": \(SurfaceWire.clip($0))" } ?? ""
        let reason = notice.reason.map { " (\(SurfaceWire.clip($0)))" } ?? ""
        switch notice.state {
        case "finished": return "Saved on \(remote.host.name)\(named)\(reason)"
        case "failed": return "Download failed on \(remote.host.name)\(named)\(reason)"
        case "running": return "Downloading on \(remote.host.name)\(named)\(reason)"
        default: return "Download on \(remote.host.name)\(named)\(reason)"
        }
    }

    private static func refusedLine(_ reason: String?) -> String {
        switch reason {
        case "menu": return "Host blocked a context menu"
        case "select": return "Host blocked a select menu"
        case "native upload": return "The page's file picker could not be relayed."
        case "folder upload": return "Folder uploads aren't available on a streamed page."
        case "upload in a frame": return "Uploads from a frame aren't available on a streamed page."
        case "media": return "Host refused the camera or microphone"
        case "certificate": return "Host refused a client certificate"
        case "app link": return "Host refused an app link"
        case "text input": return "Host refused text input"
        case let other?: return "Host refused this (\(SurfaceWire.clip(other)))"
        case nil: return "Host refused this"
        }
    }

    private func closedLine(_ reason: String?) -> String {
        switch reason {
        case "drawing machine offline": return DrawingMachine.status(of: object.props, attached: [])
        case "page input unavailable": return "The drawing Mac couldn't prepare the page for input"
        case "drawing moved": return "The page moved to another Mac"
        case "tile closed": return "Host closed this tile"
        case "board closed": return "Host closed the board"
        case "window closed": return "Host closed the window"
        case "frame too large": return "Host frame is too large to stream"
        case let other?: return "Host closed the stream (\(SurfaceWire.clip(other)))"
        case nil: return "Host closed the stream"
        }
    }

    // MARK: Status and TileContent

    private func setLinkStatus(_ text: String?) {
        linkStatus = text
        refreshStatus()
    }

    private func setNotice(_ text: String) {
        noticeText = text
        refreshStatus()
    }

    private func refreshStatus() {
        let lines = [streamID == nil && drawingOffline ? drawingStatus : linkStatus, noticeText].compactMap { $0 }
        status.stringValue = lines.joined(separator: "\n")
        status.isHidden = lines.isEmpty
        status.setAccessibilityLabel(lines.joined(separator: ". "))
        status.toolTip = relayed ? DrawingMachine(object.props).map { "\($0.host): \($0.id)" } : nil
    }

    /// The board's attached drawing Macs changed: the tile says where its page runs again, and a
    /// relayed tile that isn't streaming opens now that its drawing Mac is attached.
    func drawingMachinesChanged() {
        refreshStatus()
        guard relayed, streamID == nil, !opening, remote.mirror.drawingMachines != nil, !drawingOffline,
              owned.current()?.state == .online else { return }
        retryDelay = 1
        openStream()
    }

    /// A relayed page that moved to another Mac streams from there: the old stream and its link
    /// end, dropping input not sent yet, and a new link opens. A new name for the same Mac moves
    /// nothing.
    func update(_ object: CanvasObject) {
        let idChanged = object.id != self.object.id
        let moved = relayed && DrawingMachine(object.props)?.id != DrawingMachine(self.object.props)?.id
        let zoomChanged = object.zoom != self.object.zoom
        self.object = object
        if !chrome.isEditing { chrome.setAddress(object.props["url"]?.string ?? "") }
        if zoomChanged { layoutParts() }
        refreshStatus()
        guard idChanged || moved, wantsLive else { return }
        retryDelay = 1
        endLink()
        startLink()
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        guard let image else { return .placeholder(request, relayed ? drawingStatus : "not streamed from \(remote.host.name) yet") }
        let pageSize = self.pageSize
        let drawn = request.image { bounds in
            NSColor.controlBackgroundColor.setFill()
            bounds.fill()
            let bar = min(BrowserTile.chromeHeight, bounds.height)
            let page = NSRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - bar))
            image.drawUpright(in: Self.fitted(pageSize ?? image.size, in: page))
        }
        return TileRender(image: drawn, contentSize: request.size, state: drawn == nil ? .failed : .rendered)
    }

    private static func fitted(_ size: CGSize, in page: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, page.width > 0, page.height > 0 else { return page }
        let scale = min(page.width / size.width, page.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: page.minX + (page.width - fitted.width) / 2, y: page.minY + (page.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    func whenLiveReady(_ ready: @escaping @MainActor () -> Void) {
        if image != nil || drawingOffline { ready() } else { readyWaiters.append(ready) }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? { .object(object.id) }

    func outline(for target: MentionTarget) -> NSRect? { bounds }

    var headerHeight: CGFloat { chromeExtent }

    var takesKeyboardFocus: Bool { true }

    func enterKeyboard() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }
}

/// Typed native input. `seq` is assigned when the event is queued, not stored here.
private enum SurfaceInput {
    enum MouseAction: String { case down, up, drag, move }
    enum KeyAction: String { case down, up }
    enum Command: String { case copy, paste, selectAll, back, forward, reload, stop }

    case mouse(MouseAction, x: Double, y: Double, clicks: Int, mods: Int)
    case scroll(x: Double, y: Double, dx: Double, dy: Double, precise: Bool, mods: Int)
    case key(KeyAction, code: Int, chars: String, plain: String, repeating: Bool, mods: Int)
    case text(String)
    case compose(String, start: Int, length: Int)
    case unmark
    case focus(Bool)
    case command(Command, text: String?)
    case navigate(String)

    var readsSelection: Bool {
        if case .command(let name, _) = self { return name == .copy }
        return false
    }

    func json(seq: Int) -> JSONValue {
        var fields: [String: JSONValue] = ["seq": .number(Double(seq))]
        switch self {
        case .mouse(let action, let x, let y, let clicks, let mods):
            fields["kind"] = .string("mouse")
            fields["action"] = .string(action.rawValue)
            fields["x"] = .number(x)
            fields["y"] = .number(y)
            if clicks != 1 { fields["clicks"] = .number(Double(clicks)) }
            if mods != 0 { fields["mods"] = .number(Double(mods)) }
        case .scroll(let x, let y, let dx, let dy, let precise, let mods):
            fields["kind"] = .string("scroll")
            fields["x"] = .number(x)
            fields["y"] = .number(y)
            fields["dx"] = .number(dx)
            fields["dy"] = .number(dy)
            fields["precise"] = .bool(precise)
            if mods != 0 { fields["mods"] = .number(Double(mods)) }
        case .key(let action, let code, let chars, let plain, let repeating, let mods):
            fields["kind"] = .string("key")
            fields["action"] = .string(action.rawValue)
            fields["code"] = .number(Double(code))
            fields["chars"] = .string(chars)
            fields["plain"] = .string(plain)
            if repeating { fields["repeat"] = .bool(true) }
            if mods != 0 { fields["mods"] = .number(Double(mods)) }
        case .text(let text):
            fields["kind"] = .string("text")
            fields["text"] = .string(text)
        case .compose(let text, let start, let length):
            fields["kind"] = .string("compose")
            fields["text"] = .string(text)
            fields["start"] = .number(Double(start))
            fields["length"] = .number(Double(length))
        case .unmark:
            fields["kind"] = .string("unmark")
        case .focus(let on):
            fields["kind"] = .string("focus")
            fields["on"] = .bool(on)
        case .command(let name, let text):
            fields["kind"] = .string("command")
            fields["name"] = .string(name.rawValue)
            if let text { fields["text"] = .string(text) }
        case .navigate(let url):
            fields["kind"] = .string("navigate")
            fields["url"] = .string(url)
        }
        return .object(fields)
    }
}

private typealias HostFrame = SurfaceEvent.Frame

private struct HostDialog {
    var stream: String
    var id: String
    var kind: String
    var origin: String
    var message: String?
    var text: String?
    var choices: [String]?
    var selected: Int?
    var multiple: Bool?
    var accept: [String]?
}

private struct HostNotice {
    var stream: String
    var kind: String
    var dialog: String?
    var reason: String?
    var name: String?
    var state: String?
}

private final class DecodedFrame: @unchecked Sendable {
    let image: CGImage?
    let bytes: Int

    init(_ frame: HostFrame, video: SurfaceVideoDecoder) {
        let canvas = frame.canvas ?? CGSize(width: frame.width, height: frame.height)
        do {
            image = try SurfaceImageDecoder.decode(frame.data, format: frame.format,
                width: frame.width, height: frame.height, canvas: canvas, video: video, refinement: frame.refresh)
        } catch {
            image = nil
        }
        bytes = frame.data.count
    }
}

private enum SurfaceWire {
    static func integer(_ value: JSONValue?) -> Int? {
        guard let number = value?.number else { return nil }
        return Int(exactly: number)
    }

    static func frame(_ data: JSONValue) -> HostFrame? {
        guard let stream = data["stream"]?.string, stream.hasPrefix("str_"),
              let seq = integer(data["seq"]), seq > 0,
              let input = integer(data["input"]), input >= 0,
              let w = data["size"]?["w"]?.number, let h = data["size"]?["h"]?.number, w.isFinite, h.isFinite, w > 0, h > 0,
              let scale = data["scale"]?.number, scale.isFinite, scale > 0, scale <= SurfaceRequest.maxScale,
              let payload = data["data"]?.string, !payload.isEmpty,
              let formatName = data["format"]?.string, let format = SurfaceFormat(rawValue: formatName),
              let width = integer(data["width"]), let height = integer(data["height"]),
              width > 0, height > 0, width <= SurfaceEvent.Frame.maxPixels / height,
              let back = data["back"]?.bool, let forward = data["forward"]?.bool, let loading = data["loading"]?.bool else { return nil }
        let refresh = data["refresh"]?.bool ?? false
        guard data["refresh"] == nil || data["refresh"]?.bool != nil, !refresh || format == .h264 else { return nil }
        let supersedes = integer(data["supersedes"])
        guard data["supersedes"] == nil || supersedes.map({ $0 > 0 && $0 < seq }) == true else { return nil }
        let offset = integer(data["offset"]), total = integer(data["total"])
        guard (data["offset"] == nil && data["total"] == nil) ||
              (refresh && offset != nil && total != nil) else { return nil }
        let limit: Int
        if refresh {
            guard let offset, let total, total > 0, total <= SurfaceImageEncoder.refinementBytes,
                  offset >= 0, offset < total, offset % SurfaceRefreshTransmission.chunkBytes == 0 else { return nil }
            limit = min(SurfaceRefreshTransmission.chunkBytes, total - offset)
        } else {
            switch format {
            case .h264: limit = 48 * 1024
            case .jpeg, .png: limit = 16 << 20
            }
        }
        guard payload.utf8.count <= (limit + 2) / 3 * 4,
              let bytes = Data(base64Encoded: payload), !bytes.isEmpty, bytes.count <= limit,
              !refresh || bytes.count == limit else { return nil }
        var frame = HostFrame(stream: stream, seq: seq, input: input, size: CGSize(width: w, height: h),
                              scale: scale, format: format, data: bytes, width: width, height: height,
                              back: back, forward: forward, loading: loading)
        frame.refresh = refresh
        frame.supersedes = supersedes
        frame.offset = offset
        frame.total = total
        if let value = data["canvas"] {
            guard let cw = integer(value["w"]), let ch = integer(value["h"]),
                  cw > 0, ch > 0, cw <= SurfaceEvent.Frame.maxPixels / ch else { return nil }
            frame.canvas = CGSize(width: cw, height: ch)
        }
        return frame
    }

    static func dialog(_ data: JSONValue) -> HostDialog? {
        guard let stream = data["stream"]?.string, let id = data["dialog"]?.string, !id.isEmpty,
              let kind = data["kind"]?.string, let origin = data["origin"]?.string else { return nil }
        let choices = data["choices"]?.array?.compactMap(\.string)
        return HostDialog(stream: stream, id: id, kind: kind, origin: origin, message: data["message"]?.string,
                          text: data["text"]?.string, choices: choices, selected: integer(data["selected"]),
                          multiple: data["multiple"]?.bool, accept: data["accept"]?.array?.compactMap(\.string))
    }

    static func notice(_ data: JSONValue) -> HostNotice? {
        guard let stream = data["stream"]?.string, let kind = data["kind"]?.string else { return nil }
        let dialog = data["dialog"]?.string
        guard kind != "dialogClosed" || (dialog?.isEmpty == false) else { return nil }
        return HostNotice(stream: stream, kind: kind, dialog: dialog, reason: data["reason"]?.string,
                          name: data["name"]?.string, state: data["state"]?.string)
    }


    static func plain(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let text as NSAttributedString: return text.string
        default: return ""
        }
    }

    static func clip(_ text: String) -> String {
        text.count > 180 ? String(text.prefix(180)) + "..." : text
    }
}

/// Closes the SSH link if the tile is released without `endLink`.
private final class OwnedLink: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: EaslConnection?

    func store(_ connection: EaslConnection) {
        lock.lock()
        let previous = self.connection
        self.connection = connection
        lock.unlock()
        previous?.close()
    }

    func current() -> EaslConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    func take() -> EaslConnection? {
        lock.lock()
        defer { lock.unlock() }
        let connection = self.connection
        self.connection = nil
        return connection
    }

    deinit {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.close()
    }
}
