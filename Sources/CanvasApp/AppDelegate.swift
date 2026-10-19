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
    private struct OpeningWindow {
        let shown: Task<Void, Never>
        var select: Bool
        var visit: WorktreeVisit?
        var present: Bool
        var controller: CanvasWindowController?
    }
    private var openingWindows: [ObjectIdentifier: OpeningWindow] = [:]
    /// The boards in the order they were first opened, which orders windows that aren't tabs of
    /// one another (`openBoardsInOrder`): a board's id, or a remote board's `remoteKey`.
    private var openedOrder: [String] = []
    /// Remote boards' windows (docs/design.md "Client mode"), by easl and board (`remoteKey`):
    /// another host's board, or another easld's on the same host, may have the id of one of ours.
    /// With background attach a closed window stays here attached, `isBoardOpen` false, as a local
    /// board's closed window stays in `controllers`.
    private var remoteControllers: [String: CanvasWindowController] = [:]
    /// The remote easld boards to attach again (`RemoteReopen`), whether or not they are attached now.
    private let reopenList = RemoteReopen.Store(url: AppPaths.remoteBoards)
    private let settings = UISettings.Store(url: AppPaths.uiSettings)
    /// easl › Keep Remote Boards Attached (`UISettings.backgroundAttach`).
    private var backgroundAttach = true
    private var automaticUpdates = false
    private let updateBoards = UpdateBoardSnapshot.Store(url: AppPaths.updateBoards)
    private var updateRestoration: Task<Void, Never>?
    private var updateRestoreFailure: String?
    private var restoreNoticePending = false
    private var suppressLaunchActivation = AppPaths.isUpdateRelaunch
    /// Reopen-list boards being read to attach with no window shown, by `remoteKey`. Cancelling
    /// one (its board opened by the user, the setting off, quit) keeps it from attaching when its read ends.
    private var backgroundLoads: [String: Task<Void, Never>] = [:]
    /// Tab switches waiting for their tab group's Space to be the active one (`selectTab`), by
    /// tab group.
    private var heldTabs: [ObjectIdentifier: HeldTab] = [:]
    private var heldCloses: [CanvasWindowController] = []
    private var releasingCloses = false
    private var terminationSignal: DispatchSourceSignal?
    private var pasteMaintenance: TerminalPaste.Maintenance?
    private var localRestore: Task<Void, Never>?
    private let notifier = AgentNotifier()
    private lazy var hyper = HyperMonitor { [weak self] window in
        guard let self,
              let controller = self.controllers.values.first(where: { $0.window === window })
                ?? self.remoteControllers.values.first(where: { $0.window === window }),
              !controller.hostBoardClosed else { return nil }
        return controller.canvas
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        localRestore = Task { @MainActor in await restoreBoardsAtLaunch() }
        NSApp.mainMenu = Self.makeMenu()
        registry.drawingMachine = ClientIdentity.thisMac.drawingMachine
        MainMetricsBatch.shared.start()
        UserIdleWatch.shared.start()
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
        // A main thread stuck for a second gets `sample`d into <home>/stalls/ (docs/design.md,
        // Metrics); never during a measured run, which would see the sampler's own cost.
        if !DevPerf.enabled { Metrics.shared.sampleStalls(into: AppPaths.support.appendingPathComponent("stalls", isDirectory: true)) }
        // easl's own leftovers: dead sessions' zmx logs, read Ghostty configs, old renders.
        Housekeeping.pruneAtLaunch()
        pasteMaintenance = TerminalPaste.Maintenance(baseDirectories: [AppPaths.support, FileManager.default.temporaryDirectory])
        if let url = AppPaths.asset(DrawingStyle.fontAsset) { DrawingStyle.registerFonts(url) }
        registry.onEvent = { [weak self] board, event in
            self?.window(drawing: board)?.apply(event)
            self?.notifier.observe(event, on: board)
        }
        // Every delete of a terminal (UI close, API, batch, undo/redo) ends its zmx session (a
        // hosted one's on its host), and with it any report its agent spooled here
        // (`AgentReportSpool`), which nothing would replay.
        registry.onTerminalsEnded = { board, ended in
            for terminal in ended { TerminalTile.killSession(terminal, board: board.id) }
            Self.removeSpooledReports(ended)
        }
        // object.measure, size: "fit", and layout.check lay HTML pages out in WebKit.
        ObjectMeasure.html = { props, width, root in try await HtmlTile.measure(props: props, width: width, root: root) }
        notifier.onOpen = { [weak self] board, tile in
            Task { @MainActor in
                await self?.localRestore?.value
                guard let self, var controller = self.controllers[board] else { return }
                if !controller.isBoardOpen || controller.window.map(self.isHoldingClose) == true {
                    let reopened = await self.open(root: controller.board.root, select: false)
                    guard let open = self.controllers[reopened.id] else { return }
                    controller = open
                }
                guard !self.terminating, let window = controller.window, self.bringForward(window) else { return }
                if !CanvasApplication.neverActivate {
                    NSApp.activate(ignoringOtherApps: true)
                }
                controller.canvas.focus(tile: tile)
            }
        }
        notifier.install()
        router.updateApp = { try await Updater.shared.apiUpdate(mode: $0) }
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
        router.surface = { [weak self, registry] request, connection in
            guard self != nil else { throw ApiRouter.Failure("unavailable", "easl is quitting") }
            let peer = SocketPeer(connection: connection, registry: registry) { [weak self] board, id in self?.content(of: id, on: board) as? BrowserTile }
            return try await BrowserSurfaceHost.shared.handle(request, from: peer)
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
            if let self { return await self.open(root: root, select: select) }
            return await registry.open(root: root)
        }
        router.closeBoard = { [weak self] board, endSessions in
            guard let self else { throw ApiRouter.Failure("unavailable", "easl is quitting") }
            return try await self.closeBoard(board, endSessions: endSessions)
        }
        router.openRemoteBoard = { [weak self] host, board, select in
            guard let self else { throw ApiRouter.Failure("unavailable", "easl is quitting") }
            return try await self.openRemoteBoard(named: host, board: board, select: select)
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
        let server = SocketServer(path: AppPaths.apiSocket) { [weak self] request, connection in
            await self?.localRestore?.value
            return await router.handle(request, connection: connection)
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
        let cmuxServer = SocketServer(path: AppPaths.cmuxSocket, acceptsTextLines: true) { [weak self] request, connection in
            await self?.localRestore?.value
            return await cmux.handle(request, connection: connection)
        }
        do {
            try cmuxServer.start()
            self.cmuxServer = cmuxServer
        } catch {
            NSLog("easl: cannot listen on \(AppPaths.cmuxSocket): \(error)")
        }
        hyper.install()
        BrowserExtensions.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(showHeldTabs), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showHeldTabs), name: NSWindow.didDeminiaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showHeldTabs), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(showPendingUpdateRestoreFailure), name: name, object: nil)
        }
    }

    private func restoreBoardsAtLaunch() async {
        defer {
            localRestore = nil
            saveOpenBoards()
            if updateRestoration == nil { suppressLaunchActivation = false }
            showPendingUpdateRestoreFailure()
        }
        let settings = self.settings
        let configured = (try? await ClientFiles.read { settings.load() }) ?? UISettings()
        guard !terminating else { return }
        registry.defaultQuestionArchiveAfter = configured.questionArchiveAfter
        backgroundAttach = configured.backgroundAttach
        automaticUpdates = configured.installUpdatesAutomatically
        ChromeText.configure(configured.chromeTextScale)
        let saved = await Self.savedOpenBoards()
        let updateBoards = self.updateBoards
        var updateRecovery: UpdateBoardSnapshot.Store?
        var updateSnapshot: UpdateBoardSnapshot?
        do {
            if AppPaths.isUpdateRelaunch {
                (updateRecovery, updateSnapshot) = try await ClientFiles.read {
                    let recovery = try updateBoards.retainForRecovery(in: AppPaths.updateBoardRecovery)
                    return (recovery, try recovery?.load())
                }
            }
            if updateRecovery == nil { try await refreshUpdateRecovery() }
        } catch {
            reportUpdateRestoreFailure(error.localizedDescription)
        }
        let initialRoot = await offPool { Self.initialRoot() }
        let getStarted = await offPool {
            GetStarted.Store(url: AppPaths.getStarted).launch(boards: AppPaths.boards)
        }
        let updateRoots = updateSnapshot?.groups.flatMap(\.tabs).compactMap { tab -> URL? in
            if case .local(let root) = tab { return URL(fileURLWithPath: root) }
            return nil
        } ?? []
        let migration = await registry.store.migrateToRepoBoards(knownRoots: saved + updateRoots + [initialRoot])
        guard !terminating else { return }
        if let report = migration, !report.repos.isEmpty || !report.unresolved.isEmpty {
            let temporary = report.repos.flatMap(\.legacy).filter { $0.temporary && $0.region != nil }.map { "\($0.label) (\($0.worktree ?? ""))" }
            NSLog("easl: merged \(report.repos.reduce(0) { $0 + $1.legacy.count }) per-branch boards into \(report.repos.count) repository boards (\(report.unresolved.count) left as they were)\(temporary.isEmpty ? "" : "; regions from temporary worktrees: " + temporary.joined(separator: ", ")); report in \(AppPaths.boards.path)/\(RepoBoardMigration.backupFolder)/\(RepoBoardMigration.reportFile)")
        }
        Updater.shared.start()
        if let updateSnapshot, let updateRecovery {
            let restoring = Set(updateSnapshot.groups.flatMap(\.tabs).compactMap { tab -> String? in
                if case .remote(let entry) = tab { return Self.remoteKey(entry) }
                return nil
            })
            if backgroundAttach { await attachInBackground(excluding: restoring) }
            beginUpdateRestoration([(updateRecovery, updateSnapshot)])
        } else {
            let initial = await open(root: initialRoot, select: !suppressLaunchActivation)
            for root in saved {
                guard !terminating else { return }
                guard await offPool({ BoardStore.isDirectory(root.path) }) else { continue }
                let id = await offPool { BoardStore.boardID(for: root) }
                guard controllers[id] == nil else { continue }
                await open(root: root, select: false)
            }
            guard !terminating else { return }
            if getStarted, let controller = controllers[initial.id] {
                DispatchQueue.main.async { controller.showGetStarted() }
            }
            if let migration {
                for (id, controller) in controllers { migration.notice(for: id).map(controller.canvas.showNotice) }
            }
            if backgroundAttach { await attachInBackground() }
            guard !terminating else { return }
            if !suppressLaunchActivation, !CanvasApplication.neverActivate, controllers[initial.id]?.window?.isOnActiveSpace == true {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Quit even while a sheet or app-modal dialog is up: cancel them, then terminate once the
    /// modal loop has unwound.
    static func terminateNow() {
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
        ClientFiles.sync {}
        Updater.shared.applicationWillTerminate()
        pasteMaintenance?.stop()
        updateRestoration?.cancel()
        pasteMaintenance = nil
        for controller in controllers.values { controller.canvas.saveViewport() }
        registry.store.flush(Array(registry.boards.values))
        for controller in controllers.values { controller.saveComposer() }
        server?.stop()
        cmuxServer?.stop()
        // Normal quitting closes no sheet or connection, and a relay left to see its stdin close
        // may outlive the app (an `nc` without `-N`): end every ssh before exiting, and wait.
        // Every remote board's attachment ends with its links; the reopen list stays for the next launch.
        OpenRemotePanel.shutdown()
        for load in backgroundLoads.values { load.cancel() }
        backgroundLoads = [:]
        for load in remoteLoads.values { load.cancel() }
        remoteLoads = [:]
        for controller in remoteControllers.values { controller.remote?.mirror.close() }
        RemoteProcesses.shared.terminateAll()
        // Hosted terminals' connections; their sessions keep running on their hosts.
        TerminalHost.closeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting closes every window; those closes mustn't erase the tabs to reopen.
        terminating = true
        localRestore?.cancel()
        updateRestoration?.cancel()
        for opening in openingWindows.values { opening.shown.cancel() }
        return CodeNavigation.terminateServers()
    }

    private var terminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepsRunningWithoutWindows
    }

    var keepsRunningWithoutWindows: Bool {
        updateRestoration != nil || !backgroundLoads.isEmpty || remoteControllers.values.contains { !$0.isBoardOpen }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !terminating, !suppressLaunchActivation, localRestore == nil, updateRestoration == nil else { return false }
        guard !flag else { return true }
        if let retained = remoteControllers.first(where: { !$0.value.isBoardOpen }) {
            _ = shownRemote(retained.key, select: true)
        } else {
            Task { @MainActor in
                let saved = await Self.savedOpenBoards()
                let root: URL
                if let saved = saved.first ?? keyController?.board.root {
                    root = saved
                } else {
                    root = await offPool { Self.initialRoot() }
                }
                await open(root: root)
            }
        }
        return false
    }

    /// Opens a directory's board as a tab of the frontmost board window (its own window when it's
    /// the first). `select` brings its tab forward; the API's `board.open` leaves the user's
    /// current tab showing unless asked.
    @discardableResult
    func open(root: URL, select: Bool = true, present: Bool = true) async -> Board {
        let board = await registry.open(root: root)
        guard !terminating, !board.isClosed else { return board }
        let visit = await offPool { GitWorktree.containing(root.standardizedFileURL.path).map(WorktreeVisit.init) }
        guard canShowWindow(of: board) else { return board }
        if let existing = controllers[board.id] {
            self.present(existing, visit: visit, select: select, show: present)
        } else {
            await openingWindow(of: board, visit: visit, select: select, present: present).value
        }
        return board
    }

    private func canShowWindow(of board: Board) -> Bool {
        !terminating && !board.isClosed && registry.boards[board.id] === board && registry.windowIsOpen(board.id)
    }

    private func window(drawing board: Board) -> CanvasWindowController? {
        if let controller = controllers[board.id], controller.board === board { return controller }
        return openingWindows[ObjectIdentifier(board)]?.controller
    }

    private func openingWindow(of board: Board, visit: WorktreeVisit?, select: Bool, present: Bool) -> Task<Void, Never> {
        let key = ObjectIdentifier(board)
        if var opening = openingWindows[key] {
            opening.select = opening.select || select
            opening.present = opening.present || present
            opening.visit = visit
            openingWindows[key] = opening
            return opening.shown
        }
        let shown = Task { await self.buildWindow(of: board) }
        openingWindows[key] = OpeningWindow(shown: shown, select: select, visit: visit, present: present)
        return shown
    }

    private func buildWindow(of board: Board) async {
        let key = ObjectIdentifier(board), id = board.id
        defer { openingWindows[key] = nil }
        guard canShowWindow(of: board) else { return }
        let client = await offPool {
            let viewport = SavedViewport.Recorder(store: SavedViewport.Store(url: AppPaths.viewport(of: id)))
            let composer = (try? Data(contentsOf: AppPaths.composer(of: id))).flatMap { try? JSONDecoder().decode(ComposerState.self, from: $0) } ?? ComposerState()
            return (viewport, composer)
        }
        guard canShowWindow(of: board) else { return }
        await MainTurns.next()
        guard canShowWindow(of: board) else { return }
        let window = DevPerf.time("board.window.shell") { CanvasWindowController.makeWindow(isRemote: false) }
        await MainTurns.next()
        guard canShowWindow(of: board) else {
            window.close()
            return
        }
        let controller = DevPerf.time("board.window") {
            CanvasWindowController(window: window, board: board, registry: registry, viewport: client.0, composerState: client.1)
        }
        openingWindows[key]?.controller = controller
        await MainTurns.next()
        showBuiltWindow(controller)
    }

    private func showBuiltWindow(_ controller: CanvasWindowController) {
        let board = controller.board
        guard canShowWindow(of: board), let opening = openingWindows[ObjectIdentifier(board)] else {
            return retire(controller, savingFrame: false)
        }
        controller.canvas.scheduleOpeningView()
        present(controller, visit: opening.visit, select: opening.select, show: opening.present)
    }

    private func present(_ controller: CanvasWindowController, visit: WorktreeVisit?, select: Bool, show: Bool) {
        let board = controller.board
        let newWindow = controllers[board.id] == nil
        if let window = controller.window { cancelHeldManualClose(window) }
        controller.isBoardOpen = true
        controller.window?.isExcludedFromWindowsMenu = false
        controllers[board.id] = controller
        if !openedOrder.contains(board.id) { openedOrder.append(board.id) }
        controller.onNextNeedsYou = { [weak self] from in self?.goToNextNeedsYou(from: from) }
        let router = router
        controller.sendPrompt = { [weak board] text, terminal, mentions, answer in
            guard let board else { return }
            try await router.composerPrompt(text, to: terminal, on: board, mentions: mentions, answer: answer)
        }
        controller.showWorktree(visit)
        controller.onClose = { [weak self, weak controller] in self?.saveOpenBoards(closing: controller?.window) }
        guard show, let window = controller.window else { return }
        defer { saveOpenBoards() }
        let noActivate = CanvasApplication.neverActivate || suppressLaunchActivation
        let shown = !newWindow && isShown(window)
        if !shown, let host = tabHost(excluding: window) {
            DevPerf.time("board.tab") { addTab(window, to: host) }
        } else if !shown {
            DevPerf.time("board.show") {
                if noActivate || !select { window.orderBack(nil) } else { controller.showWindow(nil) }
            }
            return
        }
        guard select, !suppressLaunchActivation else { return }
        DevPerf.time("board.select") { _ = bringForward(window) }
    }

    private enum CloseTarget {
        case local(Board, CanvasWindowController?)
        case remote(String, CanvasWindowController)

        var controller: CanvasWindowController? {
            switch self {
            case .local(_, let controller): controller
            case .remote(_, let controller): controller
            }
        }
    }

    private func closeTarget(_ id: BoardID) throws -> CloseTarget {
        if let board = registry.board(id: id) { return .local(board, window(drawing: board)) }
        let matches = remoteControllers.filter { $0.value.board.id == id }
        guard matches.count <= 1 else {
            let easls = matches.values.compactMap { $0.remote.map { "\($0.host.sshTarget) \($0.host.socketPath)" } }.sorted().joined(separator: ", ")
            throw ApiRouter.Failure("ambiguous", "board \(id) is viewed from more than one remote easl: \(easls)")
        }
        guard let (key, controller) = matches.first else { throw ApiRouter.Failure("not_found", "board \(id)") }
        return .remote(key, controller)
    }

    private func closeBoard(_ id: BoardID, endSessions: Bool?) async throws -> BoardCloseResult {
        guard !terminating else { throw ApiRouter.Failure("unavailable", "easl is quitting") }
        if registry.board(id: id) == nil {
            let opening = remoteLoads.compactMap { $0.key.board == id ? $0.value : nil }
            for load in opening { load.cancel() }
            let loads = reopenList.load().filter { $0.board == id }.compactMap { backgroundLoads[Self.remoteKey($0)] }
            for load in loads { await load.value }
            for load in opening { _ = try? await load.value }
            guard !terminating else { throw ApiRouter.Failure("unavailable", "easl is quitting") }
        }
        var target = try closeTarget(id)
        if case .remote = target, endSessions != nil {
            throw ApiRouter.Failure("invalid_params", "board \(id) is a remote tab: its host owns its sessions, so omit endSessions")
        }
        func refuseLastBoard() throws {
            if target.controller?.isLastOpenBoard == true, !keepsRunningWithoutWindows {
                throw ApiRouter.Failure("conflict", "board \(id) is easl's last open board: closing it would quit easl; open another board first")
            }
        }
        try refuseLastBoard()
        target.controller?.apiCloseInProgress = true
        defer { target.controller?.apiCloseInProgress = false }
        let result: BoardCloseResult
        switch target {
        case .local(let board, let controller):
            var ended: [CanvasObject] = []
            do {
                if endSessions == true {
                    let terminals = board.objects.values.filter { $0.type == .terminal }.sorted { $0.id < $1.id }
                    for terminal in terminals {
                        board.beginEndingSession(terminal.id)
                        (controller?.canvas.tiles[terminal.id]?.content as? TerminalTile)?.sessionShutdownChanged()
                    }
                    defer {
                        for terminal in terminals {
                            board.endEndingSession(terminal.id)
                            (window(drawing: board)?.canvas.tiles[terminal.id]?.content as? TerminalTile)?.sessionShutdownChanged()
                        }
                    }
                    for terminal in terminals {
                        guard board.objects[terminal.id] != nil else { continue }
                        let shown = controller?.canvas.tiles[terminal.id]?.content as? TerminalTile
                        do {
                            try await TerminalTile.endSession(terminal, board: board.id)
                        } catch {
                            let message = (error as? ApiRouter.Failure)?.message ?? error.localizedDescription
                            throw ApiRouter.Failure("unavailable", message)
                        }
                        ended.append(terminal)
                        if board.objects[terminal.id] != nil {
                            let callback = registry.onTerminalsEnded
                            registry.onTerminalsEnded = nil
                            defer { registry.onTerminalsEnded = callback }
                            try board.atomically { try board.delete(terminal.id) }
                        }
                        shown?.discard()
                        Self.removeSpooledReports([terminal])
                    }
                }
                guard registry.boards[board.id] === board else { throw ApiRouter.Failure("not_found", "board \(board.id) closed while ending sessions") }
                let controller = window(drawing: board)
                target = .local(board, controller)
                controller?.apiCloseInProgress = true
                try refuseLastBoard()
                guard !terminating else { throw ApiRouter.Failure("unavailable", "easl is quitting") }
                controller?.canvas.saveViewport()
                controller?.saveComposer()
                result = BoardCloseResult(board: board, ended: ended)
                try registry.close(board.id) {
                    do {
                        try writeOpenBoards(openLocalBoards(excluding: controller?.window))
                    } catch {
                        throw ApiRouter.Failure("unavailable", "cannot save open-boards.json before closing \(board.id): \(error.localizedDescription)")
                    }
                }
                controllers.removeValue(forKey: board.id)
                openedOrder.removeAll { $0 == board.id }
            } catch {
                let failure = (error as? ApiRouter.Failure) ?? ApiRouter.Failure("unavailable", error.localizedDescription)
                guard !ended.isEmpty else { throw failure }
                let ids = ended.map(\.id).joined(separator: ", ")
                throw ApiRouter.Failure(failure.code, "\(failure.message); ended terminal sessions [\(ids)]")
            }
        case .remote(let key, let controller):
            // Out of the reopen list first: a board closed with `board.close` stays detached.
            if let entry = controller.remote.flatMap({ RemoteReopen(board: controller.board.id, on: $0.host) }) {
                do {
                    try ClientFiles.sync { try reopenList.forget(entry) }
                } catch {
                    throw ApiRouter.Failure("unavailable", "cannot save remote-boards.json before closing \(id): \(error.localizedDescription)")
                }
            }
            result = BoardCloseResult(board: controller.board)
            remoteControllers.removeValue(forKey: key)
            openedOrder.removeAll { $0 == key }
        }
        if let controller = target.controller {
            let privateWindow = openingWindows[ObjectIdentifier(controller.board)]?.controller === controller
            retire(controller, savingFrame: !privateWindow)
        }
        return result
    }

    /// Ends a board's window for good (`board.close`, a closed remote board detached).
    private func retire(_ controller: CanvasWindowController, savingFrame: Bool = true) {
        controller.onClose = nil
        controller.isBoardOpen = false
        controller.discard()
        guard let window = controller.window else { return }
        let name = window.frameAutosaveName
        if !name.isEmpty {
            if savingFrame { window.saveFrame(usingName: name) }
            window.setFrameAutosaveName("")
        }
        window.isExcludedFromWindowsMenu = true
        window.close()
    }

    private static func removeSpooledReports(_ terminals: [CanvasObject]) {
        let folders = terminals.map { AppPaths.agentReports.appendingPathComponent($0.id, isDirectory: true) }
        Task.detached { for folder in folders { try? FileManager.default.removeItem(at: folder) } }
    }

    func prepareNativeClose(_ controller: CanvasWindowController) -> Bool {
        guard !terminating, controller.isBoardOpen else { return true }
        guard !controller.apiCloseInProgress else { return false }
        if controller.remote == nil {
            registry.setWindowOpen(false, board: controller.board.id)
            return true
        }
        guard let host = controller.remote?.host,
              controller.closing?.outcome(backgroundAttach: backgroundAttach, server: host.server) == .forget,
              let entry = RemoteReopen(board: controller.board.id, on: host) else { return true }
        do {
            try ClientFiles.sync { try reopenList.forget(entry) }
            return true
        } catch {
            controller.closing = nil
            let alert = NSAlert()
            alert.messageText = "Couldn't close the remote tab"
            alert.informativeText = "Cannot save remote-boards.json. The tab is still open. \(error.localizedDescription)"
            if let window = controller.window { alert.beginSheetModal(for: window, completionHandler: nil) }
            return false
        }
    }

    // AppKit orders a selected tab's replacement onto the active Space, even without activation.
    // Keep that native window as the group's anchor until a close cannot promote an off-Space tab.
    func holdNativeClose(_ window: NSWindow) -> Bool {
        if terminating { return false }
        releaseHeldCloses(excluding: window)
        guard shouldHoldNativeClose(window),
              let controller = window.windowController as? CanvasWindowController else {
            heldCloses.removeAll { $0.window === window }
            return false
        }
        if !heldCloses.contains(where: { $0 === controller }) {
            heldCloses.append(controller)
            window.isExcludedFromWindowsMenu = true
            if controller.isBoardOpen {
                saveOpenBoards(closing: window)
                if let host = controller.remote?.host {
                    let key = Self.remoteKey(host, controller.board.id)
                    remoteControllers.removeValue(forKey: key)
                    openedOrder.removeAll { $0 == key }
                    controller.onClose = nil
                    controller.isBoardOpen = false
                    controller.discard()
                } else {
                    controller.onClose = nil
                }
            }
        }
        return true
    }

    private func shouldHoldNativeClose(_ window: NSWindow) -> Bool {
        guard let group = window.tabGroup, group.windows.count > 1, group.selectedWindow === window else { return false }
        return !canPresentTab(window)
    }

    private func canPresentTab(_ window: NSWindow) -> Bool {
        window.isVisible && window.isOnActiveSpace
            && window.tabGroup?.windows.contains(where: \.isMiniaturized) != true
    }

    func isHoldingClose(_ window: NSWindow) -> Bool {
        heldCloses.contains { $0.window === window }
    }

    private func cancelHeldManualClose(_ window: NSWindow) {
        heldCloses.removeAll { $0.window === window && $0.isBoardOpen }
        (window.windowController as? CanvasWindowController)?.closing = nil
        if window.isExcludedFromWindowsMenu { window.isExcludedFromWindowsMenu = false }
    }

    func releaseHeldCloses(excluding excluded: NSWindow? = nil) {
        guard !terminating, !heldCloses.isEmpty, !releasingCloses else { return }
        releasingCloses = true
        defer { releasingCloses = false }
        while !terminating, let index = heldCloses.firstIndex(where: {
            $0.window.map { $0 !== excluded && !shouldHoldNativeClose($0) } ?? true
        }) {
            let controller = heldCloses.remove(at: index)
            controller.window?.close()
        }
    }

    /// Selects the board only where its group already lives. Minimized groups wait for the user
    /// to restore them; selecting or restoring one from another Space can detach its tab there.
    @discardableResult
    private func bringForward(_ window: NSWindow) -> Bool {
        guard (window.windowController as? CanvasWindowController)?.isBoardOpen == true else { return false }
        guard selectTab(window), canPresentTab(window) else { return false }
        if !CanvasApplication.neverActivate { window.makeKeyAndOrderFront(nil) }
        return true
    }

    /// A board window's tab brought forward from outside the app delegate (a web extension's
    /// `windows.focus`), as `bringForward` does.
    func focusBoardWindow(_ window: NSWindow) {
        bringForward(window)
    }

    /// Shows `window`'s tab in its tab group, unless the group is on a Space nobody is viewing:
    /// AppKit shows a newly selected tab on the active Space, out of its group's place and in
    /// front of whatever the user is working on there (2026-10-07: a background
    /// `board.open --select` put a tab on the user's Space; yabai tiled it between their
    /// windows). Such a switch waits until the group's Space is active (`showHeldTabs`), and
    /// a later one for the same group replaces it. True when the tab is shown now.
    @discardableResult
    private func selectTab(_ window: NSWindow) -> Bool {
        guard let group = window.tabGroup else { return true }
        let key = ObjectIdentifier(group)
        // `isOnActiveSpace` of a window that isn't on screen says where it would be ordered in,
        // not where its group is: only a shown tab tells.
        guard let shown = group.selectedWindow else { return false }
        if shown === window {
            heldTabs[key] = nil
            return true
        }
        if !canPresentTab(shown) {
            heldTabs[key] = HeldTab(group: group, window: window, shown: shown)
            return false
        }
        heldTabs[key] = nil
        group.selectedWindow = window
        return true
    }

    /// Releases presentation changes only after the user visits or restores the group's Space.
    @objc private func showHeldTabs() {
        guard !heldTabs.isEmpty || !heldCloses.isEmpty else { return }
        for (key, held) in heldTabs {
            guard let group = held.group, let window = held.window, window.tabGroup === group,
                  (window.windowController as? CanvasWindowController)?.isBoardOpen == true,
                  let shown = group.selectedWindow, shown === held.shown else {
                heldTabs[key] = nil
                continue
            }
            guard canPresentTab(shown) else { continue }
            heldTabs[key] = nil
            let wasKey = shown.isKeyWindow
            group.selectedWindow = window
            if wasKey && !CanvasApplication.neverActivate { window.makeKeyAndOrderFront(nil) }
        }
        releaseHeldCloses()
    }

    /// Open boards in tab/window order: a tab group's boards together in tab order, and groups
    /// and lone windows by when their first board was opened. Update snapshots include hidden windows.
    private func openBoardsInOrder(includeHidden: Bool = false) -> [CanvasWindowController] {
        let open = openedOrder.compactMap { controllers[$0] ?? remoteControllers[$0] }.filter { controller in
            guard let window = controller.window else { return false }
            return controller.isBoardOpen && !isHoldingClose(window) && (includeHidden || isShown(window))
        }
        var ordered: [CanvasWindowController] = []
        for controller in open where !ordered.contains(where: { $0 === controller }) {
            let windows = controller.window?.tabbedWindows ?? controller.window.map { [$0] } ?? []
            ordered += windows.compactMap { window in open.first { $0.window === window } }
        }
        return ordered
    }

    func prepareForUpdate() throws {
        guard !terminating, localRestore == nil, updateRestoration == nil, openingWindows.isEmpty, remoteLoads.isEmpty else {
            throw ApiRouter.Failure("unavailable", "Board tabs are still reopening.")
        }
        var remaining = openBoardsInOrder(includeHidden: true)
        var groups: [UpdateBoardSnapshot.Group] = []
        while let first = remaining.first, let window = first.window {
            let windows = window.tabGroup?.windows ?? [window]
            let members = windows.compactMap { member in remaining.first { $0.window === member } }
            let selected = window.tabGroup?.selectedWindow ?? window
            let tabs = members.map { controller -> UpdateBoardSnapshot.Board in
                if let host = controller.remote?.host {
                    return .remote(RemoteReopen(host: host.name, sshTarget: host.sshTarget, home: host.home, board: controller.board.id))
                }
                return .local(root: controller.board.root.path)
            }
            groups.append(.init(tabs: tabs, selected: members.firstIndex { $0.window === selected } ?? 0,
                                minimized: selected.isMiniaturized))
            remaining.removeAll { member in members.contains { $0 === member } }
        }
        try ClientFiles.sync { try updateBoards.save(UpdateBoardSnapshot(groups: groups)) }
    }

    func cancelPreparedUpdate() throws {
        try ClientFiles.sync { try updateBoards.remove() }
    }

    private func beginUpdateRestoration(_ recoveries: [(UpdateBoardSnapshot.Store, UpdateBoardSnapshot)]? = nil) {
        guard !terminating, updateRestoration == nil else { return }
        updateRestoration = Task { @MainActor in
            defer {
                updateRestoration = nil
                suppressLaunchActivation = false
                saveOpenBoards()
                showPendingUpdateRestoreFailure()
            }
            var readable = recoveries ?? []
            if recoveries == nil {
                do {
                    let loaded = try await ClientFiles.read {
                        let stores = try UpdateBoardSnapshot.Store.recoveries(in: AppPaths.updateBoardRecovery)
                        var snapshots: [(UpdateBoardSnapshot.Store, UpdateBoardSnapshot)] = []
                        var failures: [String] = []
                        for store in stores {
                            do {
                                if let snapshot = try store.load() { snapshots.append((store, snapshot)) }
                            } catch {
                                failures.append(error.localizedDescription)
                            }
                        }
                        return (snapshots, failures)
                    }
                    readable = loaded.0
                    for failure in loaded.1 { reportUpdateRestoreFailure(failure) }
                } catch {
                    reportUpdateRestoreFailure(error.localizedDescription)
                }
            }
            for (store, snapshot) in readable {
                guard !Task.isCancelled, !terminating else { return }
                await restoreUpdateBoards(snapshot, in: store)
            }
            guard !Task.isCancelled, !terminating else { return }
            do { try await refreshUpdateRecovery() } catch { reportUpdateRestoreFailure(error.localizedDescription) }
            if backgroundAttach, !terminating { await attachInBackground() }
        }
    }

    private func restoreUpdateBoards(_ snapshot: UpdateBoardSnapshot, in store: UpdateBoardSnapshot.Store) async {
        var failures: [String] = []
        var failedGroups: [UpdateBoardSnapshot.Group] = []
        for saved in snapshot.groups {
            var restored: [(index: Int, window: NSWindow)] = []
            var failedTabs: [UpdateBoardSnapshot.Board] = []
            var failedSelection = 0
            for (index, tab) in saved.tabs.enumerated() {
                do {
                    try checkRemoteOpen()
                    let controller: CanvasWindowController
                    switch tab {
                    case .local(let root):
                        guard await offPool({ BoardStore.isDirectory(root) }) else {
                            throw ApiRouter.Failure("not_found", "Board directory no longer exists: \(root)")
                        }
                        let board = await open(root: URL(fileURLWithPath: root), select: false, present: false)
                        try checkRemoteOpen()
                        guard let prepared = controllers[board.id], prepared.board === board, prepared.isBoardOpen else {
                            throw CancellationError()
                        }
                        controller = prepared
                    case .remote(let entry):
                        let host = try await RemoteHost.discover(name: entry.host, sshTarget: entry.sshTarget,
                                                                 support: entry.support(devRemoteHome: AppPaths.devRemoteHome),
                                                                 allowDefault: AppPaths.devRemoteHome == nil)
                        controller = try await openRemoteBoard(host: host, board: entry.board, select: false, present: false).controller
                    }
                    try checkRemoteOpen()
                    if let window = controller.window { restored.append((index, window)) }
                } catch {
                    guard !Task.isCancelled, !terminating else { return }
                    failures.append((error as? ApiRouter.Failure)?.message ?? (error as? EaslConnection.Failure)?.message ?? error.localizedDescription)
                    if index == saved.selected { failedSelection = failedTabs.count }
                    failedTabs.append(tab)
                }
            }
            guard !Task.isCancelled, !terminating else { return }
            if !failedTabs.isEmpty {
                failedGroups.append(.init(tabs: failedTabs, selected: failedSelection, minimized: saved.minimized))
            }
            restored.removeAll { ($0.window.windowController as? CanvasWindowController)?.isBoardOpen != true }
            // Build the native group while hidden. Selecting an already shown tab can move it to another Space.
            for (_, window) in restored {
                window.orderOut(nil)
                window.tabGroup?.removeWindow(window)
            }
            if restored.count > 1, let first = restored.first?.window {
                var host = first
                for (_, window) in restored.dropFirst() {
                    addTab(window, to: host)
                    host = window
                }
                first.tabGroup?.selectedWindow = restored.first { $0.index == saved.selected }?.window ?? first
            }
            if let selected = restored.first(where: { $0.index == saved.selected })?.window ?? restored.first?.window {
                selected.orderBack(nil)
                if saved.minimized { selected.miniaturize(nil) }
            }
        }
        guard !Task.isCancelled, !terminating else { return }
        var remaining: UpdateBoardSnapshot?
        if !failures.isEmpty {
            remaining = UpdateBoardSnapshot(groups: failedGroups)
            remaining?.recoveryReason = failures.joined(separator: "\n")
        }
        let failed = remaining
        let roots = openBoardRoots(openLocalBoards(excluding: nil))
        do {
            try await ClientFiles.read {
                if let failed { try store.save(failed) }
                try JSONEncoder().encode(roots).write(to: AppPaths.openBoards, options: .atomic)
                if failed == nil { try store.remove() }
            }
        } catch {
            reportUpdateRestoreFailure(error.localizedDescription)
        }
    }

    private func refreshUpdateRecovery() async throws {
        let reasons = try await ClientFiles.read {
            try UpdateBoardSnapshot.Store.recoveries(in: AppPaths.updateBoardRecovery).map { store -> String in
                do { return try store.load()?.recoveryReason ?? "Saved update tabs still need attention." }
                catch { return error.localizedDescription }
            }
        }
        guard !terminating else { return }
        guard !reasons.isEmpty else {
            updateRestoreFailure = nil
            restoreNoticePending = false
            NSApp.dockTile.badgeLabel = nil
            return
        }
        reportUpdateRestoreFailure(reasons.joined(separator: "\n"))
    }

    private func reportUpdateRestoreFailure(_ reason: String) {
        updateRestoreFailure = reason
        restoreNoticePending = true
        NSApp.dockTile.badgeLabel = "!"
        NSLog("easl: update board recovery: %@", reason)
        showPendingUpdateRestoreFailure()
    }

    @objc private func showPendingUpdateRestoreFailure() {
        guard !terminating, restoreNoticePending, localRestore == nil, updateRestoration == nil, NSApp.isActive, let reason = updateRestoreFailure,
              let controller = CanvasWindowController.frontmost,
              let window = controller.window, !window.isMiniaturized, window.isVisible, window.isOnActiveSpace else { return }
        controller.canvas.showNotice("Some update board tabs could not reopen. Use easl > Retry Reopening Update Boards or Discard Update Board Recovery. \(reason)")
        restoreNoticePending = false
    }

    /// A remote board's window by its easl, the host's ssh target and socket, and its board
    /// (`remoteControllers`, `openedOrder`).
    private static func remoteKey(_ host: RemoteHost, _ board: BoardID) -> String { remoteKey(host.sshTarget, host.socketPath, board) }

    /// A reopen-list board's `remoteKey` before its host is discovered: blank where only discovery
    /// knows the socket (an entry saved before easl recorded homes, on the host's default easld).
    private static func remoteKey(_ entry: RemoteReopen) -> String {
        remoteKey(entry.sshTarget, entry.support(devRemoteHome: AppPaths.devRemoteHome).map(RemoteHost.socketPath(home:)) ?? "", entry.board)
    }

    private static func remoteKey(_ sshTarget: String, _ socketPath: String, _ board: BoardID) -> String { "\(sshTarget)|\(board)|\(socketPath)" }

    /// A board window in ⌘J's tour: its board's id, a remote board's with its easl (another
    /// host's board, or another easld's, may have the id of one of ours).
    private func tourKey(_ controller: CanvasWindowController) -> String {
        controller.remote.map { Self.remoteKey($0.host, controller.board.id) } ?? controller.board.id
    }

    /// ⌘J follows needs-you items across presentable local and remote boards in tab order.
    /// Hidden and minimized boards keep their unseen items until their windows are shown.
    func goToNextNeedsYou(from current: CanvasWindowController) {
        let boards = openBoardsInOrder()
        var entries: [NeedsYouTour.Entry] = []
        entries.reserveCapacity(boards.count)
        var waiting: CanvasWindowController?
        for controller in boards where !controller.hostBoardClosed {
            let items = controller.canvas.needsYouItems
            if let window = controller.window, canPresentTab(window.tabGroup?.selectedWindow ?? window) {
                entries.append(NeedsYouTour.Entry(board: tourKey(controller), items: items))
            } else if waiting == nil, !items.isEmpty {
                waiting = controller
            }
        }
        guard let stop = NeedsYouTour.next(from: tourKey(current), after: current.canvas.needsYouCursor, in: entries) else {
            let message = waiting.map { "Show or restore “\($0.board.root.lastPathComponent)” to continue" } ?? "Nothing needs you"
            return current.canvas.showNotice(message)
        }
        guard let target = boards.first(where: { tourKey($0) == stop.board }) else { return }
        guard let window = target.window,
              target === current ? canPresentTab(window) : bringForward(window) else {
            return current.canvas.showNotice("Show or restore “\(target.board.root.lastPathComponent)” to continue")
        }
        if target !== current {
            // A tab never shown has not been laid out: the item is framed in the view's real size.
            window.contentView?.layoutSubtreeIfNeeded()
        }
        target.canvas.visit(stop.item)
    }

    /// File › Open Remote…'s board (and DevInput's): opened and selected by
    /// `openRemoteBoard(host:board:select:)`, or why not in an alert.
    func openRemoteBoard(host: RemoteHost, board: BoardID) {
        Task { @MainActor [weak self] in
            do {
                _ = try await self?.openRemoteBoard(host: host, board: board, select: true)
            } catch is CancellationError {
                return
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't open the board on \(host.name)"
                alert.informativeText = BoardMirror.reason(error)
                // A sheet: a modal run loop would stall every socket request.
                if let window = self?.keyController?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    /// `board.open_remote`: the host `name` names as File › Open Remote… would connect to it
    /// (`RemoteHost.target` among the picker's rows: the hosts opened before and the tailnet's
    /// Macs), then `board` there as the picker opens it. A board attached already (its tab open,
    /// or background attach's with its window closed) is answered without asking the host; else
    /// the picker's host discovery, which remembers the host (`AppPaths.remoteHosts`), then
    /// `openRemoteBoard(host:board:select:)`.
    func openRemoteBoard(named name: String, board: BoardID, select: Bool) async throws -> OpenedRemoteBoard {
        try checkRemoteOpen()
        let intent = RemoteOpenIntent.named(name, board)
        if let loading = remoteLoads[intent] {
            let open = try await loading.value
            await ClientFiles.flush()
            try checkRemoteOpen()
            guard !loading.isCancelled else { throw CancellationError() }
            if select, let window = open.controller.window { bringForward(window) }
            return try opened(open.controller, alreadyOpen: true)
        }
        let loading: RemoteLoad = Task { @MainActor in
            try self.checkRemoteOpen()
            let recents = try await ClientFiles.read { RemoteHost.Recents.load(AppPaths.remoteHosts) }
            // The picker lists the tailnet's Macs when Tailscale answers, else only the hosts opened before.
            let peers = (try? await Tailnet.peers()) ?? []
            try self.checkRemoteOpen()
            let target = try RemoteHost.target(name, among: RemoteHost.candidates(peers: peers, recents: recents))
            let store = self.reopenList
            let support = try await ClientFiles.read {
                try store.support(sshTarget: target.sshTarget, board: board, devRemoteHome: AppPaths.devRemoteHome, recentHome: target.home)
            }
            try self.checkRemoteOpen()
            if let support, let open = self.shownRemote(Self.remoteKey(target.sshTarget, RemoteHost.socketPath(home: support), board), select: select) { return open }
            let host: RemoteHost
            do {
                host = try await RemoteHost.discover(name: target.name, sshTarget: target.sshTarget, support: support,
                                                     allowDefault: AppPaths.devRemoteHome == nil)
            } catch let failure as EaslConnection.Failure {
                NSLog("easl: board.open_remote: %@ unreachable: %@", target.sshTarget, failure.message)
                throw ApiRouter.Failure(failure.code, "\(target.name) is offline: \(failure.message)")
            }
            try self.checkRemoteOpen()
            ClientFiles.enqueue { RemoteHost.Recents.remember(host, in: AppPaths.remoteHosts) }
            do {
                let open = try await self.openRemoteBoard(host: host, board: board, select: select)
                try self.checkRemoteOpen()
                return open
            } catch let failure as ApiRouter.Failure {
                NSLog("easl: board.open_remote: %@ failed (%@)", host.sshTarget, failure.code)
                throw ApiRouter.Failure(failure.code, "couldn't open \(board) on \(host.name): \(failure.message)")
            }
        }
        remoteLoads[intent] = loading
        defer { remoteLoads[intent] = nil }
        let open = try await loading.value
        await ClientFiles.flush()
        try checkRemoteOpen()
        guard !loading.isCancelled else { throw CancellationError() }
        return try opened(open.controller, alreadyOpen: open.alreadyOpen)
    }

    private enum RemoteOpenIntent: Hashable {
        case named(String, BoardID)
        /// A discovered host's board, by `remoteKey`.
        case host(String, BoardID)

        var board: BoardID {
            switch self {
            case .named(_, let board), .host(_, let board): board
            }
        }
    }

    /// Named discovery and resolved-host reads share the lifetime cancelled by `board.close`.
    private typealias RemoteLoad = Task<(controller: CanvasWindowController, alreadyOpen: Bool), Error>
    private var remoteLoads: [RemoteOpenIntent: RemoteLoad] = [:]

    private func checkRemoteOpen() throws {
        try Task.checkCancellation()
        guard !terminating else { throw ApiRouter.Failure("unavailable", "easl is quitting") }
    }

    /// Opens a window mirroring `board` on `host` (docs/design.md "Client mode"): a tab of the
    /// frontmost board window, or its own window when there's none, its tab brought forward when
    /// `select`. One open (or opening) already isn't opened again (`alreadyOpen`): its tab comes
    /// forward when `select`. The board is read before the window opens, so a host that can't be
    /// reached, or that has no such board, throws its failure instead (`BoardMirror.load`:
    /// `unavailable`, `not_found`). Nothing the board holds is written on this Mac: an easld board
    /// goes in the reopen list by its host, easld home and id (`RemoteReopen`).
    func openRemoteBoard(host: RemoteHost, board: BoardID, select: Bool, present: Bool = true) async throws -> (controller: CanvasWindowController, alreadyOpen: Bool) {
        try checkRemoteOpen()
        let key = Self.remoteKey(host, board)
        let intent = RemoteOpenIntent.host(key, board)
        if let open = shownRemote(key, select: select, present: present) { return open }
        if let loading = remoteLoads[intent] {
            let open = try await loading.value
            try checkRemoteOpen()
            guard !loading.isCancelled, open.controller.isBoardOpen, remoteControllers[key] === open.controller else { throw CancellationError() }
            if present, select, let window = open.controller.window { bringForward(window) }
            return (open.controller, true)
        }
        // This read shows the board: one in the background would attach a second copy of it.
        backgroundLoads.removeValue(forKey: key)?.cancel()
        let loading: RemoteLoad = Task { @MainActor in
            let controller = try await self.loadRemoteBoard(host: host, board: board, key: key, select: select, present: present)
            return (controller: controller, alreadyOpen: false)
        }
        remoteLoads[intent] = loading
        defer { remoteLoads[intent] = nil }
        let open = try await loading.value
        try checkRemoteOpen()
        guard !loading.isCancelled else { throw CancellationError() }
        return open
    }

    /// The remote board `key`'s window, its tab brought forward when `select`. One attached with its
    /// window closed (background attach) opens as a new board's does (`show`): its tab wasn't open.
    private func shownRemote(_ key: String, select: Bool, present: Bool = true) -> (controller: CanvasWindowController, alreadyOpen: Bool)? {
        guard let controller = remoteControllers[key], let window = controller.window else { return nil }
        cancelHeldManualClose(window)
        rememberReopen(controller)
        guard controller.isBoardOpen else {
            controller.isBoardOpen = true
            if !openedOrder.contains(key) { openedOrder.append(key) }
            if present { show(controller, select: select) }
            return (controller, false)
        }
        if present, select { bringForward(window) }
        return (controller, true)
    }

    /// Reads the board, then shows its window (`openRemoteBoard(host:board:select:)`).
    private func loadRemoteBoard(host: RemoteHost, board: BoardID, key: String, select: Bool, present: Bool) async throws -> CanvasWindowController {
        try checkRemoteOpen()
        let mirror = BoardMirror(hostName: host.name, board: board, connection: host.connection(), renders: host.connection())
        let loaded: Board
        let identified: RemoteHost
        do {
            loaded = try await mirror.load()
            identified = try await host.identified(on: mirror.connection)
            try checkRemoteOpen()
        } catch {
            mirror.close()
            throw error
        }
        return try await attachRemoteWindow(host: identified, mirror: mirror, board: loaded, key: key, as: .shown(select: select, present: present))
    }

    private enum RemoteWindow {
        case shown(select: Bool, present: Bool)
        case attached
    }

    private func attachRemoteWindow(host: RemoteHost, mirror: BoardMirror, board loaded: Board, key: String, as use: RemoteWindow) async throws -> CanvasWindowController {
        func stillWanted() throws {
            try checkRemoteOpen()
            guard remoteControllers[key] == nil else { throw CancellationError() }
            if case .attached = use, remoteLoads[.host(key, loaded.id)] != nil { throw CancellationError() }
        }
        do {
            try stillWanted()
            await MainTurns.next()
            try stillWanted()
        } catch {
            mirror.close()
            throw error
        }
        let window = DevPerf.time("board.window.shell") { CanvasWindowController.makeWindow(isRemote: true) }
        await MainTurns.next()
        do {
            try stillWanted()
        } catch {
            window.close()
            mirror.close()
            throw error
        }
        let controller = DevPerf.time("board.window") {
            CanvasWindowController(window: window, board: loaded, registry: registry, viewport: nil, composerState: ComposerState(), remote: RemoteSource(host: host, mirror: mirror))
        }
        loaded.onEvent = { [weak controller] event in controller?.apply(event) }
        await MainTurns.next()
        do {
            try stillWanted()
        } catch {
            loaded.onEvent = nil
            retire(controller, savingFrame: false)
            throw error
        }
        registerRemoteWindow(controller, key: key, as: use)
        return controller
    }

    private func registerRemoteWindow(_ controller: CanvasWindowController, key: String, as use: RemoteWindow) {
        remoteControllers[key] = controller
        controller.canvas.scheduleOpeningView()
        controller.onNextNeedsYou = { [weak self] from in self?.goToNextNeedsYou(from: from) }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.remoteWindowClosed(controller, key: key)
        }
        switch use {
        case .shown(let select, let present):
            controller.isBoardOpen = true
            controller.window?.isExcludedFromWindowsMenu = false
            if !openedOrder.contains(key) { openedOrder.append(key) }
            if present { show(controller, select: select) }
            controller.serveHost()
            rememberReopen(controller)
        case .attached:
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.serveHost()
        }
    }

    /// A remote board's window closed by hand (`RemoteClose`, taken when the close was asked for):
    /// its tab beside others forgets the board; the window's only tab keeps it in the reopen list,
    /// attached while background attach is on.
    private func remoteWindowClosed(_ controller: CanvasWindowController, key: String) {
        openedOrder.removeAll { $0 == key }
        guard !terminating, let host = controller.remote?.host else { return }
        let close = controller.closing ?? .tab
        controller.closing = nil
        switch close.outcome(backgroundAttach: backgroundAttach, server: host.server) {
        case .forget, .detach:
            remoteControllers.removeValue(forKey: key)
            controller.onClose = nil
            controller.discard()
        case .retain:
            controller.window?.isExcludedFromWindowsMenu = true
        }
    }

    /// An easld board opened by the user stays in the reopen list, with the easld it is on, until
    /// its tab is closed.
    private func rememberReopen(_ controller: CanvasWindowController) {
        guard let host = controller.remote?.host, host.server == .easld,
              let entry = RemoteReopen(board: controller.board.id, on: host) else { return }
        let store = reopenList
        ClientFiles.enqueue { try? store.remember(entry) }
    }

    /// Attaches every reopen-list board that has no window here, with its window closed and never
    /// shown (background attach). Each one's host is discovered again, at its saved easld home.
    private func attachInBackground(excluding: Set<String> = []) async {
        let store = reopenList
        let entries = (try? await ClientFiles.read { store.load() }) ?? []
        guard backgroundAttach, !terminating else { return }
        for entry in entries {
            let key = Self.remoteKey(entry)
            guard !excluding.contains(key) else { continue }
            guard remoteControllers[key] == nil, remoteLoads[.host(key, entry.board)] == nil, backgroundLoads[key] == nil else { continue }
            backgroundLoads[key] = Task { await self.attachInBackground(entry, key: key) }
        }
    }

    private func attachInBackground(_ entry: RemoteReopen, key: String) async {
        // A cancelled load was taken out of `backgroundLoads` by whoever cancelled it.
        defer { if !Task.isCancelled { backgroundLoads[key] = nil } }
        do {
            let host = try await RemoteHost.discover(name: entry.host, sshTarget: entry.sshTarget, support: entry.support(devRemoteHome: AppPaths.devRemoteHome),
                                                     allowDefault: AppPaths.devRemoteHome == nil)
            guard !Task.isCancelled, !terminating else { return }
            let mirror = BoardMirror(hostName: host.name, board: entry.board, connection: host.connection(), renders: host.connection())
            let loaded: Board
            let identified: RemoteHost
            do {
                loaded = try await mirror.load()
                identified = try await host.identified(on: mirror.connection)
            } catch {
                mirror.close()
                throw error
            }
            guard !Task.isCancelled, !terminating else { return mirror.close() }
            guard identified.server == .easld else {
                mirror.close()
                return NSLog("easl: background attach skips %@: not an easld host", entry.sshTarget)
            }
            // A saved address may acquire its server-home identity only after discovery.
            _ = try await attachRemoteWindow(host: identified, mirror: mirror, board: loaded, key: Self.remoteKey(identified, entry.board), as: .attached)
        } catch {
            guard !Task.isCancelled, !terminating, !(error is CancellationError) else { return }
            let code = (error as? ApiRouter.Failure)?.code ?? (error as? EaslConnection.Failure)?.code ?? "unavailable"
            NSLog("easl: background attach to %@ failed (%@)", entry.sshTarget, code)
        }
    }

    /// Background attach off: closed windows' attachments end and reads in progress stop. Shown
    /// windows stay attached until they close; the reopen list stays.
    private func endBackgroundAttachments() {
        for load in backgroundLoads.values { load.cancel() }
        backgroundLoads = [:]
        // Each retire closes a window, which can release a held close that changes `remoteControllers`.
        let closed = remoteControllers.filter { !$0.value.isBoardOpen }
        for (key, controller) in closed where remoteControllers[key] === controller {
            remoteControllers.removeValue(forKey: key)
            retire(controller)
        }
    }

    /// What `board.open_remote` answers for a remote board's window.
    private func opened(_ controller: CanvasWindowController, alreadyOpen: Bool) throws -> OpenedRemoteBoard {
        guard let remote = controller.remote else { throw ApiRouter.Failure("internal", "\(controller.board.id)'s window mirrors no host") }
        guard controller.isBoardOpen, remoteControllers[Self.remoteKey(remote.host, controller.board.id)] === controller else { throw CancellationError() }
        return OpenedRemoteBoard(host: remote.host.name, sshTarget: remote.host.sshTarget, board: controller.board.id, root: controller.board.root.path,
                                 title: remote.title(of: controller.board), window: controller.window?.windowNumber ?? 0, alreadyOpen: alreadyOpen)
    }

    /// A new board window as a tab of the frontmost one (its own window when there's none),
    /// selected when `select`. Otherwise the tab in front stays in front, as `open(root:select:)`
    /// leaves it, and a window of its own is ordered in behind the others, never made key.
    private func show(_ controller: CanvasWindowController, select: Bool) {
        guard let window = controller.window else { return }
        let noActivate = CanvasApplication.neverActivate || suppressLaunchActivation
        if let host = tabHost(excluding: window) {
            addTab(window, to: host)
            if select, !suppressLaunchActivation { bringForward(window) }
        } else if noActivate || !select {
            window.orderBack(nil)
        } else {
            controller.showWindow(nil)
        }
    }

    // AppKit creates tab groups; inserting into an existing group leaves its selection alone.
    private func addTab(_ window: NSWindow, to host: NSWindow) {
        if let group = host.tabGroup {
            group.insertWindow(window, at: group.windows.firstIndex(of: host)! + 1)
        } else {
            host.addTabbedWindow(window, ordered: .above)
        }
    }

    /// A tab that isn't selected is ordered out and a minimized window isn't visible, so "shown"
    /// means visible, minimized, or in a tab group.
    private func isShown(_ window: NSWindow) -> Bool {
        window.isVisible || window.isMiniaturized || (window.tabGroup?.windows.count ?? 0) > 1
    }

    /// New tabs join a live board's selected native window: key first, otherwise prefer visible.
    /// Hidden and minimized groups remain hosts instead of spawning a window on the current Space.
    /// Update restoration's unshown windows are not hosts until their group is ready.
    private func tabHost(excluding window: NSWindow) -> NSWindow? {
        var preferred: NSWindow?
        func consider(_ controller: CanvasWindowController) -> NSWindow? {
            guard controller.isBoardOpen, let member = controller.window, member !== window,
                  updateRestoration == nil || isShown(member) else { return nil }
            let host = member.tabGroup?.selectedWindow ?? member
            guard host !== window else { return nil }
            if host.isKeyWindow { return host }
            if preferred == nil || (host.isVisible && preferred?.isVisible != true) { preferred = host }
            return nil
        }
        for controller in controllers.values {
            if let key = consider(controller) { return key }
        }
        for controller in remoteControllers.values {
            if let key = consider(controller) { return key }
        }
        return preferred
    }

    /// Records the shown boards' roots in tab order (AppPaths.openBoards) for the next launch.
    private func saveOpenBoards(closing: NSWindow? = nil) {
        guard !terminating, localRestore == nil, updateRestoration == nil else { return }
        let open = controllers.values.filter { controller in
            guard let window = controller.window else { return false }
            return (controller.isBoardOpen || window === closing) && !isHoldingClose(window)
        }
        let others = open.filter { $0.window !== closing }
        let shown = others.isEmpty ? open : others
        let roots = openBoardRoots(shown)
        ClientFiles.enqueue {
            if let data = try? JSONEncoder().encode(roots) { try? data.write(to: AppPaths.openBoards, options: .atomic) }
        }
    }

    private func openLocalBoards(excluding closing: NSWindow?) -> [CanvasWindowController] {
        controllers.values.filter { controller in
            controller.window !== closing && controller.isBoardOpen && !heldCloses.contains(where: { $0 === controller })
        }
    }

    private func openBoardRoots(_ shown: [CanvasWindowController]) -> [String] {
        let order = shown.first?.window?.tabbedWindows ?? []
        return shown.sorted { lhs, rhs in
            (order.firstIndex { $0 === lhs.window } ?? .max) < (order.firstIndex { $0 === rhs.window } ?? .max)
        }.map(\.board.root.path)
    }

    private func writeOpenBoards(_ shown: [CanvasWindowController]) throws {
        let roots = openBoardRoots(shown)
        try ClientFiles.sync {
            try JSONEncoder().encode(roots).write(to: AppPaths.openBoards, options: .atomic)
        }
    }

    private static func savedOpenBoards() async -> [URL] {
        (try? await ClientFiles.read {
            guard let data = try? Data(contentsOf: AppPaths.openBoards), let roots = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return roots.map { URL(fileURLWithPath: $0) }
        }) ?? []
    }

    /// The requested root, else the configured board directory, else home.
    nonisolated static func initialRoot() -> URL {
        requestedRoot() ?? configuredBoardDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// A preferred starting directory, not a restriction on which boards can open.
    nonisolated private static var configuredBoardDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: "canvas.boardDirectory") else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), BoardStore.isDirectory(expanded) else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// EASL_ROOT, else the first non-flag argument, else the working directory unless it's
    /// `/` (Finder and `open` launch there, so it names no directory).
    nonisolated static func requestedRoot() -> URL? {
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
    /// easl › Check for Updates…: says what it found (`Updater`).
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.check(manual: true) }
    @objc func toggleAutomaticUpdates(_ sender: Any?) {
        do {
            let enabled = try ClientFiles.sync {
                var enabled = false
                try settings.update {
                    $0.installUpdatesAutomatically.toggle()
                    enabled = $0.installUpdatesAutomatically
                }
                return enabled
            }
            automaticUpdates = enabled
            Updater.shared.automaticSettingChanged()
        } catch {
            keyController?.canvas.showNotice("Could not save automatic updates: \(error.localizedDescription)")
        }
    }

    @objc func retryUpdateRestoration(_ sender: Any?) {
        guard localRestore == nil else { return }
        beginUpdateRestoration()
    }

    @objc func discardUpdateRecovery(_ sender: Any?) {
        guard !terminating, localRestore == nil, updateRestoration == nil else { return }
        updateRestoration = Task { @MainActor in
            defer {
                updateRestoration = nil
                saveOpenBoards()
                showPendingUpdateRestoreFailure()
            }
            do {
                try await ClientFiles.read {
                    for store in try UpdateBoardSnapshot.Store.recoveries(in: AppPaths.updateBoardRecovery) {
                        try store.remove()
                    }
                }
                try await refreshUpdateRecovery()
            } catch {
                reportUpdateRestoreFailure(error.localizedDescription)
            }
        }
    }
    /// easl › Keep Remote Boards Attached: background attach, saved in the app's settings
    /// (`UISettings`). Off ends the closed windows' attachments now; on attaches the reopen list's
    /// boards again with their windows closed.
    @objc func toggleBackgroundAttach(_ sender: Any?) {
        let on = !backgroundAttach
        do {
            try ClientFiles.sync { try settings.update { $0.backgroundAttach = on } }
        } catch {
            NSLog("easl: cannot save background attach to %@: %@", settings.url.path, error.localizedDescription)
            return
        }
        backgroundAttach = on
        if on { Task { await attachInBackground() } } else { endBackgroundAttachments() }
    }
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
        Task { @MainActor in
            let controller = keyController
            let preferred = controller?.remote == nil ? await offPool { Self.configuredBoardDirectory } : nil
            guard !terminating else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = "Open Board"
            panel.directoryURL = controller?.remote == nil ? (preferred ?? controller?.board.root) : controller?.board.root
            let chosen: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in await self?.open(root: url) }
            }
            if let controller, controller.isBoardOpen, let window = controller.window {
                panel.beginSheetModal(for: window, completionHandler: chosen)
            } else {
                panel.begin(completionHandler: chosen)
            }
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
            // easl.sh/latest.json now (`Updater`); it also checks a minute after launch and daily.
            item("Check for Updates…", #selector(checkForUpdates(_:)), ""),
            item("Install Updates Automatically", #selector(toggleAutomaticUpdates(_:)), ""),
            item("Retry Reopening Update Boards", #selector(retryUpdateRestoration(_:)), ""),
            item("Discard Update Board Recovery", #selector(discardUpdateRecovery(_:)), ""),
            .separator(),
            // Remote easld boards stay attached with their windows closed, for agents' renders
            // and measures (`toggleBackgroundAttach`).
            item("Keep Remote Boards Attached", #selector(toggleBackgroundAttach(_:)), ""),
            .separator(),
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
            // Show or Hide (`CanvasWindowController.validateMenuItem`), docked under the address bar.
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
        case #selector(toggleBackgroundAttach(_:)):
            item.state = backgroundAttach ? .on : .off
            return true
        case #selector(toggleAutomaticUpdates(_:)):
            item.state = automaticUpdates ? .on : .off
            return localRestore == nil
        case #selector(retryUpdateRestoration(_:)), #selector(discardUpdateRecovery(_:)):
            return updateRestoreFailure != nil && localRestore == nil && updateRestoration == nil
        case #selector(openRemote(_:)), #selector(checkForUpdates(_:)): return true
        default: return keyController?.validateMenuItem(item) ?? false
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

/// A tab switch waiting for its group's Space (`AppDelegate.selectTab`): `window` to show in
/// place of `shown`. Weak: a closed window or a group that broke up drops it.
private struct HeldTab {
    weak var group: NSWindowTabGroup?
    weak var window: NSWindow?
    weak var shown: NSWindow?
}
