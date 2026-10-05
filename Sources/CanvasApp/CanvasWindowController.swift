import AppKit
import CanvasCore

/// One window per board: the canvas scene plus the composer (the tray bar).
@MainActor
final class CanvasWindowController: NSWindowController, NSWindowDelegate {
    let board: Board
    let canvas: CanvasView
    private let tray: ComposerBar
    private let composer: ComposerController
    private let navigator = NavigatorPanel()
    private let nothingHere = NothingHerePill(frame: .zero)
    private let emptyHint = EmptyBoardHint()
    private let basics = BasicsPanel()
    private let getStarted = GetStartedPanel()
    /// The walk-through's progress while Get Started is open.
    private var guide: GetStarted.Progress?
    private let registry: BoardRegistry
    private var responderObservation: NSKeyValueObservation?
    private var drawing: ShapeLayer?

    /// The board in front: the frontmost visible board window, with tabs its selected tab (the
    /// others are ordered out). What menu commands and ⌘Z act on, also while a panel such as
    /// easl Basics is key or the app isn't active (replayed input).
    static var frontmost: CanvasWindowController? {
        NSApp.orderedWindows.lazy.compactMap { window -> CanvasWindowController? in
            guard window.isVisible, window.tabGroup.map({ $0.selectedWindow === window }) ?? true else { return nil }
            return window.windowController as? CanvasWindowController
        }.first
    }

    /// A repository board opened from one of its worktrees (`Board.opened(from:)`): the
    /// subtitle names that worktree and its branch, and the view goes to the worktree's region
    /// when it has one. Opened from the main checkout, the subtitle is the board root again.
    func showWorktree(openedAt directory: URL) {
        if let worktree = board.workingWorktree {
            window?.subtitle = "\(worktree.toplevel) · \(worktree.branch ?? "detached HEAD")"
        } else {
            window?.subtitle = board.root.path
        }
        guard let worktree = GitWorktree.containing(directory.standardizedFileURL.path), worktree.commonDir == board.repo?.commonDir,
              !worktree.isMain, let region = board.region(for: worktree) else { return }
        // On the next turn, once the window has laid the canvas out and after the board's own
        // opening view (`CanvasView.placeOpeningView`): the worktree's region wins over the saved view.
        DispatchQueue.main.async { [weak self] in self?.canvas.reveal(region) }
    }

    init(board: Board, registry: BoardRegistry) {
        self.board = board
        self.registry = registry
        canvas = CanvasView(board: board)
        let bar = ComposerBar(frame: .zero)
        tray = bar
        composer = ComposerController(board: board, bar: bar, file: AppPaths.composer(of: board.id))
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = board.root.lastPathComponent
        window.subtitle = board.root.path
        window.acceptsMouseMovedEvents = true
        window.setFrameAutosaveName("Canvas-\(board.id)")
        // Boards open as tabs of one window (AppDelegate.open adds them to the frontmost group).
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "net.waldin.easl.board"
        super.init(window: window)
        window.delegate = self
        // Terminal references by file name (`core.py:10`) resolve through the listing.
        BoardFiles.of(board.root).refresh()

        let container = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        tray.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)
        container.addSubview(tray)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tray.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            tray.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            // A prompt box's width up to the window's; its height is its own (one line, a few
            // while it has the keyboard: `ComposerBar.intrinsicContentSize`).
            tray.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            {
                let width = tray.widthAnchor.constraint(equalToConstant: 760)
                width.priority = NSLayoutConstraint.Priority(480)
                return width
            }(),
        ])
        window.contentView = container
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyHint)
        NSLayoutConstraint.activate([
            emptyHint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyHint.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyHint.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        drawing = ShapeLayer.install(on: canvas, toolbarIn: container)
        canvas.chromeInsets = { [weak container, weak tray, weak drawing, weak getStarted] in
            guard let container else { return NSEdgeInsets() }
            // The toolbar and tray sit at fixed offsets, so only a window never laid out needs a
            // pass here; attention pills ask on every pan step, sometimes from inside layout.
            if tray?.frame.isEmpty ?? false { container.layoutSubtreeIfNeeded() }
            let top = drawing?.toolbar.map { $0.isHidden ? 0 : container.bounds.maxY - $0.frame.minY } ?? 0
            let bottom = tray.map { $0.isHidden ? 0 : $0.frame.maxY } ?? 0
            // Get Started's fixed width at its fixed leading offset, laid out or not.
            let left = getStarted.map { $0.isOpen ? GetStartedPanel.leading + GetStartedPanel.width : 0 } ?? 0
            return NSEdgeInsets(top: top, left: left, bottom: bottom, right: 0)
        }
        // Edge pills with no clear stretch of the view's edge go to the toolbar row beside the
        // toolbar (`PillLayout`), which only the chrome uses.
        canvas.chromeBands = { [weak container, weak drawing] in
            guard let container, let toolbar = drawing?.toolbar, !toolbar.isHidden else { return [] }
            let bar = toolbar.frame, margin: CGFloat = 16
            return [NSRect(x: margin, y: bar.minY, width: bar.minX - 2 * margin, height: bar.height),
                    NSRect(x: bar.maxX + margin, y: bar.minY, width: container.bounds.maxX - bar.maxX - 2 * margin, height: bar.height)]
                .filter { $0.width > 0 }.map { container.convert($0, to: nil) }
        }
        canvas.onChromeHiddenChange = { [weak self] in
            guard let self else { return }
            self.drawing?.toolbar?.isHidden = self.canvas.chromeHidden
            self.tray.isHidden = self.canvas.chromeHidden
        }
        // Above the toolbar and tray, so the navigator is never covered.
        for view in [nothingHere, getStarted, basics, navigator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let navigatorWidth = navigator.widthAnchor.constraint(equalToConstant: 560)
        navigatorWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            nothingHere.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            nothingHere.bottomAnchor.constraint(equalTo: tray.topAnchor, constant: -10),
            navigator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            navigator.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            navigatorWidth,
            navigator.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        let basicsHeight = basics.heightAnchor.constraint(equalToConstant: 620)
        basicsHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            basics.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            basics.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            basics.widthAnchor.constraint(equalToConstant: BasicsPanel.width),
            basicsHeight,
            basics.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -64),
        ])
        NSLayoutConstraint.activate([
            getStarted.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            getStarted.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: GetStartedPanel.leading),
            getStarted.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -64),
        ])
        navigator.onGo = { [weak self] target in
            switch target {
            case .allContent: self?.canvas.zoomToFit()
            case .object(let id):
                self?.canvas.go(to: id)
                self?.selectGoToLines(nil, in: id)
            case .heading(let id, let line): self?.canvas.go(to: id, heading: line)
            case .file(let path, let lines):
                // Relative to the listed checkout (`Board.workingRoot`), as the board stores it.
                guard let board = self?.board else { return }
                let stored = board.relativePath(path.hasPrefix("/") ? path : board.workingRoot.appendingPathComponent(path).path)
                if let id = self?.open(path: stored, lines: lines) { self?.selectGoToLines(lines, in: id) }
            case .status: break
            }
        }
        navigator.searchSymbols = { [weak self] name in await self?.workspaceSymbols(named: name) ?? NavigatorPanel.SymbolAnswer(rows: []) }
        nothingHere.onBack = { [weak self] in self?.canvas.zoomToFit() }
        basics.onHideChrome = { [weak self] in self?.toggleCanvasChrome(nil) }
        getStarted.onClose = { [weak self] in self?.getStartedClosed() }
        getStarted.onNewTerminal = { [weak self] in self?.newTerminal(nil) }
        getStarted.onShowPractice = { [weak self] in self?.showPracticeNote() }
        canvas.onTab = { [weak self] backward in
            guard let getStarted = self?.getStarted, getStarted.isOpen else { return false }
            getStarted.takeKeyboard(backward: backward)
            return true
        }
        canvas.panelOpen = { [weak self] in self?.getStarted.isOpen ?? false }
        canvas.closePanel = { [weak self] in self?.getStarted.close() }
        canvas.onContentInViewChange = { [weak self] inView in self?.nothingHere.isHidden = inView }

        tray.onReveal = { [weak self] mention in self?.canvas.revealMention(mention.target) }
        tray.targetMenu = { [weak self] in self?.targetMenu() }
        NotificationCenter.default.addObserver(self, selector: #selector(chromeTextChanged), name: ChromeText.didChange, object: nil)
        tray.onFocusChange = { [weak self] in self?.refreshTray() }
        composer.promptTarget = { [weak self] in self?.canvas.promptTarget }
        composer.notice = { [weak self] text in self?.canvas.showNotice(text) }
        composer.name = { [weak self] id in self?.terminalName(id) ?? id }
        composer.onTargetsChange = { [weak self] in self?.refreshTray() }
        canvas.onPromptTargetChange = { [weak self] in self?.refreshTray() }
        canvas.onPromptTargetTitle = { [weak self] in self?.scheduleTrayTitle() }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
        }
        trayMentions = Set(board.tray.map(\.id))
        settlePromptTarget()
        refreshTray()
        refreshTab()
        refreshEmptyHint()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// The chrome text size changed: the composer redraws its text and tokens at it and takes
    /// its new height (`ComposerBar.intrinsicContentSize`).
    @objc private func chromeTextChanged() {
        tray.chromeTextChanged()
        refreshTray()
    }

    func apply(_ event: BoardEvent) {
        canvas.apply(event)
        drawing?.apply(event)
        switch event {
        case .trayChanged(let tray):
            retargetByWorktree(tray)
            composer.trayChanged()
            refreshTray()
        case .objectCreated, .objectDeleted:
            settlePromptTarget()
            composer.objectsChanged()
            refreshTray()
            refreshTab()
            refreshEmptyHint()
        case .objectUpdated(let object) where object.type == .terminal:
            // An agent starting or exiting in a terminal can move the target.
            settlePromptTarget()
            if composer.targets.contains(object.id) { refreshTray() }
            refreshTab()
        default: break
        }
    }

    /// The composer's terminals (`ComposerController.send`): `agent.prompt` from the user, set by
    /// the app with its router.
    var sendPrompt: ((_ text: String, _ terminal: ObjectID, _ mentions: [MentionTarget], _ answering: Bool) async throws -> Void)? {
        get { composer.send }
        set { composer.send = newValue }
    }

    /// ⌘I (Edit ▸ Write Prompt): the composer takes the keyboard, from anywhere on the board.
    @objc func focusComposer(_ sender: Any?) {
        if tray.isHidden { toggleCanvasChrome(nil) }
        tray.focus()
    }

    /// The composer's draft, history and targets are written now (window closing, app quitting).
    func saveComposer() {
        composer.save()
    }

    /// How the target menu and the composer name a terminal: as its header does.
    private func terminalName(_ id: ObjectID) -> String {
        guard let terminal = board.objects[id] else { return id }
        return board.terminalLabel?(id) ?? PromptTarget.label(terminal, shownTitle: canvas.tiles[id]?.title)
    }

    private func refreshTray() {
        trayTitleWork?.cancel()
        trayTitleWork = nil
        let target = canvas.promptTarget.flatMap { board.objects[$0] }
        func named(_ terminal: CanvasObject) -> KeyboardFocus.Named {
            KeyboardFocus.Named(terminal.id, name: PromptTarget.label(terminal, shownTitle: canvas.tiles[terminal.id]?.title))
        }
        var targetName = target.map(named)
        if let affinity, affinity.target == target?.id { targetName?.name += " · works in \(affinity.checkout)" }
        trayKeyboard = canvas.focusedTerminal
        let title = KeyboardFocus.trayTarget(targetName, keyboard: trayKeyboard.flatMap { board.objects[$0] }.map(named))
        let extra = composer.targets.dropFirst().map(terminalName)
        tray.showTarget(title: title, extra: Array(extra), hasTerminal: board.objects.values.contains { $0.type == .terminal })
        composer.refreshQuestion()
        refreshGetStarted(target: target)
    }

    /// The terminal with the keyboard when the tray last named it (`KeyboardFocus.trayTarget`).
    private var trayKeyboard: ObjectID?

    /// What the tab last showed (`NeedsYou`), so a terminal's frequent updates redraw nothing.
    private var tabState: NeedsYou?

    /// The board's tab says when an agent on it needs the user, so one waiting on a background
    /// tab is seen: an orange dot for a blocked agent, a quieter green one for an agent that
    /// finished unseen (`NeedsYou`); nothing for working or idle agents. The tooltip says who
    /// and what.
    private func refreshTab() {
        guard let window else { return }
        let state = NeedsYou.of(board.objects.values)
        guard state != tabState else { return }
        tabState = state
        guard let state else {
            window.tab.accessoryView = nil
            window.tab.toolTip = nil
            return
        }
        // An accessory view, not a colored title: the tab bar draws titles in its own color.
        let blocked = state.level == .blocked
        window.tab.accessoryView = TabDot(color: blocked ? .systemOrange : .systemGreen.withAlphaComponent(0.75), diameter: blocked ? 9 : 7)
        let label = state.terminals.count == 1 ? board.objects[state.terminals[0]].map { PromptTarget.label($0, shownTitle: canvas.tiles[$0.id]?.title) } ?? "An agent" : "\(state.terminals.count) agents"
        window.tab.toolTip = blocked ? "\(label) needs you\(state.message.map { ": \($0)" } ?? "")" : "\(label) finished (not seen yet)"
    }

    private var trayTitleWork: DispatchWorkItem?

    /// The target's shown title changed. An agent retitles its terminal many times a second (a
    /// spinner), so the tray catches up at most once a second.
    private func scheduleTrayTitle() {
        guard trayTitleWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.refreshTray() }
        trayTitleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// `PromptTarget`: the terminal picked from the tray's menu, else the last focused terminal
    /// running an agent, else the board's only agent terminal, else the last focused terminal,
    /// else the board's only one, so a lone agent never needs a click and an editor or shell
    /// opened beside an agent doesn't take its mentions. What it remembers is saved with the
    /// board (`Board.promptTarget`).
    private func settlePromptTarget() {
        board.promptTarget.prune(board.objects)
        let target = PromptTarget.choose(board.promptTarget, objects: board.objects)
        if canvas.promptTarget != target { canvas.promptTarget = target }
        if affinity?.target != target { affinity = nil }
    }

    /// The tray's target: the user picks the terminal mentions go to without leaving the page
    /// they're on; it stays the target until another terminal takes the keyboard.
    private func chooseTarget(_ id: ObjectID) {
        guard board.objects[id]?.type == .terminal else { return }
        board.promptTarget.choose(id)
        settlePromptTarget()
    }

    /// A click in the target menu checks or unchecks a terminal: the composer sends to every
    /// checked one. The first is the tray's target (its integration drains the tray); unchecking
    /// it makes the next one the target; the last one stays checked.
    private func toggleTarget(_ id: ObjectID) {
        let targets = composer.targets
        let extra = Array(targets.dropFirst())
        if id == targets.first {
            guard let next = extra.first else { return }
            composer.setAlsoTo(Array(extra.dropFirst()))
            chooseTarget(next)
        } else if extra.contains(id) {
            composer.setAlsoTo(extra.filter { $0 != id })
        } else if targets.isEmpty {
            chooseTarget(id)
        } else {
            composer.setAlsoTo(extra + [id])
        }
    }

    /// ⌥-click in the target menu: that terminal alone.
    private func onlyTarget(_ id: ObjectID) {
        composer.setAlsoTo([])
        chooseTarget(id)
    }

    /// The board's terminals, those running an agent first, each named as its header names it;
    /// the composer's targets are checked. The tray's "→ name ▾" opens it; Edit ▸ Send Mentions
    /// To is the same list for the keyboard (`fillTargetMenu`).
    private func targetMenu() -> NSMenu? {
        let menu = NSMenu(title: "Send Mentions To")
        fillTargetMenu(menu)
        return menu.numberOfItems > 0 ? menu : nil
    }

    func fillTargetMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        var agents = true
        let targets = composer.targets
        for terminal in PromptTarget.menuOrder(board.objects) {
            let isAgent = PromptTarget.runsAgent(terminal)
            if agents, !isAgent, menu.numberOfItems > 0 { menu.addItem(.separator()) }
            agents = isAgent
            let name = terminalName(terminal.id)
            let id = terminal.id
            let item = MenuAction.item(name) { [weak self] in self?.toggleTarget(id) }
            item.state = targets.contains(id) ? .on : .off
            menu.addItem(item)
            let only = MenuAction.item("Only \(name)") { [weak self] in self?.onlyTarget(id) }
            only.keyEquivalentModifierMask = .option
            only.isAlternate = true
            only.state = targets == [id] ? .on : .off
            menu.addItem(only)
        }
    }

    /// Edit ▸ Remove Mention: the tray's chips in order, numbered as the prompt numbers them;
    /// picking one takes it off, as its ✕ does.
    func fillRemoveMentionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for (index, mention) in board.tray.enumerated() {
            let id = mention.id
            menu.addItem(MenuAction.item("[\(index + 1)] \(mention.label)") { [weak self] in try? self?.board.unstage(id) })
        }
    }

    /// Edit ▸ Remove Last Mention (⌥⇧⌘M): the chip staged last comes off.
    @objc func removeLastMention(_ sender: Any?) {
        guard let last = board.tray.last else { return }
        try? board.unstage(last.id)
    }

    /// Edit ▸ Clear Mentions: every chip comes off.
    @objc func clearMentions(_ sender: Any?) {
        for mention in board.tray { try? board.unstage(mention.id) }
    }

    /// The mentions the tray held when last seen, to tell which one was just staged.
    private var trayMentions: Set<MentionID> = []
    /// The terminal worktree affinity last made the target, with the checkout it works in; the
    /// tray line says so while it stays the target.
    private var affinity: (target: ObjectID, checkout: String)?

    /// Worktree affinity (`PromptTarget.affinity`): a mention just staged from a file in another
    /// checkout than the target's goes to the one agent working in that checkout, as if that
    /// terminal had been focused last (the keyboard stays where it is).
    private func retargetByWorktree(_ tray: [Mention]) {
        let staged = tray.last { !trayMentions.contains($0.id) }
        trayMentions = Set(tray.map(\.id))
        guard let staged, let checkout = PromptTarget.checkout(of: staged.target, on: board) else { return }
        guard let agent = PromptTarget.affinity(checkout: checkout, current: canvas.promptTarget, checkouts: PromptTarget.checkouts(on: board), objects: board.objects) else { return }
        board.promptTarget.focused(agent)
        settlePromptTarget()
        affinity = (agent, checkout.name)
    }

    /// Keyboard focus inside a terminal tile counts for the prompt target; in any tile it counts as
    /// seeing it (`CanvasView.keyboardUsed`).
    private func firstResponderChanged(_ responder: NSResponder?) {
        var view = responder as? NSView
        while let current = view {
            if let terminal = current as? TerminalTile {
                board.promptTarget.focused(terminal.objectID)
                settlePromptTarget()
                break
            }
            view = current.superview
        }
        if canvas.focusedTerminal != trayKeyboard { refreshTray() }
        if let tile = canvas.focusedTile { canvas.keyboardUsed(tile) }
    }

    /// A key typed (not a ⌘ shortcut) on its way to the tile holding the keyboard: typing there
    /// counts as seeing it, as its focus does (an agent's question answered in a terminal that
    /// already had the keyboard clears the marker about it), and a terminal hears of it
    /// (`TerminalTile.typed`).
    func keyTyped(_ event: NSEvent) {
        guard !event.modifierFlags.contains(.command), let tile = canvas.focusedTile else { return }
        canvas.keyboardUsed(tile)
        (canvas.tiles[tile]?.content as? TerminalTile)?.typed(event)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        registry.frontmost = board.id
    }

    /// The board's tab or window closed (not app quit, which closes nothing).
    var onClose: (() -> Void)?

    /// Closing the tab or window ends nothing: its terminals' sessions keep running (agents go
    /// on working, headless) and come back when the folder is opened again. With any terminal on
    /// the board a sheet says so first, naming what keeps running: Keep Running (Return), End
    /// Sessions (⌘⌫: its terminals close as in the close-terminal sheet, then the tab), Cancel (Esc).
    /// Closing the last board window quits easl, which the sheet says; the next launch reopens
    /// the board (`AppDelegate.saveOpenBoards`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let terminals = canvas.tiles.values.compactMap { $0.content as? TerminalTile }.sorted { $0.objectID < $1.objectID }
        guard !terminals.isEmpty else { return true }
        let tabs = sender.tabbedWindows?.count ?? 1
        let last = tabs <= 1 && !NSApp.windows.contains { $0 !== sender && $0 is CanvasWindow && ($0.isVisible || $0.isMiniaturized) }
        let keep = SessionProcesses.keepRunningText(terminals.map { $0.sessionProcesses() })
        let alert = NSAlert()
        alert.messageText = "Close “\(board.root.lastPathComponent)” and keep \(terminals.count == 1 ? "its terminal" : "its terminals") running?"
        alert.informativeText = last
            ? "This is easl's last window: closing it quits easl. \(keep) in the background; the next time easl opens it shows this board as you left it. End Sessions closes the board's terminals first."
            : "\(keep) in the background after the \(tabs > 1 ? "tab" : "window") closes; opening this folder again (File › Open Board…) shows the board as you left it. End Sessions closes the board's terminals first."
        alert.addButton(withTitle: "Keep Running")
        let end = alert.addButton(withTitle: "End Sessions")
        end.keyEquivalent = "\u{8}"
        end.keyEquivalentModifierMask = .command
        end.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let ids = terminals.map(\.objectID)
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender, response != .alertThirdButtonReturn else { return }
            if response == .alertSecondButtonReturn { self.canvas.remove(ids.filter { self.board.objects[$0] != nil }) }
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        canvas.saveViewport()
        composer.save()
        onClose?()
    }

    /// The window content as the user sees it, with the viewport it shows. Content drawn outside
    /// AppKit (Ghostty's Metal, WebKit) is missing from `cacheDisplay`, so visible tiles swap in
    /// images of it while rendering, fetched first (`prepareSnapshot`: a terminal's history
    /// comes from zmx, off the main actor). Code and changes cards in view are redrawn from their
    /// current model first (a file rewritten while zoomed out shows as it is now).
    func snapshot(format: ImageFormat) async -> (output: RenderOutput, viewport: Viewport)? {
        let visible = canvas.documentVisibleRect
        let stale = canvas.tiles.values.filter { tile in
            !tile.isLive && tile.frame.intersects(visible) && [.code, .changes].contains(board.objects[tile.objectID]?.type)
        }
        let refreshes = stale.map { tile in Task { await tile.refreshCard() } }
        let live = canvas.tiles.values.filter { $0.isLive && $0.frame.intersects(visible) }.map(\.content)
        let preparing = live.map { content in Task { await content.prepareSnapshot() } }
        for task in refreshes + preparing { await task.value }
        guard let window, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        canvas.tiles.values.forEach { $0.syncTitle() }
        live.forEach { $0.showSnapshot(true) }
        view.cacheDisplay(in: view.bounds, to: rep)
        live.forEach { $0.showSnapshot(false) }
        let encoded = format == .png ? rep.representation(using: .png, properties: [:]) : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        guard let encoded else { return nil }
        let backing = Double(rep.pixelsWide) / max(view.bounds.width, 1)
        let viewport = canvas.viewport
        let output = RenderOutput(image: encoded, format: format, width: rep.pixelsWide, height: rep.pixelsHigh, canvasRect: viewport.rect,
                                  scale: backing * viewport.zoom, objects: canvas.visibleObjects(pixelsPerPoint: backing))
        return (output, viewport)
    }

    // MARK: Actions

    @objc func newTerminal(_ sender: Any?) {
        canvas.createTerminal()
    }

    /// A sheet, not `runModal`: a modal run loop would stall every socket request.
    @objc func openCodeTile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = board.root
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self, panel] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.canvas.openForUser(.code, props: .object(["path": .string(self.board.relativePath(url.path))]))
        }
    }

    @objc func zoomToActual(_ sender: Any?) {
        canvas.zoomToActualSize()
    }

    @objc func zoomOut(_ sender: Any?) {
        canvas.zoomStep(in: false)
    }

    @objc func zoomIn(_ sender: Any?) {
        canvas.zoomStep(in: true)
    }

    /// Go to… (⌘P) shows the navigator over this board with its field holding the keyboard: never
    /// a toggle, so a ⌘P can't close a panel the user can't see and send what they type next to
    /// a terminal (a11y study round 7); Esc, a row, or a click elsewhere closes it. Already open,
    /// the field takes the keyboard back with its text selected. The files of the checkout the
    /// board was opened from (`Board.workingRoot`: a worktree's, not the main checkout's) are
    /// re-listed on every open; the list shown meanwhile is the previous one. Not while a sheet
    /// is up: the panel would open behind it, and the sheet's Esc would hand the keyboard back
    /// to the terminal under an open panel.
    @objc func showNavigator(_ sender: Any?) {
        guard window?.attachedSheet == nil else { return }
        if navigator.isOpen { return navigator.focusField() }
        let files = BoardFiles.of(board.workingRoot)
        navigator.open(rows: canvas.navigatorRows(), files: files.index)
        files.refresh { [weak self] index in self?.navigator.update(files: index) }
    }

    /// View › Hide Board Chrome (also in easl Basics): toggles presenting (`CanvasView.chromeHidden`);
    /// Esc on the canvas shows the chrome again.
    @objc func toggleCanvasChrome(_ sender: Any?) {
        canvas.chromeHidden.toggle()
        if canvas.chromeHidden { basics.close() }
    }

    /// Help › easl Basics opens (or closes) the legend over this board.
    @objc func toggleBasics(_ sender: Any?) {
        if basics.isOpen { basics.close() } else { basics.open() }
    }

    /// Help › Get Started opens (or closes) the first-run walk-through over this board; at the
    /// first launch of a new home the app opens it (`GetStarted.Store.launch`).
    @objc func toggleGetStarted(_ sender: Any?) {
        if getStarted.isOpen { getStarted.close() } else { showGetStarted() }
    }

    /// Opens Get Started with its practice note in view and selected (so ⇧⌘M works on it
    /// straight away), counting from what the tray holds now.
    func showGetStarted() {
        guard !getStarted.isOpen else { return }
        guide = GetStarted.Progress(delivered: board.delivered, trayCount: board.tray.count)
        getStarted.open()
        showPracticeNote()
        refreshTray()
        refreshEmptyHint()
    }

    /// Closing is final: it no longer opens at launch. The practice note goes with it unless
    /// the user wrote in it.
    private func getStartedClosed() {
        guide = nil
        GetStarted.Store(url: AppPaths.getStarted).dismiss()
        if let note = practiceNote, note.props["markdown"]?.string == GetStarted.practiceMarkdown { try? board.delete(note.id) }
        refreshEmptyHint()
    }

    private var practiceNote: CanvasObject? { try? board.holder(ofKey: GetStarted.practiceKey) }

    /// The practice note, made if it's gone: placed like any new tile, in the view clear of
    /// the panel (`chromeInsets`), then revealed and selected.
    private func showPracticeNote() {
        let note = practiceNote ?? board.create(
            type: .note,
            props: .object(["markdown": .string(GetStarted.practiceMarkdown), "key": .string(GetStarted.practiceKey)]),
            frame: board.place(width: 380, height: 220, near: nil))
        canvas.reveal(note.id)
        canvas.setSelection([note.id])
    }

    /// The walk-through follows the tray: staged, then taken by a prompt; step 2 says what
    /// the tray's target needs (a terminal, an agent in it, or Hyper-V).
    private func refreshGetStarted(target: CanvasObject?) {
        guard var progress = guide else { return }
        progress.observe(trayCount: board.tray.count, delivered: board.delivered)
        guide = progress
        let shown: GetStartedPanel.Target = if let target {
            PromptTarget.drains(target) ? .agent : .plain
        } else {
            board.objects.values.contains { $0.type == .terminal } ? .choose : .none
        }
        getStarted.show(progress.step, target: shown)
    }

    /// The empty-board hint shows on an empty board, unless Get Started is open over it.
    private func refreshEmptyHint() {
        emptyHint.isHidden = !board.objects.isEmpty || getStarted.isOpen
    }

    /// Go to's file, symbol and Recent rows: a code tile in view already showing the lines, else
    /// a plain code tile in view showing the file re-aimed at them (never an agent's, captioned,
    /// grouped or follow tile: `Board.openForNavigation`), gone to; else a new one placed in view
    /// like any object the user asks for. One step of Navigate Back.
    private func open(path: String, lines: LineRange?) -> ObjectID? {
        let aim = CodeAim(path: path, range: lines)
        var landed: ObjectID?
        canvas.navigating(landing: aim) {
            let opened = board.openForNavigation(aim, from: nil)
            landed = opened.id
            if opened.created, let object = board.objects[opened.id] {
                canvas.showNew(object)
            } else {
                canvas.go(to: opened.id)
            }
            return opened.reaim
        }
        return landed
    }

    /// Go to landed on a code tile: the lines it named (`path:line`, a symbol) or the tile's row
    /// showed are selected in it (`KeyboardMention.goToLines`), so ⇧⌘M mentions just them.
    private func selectGoToLines(_ lines: LineRange?, in id: ObjectID) {
        guard let range = KeyboardMention.goToLines(lines, landedOn: board.objects[id]) else { return }
        (canvas.tiles[id]?.content as? CodeTile)?.select(lines: range)
    }

    /// When the language servers last answered a Go to symbol search with symbols (they are warm).
    private var symbolsAnswered: Date?

    /// Go to's symbol rows for `name`: the workspace symbols of the projects this board's code
    /// tiles show (else of the language most of the listed checkout's files are in,
    /// `Board.workingRoot`), from the app's language servers, started if needed. Files outside
    /// that checkout are left out; rows name files relative to it, as file rows do. When no
    /// server for those files' languages could answer (not installed, crashed), the answer's
    /// note says why, with its install hint, for the panel's footer (never a row).
    private func workspaceSymbols(named name: String) async -> NavigatorPanel.SymbolAnswer {
        let root = board.workingRoot
        var files = board.objects.values.filter { $0.type == .code }.compactMap { $0.props["path"]?.string }.map(board.absoluteURL)
        if files.isEmpty {
            let configs = LanguageServerConfig.defaults
            var counts: [String: Int] = [:]
            var first: [String: String] = [:]
            for path in BoardFiles.of(root).index.paths.prefix(20_000) {
                let url = URL(fileURLWithPath: path)
                guard let language = configs.first(where: { $0.languageID(for: url) != nil })?.language else { continue }
                counts[language, default: 0] += 1
                if first[language] == nil { first[language] = path }
            }
            if let most = counts.max(by: { $0.value < $1.value })?.key, let path = first[most] { files = [root.appendingPathComponent(path)] }
        }
        guard !files.isEmpty else { return NavigatorPanel.SymbolAnswer(rows: []) }
        func ask() async -> Result<[LSPWorkspaceSymbol], Error> {
            do { return .success(try await CodeNavigation.languages.workspaceSymbols(name, files: files, boardRoot: root)) } catch { return .failure(error) }
        }
        var answer = await ask()
        // A server that just started answers before it has read the project (pyright: nothing at
        // all), so until one has answered with symbols lately, an empty answer is asked again
        // for a while; the panel says "Searching symbols…" meanwhile.
        let warm = symbolsAnswered.map { Date().timeIntervalSince($0) < 240 } ?? false
        var retries = warm ? 0 : 10
        while case .success(let found) = answer, found.isEmpty, retries > 0, !Task.isCancelled {
            retries -= 1
            try? await Task.sleep(for: .seconds(1))
            answer = await ask()
        }
        let symbolsFound: [LSPWorkspaceSymbol]
        switch answer {
        case .success(let found): symbolsFound = found
        case .failure(let error):
            if error is CancellationError { return NavigatorPanel.SymbolAnswer(rows: []) }
            return NavigatorPanel.SymbolAnswer(rows: [], note: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        var symbols = symbolsFound
        if !symbols.isEmpty { symbolsAnswered = Date() }
        // Servers match fuzzily (`_resolve_pager_command` for `resolve_command`): the name itself
        // first, then names starting with it, each in the server's order.
        let lowered = name.lowercased()
        func rank(_ symbol: LSPWorkspaceSymbol) -> Int { symbol.name == name ? 0 : symbol.name.lowercased() == lowered ? 1 : symbol.name.lowercased().hasPrefix(lowered) ? 2 : 3 }
        symbols = symbols.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        var rows: [NavigatorRow] = []
        for symbol in symbols {
            let path = Board.relativePath(symbol.location.url.path, root: root)
            guard !path.hasPrefix("/") else { continue }
            let line = symbol.location.range.start.line + 1
            rows.append(NavigatorRow(target: .file(path, lines: LineRange(start: line, end: line)), title: symbol.name, kind: symbol.kindName.capitalized, dot: nil,
                                     subtitle: [symbol.container, "\(path):\(line)"].compactMap { $0 }.joined(separator: " · "), toolTip: "\(path):\(line)"))
            if rows.count == NavigatorPanel.maxFileRows { break }
        }
        return NavigatorPanel.SymbolAnswer(rows: rows)
    }

    @objc func zoomToFit(_ sender: Any?) {
        canvas.zoomToFit()
    }

    @objc func toggleLassoSelection(_ sender: Any?) {
        CanvasView.lassoSelection.toggle()
        (sender as? NSMenuItem)?.state = CanvasView.lassoSelection ? .on : .off
    }

    @objc func exitGroup(_ sender: Any?) {
        canvas.exitGroup()
    }

    /// ⌘Z undoes the latest board change (the user's or an agent's). A text field or editor with
    /// its own pending edits undoes those first; a terminal holding the keyboard keeps ⌘Z and ⇧⌘Z
    /// for its program (`canvasUndoApplies`). No undo or redo is silent: a notice names what it
    /// did and whose change it was (`UndoHistory.Step.notice`).
    @objc func undoCanvas(_ sender: Any?) { undo(redo: false) }
    @objc func redoCanvas(_ sender: Any?) { undo(redo: true) }

    private func undo(redo: Bool) {
        if let manager = textUndoManager, redo ? manager.canRedo : manager.canUndo {
            return redo ? manager.redo() : manager.undo()
        }
        guard canvasUndoApplies(redo: redo) else { return }
        let step = redo ? board.nextRedo : board.nextUndo
        guard redo ? board.redo() : board.undo(), let step, let notice = step.notice(redo: redo, author: board.authorName(step.author)) else { return }
        canvas.showNotice(notice)
    }

    /// Canvas undo and redo act unless a terminal holds the keyboard: there ⌘Z belongs to the
    /// terminal (Ghostty's binding, else the program), so undo in nvim never rewinds a Stage.
    /// The one exception is a Hyper-V paste into that terminal as the latest step: its ⌘Z puts
    /// the chips back (`UndoHistory.Step.pastedInto`), and the next ⌘Z is the terminal's again.
    private var canvasUndoApplies: Bool { canvasUndoApplies(redo: false) }

    private func canvasUndoApplies(redo: Bool) -> Bool {
        guard let terminal = canvas.focusedTerminal else { return true }
        return (redo ? board.nextRedo : board.nextUndo)?.pastedInto == terminal
    }

    /// Edit ▸ Undo/Redo named for the step they'd take (`Undo Create 9 Code Tiles, 6 Arrows
    /// (omp)`), or the text editor's own.
    private func undoTitle(redo: Bool) -> String {
        if let manager = textUndoManager, redo ? manager.canRedo : manager.canUndo {
            return redo ? manager.redoMenuItemTitle : manager.undoMenuItemTitle
        }
        let verb = redo ? "Redo" : "Undo"
        guard canvasUndoApplies(redo: redo), let step = redo ? board.nextRedo : board.nextUndo else { return verb }
        let title = step.title
        let author = board.authorName(step.author).map { " (\($0))" } ?? ""
        return title.isEmpty ? verb : "\(verb) \(title)\(author)"
    }

    /// View ▸ Back (⌘[): the view and re-aimed tile before the last navigation. A page with the
    /// keyboard goes back itself, as in Safari.
    @objc func navigateBack(_ sender: Any?) {
        if let page = focusedPage {
            page.credit.user()
            page.webView?.goBack()
            return
        }
        canvas.navigateBack()
    }

    /// View ▸ Forward (⌘]): what Back undid, again; a page with the keyboard goes forward itself.
    @objc func navigateForward(_ sender: Any?) {
        if let page = focusedPage {
            page.credit.user()
            page.webView?.goForward()
            return
        }
        canvas.navigateForward()
    }

    /// The browser tile whose page (not its address field) holds the keyboard.
    private var focusedPage: BrowserTile? {
        guard let id = canvas.focusedTile, let browser = canvas.tiles[id]?.content as? BrowserTile,
              let webView = browser.webView, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: webView) else { return nil }
        return browser
    }

    @objc func deleteSelection(_ sender: Any?) {
        canvas.deleteSelection()
    }

    /// Edit ▸ Select All reaching the board: a text field or view holding the keyboard (a browser
    /// tile's address, a filter, a note being edited) selects its own text; else every object.
    @objc func selectAllObjects(_ sender: Any?) {
        if let text = window?.firstResponder as? NSText { return text.selectAll(sender) }
        canvas.selectAll()
    }

    @objc func groupSelection(_ sender: Any?) {
        canvas.groupSelection()
    }

    @objc func ungroupSelection(_ sender: Any?) {
        canvas.ungroupSelection()
    }

    @objc func bringToFront(_ sender: Any?) {
        canvas.bringToFront()
    }

    @objc func sendToBack(_ sender: Any?) {
        canvas.sendToBack()
    }

    /// Hyper-V (Edit ▸ Paste Mentions into Terminal): the tray's context block pasted as one
    /// bracketed paste without Enter into the terminal holding the keyboard, else the prompt
    /// target (`PromptTarget.pasteTarget`), for agents with no prompt hook to drain it (aider, a
    /// bare shell); the pasted mentions leave the tray, and ⌘Z puts them back (in that terminal
    /// too, while this is the latest step: `canvasUndoApplies`).
    @objc func pasteMentions(_ sender: Any?) {
        guard !board.tray.isEmpty, let target = pasteTarget, let terminal = canvas.tiles[target]?.content as? TerminalTile else { return }
        let board = board
        Task { @MainActor [weak terminal] in
            let drained = await board.drain(peek: true, caller: target)
            // Ends on its own line, so what the user types next starts below the block.
            guard !drained.context.isEmpty, let terminal, terminal.paste(drained.context + "\n") else { return }
            board.commit(drained.mentions.map(\.id), pastedInto: target)
        }
    }

    private var pasteTarget: ObjectID? {
        PromptTarget.pasteTarget(keyboard: canvas.focusedTerminal, target: canvas.promptTarget, objects: board.objects)
    }

    /// Edit › Mention (⇧⌘M): stages what the user is on (`KeyboardMention`), as a Hyper-click on
    /// it would (again unstages it); the keyboard stays where it is. With nothing to mention it
    /// says so, like every other command with nothing to act on.
    @objc func mentionCurrent(_ sender: Any?) {
        let keyboardTile = canvas.focusedTile
        let selection = canvas.selection
        let content = (keyboardTile ?? (selection.count == 1 ? selection.first : nil)).flatMap { canvas.tiles[$0]?.content }
        let board = board
        Task { @MainActor [weak self] in
            let current = await content?.keyboardMention(hasKeyboard: keyboardTile != nil)
            guard let target = KeyboardMention.target(keyboardTile: keyboardTile, selection: selection, current: current, on: board) else {
                self?.canvas.showNotice("Nothing to mention: select a tile, or put the cursor on a line")
                return
            }
            self?.canvas.toggleMention(target)
        }
    }

    // MARK: The context menus' actions in the menu bar

    @objc func goToNextNeedsYou(_ sender: Any?) {
        canvas.goToNextNeedsYou()
    }

    @objc func reviewChanges(_ sender: Any?) {
        canvas.reviewChanges()
    }

    /// File ▸ Review Branch: everything a branch changed against the default branch (`CanvasView.reviewChanges`).
    @objc func reviewBranch(_ sender: Any?) {
        canvas.reviewChanges(base: .branch)
    }

    @objc func clearAttentionMarkers(_ sender: Any?) {
        board.clearAllAttention()
    }

    @objc func toggleFollowFiles(_ sender: Any?) {
        canvas.toggleFollow()
    }

    /// Object ▸ Content Zoom ▸ a preset or Reset Content Zoom (the item's `tag` in percent).
    @objc func zoomContent(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        canvas.setZoom(Double(item.tag) / 100)
    }

    /// Object ▸ Content Zoom ▸ Zoom Content In (⌃⌘=) and Out (⌃⌘-).
    @objc func zoomContentIn(_ sender: Any?) { canvas.stepZoom(bigger: true) }
    @objc func zoomContentOut(_ sender: Any?) { canvas.stepZoom(bigger: false) }

    @objc func copyObjectIDs(_ sender: Any?) {
        canvas.copyIDs()
    }

    @objc func copyAsImage(_ sender: Any?) { canvas.copySelectionAsImage() }
    @objc func saveAsPNG(_ sender: Any?) { canvas.saveSelectionAsPNG() }
    @objc func saveHTMLTile(_ sender: Any?) { selected(.html).map(canvas.saveHTML) }
    @objc func openHTMLTileInBrowser(_ sender: Any?) { selected(.html).map(canvas.openHTMLInBrowser) }
    @objc func openPageInBrowser(_ sender: Any?) { selected(.browser).map(canvas.openPageInBrowser) }
    @objc func copyNoteAsMarkdown(_ sender: Any?) { selected(.note).map(canvas.copyNoteMarkdown) }
    @objc func saveNoteAsMarkdown(_ sender: Any?) { selected(.note).map(canvas.saveNoteMarkdown) }

    /// View ▸ Show/Hide Web Inspector (⌥⌘I): Safari's Web Inspector for the focused, else the one
    /// selected, browser tile's page, opened or closed.
    @objc func toggleWebInspector(_ sender: Any?) { inspectableBrowser?.toggleInspector() }

    /// View ▸ Reload Page (⌘R): the focused, else the one selected, browser tile's page, as its
    /// reload button does.
    @objc func reloadPage(_ sender: Any?) {
        guard let page = keyboardBrowser?.tile else { return }
        page.credit.user()
        page.reload()
    }

    /// File ▸ Snapshot Page to Image: the focused, else the one selected, browser tile's page.
    @objc func snapshotPage(_ sender: Any?) { keyboardBrowser.map { canvas.snapshotPage($0.id) } }

    /// File ▸ Print Page…: the focused, else the one selected, browser tile's page.
    @objc func printPage(_ sender: Any?) { keyboardBrowser?.tile.printPage() }

    /// Edit ▸ Find in Page… (⌘F): the find bar of the focused, else the one selected, browser tile.
    @objc func findInPage(_ sender: Any?) {
        guard let browser = keyboardBrowser, canvas.tiles[browser.id]?.isLive == true else { return }
        browser.tile.showFind()
    }

    private var inspectableBrowser: BrowserTile? {
        keyboardBrowser.flatMap { $0.tile.canShowInspector ? $0.tile : nil }
    }

    /// The focused, else the one selected, browser tile.
    private var keyboardBrowser: (id: ObjectID, tile: BrowserTile)? {
        let selection = canvas.selection
        guard let id = canvas.focusedTile ?? (selection.count == 1 ? selection.first : nil),
              let browser = canvas.tiles[id]?.content as? BrowserTile else { return nil }
        return (id, browser)
    }

    /// The one selected object, when it is of `type` (an HTML tile's Save as HTML and Open in
    /// Browser, a browser tile's Open Page in Browser, a note's Copy and Save as Markdown).
    private func selected(_ type: ObjectType) -> ObjectID? {
        let selection = canvas.selection
        guard selection.count == 1, let id = selection.first, board.objects[id]?.type == type else { return nil }
        return id
    }

    @objc func enterGroup(_ sender: Any?) {
        guard let group = canvas.selectedGroup else { return }
        canvas.enter(group: group)
    }

    @objc func goToDefinition(_ sender: Any?) { navigateCode(.definition) }
    @objc func openDefinitionInNewTile(_ sender: Any?) { navigateCode(.definitionInNewTile) }
    @objc func findReferences(_ sender: Any?) { navigateCode(.references) }
    @objc func showOutline(_ sender: Any?) { navigateCode(.outline) }

    /// A Code ▸ command on `CanvasView.keyboardCodeTile`; with none, it says so.
    private func navigateCode(_ navigation: CodeTile.KeyboardNavigation) {
        guard let code = canvas.keyboardCodeTile else { return canvas.showNotice("No code tile to act on: click one first") }
        code.navigate(navigation)
    }

    /// View ▸ Leave Tile (⌘Esc): the one way out of a terminal, whose Esc belongs to its program.
    @objc func leaveTile(_ sender: Any?) { canvas.focusedTile.map(canvas.leaveTile) }

    /// Whether a menu item applies now (AppDelegate forwards the menu bar's validation here).
    func validate(_ item: NSMenuItem) -> Bool {
        let selection = canvas.selection
        switch item.action {
        case #selector(undoCanvas(_:)):
            item.title = undoTitle(redo: false)
            return textUndoManager?.canUndo == true || canvasUndoApplies && board.history.canUndo
        case #selector(redoCanvas(_:)):
            item.title = undoTitle(redo: true)
            return textUndoManager?.canRedo == true || canvasUndoApplies(redo: true) && board.history.canRedo
        case #selector(navigateBack(_:)): return focusedPage?.webView?.canGoBack ?? canvas.canNavigateBack
        case #selector(navigateForward(_:)): return focusedPage?.webView?.canGoForward ?? canvas.canNavigateForward
        case #selector(deleteSelection(_:)), #selector(bringToFront(_:)), #selector(sendToBack(_:)): return !selection.isEmpty
        case #selector(groupSelection(_:)): return selection.count >= 2
        case #selector(ungroupSelection(_:)):
            return board.objects.values.contains { $0.type == .group && (selection.contains($0.id) || GroupSpec($0.props)?.members.contains(where: selection.contains) == true) }
        case #selector(pasteMentions(_:)): return !board.tray.isEmpty && pasteTarget != nil
        case #selector(mentionCurrent(_:)): return canvas.focusedTile != nil || !selection.isEmpty
        case #selector(removeLastMention(_:)), #selector(clearMentions(_:)): return !board.tray.isEmpty
        case #selector(exitGroup(_:)): return canvas.enteredGroup != nil
        case #selector(enterGroup(_:)): return canvas.selectedGroup != nil
        case #selector(copyObjectIDs(_:)):
            item.title = selection.count > 1 ? "Copy Object IDs" : "Copy Object ID"
            return !selection.isEmpty
        case #selector(toggleGetStarted(_:)):
            item.state = getStarted.isOpen ? .on : .off
            return true
        case #selector(toggleBasics(_:)):
            item.state = basics.isOpen ? .on : .off
            return true
        case #selector(toggleCanvasChrome(_:)):
            item.state = canvas.chromeHidden ? .on : .off
            return true
        case #selector(clearAttentionMarkers(_:)): return !board.attention.isEmpty
        case #selector(copyAsImage(_:)), #selector(saveAsPNG(_:)): return !selection.isEmpty
        case #selector(saveHTMLTile(_:)), #selector(openHTMLTileInBrowser(_:)): return selected(.html) != nil
        case #selector(openPageInBrowser(_:)): return selected(.browser) != nil
        case #selector(copyNoteAsMarkdown(_:)), #selector(saveNoteAsMarkdown(_:)): return selected(.note) != nil
        case #selector(toggleWebInspector(_:)):
            item.title = inspectableBrowser?.inspectorVisible == true ? "Hide Web Inspector" : "Show Web Inspector"
            return inspectableBrowser != nil
        case #selector(reloadPage(_:)): return keyboardBrowser != nil
        case #selector(snapshotPage(_:)): return keyboardBrowser != nil
        case #selector(printPage(_:)): return keyboardBrowser?.tile.canPrint == true
        case #selector(findInPage(_:)):
            guard let browser = keyboardBrowser else { return false }
            return canvas.tiles[browser.id]?.isLive == true
        case #selector(toggleFollowFiles(_:)):
            guard let terminal = canvas.followTerminal else {
                item.state = .off
                return false
            }
            item.state = canvas.follows(terminal) ? .on : .off
            return true
        case #selector(zoomContent(_:)):
            guard let levels = canvas.zoomTargetLevels else {
                item.state = .off
                return false
            }
            let zoom = Double(item.tag) / 100
            item.state = levels == [zoom] && item.tag != 100 ? .on : .off
            return item.tag != 100 || levels != [1]
        case #selector(zoomContentIn(_:)): return canvas.canStepZoom(bigger: true)
        case #selector(zoomContentOut(_:)): return canvas.canStepZoom(bigger: false)
        case #selector(showNavigator(_:)): return window?.attachedSheet == nil
        case #selector(goToDefinition(_:)), #selector(openDefinitionInNewTile(_:)), #selector(findReferences(_:)), #selector(showOutline(_:)):
            // With no code tile to act on the command still runs, to say so (`navigateCode`).
            return canvas.keyboardCodeTile?.canNavigate ?? true
        case #selector(leaveTile(_:)): return canvas.focusedTile != nil
        case #selector(reviewBranch(_:)):
            // Names the worktree's branch it will review (`CanvasView.reviewChanges`), "…" when it asks which.
            let root = board.reviewRoot(terminal: canvas.followTerminal)
            let worktree = GitWorktree.containing(root ?? board.root.path)
            let defaultBranch = worktree?.defaultBranch
            if let branch = root.flatMap({ _ in worktree?.branch }) {
                item.title = "Review \(branch) vs \(defaultBranch ?? "default branch")"
            } else {
                item.title = "Review " + ChangesBaseChoice.branch.title(defaultBranch: defaultBranch) + (root == nil && !board.branchReviewChoices.isEmpty ? "…" : "")
            }
            return defaultBranch != nil
        default: return true
        }
    }

    /// A text view with its own undo history holding the keyboard (a note being edited).
    private var textUndoManager: UndoManager? {
        guard let text = window?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text.undoManager
    }

    /// The View menu's navigation shortcuts, matched on the key's characters: ⌘P, ⌘9, ⌘0, ⌘= (and
    /// ⌘+), ⌘-, ⌘[ and ⌘] (Back, Forward), and ⌘Esc (Leave Tile, before a terminal's Ghostty
    /// keybinds could claim it). Nil for anything else, which stays with the focused view.
    static func navigationAction(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, modifiers == .command { return #selector(leaveTile(_:)) }
        switch (event.charactersIgnoringModifiers, modifiers) {
        case ("p", .command): return #selector(showNavigator(_:))
        case ("9", .command): return #selector(zoomToFit(_:))
        case ("0", .command): return #selector(zoomToActual(_:))
        case ("=", .command), ("+", .command), ("+", [.command, .shift]): return #selector(zoomIn(_:))
        case ("-", .command): return #selector(zoomOut(_:))
        // Ghostty's ⌘[ / ⌘] (go to split) have no splits here; a page keeps its own back.
        case ("[", .command): return #selector(navigateBack(_:))
        case ("]", .command): return #selector(navigateForward(_:))
        default: return nil
        }
    }

    /// ⌥⌘-arrow, by key code (the characters an arrow reports vary with modifiers). Ghostty's
    /// ⌥⌘-arrow (go to split) has no splits to go to here, and shells never see ⌘.
    static func tileHeading(for event: NSEvent) -> Layout.Heading? {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .option] else { return nil }
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    /// The chord a key press is, as Ghostty keybinds name it: its modifiers and unshifted
    /// character, or the key's name for keys without one.
    static func keyChord(for event: NSEvent) -> GhosttyConfig.KeyChord? {
        guard event.type == .keyDown else { return nil }
        let modifiers = modifiers(event.modifierFlags)
        if let name = namedKeys[event.keyCode] { return .init(modifiers, name) }
        guard let character = event.characters(byApplyingModifiers: [])?.lowercased(), character.count == 1 else { return nil }
        return .init(modifiers, character)
    }

    /// `flags` as Ghostty keybinds' modifiers.
    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> GhosttyConfig.Modifiers {
        var modifiers: GhosttyConfig.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// Keys whose unmodified characters are control codes (UCKeyTranslate gives every F-key 0x10),
    /// by key code.
    private static let namedKeys: [UInt16: String] = [
        36: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape", 117: "delete", 115: "home", 119: "end",
        116: "page_up", 121: "page_down", 123: "arrow_left", 124: "arrow_right", 125: "arrow_down", 126: "arrow_up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// Menu items a focused terminal keeps: editing (Copy, Paste, Select All), ⌘⌫, which
    /// Ghostty sends as "delete line" and which must never delete the canvas selection, and ⌘Z /
    /// ⇧⌘Z, which are the terminal's (a Stage undone from inside nvim was a silent git change),
    /// and ⌘F (Find in Page), which is the terminal's own search.
    private static let terminalMenuActions: Set<Selector> = [#selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)), #selector(AppDelegate.deleteSelection(_:)),
                                                             #selector(AppDelegate.undoCanvas(_:)), #selector(AppDelegate.redoCanvas(_:)), #selector(AppDelegate.findInPage(_:))]

    /// The main-menu item `event` is the key equivalent of.
    static func menuItem(for event: NSEvent, in menu: NSMenu?) -> NSMenuItem? {
        keyChord(for: event).flatMap { menuItem(for: $0, in: menu) }
    }

    private static func menuItem(for chord: GhosttyConfig.KeyChord, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if let found = menuItem(for: chord, in: item.submenu) { return found }
            if !item.keyEquivalent.isEmpty, chord == GhosttyConfig.KeyChord(menuKey: item.keyEquivalent, modifiers: modifiers(item.keyEquivalentModifierMask)) { return item }
        }
        return nil
    }

    /// Board shortcuts taken ahead of the focused view (see `CanvasWindow`). ⌘W closes the
    /// selection or the focused terminal and, with neither, goes on to the window's own close;
    /// ⌘F finds in a code tile and otherwise stays with the terminal or page. Hyper-V pastes the
    /// tray's mentions; a focused terminal would otherwise send the chord to its program as an
    /// encoded key (zsh prints it at the prompt). In a focused terminal, the user's Ghostty
    /// bindings of new window, tab or split open a terminal beside it and close surface closes it
    /// (`TerminalConfig.remaps`), and easl's menu shortcuts other than `terminalMenuActions`
    /// beat Ghostty's own bindings (its defaults bind ⌘T, ⌘N, ⌘Q, ⌘⇧[ and ⌘⇧] to tab, window and
    /// app actions the embedded library can't perform, so the key would do nothing).
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        if let action = Self.navigationAction(for: event) {
            perform(action, with: self)
            return true
        }
        if let heading = Self.tileHeading(for: event) {
            canvas.moveToNeighbor(heading)
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, modifiers == [.command, .shift, .option, .control], event.charactersIgnoringModifiers?.lowercased() == "v", window?.attachedSheet == nil {
            pasteMentions(nil)
            return true
        }
        guard event.type == .keyDown, window?.attachedSheet == nil else { return false }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "w": if canvas.closeSelectionOrFocused() { return true }
            case "f": if canvas.findInCodeTile() { return true }
            case "l": if canvas.focusBrowserAddress() { return true }
            // ⌘I (Write Prompt) ahead of the focused view: a page's editor would take it for
            // italics, and the composer is reached from anywhere.
            case "i":
                focusComposer(nil)
                return true
            default: break
            }
        }
        guard let terminal = canvas.focusedTerminal else { return false }
        // ⌘Z / ⇧⌘Z right after a Hyper-V paste into this terminal: the chips come back.
        if modifiers.subtracting(.shift) == .command, event.charactersIgnoringModifiers?.lowercased() == "z", canvasUndoApplies(redo: modifiers.contains(.shift)) {
            undo(redo: modifiers.contains(.shift))
            return true
        }
        if let chord = Self.keyChord(for: event), let action = TerminalConfig.shared.remaps[chord] {
            switch action {
            case .newTerminal: canvas.createTerminal(beside: terminal)
            case .closeTerminal: canvas.delete([terminal])
            }
            return true
        }
        if let item = Self.menuItem(for: event, in: NSApp.mainMenu), let action = item.action, !Self.terminalMenuActions.contains(action) {
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        }
        return false
    }
}

/// A board window. easl shortcuts reach the canvas before the focused view: the window gets
/// key equivalents ahead of its views and the main menu (AppKit's order for a real key press),
/// and a focused terminal would otherwise claim ⌘0/⌘=/⌘-/⌘9 as Ghostty bindings (font size,
/// tabs), ⌘W as close surface, and a web view ⌘=/⌘- as page zoom. Everything else (⌘C, ⌘V, ⌘A,
/// typing) stays with the focused view. Likewise ⌘-scroll zooms the canvas wherever the pointer
/// is on it, over a tile too; plain scrolling stays with the tile under the pointer.
final class CanvasWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller = windowController as? CanvasWindowController, controller.handleKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Typing reaches the focused tile through here (`CanvasWindowController.keyTyped`), and a
    /// ⌘-scroll anywhere on the canvas zooms it (`zoomsCanvas`).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let controller = windowController as? CanvasWindowController { controller.keyTyped(event) }
        if event.type == .scrollWheel, zoomsCanvas(event, at: event.locationInWindow) { return }
        super.sendEvent(event)
    }

    /// A ⌘-scroll at `point` (window coordinates) over the canvas goes to the canvas
    /// (`CanvasWheel`), which zooms. The modifiers first: every other scroll event skips the hit test.
    func zoomsCanvas(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              let canvas = (windowController as? CanvasWindowController)?.canvas, let content = contentView,
              content.hitTest(content.superview?.convert(point, from: nil) ?? point)?.isDescendant(of: canvas) == true else { return false }
        canvas.scrollWheel(with: event)
        return true
    }
}

/// The dot at the trailing edge of a board's tab while an agent on it needs the user.
private final class TabDot: NSView {
    private let color: NSColor
    private let diameter: CGFloat

    init(color: NSColor, diameter: CGFloat) {
        self.color = color
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter + 6, height: diameter + 6))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter + 6, height: diameter + 6) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)).fill()
    }
}
