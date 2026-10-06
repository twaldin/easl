import AppKit
import CanvasCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let registry = BoardRegistry(store: BoardStore(directory: AppPaths.boards), agentReports: AppPaths.agentReports)
    private lazy var router = ApiRouter(registry: registry)
    private var server: SocketServer?
    private var cmuxServer: SocketServer?
    private lazy var cmux = CmuxRouter(registry: registry, password: AppPaths.cmuxPassword)
    private var controllers: [BoardID: CanvasWindowController] = [:]
    /// The boards in the order they were first opened, which orders windows that aren't tabs of
    /// one another (`openBoardsInOrder`): a board's id, or a remote board's `remoteKey`.
    private var openedOrder: [String] = []
    /// Remote boards' windows (docs/design.md "Client mode"), by host and board (`remoteKey`):
    /// another host's board may have the id of one of ours (two checkouts of one repository).
    private var remoteControllers: [String: CanvasWindowController] = [:]
    private var terminationSignal: DispatchSourceSignal?
    private let notifier = AgentNotifier()
    private lazy var hyper = HyperMonitor { [weak self] window in
        guard let self else { return nil }
        return (self.controllers.values.first { $0.window === window } ?? self.remoteControllers.values.first { $0.window === window })?.canvas
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        // `kill <pid>` (scripts, logout) quits through the normal path so boards are flushed.
        // The signal is received off the main queue and handed to the main run loop in every
        // mode, because an app-modal session (NSAlert.runModal, NSOpenPanel) doesn't drain the
        // main queue; sheets and modal sessions are ended first since either one holds up
        // `terminate`.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        // `@Sendable`: written inside this @MainActor method, the handler would otherwise be
        // inferred main-actor isolated, and Swift's runtime check traps when it runs on the
        // global queue (every `kill <pid>` crashed instead of quitting, losing unflushed boards).
        termination.setEventHandler { @Sendable in
            let main = CFRunLoopGetMain()
            let modes = [CFRunLoopMode.commonModes.rawValue, RunLoop.Mode.modalPanel.rawValue as CFString, RunLoop.Mode.eventTracking.rawValue as CFString] as CFArray
            CFRunLoopPerformBlock(main, modes) {
                MainActor.assumeIsolated { AppDelegate.terminateNow() }
            }
            CFRunLoopWakeUp(main)
        }
        termination.resume()
        terminationSignal = termination
        DevInput.install()
        // app.metrics: main-thread stretches (and the app.log line naming a long one's cause).
        Metrics.shared.monitorMainThread()
        // easl's own leftovers: dead sessions' zmx logs, read Ghostty configs, old renders.
        Housekeeping.pruneAtLaunch()
        if let url = AppPaths.asset(DrawingStyle.fontAsset) { DrawingStyle.registerFonts(url) }
        registry.onEvent = { [weak self] board, event in
            self?.controllers[board.id]?.apply(event)
            self?.notifier.observe(event, on: board)
        }
        // Every delete of a terminal (UI close, API, batch, undo/redo) ends its zmx session (a
        // hosted one's on its host), and with it any report its agent spooled here
        // (`AgentReportSpool`), which nothing would replay.
        registry.onTerminalsEnded = { _, ended in
            for terminal in ended { TerminalTile.killSession(terminal) }
            let spooled = ended.map { AppPaths.agentReports.appendingPathComponent($0.id, isDirectory: true) }
            Task.detached { for folder in spooled { try? FileManager.default.removeItem(at: folder) } }
        }
        // object.measure, size: "fit", and layout.check lay HTML pages out in WebKit.
        ObjectMeasure.html = { props, width, root in try await HtmlTile.measure(props: props, width: width, root: root) }
        notifier.onOpen = { [weak self] board, tile in
            guard let controller = self?.controllers[board] else { return }
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.canvas.focus(tile: tile)
        }
        notifier.install()
        router.submitToTerminal = { [weak self] board, tile, text in
            guard let terminal = self?.content(of: tile, on: board) as? TerminalTile else { return false }
            return await terminal.submit(text)
        }
        router.terminalStatus = { [weak self] board, tile in
            guard let terminal = self?.content(of: tile, on: board) as? TerminalTile else { return TerminalStatus() }
            terminal.refreshProgram()
            // Gemini CLI pads its title to a fixed width.
            return TerminalStatus(title: terminal.oscTitle?.trimmingCharacters(in: .whitespaces), program: terminal.program, lastCommand: terminal.lastCommand,
                                  pid: terminal.foregroundPid, focused: terminal.isWatched)
        }
        router.terminalSessions = {
            let home = TerminalTile.homeLabel, legacy = TerminalTile.legacyHomeLabels
            return await offPool { Zmx.sessions(home: home, legacy: legacy) }
        }
        router.hostedSessions = { hosts in
            var live: [String: Set<ObjectID>] = [:]
            for target in hosts {
                if let host = TerminalHost.existing(target), let running = await host.liveSessions() { live[target] = running }
            }
            return live
        }
        router.restartTerminal = { [weak self] board, tile, argv, killing, ended in
            guard let terminal = self?.content(of: tile, on: board) as? TerminalTile else {
                throw ApiRouter.Failure("unavailable", "terminal \(tile) isn't shown in a window")
            }
            NSLog("easl: restarting terminal %@: %@", tile, argv.joined(separator: " "))
            try await terminal.restart(running: argv, killing: killing, ended: ended)
        }
        router.tmuxPane = { [weak self] board, tile in
            guard let terminal = self?.content(of: tile, on: board) as? TerminalTile else { return nil }
            return await terminal.tmuxPane()
        }
        router.readTerminalBlock = { [weak self] board, tile, index in
            guard let terminal = self?.content(of: tile, on: board) as? TerminalTile else {
                throw ApiRouter.Failure("unavailable", "terminal \(tile) isn't shown in a window")
            }
            return try terminal.block(index)
        }
        router.pageReport = { [weak self] board, tile in
            guard let browser = self?.content(of: tile, on: board) as? BrowserTile else { return nil }
            return await browser.pageReport()
        }
        router.noteExcerpts = { [weak self] board, tile in
            guard let note = self?.content(of: tile, on: board) as? NoteTile else { return nil }
            return await note.resolvedExcerpts()
        }
        router.codeRangeStatus = { [weak self] board, tile in
            guard let code = self?.content(of: tile, on: board) as? CodeTile else { return nil }
            return await code.rangeStatus()
        }
        router.reloadBrowser = { [weak self] board, tile, caller, timeoutMs in
            guard let browser = self?.content(of: tile, on: board) as? BrowserTile else {
                throw ApiRouter.Failure("unavailable", "browser tile \(tile) is not open in a window")
            }
            do {
                return try await browser.reloadPage(driver: caller, timeoutMs: timeoutMs)
            } catch let error as CmuxError {
                throw ApiRouter.Failure(error.code, error.message)
            }
        }
        router.refreshDiagram = { [weak self] board, tile in
            // A board without a window still gets its graph, just without the tile's progress.
            guard let diagram = self?.content(of: tile, on: board) as? DiagramTile else {
                let graph = try await DiagramRefresh.run(tile, on: board, languages: CodeNavigation.languages)
                return DiagramRefresh.summary(tile, graph: graph, computed: graph != nil)
            }
            return await diagram.reload()
        }
        router.snapshotBoard = { [weak self] board, format in await self?.controllers[board.id]?.snapshot(format: format) }
        router.renderView = { [weak self] board, request, format in
            guard let canvas = self?.controllers[board.id]?.canvas else { throw ApiRouter.Failure("unavailable", "board \(board.id) has no window") }
            return try await canvas.render(request, format: format)
        }
        router.viewState = { [weak self] board in self?.controllers[board.id]?.canvas.viewState }
        router.showOpenedLink = { [weak self] board, opened, source in self?.controllers[board.id]?.canvas.showOpenedLink(opened, openedFrom: source) }
        router.openBoard = { [weak self, registry] root, select in
            self?.open(root: root, select: select) ?? registry.open(root: root)
        }
        router.readTerminal = { [weak self] board, tile, lines in
            // Rows the terminal soft-wrapped join when its tile knows its width; the live
            // screen's by Ghostty's own wrap flags.
            let terminal = self?.content(of: tile, on: board) as? TerminalTile
            let columns = terminal?.columns, screen = terminal?.screenRows() ?? []
            // A hosted terminal's session is on its host (`zmx history` over ssh).
            let host = board.objects[tile].flatMap(HostedTerminal.host(of:)).map { TerminalHost.named($0).route }
            // A blocking subprocess read (`offPool`).
            return await offPool { TerminalTile.history(session: TerminalTile.sessionName(tile), on: host, lines: lines, columns: columns, screen: screen) }
        }
        let router = router
        let server = SocketServer(path: AppPaths.apiSocket) { request, connection in
            await router.handle(request, connection: connection)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("easl: cannot listen on \(AppPaths.apiSocket): \(error)")
        }
        cmux.perform = { [weak self] board, object, command, driver in
            guard let tile = self?.controllers[board.id]?.canvas.tiles[object.id]?.content as? BrowserTile else {
                throw CmuxError("unavailable", "browser surface \(object.id) is not open in a window")
            }
            return try await tile.perform(command, driver: driver)
        }
        let cmux = cmux
        let cmuxServer = SocketServer(path: AppPaths.cmuxSocket, acceptsTextLines: true) { request, connection in
            await cmux.handle(request, connection: connection)
        }
        do {
            try cmuxServer.start()
            self.cmuxServer = cmuxServer
        } catch {
            NSLog("easl: cannot listen on \(AppPaths.cmuxSocket): \(error)")
        }
        hyper.install()
        let saved = Self.savedOpenBoards()
        // Decided before any board opens, so a new home's first board doesn't count as a board
        // an existing user had.
        let getStarted = GetStarted.Store(url: AppPaths.getStarted).launch(boards: AppPaths.boards)
        // Boards are per repository now: legacy per-branch boards fold into theirs, once, before
        // any opens (docs/design/repo-boards.md).
        let migration = registry.store.migrateToRepoBoards(knownRoots: saved + [Self.initialRoot()])
        if let report = migration, !report.repos.isEmpty || !report.unresolved.isEmpty {
            let temporary = report.repos.flatMap(\.legacy).filter { $0.temporary && $0.region != nil }.map { "\($0.label) (\($0.worktree ?? ""))" }
            NSLog("easl: merged \(report.repos.reduce(0) { $0 + $1.legacy.count }) per-branch boards into \(report.repos.count) repository boards (\(report.unresolved.count) left as they were)\(temporary.isEmpty ? "" : "; regions from temporary worktrees: " + temporary.joined(separator: ", ")); report in \(AppPaths.boards.path)/\(RepoBoardMigration.backupFolder)/\(RepoBoardMigration.reportFile)")
        }
        // Before boards open, so their pages load with the extensions' content scripts.
        BrowserExtensions.start()
        let initial = open(root: Self.initialRoot())
        // The other boards that were open as tabs come back behind the initial one (one tab per
        // board: two saved worktrees of one repository are one board).
        var reopened: Set<BoardID> = [initial.id]
        for root in saved where BoardStore.isDirectory(root.path) && reopened.insert(BoardStore.boardID(for: root)).inserted {
            open(root: root, select: false)
        }
        // After the window's first layout, so the practice note lands in view.
        if getStarted, let controller = controllers[initial.id] {
            DispatchQueue.main.async { controller.showGetStarted() }
        }
        if let migration {
            for (id, controller) in controllers { migration.notice(for: id).map(controller.canvas.showNotice) }
        }
        // Testing on a shared machine: EASL_NO_ACTIVATE=1 keeps the app from taking focus.
        if ProcessInfo.processInfo.environment["EASL_NO_ACTIVATE"] != "1" {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Quit even while a sheet or app-modal dialog is up: cancel them, then terminate once the
    /// modal loop has unwound.
    private static func terminateNow() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        }
        if NSApp.modalWindow != nil {
            NSApp.abortModal()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in controllers.values { controller.canvas.saveViewport() }
        registry.store.flush(Array(registry.boards.values))
        for controller in controllers.values { controller.saveComposer() }
        server?.stop()
        cmuxServer?.stop()
        // Normal quitting closes no sheet or connection, and a relay left to see its stdin close
        // may outlive the app (an `nc` without `-N`): end every ssh before exiting, and wait.
        OpenRemotePanel.shutdown()
        RemoteProcesses.shared.terminateAll()
        // Hosted terminals' connections; their sessions keep running on their hosts.
        TerminalHost.closeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting closes every window; those closes mustn't erase the tabs to reopen.
        terminating = true
        return CodeNavigation.terminateServers()
    }

    private var terminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Opens a directory's board as a tab of the frontmost board window (its own window when it's
    /// the first). `select` brings its tab forward; the API's `board.open` leaves the user's
    /// current tab showing unless asked.
    @discardableResult
    func open(root: URL, select: Bool = true) -> Board {
        let board = registry.open(root: root)
        let controller = controllers[board.id] ?? CanvasWindowController(board: board, registry: registry)
        controllers[board.id] = controller
        if !openedOrder.contains(board.id) { openedOrder.append(board.id) }
        controller.onNextNeedsYou = { [weak self] from in self?.goToNextNeedsYou(from: from) }
        let router = router
        controller.sendPrompt = { [weak board] text, terminal, mentions, answer in
            guard let board else { return }
            try await router.composerPrompt(text, to: terminal, on: board, mentions: mentions, answer: answer)
        }
        controller.showWorktree(openedAt: root)
        controller.onClose = { [weak self, weak controller] in self?.saveOpenBoards(closing: controller?.window) }
        guard let window = controller.window else { return board }
        defer { saveOpenBoards() }
        let noActivate = ProcessInfo.processInfo.environment["EASL_NO_ACTIVATE"] == "1"
        if !isShown(window), let host = tabHost(excluding: window) {
            let front = host.tabGroup?.selectedWindow ?? host
            // `addTabbedWindow` onto a minimized window shows the new one by itself on the
            // current Space; the group takes it as a hidden tab.
            if host.isMiniaturized, let group = host.tabGroup { group.addWindow(window) } else { host.addTabbedWindow(window, ordered: .above) }
            if !select { window.tabGroup?.selectedWindow = front }
        } else if !isShown(window) {
            if noActivate { window.orderBack(nil) } else { controller.showWindow(nil) }
            return board
        }
        guard select else { return board }
        bringForward(window)
        return board
    }

    /// Brings `window`'s tab, or the window, forward. Selecting a tab of a minimized group also
    /// detaches it onto the current Space: bring the group back first (the user asked to see
    /// this board). An instance that never activates leaves the tab waiting in the minimized
    /// group.
    private func bringForward(_ window: NSWindow) {
        let noActivate = ProcessInfo.processInfo.environment["EASL_NO_ACTIVATE"] == "1"
        if let minimized = window.tabGroup?.windows.first(where: \.isMiniaturized) {
            if noActivate { return }
            minimized.deminiaturize(nil)
        }
        window.tabGroup?.selectedWindow = window
        if !noActivate { window.makeKeyAndOrderFront(nil) }
    }

    /// The open boards (shown, minimized or a tab) in tab/window order: a tab group's boards
    /// together in tab order, and groups and lone windows by when their first board was opened.
    private func openBoardsInOrder() -> [CanvasWindowController] {
        let open = openedOrder.compactMap { controllers[$0] ?? remoteControllers[$0] }.filter { $0.window.map(isShown) ?? false }
        var ordered: [CanvasWindowController] = []
        for controller in open where !ordered.contains(where: { $0 === controller }) {
            let windows = controller.window?.tabbedWindows ?? controller.window.map { [$0] } ?? []
            ordered += windows.compactMap { window in open.first { $0.window === window } }
        }
        return ordered
    }

    /// A remote board's window by its host and board (`remoteControllers`, `openedOrder`).
    private static func remoteKey(_ host: RemoteHost, _ board: BoardID) -> String { "\(host.sshTarget)|\(board)" }

    /// A board window in ⌘J's tour: its board's id, a remote board's with its host (another
    /// host's board may have the id of one of ours).
    private func tourKey(_ controller: CanvasWindowController) -> String {
        controller.remote.map { Self.remoteKey($0.host, controller.board.id) } ?? controller.board.id
    }

    /// ⌘J, Go to Next Needs-You, on `current`, the board the user is on: the next thing that needs
    /// them there (blocked agents first, then markers, then agents that finished unseen, each in
    /// reading order: `NeedsYouItem`), and once it has nothing after the item visited last, the
    /// first on the next open board that has anything, in tab/window order and around (`NeedsYouTour`),
    /// remote boards' windows included. That board's tab or window comes forward and the item is
    /// framed, selected and focused like Go to; a notice says when no board needs the user.
    func goToNextNeedsYou(from current: CanvasWindowController) {
        let boards = openBoardsInOrder()
        let entries = boards.map { NeedsYouTour.Entry(board: tourKey($0), items: $0.canvas.needsYouItems) }
        guard let stop = NeedsYouTour.next(from: tourKey(current), after: current.canvas.needsYouCursor, in: entries) else {
            return current.canvas.showNotice("Nothing needs you")
        }
        guard let target = boards.first(where: { tourKey($0) == stop.board }) else { return }
        if let window = target.window, target !== current {
            bringForward(window)
            // A tab never shown has not been laid out: the item is framed in the view's real size.
            window.contentView?.layoutSubtreeIfNeeded()
        }
        target.canvas.visit(stop.item)
    }

    /// Opens a window mirroring `board` on `host` (docs/design.md "Client mode"): a tab of the
    /// frontmost board window, or its own window when there's none; again, its tab comes forward.
    /// The board is read before the window opens, so a host that can't be reached, or that has no
    /// such board, says so in an alert instead. Nothing about the board is written on this Mac.
    func openRemoteBoard(host: RemoteHost, board: BoardID) {
        let key = Self.remoteKey(host, board)
        if let open = remoteControllers[key], let window = open.window {
            window.tabGroup?.selectedWindow = window
            if ProcessInfo.processInfo.environment["EASL_NO_ACTIVATE"] != "1" { window.makeKeyAndOrderFront(nil) }
            return
        }
        let mirror = BoardMirror(hostName: host.name, board: board, connection: host.connection(), renders: host.connection())
        Task { @MainActor [weak self] in
            let loaded: Board
            do {
                loaded = try await mirror.load()
            } catch {
                mirror.close()
                let alert = NSAlert()
                alert.messageText = "Couldn't open the board on \(host.name)"
                alert.informativeText = BoardMirror.reason(error)
                // A sheet: a modal run loop would stall every socket request.
                if let window = self?.keyController?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
                return
            }
            guard let self else { return mirror.close() }
            let controller = CanvasWindowController(board: loaded, registry: self.registry, remote: RemoteSource(host: host, mirror: mirror))
            self.remoteControllers[key] = controller
            if !self.openedOrder.contains(key) { self.openedOrder.append(key) }
            loaded.onEvent = { [weak controller] event in controller?.apply(event) }
            controller.onNextNeedsYou = { [weak self] from in self?.goToNextNeedsYou(from: from) }
            controller.onClose = { [weak self] in self?.remoteControllers.removeValue(forKey: key) }
            self.show(controller)
        }
    }

    /// A new board window as a tab of the frontmost one (its own window when there's none), selected.
    private func show(_ controller: CanvasWindowController) {
        guard let window = controller.window else { return }
        let noActivate = ProcessInfo.processInfo.environment["EASL_NO_ACTIVATE"] == "1"
        if let host = tabHost(excluding: window) {
            if host.isMiniaturized, let group = host.tabGroup { group.addWindow(window) } else { host.addTabbedWindow(window, ordered: .above) }
            window.tabGroup?.selectedWindow = window
            if !noActivate { window.makeKeyAndOrderFront(nil) }
        } else if noActivate {
            window.orderBack(nil)
        } else {
            controller.showWindow(nil)
        }
    }

    /// A tab that isn't selected is ordered out and a minimized window isn't visible, so "shown"
    /// means visible, minimized, or in a tab group.
    private func isShown(_ window: NSWindow) -> Bool {
        window.isVisible || window.isMiniaturized || (window.tabGroup?.windows.count ?? 0) > 1
    }

    /// The board window new boards join as tabs: the key one, else any on screen, else a
    /// minimized one (a board opened while the window is in the Dock joins it there rather than
    /// opening a window of its own on the user's current Space).
    private func tabHost(excluding window: NSWindow) -> NSWindow? {
        let windows = controllers.values.compactMap(\.window).filter { $0 !== window && ($0.isVisible || $0.isMiniaturized) }
        return windows.first(where: \.isKeyWindow) ?? windows.first(where: \.isVisible) ?? windows.first
    }

    /// Records the shown boards' roots in tab order (AppPaths.openBoards) for the next launch.
    /// Closing the last board window quits easl (`applicationShouldTerminateAfterLastWindowClosed`),
    /// so that board stays recorded, as Quit keeps every tab.
    private func saveOpenBoards(closing: NSWindow? = nil) {
        guard !terminating else { return }
        let open = controllers.values.filter { $0.window.map(isShown) ?? false }
        let others = open.filter { $0.window !== closing }
        let shown = others.isEmpty ? open : others
        let order = shown.first?.window?.tabbedWindows ?? []
        let roots = shown.sorted { lhs, rhs in
            (order.firstIndex { $0 === lhs.window } ?? .max) < (order.firstIndex { $0 === rhs.window } ?? .max)
        }.map(\.board.root.path)
        guard let data = try? JSONEncoder().encode(roots) else { return }
        try? data.write(to: AppPaths.openBoards, options: .atomic)
    }

    private static func savedOpenBoards() -> [URL] {
        guard let data = try? Data(contentsOf: AppPaths.openBoards), let roots = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return roots.map { URL(fileURLWithPath: $0) }
    }

    /// The requested root, else home (launched from Finder or `open` without a root).
    static func initialRoot() -> URL {
        requestedRoot() ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// EASL_ROOT, else the first non-flag argument, else the working directory unless it's
    /// `/` (Finder and `open` launch there, so it names no directory).
    static func requestedRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let root = env["EASL_ROOT"] { return URL(fileURLWithPath: root) }
        if let argument = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) { return URL(fileURLWithPath: argument) }
        let cwd = FileManager.default.currentDirectoryPath
        return cwd == "/" ? nil : URL(fileURLWithPath: cwd)
    }

    /// The board the user is on (`CanvasWindowController.frontmost`).
    fileprivate var keyController: CanvasWindowController? {
        CanvasWindowController.frontmost ?? controllers.values.first
    }

    /// Tile `id`'s content in `board`'s window, for the router's questions only a live tile answers.
    private func content(of id: ObjectID, on board: Board) -> (any TileContent)? {
        controllers[board.id]?.canvas.tiles[id]?.content
    }

    @objc func newTerminal(_ sender: Any?) { keyController?.newTerminal(sender) }
    @objc func newBrowserTile(_ sender: Any?) {
        guard let controller = keyController, let window = controller.window else { return }
        BrowserTile.promptForNew(in: window) { [weak controller] url in
            controller?.canvas.openForUser(.browser, props: .object(["url": .string(url.absoluteString)]))
        }
    }
    @objc func openCodeTile(_ sender: Any?) { keyController?.openCodeTile(sender) }
    /// An empty note in view, editing (`CanvasView.openForUser`).
    @objc func newNote(_ sender: Any?) {
        keyController?.canvas.openForUser(.note, props: .object(["markdown": .string("")]))
    }

    @objc func newHtmlTile(_ sender: Any?) {
        keyController?.canvas.openForUser(.html, props: .object(["html": .string(HtmlKit.emptyTemplate), "title": .string("HTML")]))
    }
    @objc func zoomToActual(_ sender: Any?) { keyController?.zoomToActual(sender) }
    @objc func increaseChromeText(_ sender: Any?) { ChromeText.step(bigger: true) }
    @objc func decreaseChromeText(_ sender: Any?) { ChromeText.step(bigger: false) }
    @objc func resetChromeText(_ sender: Any?) { ChromeText.reset() }
    @objc func zoomOut(_ sender: Any?) { keyController?.zoomOut(sender) }
    @objc func zoomIn(_ sender: Any?) { keyController?.zoomIn(sender) }
    @objc func zoomToFit(_ sender: Any?) { keyController?.zoomToFit(sender) }
    @objc func showNavigator(_ sender: Any?) { keyController?.showNavigator(sender) }
    @objc func toggleBasics(_ sender: Any?) { keyController?.toggleBasics(sender) }
    @objc func toggleGetStarted(_ sender: Any?) { keyController?.toggleGetStarted(sender) }
    @objc func toggleCanvasChrome(_ sender: Any?) { keyController?.toggleCanvasChrome(sender) }
    @objc func toggleLassoSelection(_ sender: Any?) { keyController?.toggleLassoSelection(sender) }
    @objc func exitGroup(_ sender: Any?) { keyController?.exitGroup(sender) }
    @objc func togglePerformanceHUD(_ sender: Any?) { MetricsHUD.shared.toggle() }
    @objc func undoCanvas(_ sender: Any?) { keyController?.undoCanvas(sender) }
    @objc func redoCanvas(_ sender: Any?) { keyController?.redoCanvas(sender) }
    @objc func deleteSelection(_ sender: Any?) { keyController?.deleteSelection(sender) }
    @objc func selectAll(_ sender: Any?) { keyController?.selectAllObjects(sender) }
    @objc func groupSelection(_ sender: Any?) { keyController?.groupSelection(sender) }
    @objc func ungroupSelection(_ sender: Any?) { keyController?.ungroupSelection(sender) }
    @objc func bringToFront(_ sender: Any?) { keyController?.bringToFront(sender) }
    @objc func sendToBack(_ sender: Any?) { keyController?.sendToBack(sender) }
    @objc func pasteMentions(_ sender: Any?) { keyController?.pasteMentions(sender) }
    @objc func mentionCurrent(_ sender: Any?) { keyController?.mentionCurrent(sender) }
    @objc func focusComposer(_ sender: Any?) { keyController?.focusComposer(sender) }
    @objc func removeLastMention(_ sender: Any?) { keyController?.removeLastMention(sender) }
    @objc func clearMentions(_ sender: Any?) { keyController?.clearMentions(sender) }
    @objc func goToNextNeedsYou(_ sender: Any?) { keyController?.goToNextNeedsYou(sender) }
    @objc func navigateBack(_ sender: Any?) { keyController?.navigateBack(sender) }
    @objc func navigateForward(_ sender: Any?) { keyController?.navigateForward(sender) }
    @objc func reviewChanges(_ sender: Any?) { keyController?.reviewChanges(sender) }
    @objc func reviewBranch(_ sender: Any?) { keyController?.reviewBranch(sender) }
    @objc func clearAttentionMarkers(_ sender: Any?) { keyController?.clearAttentionMarkers(sender) }
    @objc func toggleFollowFiles(_ sender: Any?) { keyController?.toggleFollowFiles(sender) }
    @objc func zoomContent(_ sender: Any?) { keyController?.zoomContent(sender) }
    @objc func zoomContentIn(_ sender: Any?) { keyController?.zoomContentIn(sender) }
    @objc func zoomContentOut(_ sender: Any?) { keyController?.zoomContentOut(sender) }
    @objc func copyObjectIDs(_ sender: Any?) { keyController?.copyObjectIDs(sender) }
    @objc func enterGroup(_ sender: Any?) { keyController?.enterGroup(sender) }
    @objc func goToDefinition(_ sender: Any?) { keyController?.goToDefinition(sender) }
    @objc func openDefinitionInNewTile(_ sender: Any?) { keyController?.openDefinitionInNewTile(sender) }
    @objc func findReferences(_ sender: Any?) { keyController?.findReferences(sender) }
    @objc func showOutline(_ sender: Any?) { keyController?.showOutline(sender) }
    @objc func leaveTile(_ sender: Any?) { keyController?.leaveTile(sender) }
    @objc func copyAsImage(_ sender: Any?) { keyController?.copyAsImage(sender) }
    @objc func saveAsPNG(_ sender: Any?) { keyController?.saveAsPNG(sender) }
    @objc func saveHTMLTile(_ sender: Any?) { keyController?.saveHTMLTile(sender) }
    @objc func openHTMLTileInBrowser(_ sender: Any?) { keyController?.openHTMLTileInBrowser(sender) }
    @objc func openPageInBrowser(_ sender: Any?) { keyController?.openPageInBrowser(sender) }
    @objc func copyNoteAsMarkdown(_ sender: Any?) { keyController?.copyNoteAsMarkdown(sender) }
    @objc func saveNoteAsMarkdown(_ sender: Any?) { keyController?.saveNoteAsMarkdown(sender) }
    @objc func toggleWebInspector(_ sender: Any?) { keyController?.toggleWebInspector(sender) }
    @objc func reloadPage(_ sender: Any?) { keyController?.reloadPage(sender) }
    @objc func snapshotPage(_ sender: Any?) { keyController?.snapshotPage(sender) }
    @objc func printPage(_ sender: Any?) { keyController?.printPage(sender) }
    @objc func findInPage(_ sender: Any?) { keyController?.findInPage(sender) }
    @objc func clearBrowsingData(_ sender: Any?) {
        guard let controller = keyController, let window = controller.window else { return }
        let profiles = Set(registry.boards.values.flatMap { $0.objects.values }.filter { $0.type == .browser }.compactMap { BrowserProfile.name(in: $0.props) })
        BrowserProfile.confirmClear(in: window, profiles: profiles) { [weak controller] in controller?.canvas.showNotice("Browsing data cleared") }
    }

    /// The tab bar's + button: open another board as a tab.
    @objc func newWindowForTab(_ sender: Any?) { openBoard(sender) }

    /// One canvas per directory: choosing a folder opens (or brings forward) its board. A sheet,
    /// not `runModal`: a modal run loop would stall every socket request until the user answers.
    @objc func openBoard(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open Board"
        panel.directoryURL = keyController?.board.root
        let chosen: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(root: url)
        }
        if let window = keyController?.window {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }

    /// File › Open Remote…: a board on another machine, over ssh (`OpenRemotePanel`).
    @objc func openRemote(_ sender: Any?) {
        OpenRemotePanel.show(over: keyController?.window) { [weak self] host, board in
            self?.openRemoteBoard(host: host, board: board)
        }
    }

    static func makeMenu() -> NSMenu {
        let main = NSMenu()
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("easl", [
            // Every browser tile's cookies, storage and caches (`BrowserProfile`), after a sheet.
            item("Clear Browsing Data…", #selector(clearBrowsingData(_:)), ""),
            // Safari web extensions in browser tiles (`BrowserExtensions`), filled as it opens.
            BrowserExtensions.menuItem(),
            .separator(),
            item("Quit easl", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Terminal", #selector(newTerminal(_:)), "t"),
            item("New Note", #selector(newNote(_:)), "n"),
            // Shifted items use the uppercase key: a lowercase key with a Shift mask also matches
            // the plain ⌘ key (⌘O opened Open Board, ⌘B New Browser Tile).
            item("New Browser Tile…", #selector(newBrowserTile(_:)), "B", [.command, .shift]),
            item("Open File as Code Tile…", #selector(openCodeTile(_:)), "o"),
            item("Open Board…", #selector(openBoard(_:)), "O", [.command, .shift]),
            item("Open Remote…", #selector(openRemote(_:)), ""),
            item("New HTML Tile", #selector(newHtmlTile(_:)), "H", [.command, .shift]),
            item("Review Changes", #selector(reviewChanges(_:)), "R", [.command, .shift]),
            item("Review Branch", #selector(reviewBranch(_:)), ""),
            .separator(),
            item("Export Selection as PNG…", #selector(saveAsPNG(_:)), "E", [.command, .shift]),
            item("Save HTML Tile as HTML…", #selector(saveHTMLTile(_:)), ""),
            item("Open HTML Tile in Browser", #selector(openHTMLTileInBrowser(_:)), ""),
            item("Open Page in Browser", #selector(openPageInBrowser(_:)), ""),
            item("Save Note as Markdown…", #selector(saveNoteAsMarkdown(_:)), ""),
            // The focused or selected browser tile's page, frozen as an image tile beside it.
            item("Snapshot Page to Image", #selector(snapshotPage(_:)), ""),
            // The focused or selected browser tile's page, through the print panel (⌘P is Go to…).
            item("Print Page…", #selector(printPage(_:)), ""),
            .separator(),
            // The board window takes ⌘W first to close the selection or the focused terminal
            // (CanvasWindowController.handleKeyEquivalent); with neither, the tab or window closes.
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", #selector(undoCanvas(_:)), "z"),
            item("Redo", #selector(redoCanvas(_:)), "Z", [.command, .shift]),
            .separator(),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Copy as Image", #selector(copyAsImage(_:)), "C", [.command, .shift]),
            item("Copy Note as Markdown", #selector(copyNoteAsMarkdown(_:)), ""),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Delete Selection", #selector(deleteSelection(_:)), "\u{8}"),
            .separator(),
            // The focused or selected browser tile's find bar. A page with the keyboard sees ⌘F
            // first (a web app's own find); a code tile's ⌘F is the board window's
            // (CanvasWindowController.handleKeyEquivalent) and a terminal's is its own.
            item("Find in Page…", #selector(findInPage(_:)), "f"),
            .separator(),
            // Hyper-V: no shell, TUI, or Ghostty default binding uses all four modifiers.
            item("Paste Mentions into Terminal", #selector(pasteMentions(_:)), "v", [.control, .option, .shift, .command]),
            // ⇧⌘M: no shell or TUI sees ⌘, Ghostty binds nothing to it, and the board window
            // takes it ahead of a focused terminal (CanvasWindowController.handleKeyEquivalent).
            item("Mention", #selector(mentionCurrent(_:)), "M", [.command, .shift]),
            // The tray from the keyboard: take chips off, pick the terminal they go to. ⌥⇧⌘M
            // beside Mention's ⇧⌘M: no shell sees ⌘, and neither macOS nor Ghostty binds it.
            item("Remove Last Mention", #selector(removeLastMention(_:)), "M", [.command, .shift, .option]),
            TrayMenu.item("Remove Mention"),
            item("Clear Mentions", #selector(clearMentions(_:)), ""),
            TrayMenu.item("Send Mentions To"),
            // ⌘I as Cursor's composer: no shell sees ⌘, Ghostty binds nothing to it, and the
            // board window takes it ahead of a focused terminal or page
            // (CanvasWindowController.handleKeyEquivalent).
            item("Write Prompt", #selector(focusComposer(_:)), "i"),
        ])
        // Content Zoom: how big a tile's content draws inside its frame, in place (View ▸ Zoom
        // In/Out, ⌘= / ⌘-, zoom the board); the selection, else the tile holding the keyboard
        // (`CanvasView.zoomTargets`). ⌃⌘ chords: ⌥⌘= / ⌥⌘- are macOS Zoom's (Accessibility),
        // which the people who need bigger text use; Ghostty's ⌃⌘= (equalize splits) has no
        // splits here, and a focused terminal's menu shortcuts beat its bindings
        // (CanvasWindowController.handleKeyEquivalent).
        let zoom = NSMenuItem(title: "Content Zoom", action: nil, keyEquivalent: "")
        zoom.submenu = NSMenu(title: "Content Zoom")
        zoom.submenu?.addItem(item("Zoom Content In", #selector(zoomContentIn(_:)), "=", [.control, .command]))
        zoom.submenu?.addItem(item("Zoom Content Out", #selector(zoomContentOut(_:)), "-", [.control, .command]))
        zoom.submenu?.addItem(.separator())
        for preset in ObjectZoom.presets {
            let item = item(ObjectZoom.percent(preset), #selector(zoomContent(_:)), "")
            item.tag = Int((preset * 100).rounded())
            zoom.submenu?.addItem(item)
        }
        zoom.submenu?.addItem(.separator())
        let actual = item("Reset Content Zoom", #selector(zoomContent(_:)), "0", [.control, .command])
        actual.tag = 100
        zoom.submenu?.addItem(actual)
        submenu("Object", [
            item("Group", #selector(groupSelection(_:)), "g"),
            item("Ungroup", #selector(ungroupSelection(_:)), "G", [.command, .shift]),
            item("Enter Group", #selector(enterGroup(_:)), ""),
            .separator(),
            // "}" and "{": ⇧⌘] and ⇧⌘[ as the key produces them. "]" and "[" with a Shift mask
            // matched the plain ⌘] and ⌘[ (Forward and Back) and never the shifted chords.
            item("Bring to Front", #selector(bringToFront(_:)), "}", [.command, .shift]),
            item("Send to Back", #selector(sendToBack(_:)), "{", [.command, .shift]),
            zoom,
            .separator(),
            // The focused terminal's, else the selected one's (the context menu's toggle).
            item("Follow Files", #selector(toggleFollowFiles(_:)), ""),
            item("Copy Object ID", #selector(copyObjectIDs(_:)), ""),
            .separator(),
            // ⌘W itself is File ▸ Close's (the board window takes it first for the selection).
            item("Close Selection", #selector(deleteSelection(_:)), ""),
        ])
        // The focused code tile's, else the selected one's, at its selection or the first name on
        // its first line (CodeTile.navigate). ⌃⌘ chords: no shell sees ⌘, and Ghostty binds none.
        submenu("Code", [
            item("Go to Definition", #selector(goToDefinition(_:)), "j", [.control, .command]),
            item("Open Definition in New Tile", #selector(openDefinitionInNewTile(_:)), "j", [.control, .option, .command]),
            item("Find References", #selector(findReferences(_:)), "r", [.control, .command]),
            item("Outline", #selector(showOutline(_:)), "o", [.control, .command]),
        ])
        let lasso = item("Lasso Selection", #selector(toggleLassoSelection(_:)), "")
        lasso.state = CanvasView.lassoSelection ? .on : .off
        submenu("View", [
            // ⌘P, not ⌘K: Ghostty binds ⌘K (clear screen) and terminal tiles take it first.
            item("Go to…", #selector(showNavigator(_:)), "p"),
            // ⌘J: no shell sees ⌘, and Ghostty binds nothing to it.
            item("Go to Next Needs-You", #selector(goToNextNeedsYou(_:)), "j"),
            // ⌘Esc: Esc belongs to a terminal's program, so this is the way out of one (and of
            // any tile); the board window takes it before Ghostty's keybinds. No shell sees ⌘.
            item("Leave Tile", #selector(leaveTile(_:)), "\u{1b}"),
            // ⌘[ / ⌘] as in Xcode, PyCharm and Safari: the board window takes them ahead of a
            // terminal (Ghostty's go to split has no splits here); a page with the keyboard goes
            // back itself. Send to Back and Bring to Front are ⇧⌘[ / ⇧⌘].
            item("Back", #selector(navigateBack(_:)), "["),
            item("Forward", #selector(navigateForward(_:)), "]"),
            .separator(),
            item("Actual Size", #selector(zoomToActual(_:)), "0"),
            item("Zoom In", #selector(zoomIn(_:)), "="),
            item("Zoom Out", #selector(zoomOut(_:)), "-"),
            item("Zoom to Fit", #selector(zoomToFit(_:)), "9"),
            .separator(),
            // The app's own text (tray, tile title bars), separate from the board's zoom (⌘= ⌘-)
            // and a tile's content zoom (⌃⌘=). ⌥⌘ so no terminal's font-size key or zoom claims them.
            item("Increase Chrome Text Size", #selector(increaseChromeText(_:)), "=", [.option, .command]),
            item("Decrease Chrome Text Size", #selector(decreaseChromeText(_:)), "-", [.option, .command]),
            item("Reset Chrome Text Size", #selector(resetChromeText(_:)), "0", [.option, .command]),
            .separator(),
            item("Clear Attention Markers", #selector(clearAttentionMarkers(_:)), ""),
            // ⌘R and ⌥⌘I as in Safari: the focused or selected browser tile's page. Disabled
            // otherwise, so the key goes on to whoever has the keyboard.
            item("Reload Page", #selector(reloadPage(_:)), "r"),
            // Show or Hide (`CanvasWindowController.validate`), docked under the address bar.
            item("Show Web Inspector", #selector(toggleWebInspector(_:)), "i", [.option, .command]),
            // Presenting: toolbar, tray, selection rings, author marks, code headers, markers.
            // ⌥⌘T as AppKit's Show/Hide Toolbar; Ghostty binds nothing to it.
            item("Hide Board Chrome", #selector(toggleCanvasChrome(_:)), "t", [.option, .command]),
            lasso,
            item("Exit Group", #selector(exitGroup(_:)), ""),
            .separator(),
            // `app.metrics` at a glance, redrawn each second while shown.
            item("Performance HUD", #selector(togglePerformanceHUD(_:)), ""),
        ])
        // AppKit lists the board windows and tabs here (and the tab commands) itself.
        NSApp.windowsMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        // The Help menu gets AppKit's menu search (⌘?), which finds every item above, the
        // first-run walk-through (`GetStartedPanel`), and the legend of what the canvas shows
        // (`BasicsPanel`), ⌥⌘/ beside that search's ⌘?.
        NSApp.helpMenu = submenu("Help", [
            item("Get Started", #selector(toggleGetStarted(_:)), ""),
            item("easl Basics", #selector(toggleBasics(_:)), "/", [.option, .command]),
        ])
        return main
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Menu items that don't apply now are disabled (the board window decides).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(increaseChromeText(_:)): return ChromeText.canStep(bigger: true)
        case #selector(decreaseChromeText(_:)): return ChromeText.canStep(bigger: false)
        case #selector(resetChromeText(_:)): return ChromeText.scale != ChromeTextScale.normal
        case #selector(togglePerformanceHUD(_:)):
            item.state = MetricsHUD.shared.isShown ? .on : .off
            return true
        case #selector(openRemote(_:)): return true
        default: return keyController?.validate(item) ?? false
        }
    }
}

/// Edit ▸ Remove Mention and Send Mentions To: the tray's chips and the board's terminals, as
/// the tray shows them on the board the user is on, filled each time the submenu opens (menu
/// search too), so a keyboard user can take any chip off and change where they go.
@MainActor
private final class TrayMenu: NSObject, NSMenuDelegate {
    static let shared = TrayMenu()

    static func item(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = shared
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let controller = (NSApp.delegate as? AppDelegate)?.keyController else { return menu.removeAllItems() }
        let removing = menu.title == "Remove Mention"
        if removing { controller.fillRemoveMentionMenu(menu) } else { controller.fillTargetMenu(menu) }
        guard menu.numberOfItems == 0 else { return }
        let none = NSMenuItem(title: removing ? "No Mentions Staged" : "No Terminals", action: nil, keyEquivalent: "")
        none.isEnabled = false
        menu.addItem(none)
    }
}
