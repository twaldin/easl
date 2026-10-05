import AppKit
import CanvasCore

/// What a code view offers the language features. Implemented by code tiles.
@MainActor
protocol CodeNavigationHost: AnyObject {
    /// Board-relative path of the file shown.
    var navigationPath: String { get }
    /// The view showing the code; hover, ⌘-click, and right-click are handled over it.
    var navigationView: NSView { get }
    /// Height of one row, so panels open just below the hovered line.
    var navigationLineHeight: CGFloat { get }
    /// Source position under `point` (in `navigationView`'s coordinates): 1-based line,
    /// 0-based UTF-16 column on the current side; nil over peeked base rows and gutters.
    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)?
    /// The http(s) URL written under `point` (in `navigationView`'s coordinates), if any.
    func webLink(atViewPoint point: NSPoint) -> URL?
    /// Scrolls a 1-based source line into view.
    func reveal(line: Int)
}

/// Language features for one code view, answered by the app's shared language servers:
///  - hover (pointer still for ~500 ms) shows the server's hover docs; moving cancels the request
///  - ⌘-click goes to the definition: this tile re-aims when it is plain navigation surface
///    and the definition is in its file, else a plain tile in view showing the file, else a new
///    tile beside it (`Board.openForNavigation`); ⌥⌘-click always opens a new tile
///  - without the language's server, definitions, references and the outline come from text
///    search and tree-sitter (`TextNavigation`), labelled so
///  - the context menu adds Go to Definition, Find References, and Outline
///  - the Outline button lists the file's symbols; choosing one reveals it
/// Code tiles never take keyboard focus, so nothing here does either.
@MainActor
final class CodeNavigation: NSObject {
    /// Shared by every code view in the app (one server per language and project root).
    nonisolated static let languages = LanguageService()

    /// App quit waits for the language servers to be gone (SIGKILL after 2 s), so none outlives
    /// the app. Returns `.terminateLater` while they're ending and replies when they have.
    static func terminateServers() -> NSApplication.TerminateReply {
        guard languages.liveProcessCount > 0 else { return .terminateNow }
        Task.detached {
            await languages.terminateAll(grace: .seconds(2))
            // While termination is deferred the main run loop runs only in the modal-panel mode,
            // which doesn't service the main queue (so not MainActor jobs either).
            RunLoop.main.perform(inModes: [.modalPanel, .default]) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    private static let hoverDelay: TimeInterval = 0.5
    private static let controllers = NSHashTable<CodeNavigation>.weakObjects()
    private static var monitor: Any?

    private weak var host: CodeNavigationHost?
    private weak var codeView: NSView?
    private let board: Board
    private let tile: ObjectID

    /// Hover timing without a timer per mouse move: moves only stamp `lastMove`; one pending
    /// perform re-arms itself until the pointer has been still for `hoverDelay`.
    private var lastMove: TimeInterval = 0
    private var hoverScheduled = false
    private var pointer: NSPoint?
    private var hoverTask: Task<Void, Never>?
    /// What the visible hover describes, so moving within it keeps it open.
    private var hoverShown: (position: LSPPosition, range: LSPRange?)?
    private var hoverPanel: NavigationPanel?
    /// Bumped whenever hover work is cancelled, so a late answer can't show a stale hover.
    private var hoverGeneration = 0
    /// The list or message panel this view opened.
    private weak var panel: NavigationPanel?
    private var observingTileFrame = false
    private var lease: DocumentLease?
    /// Where a context menu was opened, for its actions.
    private var menuContext: (position: (line: Int, character: Int)?, anchor: NSPoint)?
    private var actionTask: Task<Void, Never>?

    /// `accessories` is the host's header: the Outline button goes at its top right, inside the
    /// trailing `reservedWidth` points the host keeps free.
    init(host: CodeNavigationHost, board: Board, tile: ObjectID, accessories: NSView, reservedWidth: CGFloat) {
        self.host = host
        self.board = board
        self.tile = tile
        let codeView = host.navigationView
        self.codeView = codeView
        super.init()
        setActive(true)
        installOutlineButton(in: accessories, reservedWidth: reservedWidth)
        Self.controllers.add(self)
        Self.installMonitor()
    }

    private var hoverArea: NSTrackingArea?

    /// Hover tracking exists only while the host's view is live: a tracking area on a tile the
    /// canvas has zoomed out or scrolled away is rebuilt on every frame of a pan.
    func setActive(_ active: Bool) {
        guard active != (hoverArea != nil), let codeView else { return }
        if active {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            codeView.addTrackingArea(area)
            hoverArea = area
        } else if let hoverArea {
            codeView.removeTrackingArea(hoverArea)
            self.hoverArea = nil
            dismissAll()
        }
    }

    private var file: URL? {
        host.map { board.absoluteURL($0.navigationPath) }
    }

    // MARK: Hover

    // Tracking areas send `mouseMoved:`/`mouseEntered:`/`mouseExited:` to their owner. This class
    // isn't an NSResponder, so Swift would name these `mouseMovedWith:` etc. and hover never fired.
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
        guard let codeView, event.window === codeView.window else { return }
        pointer = event.locationInWindow
        if let hoverPanel, hoverPanel.superview != nil {
            if hoverPanel.contains(windowPoint: event.locationInWindow, in: event.window) { return }
            if let shown = hoverShown, let position = position(atWindowPoint: event.locationInWindow), covers(shown, position) { return }
            dismissHover()
        }
        hoverTask?.cancel()
        hoverTask = nil
        lastMove = ProcessInfo.processInfo.systemUptime
        guard !hoverScheduled else { return }
        hoverScheduled = true
        perform(#selector(hoverDue), with: nil, afterDelay: Self.hoverDelay)
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        cancelPendingHover()
        if let hoverPanel, hoverPanel.contains(windowPoint: event.locationInWindow, in: event.window) { return }
        dismissHover()
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {}

    /// The host scrolled or showed new content (a re-aim, a reload): panels point at what was
    /// there.
    func contentChanged() {
        dismissAll()
    }

    /// The tile moved, was resized, hidden, re-aimed, or removed: nothing shown or pending is
    /// about what's on screen anymore.
    @objc private func dismissAll() {
        cancelPendingHover()
        dismissHover()
        actionTask?.cancel()
        actionTask = nil
        panel?.dismiss()
    }

    private func cancelPendingHover() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hoverDue), object: nil)
        hoverScheduled = false
        hoverTask?.cancel()
        hoverTask = nil
        hoverGeneration += 1
    }

    @objc private func hoverDue() {
        let still = ProcessInfo.processInfo.systemUptime - lastMove
        guard still >= Self.hoverDelay else {
            perform(#selector(hoverDue), with: nil, afterDelay: Self.hoverDelay - still)
            return
        }
        hoverScheduled = false
        guard let pointer, let codeView, let file, let position = position(atWindowPoint: pointer) else { return }
        let anchor = codeView.convert(pointer, from: nil)
        let root = board.root
        lease(file)
        let generation = hoverGeneration
        hoverTask = Task { [weak self] in
            let hover = try? await Self.languages.hover(file: file, boardRoot: root, at: position)
            guard let self, let hover, !Task.isCancelled, self.hoverGeneration == generation else { return }
            self.showHover(hover, at: position, anchor: anchor)
        }
    }

    /// Shows hover docs for `position` below `anchor` (in the text view's coordinates).
    private func showHover(_ hover: LSPHover, at position: LSPPosition, anchor: NSPoint) {
        guard let codeView else { return }
        let panel = NavigationPanel.hover(hover.markdown)
        panel.onPointerExit = { [weak self, weak panel] in
            guard let self, let panel, self.hoverPanel === panel else { return }
            self.dismissHover()
        }
        panel.show(below: anchor, lineHeight: lineHeight, in: codeView)
        observeTileFrame(codeView)
        hoverPanel = panel
        hoverShown = (position, hover.range)
    }

    private func dismissHover() {
        hoverPanel?.dismiss()
        hoverPanel = nil
        hoverShown = nil
    }

    private func covers(_ shown: (position: LSPPosition, range: LSPRange?), _ position: LSPPosition) -> Bool {
        shown.range?.contains(position) ?? (shown.position == position)
    }

    private func position(atWindowPoint point: NSPoint) -> LSPPosition? {
        guard let host, let codeView else { return nil }
        let local = codeView.convert(point, from: nil)
        guard codeView.visibleRect.contains(local), let position = host.sourcePosition(atViewPoint: local) else { return nil }
        return LSPPosition(line: position.line - 1, character: position.character)
    }

    private var lineHeight: CGFloat {
        host?.navigationLineHeight ?? 18
    }

    // MARK: Definition and references

    /// ⌘-click (⌥⌘-click with `newTile`) at a point in the text view.
    func goToDefinition(atViewPoint point: NSPoint, newTile: Bool) {
        guard let host, let position = host.sourcePosition(atViewPoint: point) else { return }
        goToDefinition(at: position, anchor: point, newTile: newTile)
    }

    func goToDefinition(at position: (line: Int, character: Int), anchor: NSPoint, newTile: Bool) {
        run(anchor: anchor) { [weak self] file, root in
            guard let locations = try await Self.serverAnswer({
                try await Self.languages.definition(file: file, boardRoot: root, at: LSPPosition(line: position.line - 1, character: position.character))
            }, else: { try await self?.textDefinition(at: position, file: file, root: root, anchor: anchor, newTile: newTile, reason: $0) }), let self else { return }
            switch locations.count {
            case 0: await self.showEmpty("No definition found", file: file, root: root, anchor: anchor)
            case 1: self.open(locations[0], newTile: newTile)
            default:
                let lines = await Self.languages.lineTexts(locations)
                self.showLocations("\(locations.count) definitions", locations, lines: lines, anchor: anchor, newTile: newTile)
            }
        }
    }

    /// The references as a keyboard list (type to filter, ↑/↓, Return opens one, ⌘↩ Open All,
    /// Esc closes), each line once: servers list a line twice (a re-export's two names).
    func findReferences(at position: (line: Int, character: Int), anchor: NSPoint) {
        showMessage("Finding references…", anchor: anchor)
        run(anchor: anchor) { [weak self] file, root in
            guard let answer = try await Self.serverAnswer({
                try await Self.languages.references(file: file, boardRoot: root, at: LSPPosition(line: position.line - 1, character: position.character))
            }, else: { try await self?.textReferences(at: position, file: file, root: root, anchor: anchor, reason: $0) }), let self else { return }
            var seen = Set<String>()
            let locations = answer.filter { seen.insert("\($0.url.resolvingSymlinksInPath().path):\($0.range.start.line)").inserted }
            guard !locations.isEmpty else { return await self.showEmpty("No references found", file: file, root: root, anchor: anchor) }
            let lines = await Self.languages.lineTexts(locations)
            let name = await self.identifier(at: position, file: file)
            let title = locations.count == 1 ? "1 reference" : "\(locations.count) references"
            self.showLocations(title, locations, lines: lines, anchor: anchor, newTile: false,
                               openAll: ("Open All ⌘↩", { [weak self] in self?.openAll(locations, name: name) }))
        }
    }

    private func showLocations(_ title: String, _ locations: [LSPLocation], lines: [String], anchor: NSPoint, newTile: Bool,
                               openAll: (title: String, run: @MainActor () -> Void)? = nil, note: String? = nil) {
        let rows = zip(locations, lines).map { location, line in
            NavigationPanel.Row(title: "\(board.relativePath(location.url.path)):\(location.range.start.line + 1)", detail: line) { [weak self] in
                NavigationPanel.current?.dismiss()
                self?.open(location, newTile: newTile)
            }
        }
        present(NavigationPanel.filterList(title: title, rows: rows, headerAction: openAll, note: note), anchor: anchor)
    }

    // MARK: Without a language server

    /// `request`'s answer; nil after `fallback` ran with the one-line reason when the language's
    /// server can't answer: it isn't installed, has no configuration, failed to start, or exited.
    /// Anything else (a timeout, the server's own error) is thrown, to be shown as it is.
    private static func serverAnswer<T>(_ request: () async throws -> T, else fallback: (String) async throws -> Void) async throws -> T? {
        do {
            return try await request()
        } catch let error as LSPError {
            switch error {
            case .unavailable, .unsupportedLanguage, .startFailed, .serverExited:
                try await fallback(error.errorDescription ?? "")
                return nil
            default: throw error
            }
        }
    }

    /// The name under the cursor (the file read off the main actor), or nil when there is none.
    private func identifier(at position: (line: Int, character: Int), file: URL) async -> String? {
        await offPool { Self.identifier(in: file, line: position.line, character: position.character) }
    }

    /// Where a text search's match is, as a location the lists and Open All take.
    nonisolated private static func location(_ match: TextNavigation.Match, in root: URL) -> LSPLocation {
        let position = LSPPosition(line: match.line - 1, character: max(0, match.column - 1))
        return LSPLocation(url: root.appendingPathComponent(match.path), range: LSPRange(start: position, end: position))
    }

    /// Go to Definition without a language server: the likely declarations of the name under the
    /// cursor (`TextNavigation.declarations`), this file's first; one opens, several list, each
    /// labelled as a text search with the server's hint as a note.
    private func textDefinition(at position: (line: Int, character: Int), file: URL, root: URL, anchor: NSPoint, newTile: Bool, reason: String) async throws {
        guard let name = await identifier(at: position, file: file) else { return showMessage(reason, anchor: anchor) }
        let searchRoot = TextNavigation.searchRoot(for: file, boardRoot: root)
        let relative = String(file.resolvingSymlinksInPath().path.dropFirst(searchRoot.path.count + 1))
        let found = try await TextNavigation.declarations(of: name, in: searchRoot, preferring: relative)
        try Task.checkCancellation()
        let locations = found.map { Self.location($0, in: searchRoot) }
        switch locations.count {
        case 0: showMessage("No declaration of \(name) found by text search (no language server). \(reason)", anchor: anchor)
        case 1: open(locations[0], newTile: newTile)
        default:
            showLocations("\(locations.count) likely declarations of \(name) · text search, no language server", locations,
                          lines: found.map { $0.text.trimmingCharacters(in: .whitespaces) }, anchor: anchor, newTile: newTile, note: reason)
        }
    }

    /// Find References without a language server: the lines of the root's files with the name as
    /// a whole word (`TextNavigation.wordMatches`), labelled text matches, with Open All.
    private func textReferences(at position: (line: Int, character: Int), file: URL, root: URL, anchor: NSPoint, reason: String) async throws {
        guard let name = await identifier(at: position, file: file) else { return showMessage(reason, anchor: anchor) }
        let searchRoot = TextNavigation.searchRoot(for: file, boardRoot: root)
        let (matches, truncated) = try await TextNavigation.wordMatches(name, in: searchRoot)
        try Task.checkCancellation()
        guard !matches.isEmpty else { return showMessage("No text matches for \(name) (no language server). \(reason)", anchor: anchor) }
        let locations = matches.map { Self.location($0, in: searchRoot) }
        let count = truncated ? "First \(matches.count)" : "\(matches.count)"
        let title = "\(count) text \(matches.count == 1 ? "match" : "matches") for \(name) · no language server"
        showLocations(title, locations, lines: matches.map { $0.text.trimmingCharacters(in: .whitespaces) }, anchor: anchor, newTile: false,
                      openAll: ("Open All ⌘↩", { [weak self] in self?.openAll(locations, name: name) }), note: reason)
    }

    /// Outline without a language server: tree-sitter's declarations and the file's top-level
    /// ones by pattern (`TextNavigation.outline`).
    private func textOutline(file: URL, anchor: NSPoint, reason: String) async {
        let path = file.path
        let entries = await offPool { () -> [TextNavigation.OutlineEntry] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return TextNavigation.outline(of: text, path: path)
        }
        guard !Task.isCancelled else { return }
        guard !entries.isEmpty else { return showMessage("No symbols found without a language server. \(reason)", anchor: anchor) }
        showOutline("Outline · from syntax, no language server", entries.map { ($0.name, $0.kind, $0.line, $0.depth) }, anchor: anchor, note: reason)
    }

    /// An outline as a keyboard list (`name`, `kind · L<line>`, indented by `depth`); choosing a
    /// symbol reveals its line.
    private func showOutline(_ title: String, _ entries: [(name: String, kind: String, line: Int, depth: Int)], anchor: NSPoint, note: String? = nil) {
        let rows = entries.map { entry in
            NavigationPanel.Row(title: entry.name, detail: "\(entry.kind) · L\(entry.line)", indent: entry.depth) { [weak self] in
                NavigationPanel.current?.dismiss()
                self?.host?.reveal(line: entry.line)
            }
        }
        present(NavigationPanel.filterList(title: title, rows: rows, note: note), anchor: anchor)
    }

    /// Lines of context above and below each reference in an Open All layout.
    private static let referenceContext = 3

    /// Find References → Open All: one captioned code tile per reference (the reference line
    /// with `referenceContext` lines around it), in one group beside this tile, as one undo step,
    /// panned into view.
    private func openAll(_ locations: [LSPLocation], name: String?) {
        NavigationPanel.current?.dismiss()
        let root = board.root
        let entries = locations.map { (path: board.relativePath($0.url.path), line: $0.range.start.line + 1, url: $0.url) }
        let subject = name.map { " to `\($0)`" } ?? ""
        Task { [weak self] in
            let urls = Array(Set(entries.map(\.url)))
            let lineCounts = await offPool {
                Dictionary(uniqueKeysWithValues: urls.map { url in
                    (url, (try? String(contentsOf: url, encoding: .utf8)).map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? Int.max)
                })
            }
            var excerpts: [CodeExcerpt] = []
            for (index, entry) in entries.enumerated() {
                let last = max(entry.line, lineCounts[entry.url] ?? Int.max)
                let lines = LineRange(start: max(1, entry.line - Self.referenceContext), end: min(last, entry.line + Self.referenceContext))
                let caption = "Reference \(index + 1) of \(entries.count)\(subject) · L\(entry.line)"
                let props: JSONValue = .object(["path": .string(entry.path), "caption": .string(caption), "range": lines.json])
                let size = (try? await ObjectMeasure.size(type: .code, props: props, width: nil, root: root)) ?? CGSize(width: Board.defaultSize(.code).w, height: 220)
                excerpts.append(CodeExcerpt(path: entry.path, lines: lines, caption: caption, size: size))
            }
            let title = "\(entries.count == 1 ? "1 reference" : "\(entries.count) references")\(name.map { " to \($0)" } ?? "")"
            guard let self, let opened = try? self.board.openExcerpts(excerpts, title: title, beside: self.tile) else { return }
            // The least pan that shows the first reference (the group's title sits just above it);
            // a long list runs on below and to the right. One step of Navigate Back.
            guard let canvas = self.canvas else { return }
            canvas.navigating {
                canvas.reveal(opened.tiles[0])
                return nil
            }
        }
    }

    /// The identifier at a 1-based line and UTF-16 column of a file, for titles. Blocking: call
    /// through `offPool`.
    nonisolated private static func identifier(in file: URL, line: Int, character: Int) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.indices.contains(line - 1) else { return nil }
        let units = Array(lines[line - 1].utf16)
        func isWord(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        var start = min(max(0, character), units.count), end = start
        while start > 0, isWord(units[start - 1]) { start -= 1 }
        while end < units.count, isWord(units[end]) { end += 1 }
        guard end > start else { return nil }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    /// An empty answer while the server is still loading or indexing the project (sourcekit-lsp
    /// answers from fallback settings and an empty index until then) says so, instead of
    /// claiming there is nothing.
    private func showEmpty(_ text: String, file: URL, root: URL, anchor: NSPoint) async {
        let server = await Self.languages.existingServer(for: file, boardRoot: root)
        let busy = await server?.activity ?? []
        if !busy.isEmpty { return showMessage("\(text) yet — \(busy.joined(separator: ", ")) in progress", anchor: anchor) }
        showMessage([text, server?.config.emptyResultHint].compactMap { $0 }.joined(separator: ". "), anchor: anchor)
    }

    /// A definition, near this tile and never re-aiming someone else's (`Board.openForNavigation`):
    /// a tile already showing it (exactly, or a captioned stop whose range holds it) anywhere,
    /// gone to (this tile scrolls to it when that's this one); else this tile when it is plain
    /// navigation surface and the definition is in its file, else a plain tile in view showing
    /// that file, else a new tile beside this one, shown with the least pan that keeps this one
    /// in view. `newTile` (⌥⌘) always opens a new tile. One step of Navigate Back.
    private func open(_ location: LSPLocation, newTile: Bool) {
        let aim = CodeAim(path: board.relativePath(location.url.path), range: location.range.lines)
        let board = board, tile = tile
        let go = { [weak self] () -> CodeReaim? in
            var opened = CodeOpened(id: tile, created: false, reaim: nil)
            if newTile {
                let size = Board.defaultSize(.code)
                opened.id = board.create(type: .code, props: .object(["path": .string(aim.path), "range": location.range.lines.json]),
                                         frame: board.place(width: size.w, height: size.h, near: tile)).id
            } else {
                opened = board.openForNavigation(aim, from: tile)
            }
            if opened.existing, opened.id == tile {
                self?.host?.reveal(line: location.range.lines.start)
            } else if opened.existing {
                self?.canvas?.goToShown(opened.id)
            } else if opened.id != tile {
                self?.canvas?.reveal(opened.id, keeping: tile)
            }
            return opened.reaim
        }
        guard let canvas else {
            _ = go()
            return
        }
        canvas.navigating(landing: aim, go)
    }

    /// The canvas this code view is on.
    private var canvas: CanvasView? {
        codeView.flatMap { sequence(first: $0, next: \.superview).first { $0 is CanvasView } as? CanvasView }
    }

    // MARK: Outline

    private func installOutlineButton(in container: NSView, reservedWidth: CGFloat) {
        let button = OutlineButton(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Outline") ?? NSImage(), target: self, action: #selector(outlineClicked(_:)))
        button.toolTip = "Outline"
        button.onDetach = { [weak self] in self?.dismissAll() }
        let size: CGFloat = 20
        let top = container.isFlipped ? 3 : container.bounds.height - size - 3
        let inset = min(8, max(0, (reservedWidth - size) / 2))
        button.frame = NSRect(x: container.bounds.width - size - inset, y: top, width: size, height: size)
        button.autoresizingMask = container.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        container.addSubview(button)
    }

    @objc private func outlineClicked(_ sender: NSButton) {
        guard let codeView else { return }
        let anchor = codeView.convert(NSPoint(x: sender.frame.maxX, y: sender.frame.midY), from: sender.superview)
        showOutline(anchor: NSPoint(x: max(0, anchor.x - 240), y: anchor.y))
    }

    /// Top-level symbols and the members of types (not locals), filtered as the user types.
    func showOutline(anchor: NSPoint) {
        run(anchor: anchor) { [weak self] file, root in
            guard let answer = try await Self.serverAnswer({ try await Self.languages.documentSymbols(file: file, boardRoot: root) },
                                                           else: { await self?.textOutline(file: file, anchor: anchor, reason: $0) }), let self else { return }
            let symbols = LSPSymbol.outline(answer)
            guard !symbols.isEmpty else { return self.showMessage("No symbols", anchor: anchor) }
            // LSP has no macro, trait or impl kinds: rust-analyzer sends `macro_rules!` as a
            // function, a trait as an interface and an impl block as an object. The declaring
            // line names them as the text outline does.
            let lines = await offPool { (try? String(contentsOf: file, encoding: .utf8)).map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? [] }
            let precise = ["function": "macro", "interface": "trait", "object": "impl"]
            func kind(_ symbol: LSPSymbol) -> String {
                let line = symbol.selectionRange.start.line
                guard let exact = precise[symbol.kindName], lines.indices.contains(line), DeclarationKeywords.kind(declaredBy: String(lines[line])) == exact else { return symbol.kindName }
                return exact
            }
            self.showOutline("Outline", symbols.map { ($0.symbol.name, kind($0.symbol), $0.symbol.selectionRange.start.line + 1, $0.depth) }, anchor: anchor)
        }
    }

    // MARK: Context menu

    /// The context menu a right-click `event` over a code view shows (input replay performs its
    /// items: a shown menu's tracking loop ignores posted events).
    static func menu(for event: NSEvent) -> NSMenu? {
        controller(at: event)?.menu(for: event)
    }

    /// The controller whose code view is under `event`.
    private static func controller(at event: NSEvent) -> CodeNavigation? {
        guard let contentView = event.window?.contentView,
              let hit = contentView.hitTest(contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) else { return nil }
        return controllers.allObjects.first { $0.codeView.map { hit.isDescendant(of: $0) } ?? false }
    }

    private func menu(for event: NSEvent) -> NSMenu? {
        guard let host, let codeView else { return nil }
        let point = codeView.convert(event.locationInWindow, from: nil)
        let position = host.sourcePosition(atViewPoint: point)
        menuContext = (position, point)
        // Build on the view's own menu (copied: AppKit shares it) so its items stay available.
        let menu = (codeView.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        var items: [NSMenuItem] = []
        if position != nil {
            items.append(NSMenuItem(title: "Go to Definition", action: #selector(menuDefinition), keyEquivalent: ""))
            items.append(NSMenuItem(title: "Open Definition in New Tile", action: #selector(menuDefinitionNewTile), keyEquivalent: ""))
            items.append(NSMenuItem(title: "Find References", action: #selector(menuReferences), keyEquivalent: ""))
        }
        items.append(NSMenuItem(title: "Outline", action: #selector(menuOutline), keyEquivalent: ""))
        if menu.numberOfItems > 0 { items.append(.separator()) }
        for (index, item) in items.enumerated() {
            item.target = self
            menu.insertItem(item, at: index)
        }
        return menu
    }

    @objc private func menuDefinition() {
        guard let context = menuContext, let position = context.position else { return }
        goToDefinition(at: position, anchor: context.anchor, newTile: false)
    }

    @objc private func menuDefinitionNewTile() {
        guard let context = menuContext, let position = context.position else { return }
        goToDefinition(at: position, anchor: context.anchor, newTile: true)
    }

    @objc private func menuReferences() {
        guard let context = menuContext, let position = context.position else { return }
        findReferences(at: position, anchor: context.anchor)
    }

    @objc private func menuOutline() {
        guard let context = menuContext else { return }
        showOutline(anchor: context.anchor)
    }

    // MARK: Plumbing

    /// Runs one explicit action (superseding the previous one and any hover) and shows its
    /// failure where it was asked for: an uninstalled or crashed server is reported, not swallowed.
    private func run(anchor: NSPoint, _ action: @escaping @MainActor (URL, URL) async throws -> Void) {
        cancelPendingHover()
        dismissHover()
        guard let file else { return }
        let root = board.root
        lease(file)
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            do {
                try await action(file, root)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.showMessage((error as? LocalizedError)?.errorDescription ?? "\(error)", anchor: anchor)
            }
        }
    }

    func showMessage(_ text: String, anchor: NSPoint) {
        present(NavigationPanel.message(text), anchor: anchor)
    }

    /// Shows `panel` below `anchor`. A list takes the keyboard until it closes: the user asked for it.
    private func present(_ panel: NavigationPanel, anchor: NSPoint) {
        guard let codeView else { return }
        panel.show(below: anchor, lineHeight: lineHeight, in: codeView)
        observeTileFrame(codeView)
        self.panel = panel
        panel.focusFilter()
    }

    /// Panels sit in the canvas document, not the tile, so a moved or resized tile would leave
    /// them behind: dismiss them when the tile's frame changes.
    private func observeTileFrame(_ codeView: NSView) {
        guard !observingTileFrame,
              let tileView = sequence(first: codeView, next: \.superview).first(where: { $0.superview is CanvasDocumentView }) else { return }
        observingTileFrame = true
        NotificationCenter.default.addObserver(self, selector: #selector(dismissAll), name: NSView.frameDidChangeNotification, object: tileView)
    }

    /// Keeps the shown file open in its language server (re-synced before each request) while
    /// this view shows it.
    private func lease(_ file: URL) {
        guard lease?.file != file else { return }
        lease = DocumentLease(file: file, root: board.root)
    }

    /// The http(s) URL written under a click.
    private func webLink(at event: NSEvent) -> URL? {
        guard let host, let codeView else { return nil }
        let point = codeView.convert(event.locationInWindow, from: nil)
        return codeView.visibleRect.contains(point) ? host.webLink(atViewPoint: point) : nil
    }

    /// A clicked URL: in a browser tile beside this code tile (`Board.openLink`; one already
    /// showing it is reused), shown like any link the user followed, or in the default browser.
    private func open(_ url: URL, inDefaultBrowser: Bool) {
        if inDefaultBrowser {
            ExternalOpen.open(url, because: "code \(tile) link (⌥-click)")
            return
        }
        let opened = board.openLink(url, near: tile, caller: nil)
        NSLog("easl: code %@ link %@ → %@ %@", tile, url.absoluteString, opened.existing ? "existing browser tile" : "new browser tile", opened.object.id)
        canvas?.showOpenedLink(opened.object.id, openedFrom: tile)
    }

    /// One app-level monitor for every code view: ⌘/⌥⌘-click and right-click on a host's text
    /// view, and closing a list panel on any click outside it. Hyper (which includes ⌃) is left
    /// to the HyperMonitor. A web URL in the text takes the ⌘-click before go-to-definition does
    /// (a browser tile beside the code; ⌥⌘- and ⌥-click: the default browser).
    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handle(event) ? nil : event
        }
    }

    /// True when the event was consumed.
    private static func handle(_ event: NSEvent) -> Bool {
        if let panel = NavigationPanel.current, !panel.contains(windowPoint: event.locationInWindow, in: event.window) {
            panel.dismiss()
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.contains(.control), let controller = controller(at: event), let codeView = controller.codeView else { return false }
        let linkClicks: [NSEvent.ModifierFlags] = [[.command], [.command, .option], [.option]]
        if event.type == .leftMouseDown, linkClicks.contains(flags), let link = controller.webLink(at: event) {
            controller.open(link, inDefaultBrowser: flags.contains(.option))
            return true
        }
        switch (event.type, flags) {
        case (.leftMouseDown, [.command]), (.leftMouseDown, [.command, .option]):
            controller.goToDefinition(atViewPoint: codeView.convert(event.locationInWindow, from: nil), newTile: flags.contains(.option))
            return true
        case (.rightMouseDown, []):
            if let menu = controller.menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: codeView) }
            return true
        default:
            return false
        }
    }
}

/// The outline button over a code view: works on the first click into a background window and
/// never takes keyboard focus.
private final class OutlineButton: NSButton {
    /// The button lives inside the tile, so it learns when the tile leaves the window (deleted)
    /// or is hidden (zoomed out, offscreen).
    var onDetach: (() -> Void)?

    convenience init(image: NSImage, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        imagePosition = .imageOnly
        bezelStyle = .accessoryBarAction
        isBordered = true
        refusesFirstResponder = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDetach?() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        onDetach?()
    }
}

/// A code view's claim on its file in the language service. Retains and releases go through one
/// ordered stream (a release must never overtake its retain), and dropping the lease — a new
/// file, or the view going away — releases it.
private final class DocumentLease: Sendable {
    let file: URL
    let root: URL

    private static let changes: AsyncStream<(retain: Bool, file: URL, root: URL)>.Continuation = {
        let (stream, continuation) = AsyncStream.makeStream(of: (retain: Bool, file: URL, root: URL).self)
        Task {
            for await change in stream {
                if change.retain {
                    await CodeNavigation.languages.retain(file: change.file, boardRoot: change.root)
                } else {
                    await CodeNavigation.languages.release(file: change.file, boardRoot: change.root)
                }
            }
        }
        return continuation
    }()

    init(file: URL, root: URL) {
        self.file = file
        self.root = root
        Self.changes.yield((true, file, root))
    }

    deinit {
        Self.changes.yield((false, file, root))
    }
}
