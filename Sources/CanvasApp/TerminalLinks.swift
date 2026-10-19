import AppKit
import CanvasCore
import GhosttyKit
import GhosttyTerminal
import ImageIO
import UniformTypeIdentifiers

enum TerminalImageInput: Sendable {
    case bytes(Data)
    case fileURL(URL)
}

struct TerminalPasteDestination: Sendable {
    enum Machine: Sendable {
        case local
        case hosted(HostRoute)
        case remote(RemoteHost)
    }

    let machine: Machine
    let instance: String
    let session: String

    var key: String {
        let host: String = switch machine {
        case .local: "local"
        case .hosted(let route): route.target
        case .remote(let host): host.sshTarget
        }
        return "\(host)\n\(instance)\n\(session)"
    }

    private func run(_ arguments: [String], input: Data? = nil) async throws -> String {
        let result: RemoteHost.RunResult
        switch machine {
        case .local:
            result = try await RemoteHost.run("/bin/sh", ["-c", TerminalPaste.script, "easl"] + arguments, input: input, timeout: 60)
        case .hosted(let route):
            result = try await RemoteHost.run("/usr/bin/ssh", route.ssh(HostedTerminal.remote(TerminalPaste.hostScript, arguments)), input: input, timeout: 60)
        case .remote(let host):
            let base = ((host.zmxDir ?? host.socketPath) as NSString).deletingLastPathComponent
            let script = "export EASL_PASTE_BASE=\(RemoteHost.quote(base))\n" + TerminalPaste.script
            result = try await RemoteHost.run(RemoteHost.ssh, host.scriptArguments(script, arguments), input: input, timeout: 60)
        }
        guard result.status == 0 else {
            throw EaslConnection.Failure("unavailable", "Image copy failed on the terminal's host. \(result.errors.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output
    }
    private static func encodedImage(_ input: TerminalImageInput) throws -> (data: Data, ext: String) {
        let data: Data
        switch input {
        case .bytes(let bytes):
            data = bytes
        case .fileURL(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            data = try Data(contentsOf: url)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw EaslConnection.Failure("invalid", "The pasted image couldn't be read")
        }
        let ext: String?
        switch CGImageSourceGetType(source) as String? {
        case UTType.png.identifier: ext = "png"
        case UTType.jpeg.identifier: ext = "jpg"
        case UTType.gif.identifier: ext = "gif"
        case "org.webmproject.webp": ext = "webp"
        default: ext = nil
        }
        if let ext { return (data, ext) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary) else {
            throw EaslConnection.Failure("invalid", "The pasted image couldn't be read")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw EaslConnection.Failure("invalid", "The pasted image couldn't be converted to PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EaslConnection.Failure("invalid", "The pasted image couldn't be converted to PNG")
        }
        return (output as Data, "png")
    }


    func stage(_ images: [TerminalImageInput]) async throws -> String {
        var paths: [String] = []
        for input in images {
            try Task.checkCancellation()
            let encoded = await offPool { Result { try Self.encodedImage(input) } }
            let image = try encoded.get()
            try Task.checkCancellation()
            let output = try await run(TerminalPaste.stageArguments(instance: instance, session: session, name: UUID().uuidString + "." + image.ext, size: image.data.count), input: image.data)
            guard let path = TerminalPaste.stagedPath(output) else {
                throw EaslConnection.Failure("unavailable", "The terminal's host returned an invalid image path")
            }
            paths.append(path)
        }
        try Task.checkCancellation()
        return TerminalPaste.text(paths: paths)
    }

    func discard() async {
        do {
            _ = try await run(TerminalPaste.discardArguments(instance: instance, session: session))
        } catch {
            NSLog("easl: couldn't remove terminal image copies: %@", (error as? EaslConnection.Failure)?.message ?? error.localizedDescription)
        }
    }
}

/// The Ghostty view of a terminal tile, with ⌘-hover and ⌘-click on `path:line` references
/// (`TerminalReferences`) that resolve to a file. Everything else (URLs included) stays Ghostty's.
@MainActor
final class CanvasTerminalView: TerminalView {
    /// The reference at a point in this view's coordinates, if it names an existing file.
    var linkAt: ((NSPoint) -> TerminalReferences.Hit?)?
    var onHover: ((TerminalReferences.Hit?) -> Void)?
    /// A ⌘-clicked reference; `newTile` for ⌥⌘- or ⇧⌘-click (always a tile of its own).
    var onOpen: ((TerminalReferences.Hit, _ newTile: Bool) -> Void)?
    /// A ⌘-click that found no file to open (`linkAt` was nil) at a point in this view's coordinates.
    var onMissedLink: ((NSPoint, _ newTile: Bool) -> Void)?
    var onReferenceClick: ((NSPoint, _ newTile: Bool) -> Bool)?
    var onClick: (() -> Void)?
    var onUserInput: (() -> Void)?
    private(set) var openingNewTile = false
    /// Keyboard focus came or went: libghostty-spm has just told Ghostty the view is focused
    /// or not, without asking whether its window is key in an active app.
    var onFocusChange: (() -> Void)?
    /// Whether the terminal has scrollback to scroll (more rows than its screen).
    var hasScrollback: (() -> Bool)?
    var imageDestination: (() -> TerminalPasteDestination?)?
    var onImageProblem: ((String) -> Void)?

    private final class SubmissionCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    @MainActor
    private final class Submission {
        let id: UUID
        let paste: @MainActor () -> Bool
        let delay: Duration
        let cancellation: SubmissionCancellation
        private var continuation: CheckedContinuation<Bool, Never>?

        init(id: UUID, paste: @escaping @MainActor () -> Bool, delay: Duration, cancellation: SubmissionCancellation, continuation: CheckedContinuation<Bool, Never>) {
            self.id = id
            self.paste = paste
            self.delay = delay
            self.cancellation = cancellation
            self.continuation = continuation
        }

        var isPending: Bool { continuation != nil && !cancellation.isCancelled }

        func resolve(_ result: Bool) {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: result)
        }

        deinit { continuation?.resume(returning: false) }
    }

    private enum Input {
        case key(NSEvent)
        case text(String)
        case images([TerminalImageInput], TerminalPasteDestination)
        case submission(Submission)
        case problem(String)
    }

    private struct ActiveInput: Sendable {
        let token: UUID
        let task: Task<Void, Never>
        let submission: Submission?
    }

    private var pendingInput: [Input] = []
    private var inputIndex = 0
    private var activeInput: ActiveInput?
    private var pasteKeyUp: UInt16?
    private static var imageUploads: [String: [UUID: Task<Void, Never>]] = [:]

    private static let imageDragTypes: [NSPasteboard.PasteboardType] = {
        let images = CGImageSourceCopyTypeIdentifiers() as! [String]
        return [.fileURL] + images.map { NSPasteboard.PasteboardType($0) }
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.imageDragTypes)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { activeInput?.task.cancel() }

    func cancelImageInput() {
        let active = activeInput
        activeInput = nil
        active?.task.cancel()
        active?.submission?.resolve(false)
        for input in pendingInput[inputIndex...] {
            if case .submission(let submission) = input { submission.resolve(false) }
        }
        pendingInput.removeAll()
        inputIndex = 0
    }

    static func cancelImageUploads(for key: String) -> [Task<Void, Never>] {
        let tasks = imageUploads[key].map { Array($0.values) } ?? []
        for task in tasks { task.cancel() }
        return tasks
    }

    func submitOrdered(_ paste: @escaping @MainActor () -> Bool, delay: Duration) async -> Bool {
        let id = UUID()
        let cancellation = SubmissionCancellation()
        let cancelOnMain: @MainActor @Sendable () -> Void = { [weak self] in self?.cancelSubmission(id) }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                enqueue(.submission(Submission(id: id, paste: paste, delay: delay, cancellation: cancellation, continuation: continuation)))
            }
        } onCancel: {
            cancellation.cancel()
            Task { await cancelOnMain() }
        }
        return result && !Task.isCancelled
    }

    private func cancelSubmission(_ id: UUID) {
        if let active = activeInput, active.submission?.id == id {
            activeInput = nil
            active.task.cancel()
            active.submission?.resolve(false)
            drainInput()
            return
        }
        for input in pendingInput[inputIndex...] {
            if case .submission(let submission) = input, submission.id == id {
                submission.resolve(false)
                return
            }
        }
    }

    private func finishInput(_ token: UUID, result: Bool = false) {
        guard let active = activeInput, active.token == token else { return }
        activeInput = nil
        active.submission?.resolve(result)
        drainInput()
    }

    @discardableResult
    func pasteOrdered(_ text: String) -> Bool {
        guard activeInput != nil else { return paste(text: text) }
        guard !text.isEmpty else { return false }
        enqueue(.text(text))
        return true
    }

    private static func imageFile(_ item: NSPasteboardItem) -> URL? {
        guard let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return url
    }

    private static func imageType(_ item: NSPasteboardItem) -> NSPasteboard.PasteboardType? {
        if item.types.contains(.png) { return .png }
        return item.types.first { UTType($0.rawValue)?.conforms(to: .image) == true }
    }

    private static func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.pasteboardItems,
              !items.contains(where: { $0.types.contains(.fileURL) && imageFile($0) == nil }) else { return false }
        return items.contains { imageFile($0) != nil || imageType($0) != nil }
    }


    @discardableResult
    func pasteImages(from pasteboard: NSPasteboard, imageOnly: Bool = false, dropping: Bool = false) -> Bool {
        let hasText = pasteboard.types?.contains(.string) == true
        if !dropping, imageOnly, hasText { return false }
        let items = pasteboard.pasteboardItems ?? []
        if !dropping, hasText, !items.contains(where: { Self.imageFile($0) != nil }) { return false }
        guard Self.hasImages(pasteboard) else { return false }
        do {
            var images: [TerminalImageInput] = []
            for item in items {
                if let url = Self.imageFile(item) {
                    images.append(.fileURL(url))
                } else if let type = Self.imageType(item) {
                    guard let data = item.data(forType: type) else {
                        throw EaslConnection.Failure("invalid", "The pasted image couldn't be read")
                    }
                    images.append(.bytes(data))
                }
            }
            guard let destination = imageDestination?() else {
                throw EaslConnection.Failure("unavailable", "The terminal's image destination isn't available yet")
            }
            enqueue(.images(images, destination))
        } catch {
            enqueue(.problem((error as? EaslConnection.Failure)?.message ?? error.localizedDescription))
        }
        return true
    }


    @IBAction override func paste(_ sender: Any?) {
        onUserInput?()
        if pasteImages(from: .general) { return }
        if activeInput != nil {
            if let text = TerminalPasteboardContent.text() { enqueue(.text(text)) }
        } else {
            super.paste(sender)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.hasImages(sender.draggingPasteboard) && sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !draggingEntered(sender).isEmpty else { return false }
        onUserInput?()
        window?.makeFirstResponder(self)
        return pasteImages(from: sender.draggingPasteboard, dropping: true)
    }

    private func enqueue(_ input: Input) {
        pendingInput.append(input)
        drainInput()
    }

    private func drainInput() {
        guard activeInput == nil else { return }
        while inputIndex < pendingInput.count {
            let input = pendingInput[inputIndex]
            inputIndex += 1
            switch input {
            case .key(let event):
                switch event.type {
                case .keyDown: super.keyDown(with: event)
                case .keyUp: super.keyUp(with: event)
                case .flagsChanged: super.flagsChanged(with: event)
                default: break
                }
            case .text(let text):
                if !super.paste(text: text) { onImageProblem?("The terminal isn't ready to receive pasted text") }
            case .problem(let problem):
                onImageProblem?(problem)
            case .submission(let submission):
                guard submission.isPending else {
                    submission.resolve(false)
                    continue
                }
                let token = submission.id
                let task = Task { [weak self] in
                    guard self?.activeInput?.token == token else { return }
                    guard !Task.isCancelled, submission.isPending, submission.paste() else {
                        self?.finishInput(token)
                        return
                    }
                    do {
                        try await Task.sleep(for: submission.delay)
                    } catch {
                        self?.finishInput(token)
                        return
                    }
                    guard !Task.isCancelled, submission.isPending, let self, self.activeInput?.token == token else {
                        self?.finishInput(token)
                        return
                    }
                    self.finishInput(token, result: self.sendKey(.enter))
                }
                activeInput = ActiveInput(token: token, task: task, submission: submission)
                return
            case .images(let images, let destination):
                let ticket = UUID()
                let key = destination.key
                let task = Task { [weak self] in
                    defer {
                        Self.imageUploads[key]?[ticket] = nil
                        if Self.imageUploads[key]?.isEmpty == true { Self.imageUploads[key] = nil }
                        self?.finishInput(ticket)
                    }
                    do {
                        let text = try await destination.stage(images)
                        guard !Task.isCancelled, let self, self.activeInput?.token == ticket else { return }
                        if !self.paste(text: text) {
                            self.onImageProblem?("The terminal isn't ready to receive the copied image paths")
                        }
                    } catch {
                        guard !Task.isCancelled, let self, self.activeInput?.token == ticket else { return }
                        self.onImageProblem?((error as? EaslConnection.Failure)?.message ?? error.localizedDescription)
                    }
                }
                activeInput = ActiveInput(token: ticket, task: task, submission: nil)
                Self.imageUploads[key, default: [:]][ticket] = task
                return
            }
        }
        pendingInput.removeAll(keepingCapacity: true)
        inputIndex = 0
    }

    private var swallowedMouseUp = false
    private var hovered: TerminalReferences.Hit?
    /// AppKit takes keyboard focus from a view it hides, and a terminal is hidden whenever its
    /// tile turns into its card (panned offscreen, zoomed out, a resize that took it out of
    /// view): the terminal that lost focus that way gets it back when shown again, unless
    /// something took it meanwhile. One at a time: focusing any terminal forgets it.
    private static weak var refocusTarget: CanvasTerminalView?

    /// Redraws, for `easl metrics` (`terminal.draw`) and DevPerf spans: a terminal nobody is
    /// watching should show few (`IdleRedraw`). Counted here, handed to Metrics once a second.
    override func surfaceDidDraw() {
        MainMetricsBatch.shared.draws += 1
        DevPerf.count("terminal.draw")
    }

    override func becomeFirstResponder() -> Bool {
        Self.refocusTarget = nil
        let became = super.becomeFirstResponder()
        onFocusChange?()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isHiddenOrHasHiddenAncestor { Self.refocusTarget = self }
        onFocusChange?()
        return resigned
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard Self.refocusTarget === self, let window else { return }
        Self.refocusTarget = nil
        // Nothing chose a responder since: AppKit leaves the window or hands the canvas the focus.
        if window.firstResponder == nil || window.firstResponder === window || window.firstResponder is CanvasDocumentView {
            window.makeFirstResponder(self)
        }
    }

    /// Out of the key-view loop, so hiding one terminal never passes the focus to another
    /// (which would then take the refocus when it is hidden in turn).
    override var canBecomeKeyView: Bool { false }

    /// A ⌥⌘-click is on its way to Ghostty as a ⌘-click (below), so a web link it opens goes to the
    /// default browser (`TerminalTile.openLink`).
    private(set) var forcingDefaultBrowser = false

    override func mouseDown(with event: NSEvent) {
        onClick?()
        let flags = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)
        openingNewTile = !flags.isDisjoint(with: [.option, .shift])
        if flags.contains(.command), onReferenceClick?(point, openingNewTile) == true {
            swallowedMouseUp = true
            setHover(nil)
            return
        }
        if flags.contains(.command), let hit = linkAt?(point) {
            // Ghostty never sees this click, so it neither selects nor opens anything.
            swallowedMouseUp = true
            setHover(nil)
            onOpen?(hit, !flags.isDisjoint(with: [.option, .shift]))
            return
        }
        if flags.contains(.command) { onMissedLink?(point, !flags.isDisjoint(with: [.option, .shift])) }
        forcingDefaultBrowser = Self.isOptionCommand(flags)
        super.mouseDown(with: forcingDefaultBrowser ? Self.commandOnly(event) : event)
    }

    /// Ghostty opens a URL only for a click with exactly ⌘ (its `link-url` modifiers must equal
    /// the click's, so ⌥⌘ finds no link). ⌥⌘-click on a URL is the user's way to ask for the
    /// default browser, so Ghostty gets the click as a plain ⌘-click and `forcingDefaultBrowser`
    /// says where the URL goes.
    private static func isOptionCommand(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .option, .control, .shift]) == [.command, .option]
    }

    private static func commandOnly(_ event: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags.subtracting([.option, .shift, .control]),
                           timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                           clickCount: event.clickCount, pressure: event.pressure) ?? event
    }

    /// In a window that isn't key, AppKit hands a view only a plain ⌘-click; ⌥⌘- and ⇧⌘-clicks
    /// on a reference open it there too, and a ⌥⌘-click is always taken (it may be on a URL).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, Self.isOptionCommand(event.modifierFlags) { return true }
        if let event, event.modifierFlags.contains(.command), onReferenceClick != nil { return true }
        if let event, event.modifierFlags.contains(.command), linkAt?(convert(event.locationInWindow, from: nil)) != nil { return true }
        return super.acceptsFirstMouse(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        if swallowedMouseUp {
            swallowedMouseUp = false
            openingNewTile = false
            return
        }
        defer {
            forcingDefaultBrowser = false
            openingNewTile = false
        }
        super.mouseUp(with: forcingDefaultBrowser ? Self.commandOnly(event) : event)
    }

    /// Scrolling goes to the terminal (its scrollback, or a program that reads the wheel) except
    /// when it would pan over a code tile too: a horizontal-dominant step pans the canvas, and
    /// over a terminal without keyboard focus a vertical step pans unless the terminal has
    /// scrollback to scroll (a full-screen TUI in the alternate screen has none; click in first).
    override func scrollWheel(with event: NSEvent) {
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if horizontal || (window?.firstResponder !== self && hasScrollback?() != true) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil), command: event.modifierFlags.contains(.command))
    }

    /// How long the key waited in the event queue for the main thread (`event.timestamp` is the
    /// press, on the uptime clock) and how long handing it to Ghostty's key handler took: summed
    /// in `KeyLatency` here (six numbers, no lock, no allocation) and handed to `Metrics` once a
    /// second by one long-lived timer (`MainMetricsBatch`), for `easl metrics` "keys". A
    /// main-thread stall holds every key typed during it and releases them together, late and in
    /// order; a long wait here is the board's doing, upstream of the terminal, zmx and the
    /// program. `key.handle` ends at the hand-over: Ghostty queues the PTY write for its IO
    /// thread, which this doesn't see, and a consumed binding or a composing IME key writes
    /// nothing at all.
    override func keyDown(with event: NSEvent) {
        onUserInput?()
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.charactersIgnoringModifiers?.lowercased() == "v" {
            if !event.isARepeat { pasteKeyUp = nil }
            if modifiers == [.command] || modifiers == [.control] {
                if pasteImages(from: .general, imageOnly: modifiers == [.control]) {
                    pasteKeyUp = event.keyCode
                    return
                }
                if modifiers == [.command], activeInput != nil {
                    pasteKeyUp = event.keyCode
                    if let text = TerminalPasteboardContent.text() { enqueue(.text(text)) }
                    return
                }
            }
        }
        if activeInput != nil {
            enqueue(.key(event))
            return
        }
        let waited = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
        let start = Metrics.now()
        super.keyDown(with: event)
        let handled = (Metrics.now() - start) * 1000
        MainMetricsBatch.shared.latency.add(waitMs: waited, handleMs: handled)
    }

    override func keyUp(with event: NSEvent) {
        if pasteKeyUp == event.keyCode {
            pasteKeyUp = nil
            return
        }
        if activeInput != nil { enqueue(.key(event)) } else { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if activeInput != nil { enqueue(.key(event)) } else { super.flagsChanged(with: event) }
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), command: event.modifierFlags.contains(.command))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(nil)
    }

    private func updateHover(at point: NSPoint, command: Bool) {
        setHover(command && bounds.contains(point) ? linkAt?(point) : nil)
        if hovered != nil { NSCursor.pointingHand.set() }
    }

    private func setHover(_ hit: TerminalReferences.Hit?) {
        guard hit != hovered else { return }
        hovered = hit
        onHover?(hit)
    }
}

extension TerminalSurface {
    /// Ghostty's handle for this surface, for its public C API where libghostty-spm has no
    /// wrapper. The wrapper keeps it private, so it's taken by reflection; nil if a package
    /// update renames it.
    var handle: ghostty_surface_t? {
        Mirror(reflecting: self).children.first(where: { $0.label == "surface" })?.value as? ghostty_surface_t
    }

    /// The text of viewport row `row`, `columns` cells wide. libghostty-spm reads a grid's text
    /// only for its in-memory backend (`InMemoryTerminalSession.readViewportText`); for exec
    /// surfaces it's read through Ghostty's C API the same way.
    func viewportRow(_ row: Int, columns: Int) -> String? {
        guard row >= 0, columns > 0, let handle else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(columns - 1), y: UInt32(row)),
            rectangle: false)
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(handle, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(handle, &out) }
        guard let text = out.text, out.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(out.text_len)), as: UTF8.self)
    }
}

/// Underlines the hovered reference over the terminal; transparent to the mouse.
@MainActor
final class TerminalLinkUnderline: NSView {
    var rects: [NSRect] = [] { didSet { if rects != oldValue { needsDisplay = true } } }
    var color: NSColor = .labelColor

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        rects.forEach { $0.fill() }
    }
}

/// Main-actor metrics summed without a lock and handed to Metrics once a second: the key batch
/// (`KeyLatency`) and the terminal redraw count. One repeating main-queue timer costs a wakeup a
/// second and nothing on the key or draw path; `flush` also runs before an `app.metrics` snapshot
/// or reset (so a key typed before a reset lands in its own epoch) and logs once when keys
/// waited 50 ms or more.
@MainActor
final class MainMetricsBatch {
    static let shared = MainMetricsBatch()
    var latency = KeyLatency()
    var draws = 0
    private var timer: DispatchSourceTimer?

    private init() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { MainActor.assumeIsolated { MainMetricsBatch.shared.flush() } }
        timer.resume()
        self.timer = timer
        Metrics.flushBeforeSnapshot = { MainMetricsBatch.shared.flush() }
    }

    /// Called once at launch so the timer and the snapshot hook exist before the first key.
    func start() {}

    func flush() {
        if draws > 0 {
            Metrics.shared.record("terminal.draw", count: draws)
            draws = 0
        }
        let batch = latency.flush()
        guard !batch.isEmpty else { return }
        Metrics.shared.record("key.wait", batchMs: batch.waitMs, maxMs: batch.waitMaxMs, count: batch.keys)
        Metrics.shared.record("key.handle", batchMs: batch.handleMs, maxMs: batch.handleMaxMs, count: batch.keys)
        if batch.late > 0 {
            NSLog("easl: %d of %d keys waited %.0f ms or more for the main thread (longest %.0f ms)", batch.late, batch.keys, KeyLatency.lateMs, batch.waitMaxMs)
        }
    }
}
