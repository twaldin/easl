import AppKit
import CanvasCore
import GhosttyKit
import GhosttyTerminal

/// A Ghostty surface running `zmx attach <session>`: the agent/shell survives app quit, crash,
/// and rebuild; reattaching restores the screen. After a reboot, a recorded agent session resumes.
/// A hosted terminal (`props.host`) attaches to its session on that machine over ssh instead
/// (`TerminalHost`, `HostedTerminal`).
@MainActor
final class TerminalTile: NSView, TileContent {
    let objectID: ObjectID
    let sessionName: String
    let terminal: CanvasTerminalView
    private let board: Board
    private var surface: TerminalSurface?
    private let handler = TerminalEvents()
    private let underline = TerminalLinkUnderline()
    /// The header text changed: the name (`props.name`, else the foreground program) and the
    /// live title the program set (`TerminalName.label`).
    var onTitle: ((String) -> Void)?
    /// The last command's status for the header (`TerminalCommand.status`: `exit 1 · 42 s`), nil
    /// after a quick success; `detail` says what ran, for its tooltip.
    var onStatus: ((_ status: String?, _ failed: Bool, _ detail: String?) -> Void)?
    /// A ⌘-clicked reference opened this code tile (`created`) or re-aimed or found it there;
    /// `source` is the reference's rect in window coordinates.
    var onOpenedCode: ((CodeOpened, _ source: NSRect) -> Void)?
    /// A web link the terminal's text activated (⌘-click on a URL) opened or found this browser
    /// tile; the canvas shows it.
    var onOpenedLink: ((ObjectID) -> Void)?
    /// Something asked of this terminal can't happen on this Mac (a remote terminal's file
    /// reference: the file is on the host); the canvas says `text` for a moment (`CanvasView.showNotice`).
    var onNotice: ((String) -> Void)?
    /// A remote board's terminal (docs/design.md "Client mode"): the host's session, attached
    /// over ssh; its programs, notifications and exit are the host's to watch, not this Mac's.
    let isRemote: Bool

    /// The machine this terminal's session runs on (`props.host`); nil for this Mac, and for a
    /// remote board's terminal (its host's easl runs that session). Fixed for the tile's life:
    /// the session is where it was started.
    let host: TerminalHost?
    /// Shown over the top of a hosted terminal while its host is offline or its session couldn't
    /// start, with Reconnect.
    private var hostBanner: HostBanner?

    /// `attach`: a remote board's terminal, shown by running that command (`RemoteHost.terminalAttachCommand`).
    init(object: CanvasObject, board: Board, attach: [String]? = nil) {
        objectID = object.id
        sessionName = Self.sessionName(object.id)
        self.board = board
        isRemote = attach != nil
        host = attach == nil ? HostedTerminal.host(of: object).map(TerminalHost.named) : nil
        terminal = CanvasTerminalView(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        super.init(frame: terminal.frame)
        terminal.autoresizingMask = [.width, .height]
        if let attach {
            terminal.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: NSHomeDirectory(), envVars: [:], command: Self.remoteCommand(attach))
        } else {
            let environment = Self.environment(tile: object.id, board: board)
            let keep = Set(environment.keys)
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec,
                // A hosted session's `cwd` is the host's; ssh runs here.
                workingDirectory: host == nil ? object.props["cwd"]?.string ?? board.root.path : board.root.path,
                envVars: environment,
                command: host.map { Self.hostedCommand(session: sessionName, tile: object.id, board: board.id, route: $0.route, keep: keep) }
                    ?? Self.command(session: sessionName, object: object, board: board, keep: keep)
            )
        }
        terminal.controller = TerminalConfig.shared.controller
        handler.tile = self
        terminal.delegate = handler
        if isRemote {
            // Its paths are the host's: nothing here looks them up (on this Mac a reference would
            // find, and open, a same-named file of its own).
            terminal.onMissedLink = { [weak self] point, _ in self?.remoteReference(at: point) }
        } else {
            terminal.linkAt = { [weak self] point in self?.link(at: point) }
            terminal.onHover = { [weak self] hit in self?.showUnderline(hit) }
            terminal.onOpen = { [weak self] hit, newTile in self?.open(hit, newTile: newTile) }
            terminal.onMissedLink = { [weak self] point, newTile in self?.retryLink(at: point, newTile: newTile) }
        }
        // AppKit makes the view first responder only after `becomeFirstResponder` returns.
        terminal.onFocusChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateSurfaceFocus() } }
        }
        terminal.hasScrollback = { [weak self] in self?.scrollbar.map { $0.total > $0.len } ?? false }
        addSubview(terminal)
        underline.frame = bounds
        underline.autoresizingMask = [.width, .height]
        underline.isHidden = true
        addSubview(underline)
        name = object.props["name"]?.string
        if !isRemote { TerminalProgramWatch.shared.add(self) }
        host?.add(self)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Launch

    static func environment(tile: ObjectID, board: Board) -> [String: String] {
        var env = [
            "EASL_ENV": "1",
            "EASL_SOCKET": AppPaths.apiSocket,
            "EASL_TILE_ID": tile,
            "EASL_BOARD_ID": board.id,
            "EASL_BOARD_ROOT": board.root.path,
            // omp's browser tool drives browser tiles through the cmux subset (docs/contracts.md).
            "CMUX_SOCKET_PATH": AppPaths.cmuxSocket,
            "CMUX_SURFACE_ID": tile,
            "CMUX_WORKSPACE_ID": board.id,
        ]
        if let password = AppPaths.cmuxPassword { env["CMUX_SOCKET_PASSWORD"] = password }
        if let resources = AppPaths.resources {
            // Shell integration (extensions/shell): after the user's startup files, easl's bin
            // goes back to the front of PATH so its claude/codex wrappers aren't shadowed. An
            // integration the app inherited from a tile it was launched in is not the user's.
            env.merge(LoginSession.tileShellIntegration(resources: resources.path, inherited: ProcessInfo.processInfo.environment)) { _, new in new }
            // Ghostty's own shell integration (prompt marks), which the scripts above load.
            if let integration = TerminalConfig.shared.shellIntegration { env["EASL_GHOSTTY_INTEGRATION"] = integration }
        }
        return env
    }

    /// Shell-quoted command string (Ghostty takes a string, not argv). zmx ignores the trailing
    /// command when the session already exists, so it only runs for a new session. A session
    /// that doesn't answer is waited for first (`SessionReach`), then its owner checked.
    /// `keep`: the tile's own variables. `env -u` runs after Ghostty applied them, so an inherited
    /// variable of the same name (a dev instance launched with EASL_SOCKET set) must not unset them.
    /// Everything else the app inherited is unset (`LoginSession.strippedForTile`): the shell starts
    /// like a fresh login session and the user's startup files set their own variables.
    static func command(session: String, object: CanvasObject, board: Board, keep: Set<String>, start initial: String? = nil) -> String {
        let shell = AppPaths.userShell
        let start = (initial ?? initialCommand(object)).map { [shell, "-l", "-c", "\($0); exec \(ShellWords.quote([shell])) -l"] } ?? [shell, "-l"]
        guard let zmx = AppPaths.zmx else { return ShellWords.quote(start) }
        let strip = LoginSession.strippedForTile(ProcessInfo.processInfo.environment, keep: keep).flatMap { ["-u", $0] }
        // `canvas.home` names the owning instance: board copies in another home (replicas, dev
        // instances) carry the same board and tile ids, so ids alone can't tell whose session it is.
        let labels = "canvas.board=\(board.id) canvas.tile=\(object.id) canvas.home=\(homeLabel)"
        let attach = ["/usr/bin/env"] + strip + [zmx, "attach", "--labels", labels, session] + start
        let refusal = #"printf '\nThis terminal session (%s) belongs to another easl instance (%s).\nNot attaching: this copy of the board can neither type into it nor end it.\n' "$2" "$owner"; exec sleep 2147483647"#
        let prologue = SessionReach.prologue() + ownerGuard(refusal: refusal)
        return ShellWords.quote(["/bin/sh", "-c", prologue + "shift 3\nexec \"$@\"", "canvas-attach", zmx, session, homeLabel] + attach)
    }

    /// A prologue for `sh -c` with $1 = zmx, $2 = session name, $3 = this instance's home label:
    /// runs `refusal` when the session exists labelled for another home. A board copied into
    /// another home has the same tile ids, and `zmx attach --labels` relabels an existing session,
    /// so without this a copy took over the original's sessions and its cleanup ended them.
    /// Sessions without a home label (older ones) pass, and so do those of the earlier names'
    /// default homes (`legacyHomeLabels`).
    static func ownerGuard(refusal: String) -> String {
        let legacy = legacyHomeLabels.map { #" && [ "$owner" != '\#($0)' ]"# }.joined()
        return #"""
        owner=$("$1" list 2>/dev/null | awk -F'\t' -v n="name=$2" '{ s = $1; sub(/^[ *]+/, "", s) } s == n { for (i = 2; i <= NF; i++) if (index($i, "canvas.home=") == 1) print substr($i, 13) }')
        if [ -n "$owner" ] && [ "$owner" != "$3" ]\#(legacy); then \#(refusal); fi

        """#
    }

    /// The support directory as a zmx label value (`label(_:)`).
    static let homeLabel = label(AppPaths.support.path)
    /// The default home's sessions from before a rename, labelled with an earlier name's support
    /// directory (Canvas's, Chalkwork's), which LegacyMigration moved here: this instance's own
    /// (attaching relabels them).
    static let legacyHomeLabels: [String] = {
        guard AppPaths.isDefaultHome else { return [] }
        let migration = LegacyMigration(home: FileManager.default.homeDirectoryForCurrentUser)
        return migration.sources.map { TerminalTile.label(migration.support($0).path) }
    }()

    /// A path as a zmx label value, which allows only `[A-Za-z0-9._-]`: every other UTF-8 byte
    /// becomes `_` (what `tr -c` does in scripts/dev.sh).
    static func label(_ path: String) -> String {
        let legal = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        return String(decoding: path.utf8.map { legal.contains($0) ? $0 : UInt8(ascii: "_") }, as: UTF8.self)
    }

    /// What a new session runs before dropping to a login shell: after a reboot, resume the
    /// recorded agent session with the options of the tile's own `command` (`AgentResume`: omp,
    /// claude, codex, gemini, opencode); otherwise the tile's initial `command`. As argv.
    static func initialArgv(_ object: CanvasObject) -> [String]? {
        let argv = object.props["command"]?.array?.compactMap(\.string) ?? []
        if let kind = object.props["agent"]?["kind"]?.string, let sessionId = object.props["agent"]?["sessionId"]?.string,
           let resume = AgentResume.argv(kind: kind, sessionId: sessionId, command: argv) {
            return resume
        }
        return argv.isEmpty ? nil : argv
    }

    /// `initialArgv` as one command line.
    static func initialCommand(_ object: CanvasObject) -> String? {
        initialArgv(object).map(ShellWords.quote)
    }

    /// A hosted terminal's command: the attach loop through the app's connection to its host
    /// (`HostedTerminal.attachLoop`), with the app's inherited variables unset as for a local one.
    /// The session itself is easld's to start (`hostedSpawnParams`); the host attaches only to one
    /// labelled with this instance's home, `board` and `tile`, as that starts it.
    static func hostedCommand(session: String, tile: ObjectID, board: BoardID, route: HostRoute, keep: Set<String>) -> String {
        let strip = LoginSession.strippedForTile(ProcessInfo.processInfo.environment, keep: keep).flatMap { ["-u", $0] }
        let attach = HostedTerminal.attach(session: session, home: homeLabel, board: board, tile: tile)
        return ShellWords.quote(["/usr/bin/env"] + strip + ["/bin/sh", "-c", HostedTerminal.attachLoop, "canvas-host",
                                 "/usr/bin/ssh", route.controlPath, route.target, session, attach])
    }

    /// `session.spawn`'s params for this hosted terminal, read from the object as it is now (a
    /// recorded agent session resumes), or running `argv` (agent.restart's relaunch): `home` is
    /// the host's, `run` this instance's relayed sockets' directory there.
    func hostedSpawnParams(home: String, run: String, argv: [String]? = nil) -> JSONValue? {
        guard let object = board.objects[objectID] else { return nil }
        return HostedTerminal.spawnParams(tile: objectID, board: board.id, argv: argv ?? Self.initialArgv(object), cwd: object.props["cwd"]?.string,
                                          home: home, run: run, homeLabel: Self.homeLabel, cmuxPassword: AppPaths.cmuxPassword,
                                          ghosttyIntegration: TerminalConfig.shared.shellIntegration != nil)
    }

    /// A remote terminal's command: the host's attach, again until the tile closes. An attach that
    /// ends cleanly (a detach, or the session's shell exited) attaches again after a second, as a
    /// local tile's detach reattaches (`surfaceClosed`). The host having no such session
    /// (`RemoteHost.noSessionStatus`) before the first attach means its own tile hasn't started it
    /// yet; after one, that the session ended: the command exits, and the host's delete of the
    /// tile arrives. Any other failure (the link dropped) is retried every 2 s.
    static func remoteCommand(_ attach: [String]) -> String {
        let loop = #"""
        attached=
        while :; do
          "$@"
          case $? in
            0) attached=1; sleep 1; continue ;;
            \#(RemoteHost.noSessionStatus)) [ -z "$attached" ] || exit 0 ;;
          esac
          printf '\r\033[2K[easl] waiting for the host…'
          sleep 2
        done
        """#
        return ShellWords.quote(["/bin/sh", "-c", loop, "easl-remote"] + attach)
    }

    /// Reports this hosted terminal's integration spooled on its host while it couldn't reach the
    /// app (`TerminalHost`), applied as the board applies its local spool (`Board.replay`).
    func replay(_ entries: [AgentReportSpool.Entry]) {
        guard !entries.isEmpty else { return }
        board.replay(entries)
    }

    /// Ends a deleted terminal's persistent session (`Board.onTerminalsEnded`: every delete path,
    /// UI, API, batch, undo/redo), then deletes zmx's log of it (`Housekeeping.sessionLog`), which
    /// zmx keeps forever. Never another instance's session or log (`ownerGuard`). A hosted
    /// terminal's session is ended by its host's easld (`session.kill`).
    static func killSession(_ object: CanvasObject) {
        if let host = HostedTerminal.host(of: object) { return TerminalHost.named(host).kill(object.id) }
        guard let arguments = killArguments(tile: object.id, refusal: "exit 0") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        try? process.run()
    }

    /// `/bin/sh` arguments that kill `tile`'s session unless another instance owns it
    /// (`ownerGuard`, which runs `refusal` instead), then delete zmx's log of it; nil without zmx.
    private static func killArguments(tile: ObjectID, refusal: String) -> [String]? {
        guard let zmx = AppPaths.zmx else { return nil }
        let session = sessionName(tile)
        let log = AppPaths.zmxLogs.appendingPathComponent(Housekeeping.sessionLog(session: session)).path
        return ["-c", ownerGuard(refusal: refusal) + "\"$1\" kill \"$2\"\nexec rm -f -- \"$4\"", "canvas-kill", zmx, session, homeLabel, log]
    }

    /// How `killArguments` exits for `endSession` when another instance owns the session.
    private nonisolated static let notOurs: Int32 = 3

    /// Ends `tile`'s session as `killSession` does (`arguments`: `killArguments` refusing with
    /// `exit notOurs`) and confirms it is gone: zmx no longer lists it (at most 3 s more: the
    /// processes in it get SIGHUP and may take a moment to go). Nil once it is gone, else why it
    /// may still run: the kill couldn't start, another instance owns the session, or zmx still
    /// lists it (or can't list its sessions). Blocks: call it off the main actor.
    nonisolated static func endSession(tile: ObjectID, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            return "terminal \(tile)'s session couldn't be ended (\(error.localizedDescription)), so nothing was relaunched"
        }
        process.waitUntilExit()
        if process.terminationStatus == notOurs {
            return "terminal \(tile)'s session belongs to another easl instance, which alone can end it, so nothing was relaunched"
        }
        let session = sessionName(tile)
        for attempt in 0...30 {
            if Zmx.list().map({ Housekeeping.sessionNames(zmxList: $0).contains(session) }) == false { return nil }
            if attempt < 30 { usleep(100_000) }
        }
        return "zmx still lists terminal \(tile)'s session (or can't list its sessions) 3 s after ending it, so it may still run and nothing was relaunched"
    }

    // MARK: Restart

    /// When agent.restart last killed this tile's session: the old surface's close (its
    /// `zmx attach` exiting) is the restart, not the terminal ending (`surfaceClosed`).
    private var restartedAt: Date?

    /// agent.restart: `killing` (which throws to call it off), then kills the session (the agent
    /// and everything it started end), calls `ended` once it is confirmed gone, and starts a new
    /// one running `argv` in this tile, which keeps its id, frame and name. A local tile gets a
    /// new surface running the new command, attaching to the session it creates, even when the
    /// command reads as the one it had (a second resume of the same session, a plain command
    /// rerun): the old surface's attach ended with the old session. A hosted tile's session is
    /// its host's: its easld ends it and starts the relaunch (`TerminalHost.restart`), and the
    /// attach loop starts again. Throws, with nothing relaunched, when the old session can't be
    /// confirmed gone. A remote board's terminal is never restarted here: its host's easl does
    /// that, through its own API.
    func restart(running argv: [String], killing: @MainActor () throws -> Void, ended: @MainActor () throws -> Void) async throws {
        guard !isRemote else {
            throw ApiRouter.Failure("unsupported", "terminal \(objectID) is on a remote board: its host restarts it (agent.restart on the host's easl)")
        }
        if let host {
            restartedAt = Date()
            try await host.restart(self, running: argv, killing: killing, ended: ended)
            restartedAt = Date()
            return reattach()
        }
        guard let arguments = Self.killArguments(tile: objectID, refusal: "exit \(Self.notOurs)") else {
            throw ApiRouter.Failure("unavailable", "terminal \(objectID) runs without zmx (easl's zmx is missing), so its session can't be ended and confirmed gone")
        }
        try killing()
        restartedAt = Date()
        let tile = objectID
        if let failure = await offPool({ Self.endSession(tile: tile, arguments: arguments) }) {
            restartedAt = nil
            throw ApiRouter.Failure("unavailable", failure)
        }
        try ended()
        // The old session's shell and program are gone with it.
        shell = nil
        shellName = nil
        shellLookup = nil
        foregroundJob = nil
        restartedAt = Date()
        guard let object = board.objects[objectID] else { throw ApiRouter.Failure("not_found", "terminal \(objectID) was closed while it restarted") }
        var options = terminal.configuration
        options.command = Self.command(session: sessionName, object: object, board: board, keep: Set(options.envVars.keys), start: ShellWords.quote(argv))
        // The coordinator rebuilds only on a configuration that differs.
        if options.command == terminal.configuration.command { reattach() } else { terminal.configuration = options }
        refreshProgram()
    }

    /// The foreground process of the session (the agent, when one runs): agent.list `pid`.
    var foregroundPid: Int32? {
        shell.flatMap(ForegroundProgram.foregroundPid)
    }

    /// zmx session names stay short: socket paths under the GUI app's TMPDIR are capped (docs/contracts.md).
    nonisolated static func sessionName(_ tile: ObjectID) -> String { "canvas-\(tile)" }

    /// The last `limit` lines of the session's text (on `host`, over ssh, for a hosted terminal);
    /// nil when zmx is missing or the session doesn't exist. Streams zmx's output through a
    /// bounded tail (never the whole scrollback) and blocks until zmx exits, so call it off the
    /// main actor when it isn't for drawing. `columns`: the terminal's width, so rows it
    /// soft-wrapped read as one line; `screen`: the live screen as Ghostty reads it
    /// (`screenRows`), whose rows join by Ghostty's wrap flags.
    nonisolated static func history(session: String, on host: HostRoute? = nil, lines limit: Int, columns: Int? = nil, screen: [TerminalTail.ScreenRow] = []) -> TerminalTail.Tail? {
        var tail = TerminalTail(limit: limit, columns: columns, screen: screen)
        guard Zmx.run(["history", session], on: host, { tail.append($0) }) else { return nil }
        return tail.finish()
    }

    // MARK: Input

    /// Paste text honoring bracketed-paste mode.
    @discardableResult
    func paste(_ text: String) -> Bool {
        terminal.paste(text: text)
    }

    /// How long a submitted prompt waits between its paste and Enter. TUIs take an Enter that
    /// follows the previous input within a few milliseconds as part of a paste (Gemini CLI turns
    /// one within 30 ms into Shift+Enter, a newline), so the prompt would sit unsent.
    static let submitDelay: Duration = .milliseconds(80)

    /// Pastes `text` and presses Enter once the paste has landed (`submitDelay`). Into a shell at
    /// its prompt a one-line command is typed instead (`ShellTyping`), so no bracketed-paste
    /// marker can reach its line editor in pieces.
    func submit(_ text: String) async -> Bool {
        refreshProgram()
        if shell != nil, program == nil, let typing = ShellTyping.action(text) {
            guard terminal.performBindingAction(typing) else { return false }
        } else {
            guard terminal.paste(text: text) else { return false }
        }
        try? await Task.sleep(for: Self.submitDelay)
        terminal.sendKey(.enter)
        return true
    }

    func focus() {
        window?.makeFirstResponder(terminal)
    }

    func enterKeyboard() -> Bool {
        focus()
        return true
    }

    /// Ghostty starts a surface focused, and libghostty-spm tells it otherwise only when first
    /// responder or key window changes. Until then a terminal nobody had focused kept Ghostty's
    /// focused-surface timers (cursor blink, termios polling) running once it had been shown,
    /// minimized or not: ~12 wakeups/s per terminal.
    fileprivate func attached(_ surface: TerminalSurface?) {
        self.surface = surface
        updateSurfaceFocus()
    }

    /// Ghostty's focus, as a terminal app has it: the terminal has keyboard focus in the key
    /// window of the active app, and the window isn't minimized. libghostty-spm sets it on first
    /// responder and key-window changes only, so a terminal focused while the app was inactive
    /// (an API focus, a window that never became key) or whose window was minimized kept
    /// Ghostty's focused timers (cursor blink, termios polling: 12–18 wakeups/s) running.
    func updateSurfaceFocus() {
        guard let handle = surface?.handle else { return }
        let focused = window.map { NSApp.isActive && $0.isKeyWindow && !$0.isMiniaturized && $0.firstResponder === terminal } ?? false
        ghostty_surface_set_focus(handle, focused)
    }

    fileprivate func titleChanged(_ title: String) {
        DevPerf.count("terminal.title")
        oscTitle = title
        if !isRemote { board.terminalTitled(objectID, title: title) }
        // A new command: the header's status was the previous one's.
        if commands.title(title, at: Date(), promptTitle: TerminalCommandTracker.promptTitle(cwd: reportedCwd, home: NSHomeDirectory())) {
            onStatus?(nil, false, nil)
        }
        refreshProgram()
        publishLabel()
    }

    // MARK: Name

    /// The user's or an agent's name for this terminal (`props.name`).
    private var name: String?
    /// The title the program in the terminal set (OSC 0/2), as it reports it.
    private(set) var oscTitle: String?
    /// What runs in the foreground (`TerminalName.program`: `gemini`, `cargo test`); nil at the prompt.
    private(set) var program: String?
    /// The session's shell (`ForegroundProgram.shellPid`), looked up once, and its name (`zsh`).
    private var shell: pid_t?
    private var shellName: String?
    private var shellLookup: Date?
    /// The foreground job `refreshProgram` found last (`ForegroundProgram.foreground`), reused
    /// while it holds; nil at the prompt or until a job was found.
    private var foregroundJob: ForegroundJob?

    /// Reads the foreground program again (a few syscalls once the session's shell is known).
    /// A program starting clears the header's last-command status (the integration's title,
    /// when it comes, does too); back at the prompt, an agent reporting by notification has
    /// exited (`Board.terminalProgram`). Where it works goes to the board too (`worksIn`).
    func refreshProgram() {
        // A remote or hosted terminal's processes run on its host: none of this Mac's process table.
        guard !isRemote, host == nil else { return }
        guard let shell else {
            worksIn(reportedCwd)
            return findShell()
        }
        let (state, directory) = ForegroundProgram.foreground(shell: shell, job: &foregroundJob)
        if state == .gone { self.shell = nil }
        worksIn(directory ?? reportedCwd)
        let program: String? = switch state {
        case .running(let argv): TerminalName.program(argv: argv)
        case .gone, .prompt: nil
        }
        commands.running(program: program)
        board.terminalProgram(objectID, is: program)
        guard program != self.program else { return }
        if self.program == nil, program != nil { onStatus?(nil, false, nil) }
        self.program = program
        publishLabel()
    }

    /// The directory last told to the board (`worksIn`).
    private var workingDirectory: String?

    /// The terminal works in `directory` (the foreground program's, else the shell's, else the
    /// shell's last report): the board files it under that checkout (`Board.terminalWorks`).
    private func worksIn(_ directory: String?) {
        guard let directory, directory != workingDirectory else { return }
        workingDirectory = directory
        board.terminalWorks(objectID, in: directory)
    }

    /// Inside tmux, what its active pane runs (`ForegroundProgram.tmuxPane`); nil otherwise.
    func tmuxPane() async -> String? {
        guard let shell else { return nil }
        return await offPool { ForegroundProgram.tmuxPane(shell: shell) }
    }

    /// What closing this terminal ends, for the close sheet (`SessionProcesses`); nil until the
    /// session's shell is known.
    func sessionProcesses() -> SessionProcesses? {
        shell.flatMap { ForegroundProgram.session(shell: $0) }
    }

    /// Looks up the session's shell off the main actor, at most every few seconds (a session
    /// that doesn't exist yet appears once zmx has started it).
    private func findShell() {
        if let shellLookup, Date().timeIntervalSince(shellLookup) < 5 { return }
        shellLookup = Date()
        let session = sessionName
        Task { [weak self] in
            let pid = await offPool { ForegroundProgram.shellPid(session: session) }
            guard let self, let pid else { return }
            self.shell = pid
            self.shellName = ForegroundProgram.name(pid)
            self.refreshProgram()
        }
    }

    private func publishLabel() {
        guard let object = board.objects[objectID] else { return }
        onTitle?(label ?? TileFrameView.title(for: object))
    }

    /// What the header calls this terminal: its name, else the program running in it, with the
    /// title that program set (`TerminalName.label`; for an unnamed terminal, not the command
    /// line the shell titled it with: `aider`, not `aider --model … --read …`); nil when it has
    /// none of them.
    var label: String? {
        TerminalName.label(name: name ?? program, title: oscTitle?.trimmingCharacters(in: .whitespaces), command: name == nil ? commands.running : nil)
    }

    // MARK: Notices

    /// The user is looking at this terminal: it has keyboard focus in the active app's key window.
    var isWatched: Bool {
        guard let window, NSApp.isActive, window.isKeyWindow else { return false }
        return window.firstResponder === terminal
    }

    /// When the user last typed in this terminal (`typed`).
    private var lastKeyAt: Date?

    /// The user typed a key in this terminal (the window saw it on its way here). Return may start
    /// work for an agent reporting by notification: its state is unknown again
    /// (`Board.notifyingAgentSubmitted`).
    func typed(_ event: NSEvent) {
        lastKeyAt = Date()
        if [36, 76].contains(event.keyCode), !isRemote { board.notifyingAgentSubmitted(objectID) }
    }

    /// A program asked for the user (OSC 9 / OSC 777 `notify`, or BEL): the lifecycle of the
    /// agent holding the foreground (`NotifyingAgent`), else an attention marker on this
    /// terminal, unless the user is already looking at it (`Board.terminalNotified`).
    fileprivate func notified(_ message: String, bell: Bool) {
        // The host's own tile hears a remote terminal's notifications and raises their markers.
        guard !isRemote else { return }
        refreshProgram()
        let answersKey = lastKeyAt.map { Date().timeIntervalSince($0) <= NotifyingAgent.bellAfterKey } ?? false
        let effect = board.terminalNotified(objectID, message: message, bell: bell, program: program, watched: isWatched, answersKey: answersKey)
        guard effect != .none else { return }
        NSLog("easl: terminal %@ %@: %@%@", objectID, bell ? "rang the bell" : "sent a notification", message, effect == .lifecycle ? " (its agent waits)" : "")
    }

    /// BEL: named by what rang it (`TerminalCommand.bellMessage`).
    fileprivate func bell() {
        refreshProgram()
        notified(TerminalCommand.bellMessage(program: program, shell: shellName, last: lastCommand, at: Date()), bell: true)
    }

    // MARK: Commands

    /// What the shell is running, from the titles Ghostty's shell integration sets.
    fileprivate var commands = TerminalCommandTracker()
    /// The commands the shell finished since easl attached (Ghostty's shell integration: OSC
    /// 133 D), which name their blocks in the terminal's text (`TerminalCommandLog`).
    private(set) var log = TerminalCommandLog()
    /// The last command the shell finished, and when.
    var lastCommand: TerminalCommandLog.Entry? { log.last }

    /// A command finished: the header shows its exit status or duration when it failed or ran
    /// long, and one that ran `noticeAfterMs` or more raises a marker unless the user is looking
    /// at the terminal (`Board.raiseTerminalNotice`: never for an agent reporting a lifecycle).
    /// A mark while a program holds the foreground, or while the tile's agent reports a
    /// lifecycle, is that program's, not a shell command (`TerminalCommandTracker.finished`).
    fileprivate func commandFinished(exit: Int?, durationNanos: UInt64) {
        var atPrompt = true
        if let shell, case .running = ForegroundProgram.state(shell: shell) { atPrompt = false }
        // An agent reporting by notification ran as the shell's command, whose D is the user's.
        let reporting = board.objects[objectID].map(NotifyingAgent.integrationReports) ?? false
        guard let command = commands.finished(exit: exit, durationNanos: durationNanos, at: Date(), shellAtPrompt: atPrompt, agentReporting: reporting) else { return }
        log.append(command, at: Date())
        let detail = ([command.command ?? "The last command"] + [command.exit.map { "exit \($0)" }, command.durationMs.map(TerminalCommand.duration)].compactMap { $0 })
            .joined(separator: " · ")
        onStatus?(command.status, (command.exit ?? 0) != 0, detail)
        guard !isRemote, (command.durationMs ?? 0) >= TerminalCommand.noticeAfterMs, !isWatched,
              board.raiseTerminalNotice(objectID, message: command.noticeMessage, bell: false) else { return }
        NSLog("easl: terminal %@ finished a long command: %@", objectID, command.noticeMessage)
    }

    // MARK: Mentions

    /// While Hyper is held: the selection, else the whole terminal. A click resolves more
    /// (`resolveMention`), but finding a command's block takes Ghostty a click, too much for hover.
    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        if let text = surface?.readSelection(), !text.isEmpty {
            return .terminal(object: objectID, text: text)
        }
        return .object(objectID)
    }

    /// A Hyper-click: the selection; else, inside a finished command's output that Ghostty's
    /// shell integration marked, that command's block; else the screen rows around the click
    /// (also in the output of the program still running: an agent TUI's whole session is no
    /// block to hand over). Outside the text (the title bar, the padding): the whole terminal.
    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        if let text = surface?.readSelection(), !text.isEmpty {
            return .terminal(object: objectID, text: text)
        }
        guard let surface, let grid, let cell = cell(at: point) else { return .object(objectID) }
        refreshProgram()
        if let block = commandBlock(row: cell.row, column: cell.column) {
            return .terminal(object: objectID, text: block.output, part: .command, command: block.command)
        }
        let from = max(0, cell.row - Self.rowsBefore), to = min(grid.rows - 1, cell.row + Self.rowsAfter)
        let rows = (from...to).map { surface.viewportRow($0, columns: grid.columns) ?? "" }
        let lines = TerminalExcerpt.around(rows, index: cell.row - from, before: Self.rowsBefore, after: Self.rowsAfter)
        return .terminal(object: objectID, text: lines.joined(separator: "\n"), part: .rows)
    }

    /// Edit › Mention: the selection; else, with the keyboard here and the shell at its prompt,
    /// the last command's block (what ran, its output); else the whole terminal.
    func keyboardMention(hasKeyboard: Bool) async -> MentionTarget? {
        if let text = surface?.readSelection(), !text.isEmpty { return .terminal(object: objectID, text: text) }
        refreshProgram()
        guard hasKeyboard, shell != nil, program == nil, let block = selectedLastBlock(), !block.output.isEmpty else { return nil }
        return .terminal(object: objectID, text: block.output, part: .command, command: block.command)
    }

    /// The screen rows a Hyper-click outside a command's output mentions: an error's context is
    /// mostly above it.
    static let rowsBefore = 8
    static let rowsAfter = 3

    /// The viewport cell under `point` (this view's coordinates); nil in the padding.
    private func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        guard let grid else { return nil }
        let fromTop = terminal.bounds.height - point.y
        let column = Int(floor((point.x - padding.width) / grid.cell.width))
        let row = Int(floor((fromTop - padding.height) / grid.cell.height))
        guard (0..<grid.columns).contains(column), (0..<grid.rows).contains(row) else { return nil }
        return (row, column)
    }

    /// The finished command block whose output covers viewport cell (`row`, `column`): its
    /// output, as Ghostty selects it, and what ran. The terminal's command log names it by the
    /// clicked line in the terminal's text (`TerminalCommandLog.block(holding:)`: what ran, its
    /// exit status and duration, also when its prompt row scrolled away or `clear` wiped it),
    /// when the output below that command's line is the one selected; else, for a block older
    /// than the log, the shell's last command when the output ends just above the prompt, else
    /// the prompt row shown above the output. Nil without Ghostty's prompt marks there, and in the
    /// output of the program still running (it goes on to the cursor).
    private func commandBlock(row: Int, column: Int) -> (output: String, command: TerminalCommand?)? {
        guard let surface, let grid, let output = selectOutput(row: row, column: column) else { return nil }
        let lines = TerminalExcerpt.lines(output.text)
        // The program still running: its output goes on to the cursor.
        if program != nil, let cursor = cursorRow, let last = lines.last,
           (max(0, cursor - 2)...cursor).contains(where: { row in activeRow(row).map { !$0.isEmpty && last.hasSuffix($0) } ?? false }) { return nil }
        if let text = textToCursor(), let cursor = cursorRow, let below = read(viewport(0, row), active(grid.columns - 1, cursor)) {
            let clicked = text.count - below.split(separator: "\n", omittingEmptySubsequences: false).count
            let positions = log.positions(in: text)
            if let index = log.block(holding: clicked, in: text, positions: positions), let entry = log[fromEnd: index], let line = positions[index],
               let first = text[(line + 1)...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               text[first].trimmingCharacters(in: .whitespaces) == lines.first?.trimmingCharacters(in: .whitespaces) {
                // The prompt's lines above its input line: between this output's end and the next
                // command's line (the current prompt may show more: a transient prompt's do).
                if let next = positions[index + 1], (0...TerminalBlocks.promptRows).contains(next - (first + lines.count)) {
                    promptAbove = next - (first + lines.count)
                }
                return (TerminalBlocks.output(output.text, after: entry.command.command), entry.command)
            }
        }
        func shown(_ row: Int) -> String { (surface.viewportRow(row, columns: grid.columns) ?? "").trimmingCharacters(in: .whitespaces) }
        let promptRow = output.top.flatMap { $0 > 0 ? shown($0 - 1) : nil }
        // Where the output ends on screen: the row just above the prompt showing its last line.
        let last = output.text.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let cursor = scrolledBack == 0 ? cursorRow : nil
        let end = cursor.flatMap { cursor in
            stride(from: cursor - 1, through: max(0, cursor - TerminalBlocks.promptRows - 1), by: -1).first { !shown($0).isEmpty && last.hasSuffix(shown($0)) }
        } ?? output.top.map { $0 + TerminalBlocks.rows(of: output.text, columns: grid.columns) - 1 } ?? grid.rows
        let command = TerminalBlocks.command(promptRow: promptRow, outputEnd: end, cursorRow: cursor,
                                             atPrompt: shell != nil && program == nil, last: lastCommand?.command)
        guard command?.exit != nil || command?.durationMs != nil else {
            // Starting at the very top of everything the terminal holds, with no prompt above:
            // text from before easl reattached to the session, which carries no marks.
            if output.top == 0, (scrollbar?.offset ?? 0) == 0 { return nil }
            return (output.text, command)
        }
        return (TerminalBlocks.output(output.text, after: command?.command), command)
    }

    /// The lines a prompt shows above its input line, as last measured between a block's output
    /// and the next command's line; nil until then (reads of older blocks assume none).
    private var promptAbove: Int?

    /// The output of the command whose block covers viewport cell (`row`, `column`), as Ghostty
    /// selects it on a ⌘-triple-click (Ghostty's semantic prompts: the output between the
    /// command's line and the next prompt), and the viewport row it starts on (nil above the
    /// viewport). Ghostty's C API has no call for the block itself, so this is that triple
    /// click, with the selection cleared after it by a click on the top-left cell (above any
    /// prompt, so it never moves the cursor). Nil when a program owns the mouse (a TUI), the
    /// user has a selection (it would be lost), or the cell isn't command output.
    private func selectOutput(row: Int, column: Int) -> (text: String, top: Int?)? {
        guard let handle = surface?.handle, let grid, !ghostty_surface_mouse_captured(handle), !ghostty_surface_has_selection(handle) else { return nil }
        // The current prompt at the top of the screen: that click would land on it.
        if let cursorRow, cursorRow < TerminalBlocks.promptRows { return nil }
        let none = GHOSTTY_MODS_NONE, command = GHOSTTY_MODS_SUPER
        ghostty_surface_mouse_pos(handle, Double(padding.width + (CGFloat(column) + 0.5) * grid.cell.width),
                                  Double(padding.height + (CGFloat(row) + 0.5) * grid.cell.height), none)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, command)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, command)
        let word = readSelection(handle)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, command)
        let output = readSelection(handle)
        ghostty_surface_mouse_pos(handle, Double(padding.width + grid.cell.width / 2), Double(padding.height + grid.cell.height / 2), none)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, none)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, none)
        ghostty_surface_mouse_pos(handle, -1, -1, none)
        if ghostty_surface_has_selection(handle) { NSLog("easl: terminal %@ kept a selection after reading a command block", objectID) }
        guard let output, !output.text.isEmpty, output.text != word?.text else { return nil }
        // `tl_px_y`: the first row's baseline, in points from the top; negative when that row is
        // above the viewport.
        guard output.y >= 0 else { return (output.text, nil) }
        let top = Int(floor((CGFloat(output.y) - padding.height) / grid.cell.height))
        return (output.text, max(0, top))
    }

    private func readSelection(_ handle: ghostty_surface_t) -> (text: String, y: Double)? {
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(handle, &out) else { return nil }
        defer { ghostty_surface_free_text(handle, &out) }
        guard let text = out.text, out.text_len > 0 else { return nil }
        return (String(decoding: UnsafeRawBufferPointer(start: text, count: Int(out.text_len)), as: UTF8.self), out.tl_px_y)
    }

    /// The cursor's cell as Ghostty gives it to input methods: its bottom and height, in points
    /// from the top; nil without a surface.
    private var cursorCell: (bottom: CGFloat, height: CGFloat)? {
        guard let handle = surface?.handle else { return nil }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(handle, &x, &y, &width, &height)
        return (CGFloat(y), CGFloat(height))
    }

    /// The row the cursor is on in the terminal's active screen (its last `rows` rows, whatever
    /// the view is scrolled to); nil when unknown.
    private var cursorRow: Int? {
        guard let cell = cursorCell, let grid else { return nil }
        let row = Int(((cell.bottom - cell.height - padding.height) / grid.cell.height).rounded())
        return (0..<grid.rows).contains(row) ? row : nil
    }

    /// How many rows the view is scrolled back from the active screen (Ghostty's scrollbar).
    private var scrolledBack: Int {
        scrollbar.map { max(0, Int($0.total) - Int($0.offset) - Int($0.len)) } ?? 0
    }

    /// The terminal's lines from the top of its scrollback to the cursor's (the prompt's input
    /// line at a prompt), soft-wrapped rows joined; nil without a surface.
    private func textToCursor() -> [String]? {
        guard let grid, let cursorRow else { return nil }
        let top = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        return read(top, active(grid.columns - 1, cursorRow)).map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    }

    /// Row `row` of the active screen, trailing blanks trimmed.
    private func activeRow(_ row: Int) -> String? {
        guard let grid else { return nil }
        return read(active(0, row), active(grid.columns - 1, row)).map(TerminalTail.trimmed)
    }

    /// The text from `from` to `to` (inclusive), soft-wrapped rows joined; nil when Ghostty has
    /// no such cells.
    private func read(_ from: ghostty_point_s, _ to: ghostty_point_s) -> String? {
        guard let handle = surface?.handle else { return nil }
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(handle, ghostty_selection_s(top_left: from, bottom_right: to, rectangle: false), &out) else { return nil }
        defer { ghostty_surface_free_text(handle, &out) }
        guard let text = out.text, out.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(out.text_len)), as: UTF8.self)
    }

    /// The last command's block as Ghostty selects it on the rows just above the prompt (its
    /// output exactly), while the view shows the active screen; nil when it can't be selected.
    private func selectedLastBlock() -> (command: TerminalCommand, output: String)? {
        guard let last = lastCommand?.command, program == nil, scrolledBack == 0, surface?.readSelection()?.isEmpty ?? true, let cursorRow else { return nil }
        for row in stride(from: cursorRow - 1, through: max(0, cursorRow - TerminalBlocks.promptRows - 1), by: -1) {
            guard let block = commandBlock(row: row, column: 0) else { continue }
            // An older block nearest the prompt: the last command printed nothing.
            guard block.command == last else { break }
            return (last, block.output)
        }
        return (last, "")
    }

    /// `agent.read` `block`: the output of the command `index` from the end (-1 the last the
    /// shell finished, -2 the one before) and what ran. The last one's output is Ghostty's
    /// selection of it when it is on screen above the prompt; otherwise (an older block, the
    /// view scrolled back, a program running) the terminal's lines below its command's line up
    /// to the next command's (`TerminalCommandLog.output`), less the prompt above that
    /// (`promptAbove`, measured whenever a Hyper-click selects a logged block).
    func block(_ index: Int) throws -> (command: TerminalCommand, output: String) {
        refreshProgram()
        guard !log.entries.isEmpty else {
            throw ApiRouter.Failure("unavailable", "no command has finished in terminal \(objectID) since easl attached to it (its shell needs Ghostty's shell integration; read with lines instead)")
        }
        guard let entry = log[fromEnd: index] else {
            throw ApiRouter.Failure("not_found", "terminal \(objectID) has \(log.entries.count) finished command\(log.entries.count == 1 ? "" : "s") since easl attached to it: block goes back to -\(log.entries.count)")
        }
        guard surface?.handle != nil, grid != nil else { throw ApiRouter.Failure("unavailable", "terminal \(objectID) isn't shown in a window") }
        if index == -1, let selected = selectedLastBlock() { return selected }
        guard var text = textToCursor() else { throw ApiRouter.Failure("unavailable", "terminal \(objectID) isn't shown in a window") }
        // A command still running: its line ends the last finished one's output.
        if program != nil, let running = commands.running, let line = text.lastIndex(where: { TerminalBlocks.isCommandLine($0, of: running) }) {
            text = Array(text[...line])
        }
        guard let lines = log.output(index, in: text, promptAbove: promptAbove ?? 0) else {
            throw ApiRouter.Failure("unavailable", "the output of `\(entry.command.command ?? "that command")` is no longer in terminal \(objectID) (cleared, or trimmed from its scrollback); read with lines instead")
        }
        return (entry.command, text[lines].joined(separator: "\n"))
    }

    /// Which finished command `command` is now, from the newest (`block`'s index), while
    /// `block` can still read it: the last one (Ghostty's selection of it), or an older one whose
    /// line is still in the terminal's text (not cleared or trimmed from the scrollback).
    func blockIndex(of command: TerminalCommand) -> Int? {
        guard let index = log.index(of: command) else { return nil }
        return index == -1 || textToCursor().map({ log.positions(in: $0)[index] != nil }) == true ? index : nil
    }

    /// The terminal's current screen (not where the user scrolled to), soft-wrapped rows joined.
    func screenText() -> String? {
        guard let grid else { return nil }
        return read(active(0, 0), active(grid.columns - 1, grid.rows - 1))
    }

    /// What a mention of the whole terminal quotes: the rows its view shows while the user has
    /// scrolled back (`scrolledBack` rows above the live screen), else the current screen.
    func shownText() -> (text: String, scrolledBack: Int)? {
        guard let grid else { return nil }
        let back = scrolledBack
        guard back > 0 else { return screenText().map { ($0, 0) } }
        return read(viewport(0, 0), viewport(grid.columns - 1, grid.rows - 1)).map { ($0, back) }
    }

    private func active(_ column: Int, _ row: Int) -> ghostty_point_s {
        ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(column), y: UInt32(row))
    }

    private func viewport(_ column: Int, _ row: Int) -> ghostty_point_s {
        ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(column), y: UInt32(row))
    }

    /// The active screen's rows as Ghostty reads them, each with whether Ghostty soft-wrapped it
    /// into the next (a row that fills the width, read together with the next one without a line
    /// break between), for `agent.read` `lines` (`TerminalTail.ScreenRow`); empty without a surface.
    func screenRows() -> [TerminalTail.ScreenRow] {
        guard let grid else { return [] }
        let rows = (0..<grid.rows).map { activeRow($0) ?? "" }
        return rows.indices.map { index in
            let width = TerminalStyledTail.width(rows[index])
            guard width >= grid.columns - 1, index + 1 < rows.count, !rows[index + 1].isEmpty,
                  let pair = read(active(0, index), active(grid.columns - 1, index + 1)) else { return .init(text: rows[index], wraps: false) }
            return .init(text: rows[index], wraps: !pair.contains("\n"))
        }
    }

    /// The screen as VoiceOver's text area, read from Ghostty (`screenText`, as a mention of the
    /// whole terminal reads it) only when asked, without the blank rows below the last output.
    private(set) lazy var accessibleText: AccessibleTextElement? = AccessibleTextElement(view: self, label: { "screen" }, read: { [weak self] in
        self?.screenText().map { AccessibleText($0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)) }
    })

    /// The terminal's width in cells, once Ghostty laid it out.
    var columns: Int? { grid?.columns }

    // MARK: Exit

    /// Ghostty closed the surface: its process (`zmx attach`) exited, and the user pressed a key
    /// on "Process exited. Press any key to close the terminal" (or it exited cleanly). The
    /// session ended with it, so the tile goes the normal delete path without asking: there is
    /// nothing left to kill. A detached client (the session still runs) reattaches instead.
    /// `processAlive` is Ghostty's own close request (its ⌘W binding): not an exit, ignored here.
    /// A hosted terminal asks its host's easld; one it can't ask (offline) reattaches, and the
    /// attach waits for the connection.
    fileprivate func surfaceClosed(processAlive: Bool) {
        // A remote session's end is the host's: its tile closes there, and the delete arrives.
        guard !processAlive, !isRemote else { return }
        // agent.restart killed the session it was attached to and is starting another.
        if let restartedAt, Date().timeIntervalSince(restartedAt) < 10 { return }
        let session = sessionName, tile = objectID, host = host
        Task { [weak self] in
            let running = if let host { await host.hasSession(tile) ?? true } else { await offPool { Self.sessionExists(session) } }
            guard let self, self.board.objects[self.objectID] != nil else { return }
            if running {
                NSLog("easl: terminal %@ detached from a running session; reattaching", self.objectID)
                self.reattach()
            } else {
                NSLog("easl: terminal %@ exited; closing it", self.objectID)
                self.board.transaction { try? self.board.delete(self.objectID) }
            }
        }
    }

    /// Starts the surface's command again (a new `zmx attach`, or a hosted terminal's attach loop).
    private func reattach() {
        let controller = terminal.controller
        terminal.controller = nil
        terminal.controller = controller
    }

    /// Whether zmx still has `session`. Blocks until zmx exits; false without zmx.
    nonisolated static func sessionExists(_ session: String) -> Bool {
        Zmx.list().map { Housekeeping.sessionNames(zmxList: $0).contains(session) } ?? false
    }

    // MARK: References

    /// The directory the shell last reported (OSC 7), which relative references resolve against
    /// first; where the terminal works until its shell's process is found (`worksIn`).
    fileprivate(set) var reportedCwd: String?

    /// The `path:line` reference (or source file named alone) drawn at `point` (terminal view
    /// coordinates) that names an existing file (`TerminalReferences.hit`, which follows it onto
    /// neighbouring rows): relative to the reported cwd, then `props.cwd`, then the board root,
    /// then by name among the board root's files (`BoardFiles`), nearest the cwd; a missing
    /// absolute path by its longest trailing part among them (`TerminalReferences.resolve`).
    private func link(at point: NSPoint) -> TerminalReferences.Hit? {
        let cwd = board.objects[objectID]?.props["cwd"]?.string
        let directories = [reportedCwd, cwd, board.root.path].compactMap { $0 }
        let files = BoardFiles.of(board.root)
        let listed = (root: files.root.path, files: files.current())
        let near = reportedCwd ?? cwd ?? board.root.path
        return hit(at: point) { TerminalReferences.resolve($0, directories: directories, home: NSHomeDirectory(), isFile: TerminalReferences.isFile, listed: listed, near: near) }
    }

    /// The reference drawn at `point` that `resolve` finds a file for (`TerminalReferences.hit`).
    private func hit(at point: NSPoint, resolve: (String) -> String?) -> TerminalReferences.Hit? {
        guard let surface, let grid, let cell = cell(at: point) else { return nil }
        return TerminalReferences.hit(row: cell.row, column: cell.column, columns: grid.columns,
                                      read: { $0 < grid.rows ? surface.viewportRow($0, columns: grid.columns) : nil }, resolve: resolve)
    }

    /// A ⌘-click that found no file on a reference: the file may be newer than the board root's
    /// file list (a test just wrote it, and the click that made the list stale started the
    /// re-listing). Look again once the list is fresh, and open it then.
    private func retryLink(at point: NSPoint, newTile: Bool) {
        guard hit(at: point, resolve: { $0 }) != nil else { return }
        BoardFiles.of(board.root).refresh { [weak self] _ in
            guard let self, let hit = self.link(at: point) else { return }
            self.open(hit, newTile: newTile)
        }
    }

    /// A ⌘-click in a remote terminal: on what reads as a file reference (`TerminalReferences`,
    /// not looked up: the file is on the host), says where it opens instead.
    private func remoteReference(at point: NSPoint) {
        guard hit(at: point, resolve: { $0 }) != nil else { return }
        onNotice?(Self.remoteReferenceNotice)
    }

    /// What a remote terminal says to a ⌘-clicked file reference or path.
    static let remoteReferenceNotice = "File references open on the host's own board"

    /// The cells `runs` cover in the underline's (flipped) coordinates, `height` tall at the
    /// bottom of each cell (the whole cell when nil).
    private func rects(_ runs: [TerminalTextRows.Run], grid: TerminalRender.Grid, height: CGFloat? = nil) -> [NSRect] {
        let padding = self.padding
        return runs.map { run in
            let height = height ?? grid.cell.height
            return NSRect(x: padding.width + CGFloat(run.column) * grid.cell.width,
                          y: padding.height + CGFloat(run.row + 1) * grid.cell.height - height,
                          width: CGFloat(run.width) * grid.cell.width, height: height)
        }
    }

    private func showUnderline(_ hit: TerminalReferences.Hit?) {
        guard let hit, let grid else {
            underline.isHidden = true
            return
        }
        underline.color = TerminalConfig.shared.style(for: effectiveAppearance).foreground
        underline.rects = rects(hit.runs, grid: grid, height: max(1, (grid.cell.height / 14).rounded()))
        underline.isHidden = false
    }

    private func open(_ hit: TerminalReferences.Hit, newTile: Bool) {
        if let test = hit.test {
            // A pytest node id: its line is the test's `def`, read off the main thread.
            let file = hit.file
            Task { [weak self] in
                let line = await offPool { (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { PytestNode.line(of: test, in: $0) } } ?? 1
                var located = hit
                located.test = nil
                located.lines = LineRange(start: line, end: line)
                self?.open(located, newTile: newTile)
            }
            return
        }
        let opened = board.openCode(path: hit.file, lines: hit.lines, beside: objectID, newTile: newTile)
        NSLog("easl: terminal %@ opened %@%@ as %@ (%@)", objectID, hit.file, hit.lines.map { ":\($0.start)-\($0.end)" } ?? "", opened.id,
              opened.created ? (newTile ? "new tile" : "new preview") : opened.existing ? "existing" : "re-aimed preview")
        let source = grid.map { rects(hit.runs, grid: $0).reduce(NSRect.null) { $0.union($1) } } ?? .null
        onOpenedCode?(opened, source.isNull ? .null : underline.convert(source, to: nil))
    }

    /// A URL or path Ghostty found under a ⌘-click (`TerminalSurfaceOpenURLDelegate`; with a
    /// delegate answering it Ghostty doesn't run `/usr/bin/open` itself). An http(s) URL opens in
    /// a browser tile beside this terminal (`Board.openLink`: a tile already showing it is
    /// reused); ⌥ held (a ⌥⌘-click, which `CanvasTerminalView` hands Ghostty as a ⌘-click: Ghostty
    /// finds no link under ⌥⌘) opens it in the default browser instead, and any other scheme or a
    /// file path goes to the system, as `open` would. A remote terminal's text is its host's: a
    /// path or `file:` URL there names the host's file, so nothing opens here (this Mac's file of
    /// that name would) and the notice says so, and app.log never gets its links.
    func openLink(_ text: String) {
        let url = URL(string: text).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        if isRemote, url.isFileURL || TerminalReferences.reference(in: text, at: 0) != nil {
            onNotice?(Self.remoteReferenceNotice)
            return
        }
        let forced = terminal.forcingDefaultBrowser || NSApp.currentEvent?.modifierFlags.contains(.option) == true
        guard WebLink.isWeb(url), !forced else {
            ExternalOpen.open(url, because: "terminal \(objectID) link\(forced ? " (⌥-click)" : "")", naming: !isRemote)
            return
        }
        let opened = board.openLink(url, near: objectID, caller: objectID)
        NSLog("easl: terminal %@ link %@ → %@ %@", objectID, isRemote ? "(remote, not logged)" : text, opened.existing ? "existing browser tile" : "new browser tile", opened.object.id)
        onOpenedLink?(opened.object.id)
    }

    // MARK: Scrollback

    /// Ghostty's scrollbar (rows in total, the viewport's offset and rows); nil until reported.
    fileprivate var scrollbar: TerminalScrollbar?

    // MARK: TileContent

    private var isLive = true
    private var windowObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func setLive(_ live: Bool) {
        isLive = live
        updateSurfaceVisibility()
    }

    /// Below this a terminal is a smudge, and Ghostty at ~0.1 zoom held ~235 MB of GPU memory
    /// that a card doesn't.
    var liveZoom: CGFloat { 0.15 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { observer.center.removeObserver(observer.token) }
        windowObservers = []
        if let window {
            let changed: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.windowVisibilityChanged() }
            }
            let app = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            windowObservers = names.map { (app, app.addObserver(forName: $0, object: window, queue: .main, using: changed)) }
                + [NSApplication.didHideNotification, NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
                    .map { (app, app.addObserver(forName: $0, object: NSApp, queue: .main, using: changed)) }
                + [(workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: changed))]
        }
        updateSurfaceVisibility()
    }

    /// AppKit posts these before `occlusionState` settles (`didMiniaturize` arrives with the
    /// window still occlusion-visible, `didDeminiaturize` with it still occluded), so look again
    /// on the next main-loop turn. Ghostty's focus follows key window, app activation and
    /// minimizing (`updateSurfaceFocus`), after libghostty-spm's own key-window handlers ran.
    private func windowVisibilityChanged() {
        updateSurfaceVisibility()
        updateSurfaceFocus()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.updateSurfaceVisibility()
                self?.updateSurfaceFocus()
            }
        }
    }

    /// Ghostty renders every display-link tick while output streams, even into a window nobody
    /// sees: ~18% CPU for one busy terminal. Draw only while the tile is live and its window
    /// shown (not minimized, covered, on another Space, in a background tab, or the app hidden);
    /// the session keeps running either way, and a surface shown again draws the current screen.
    private func updateSurfaceVisibility() {
        let shown = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        terminal.setSurfaceVisible(isLive && shown)
    }

    /// The grid Ghostty reports for this surface, in points; nil until it first lays out.
    private var grid: TerminalRender.Grid?

    fileprivate func resized(_ metrics: TerminalGridMetrics) {
        let scale = window?.backingScaleFactor ?? 2
        guard metrics.columns > 0, metrics.rows > 0, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return }
        grid = TerminalRender.Grid(columns: Int(metrics.columns), rows: Int(metrics.rows),
                                   cell: CGSize(width: CGFloat(metrics.cellWidthPixels) / scale, height: CGFloat(metrics.cellHeightPixels) / scale))
    }

    /// The row the cursor is on (the line being typed), across the terminal's width, in the
    /// terminal view's coordinates: what attention pills keep off while the terminal has the
    /// keyboard. Nil until the surface attaches and lays out.
    var caretRow: NSRect? {
        guard let cell = cursorCell, let grid else { return nil }
        return NSRect(x: 0, y: terminal.bounds.height - cell.bottom, width: terminal.bounds.width, height: max(cell.height, grid.cell.height))
    }

    /// Space between the tile's edge and the grid (the user's `window-padding-x`/`-y`).
    private var padding: CGSize { TerminalConfig.shared.style(for: effectiveAppearance).padding }

    /// The terminal's theme background (a light Ghostty theme draws the default ink dark).
    var surfaceLuminance: Double? {
        DrawingStyle.luminance(TerminalConfig.shared.style(for: effectiveAppearance).background, in: effectiveAppearance)
    }

    /// The session's styled screen text: the last `rows` lines of `zmx history --vt` (on `host`
    /// for a hosted terminal) and the row the cursor ends on. Blocks until zmx exits; nil when zmx
    /// or the session is missing, or the host can't be reached.
    nonisolated static func styledHistory(session: String, on host: HostRoute?, rows: Int) -> (lines: [TerminalLine], cursorRow: Int?)? {
        var tail = TerminalStyledTail(limit: rows)
        guard Zmx.run(["history", session, "--vt"], on: host, { tail.append($0) }) else { return nil }
        let lines = tail.finish()
        return (lines, tail.cursorRow)
    }

    /// Ghostty draws through Metal, which `cacheDisplay` can't capture, so renders, cards, and
    /// `view.snapshot` covers draw the session's styled text on the tile's grid instead (a remote
    /// terminal's session is on its host: the live surface's text, unstyled).
    func render(_ request: TileRenderRequest) async -> TileRender {
        let grid = TerminalRender.grid(for: request.size, known: grid, style: TerminalConfig.shared.style(for: request.appearance))
        let session = sessionName, route = host?.route
        let rows = grid.rows
        let fetched = isRemote ? liveScreen() : await offPool(qos: .userInitiated, { Self.styledHistory(session: session, on: route, rows: rows) })
        guard let history = fetched else {
            return .placeholder(request, isRemote ? "remote terminal \(objectID) isn't attached yet"
                : route.map { "terminal session \(session) on \($0.target) can't be read" } ?? "terminal session \(session) is not running")
        }
        let screen = TerminalRender.screen(history.lines, cursorRow: history.cursorRow, rows: rows)
        let image = request.image { bounds in TerminalRender.draw(screen, grid: grid, in: bounds, appearance: request.appearance) }
        return TileRender(image: image, contentSize: request.size, state: image == nil ? .failed : .rendered)
    }

    private var snapshotView: NSImageView?
    /// The session's styled screen text `prepareSnapshot` fetched for the next `showSnapshot`.
    private var snapshotHistory: (lines: [TerminalLine], cursorRow: Int?)?

    private var snapshotGrid: TerminalRender.Grid {
        TerminalRender.grid(for: bounds.size, known: grid, style: TerminalConfig.shared.style(for: effectiveAppearance))
    }

    /// `zmx history` blocks until zmx exits, so it runs off the main actor before the cover is drawn.
    func prepareSnapshot() async {
        let session = sessionName, route = host?.route, rows = snapshotGrid.rows
        snapshotHistory = isRemote ? liveScreen() : await offPool(qos: .userInitiated) { Self.styledHistory(session: session, on: route, rows: rows) }
    }

    /// A remote terminal's screen as its surface shows it, without styles; nil before it attached.
    private func liveScreen() -> (lines: [TerminalLine], cursorRow: Int?)? {
        let rows = screenRows()
        guard !rows.isEmpty else { return nil }
        return (rows.map { TerminalLine(runs: [TerminalRun(text: $0.text, style: TerminalStyle())]) }, nil)
    }

    /// Temporarily covers the Metal surface with its text (`prepareSnapshot`) so `cacheDisplay`
    /// can capture it (synchronous: `view.snapshot` renders in one pass). The surface stays
    /// unhidden: hiding it would take its keyboard focus, and the program would see a focus-out
    /// and focus-in.
    func showSnapshot(_ show: Bool) {
        snapshotView?.removeFromSuperview()
        snapshotView = nil
        let history = snapshotHistory
        snapshotHistory = nil
        guard show, let history else { return }
        let grid = snapshotGrid
        let screen = TerminalRender.screen(history.lines, cursorRow: history.cursorRow, rows: grid.rows)
        let request = TileRenderRequest(size: bounds.size, scale: window?.backingScaleFactor ?? 2, full: false, appearance: effectiveAppearance)
        let view = NSImageView(frame: bounds)
        view.image = request.image { rect in TerminalRender.draw(screen, grid: grid, in: rect, appearance: request.appearance) }
        view.imageScaling = .scaleAxesIndependently
        addSubview(view)
        snapshotView = view
    }

    func outline(for target: MentionTarget) -> NSRect? { bounds }

    var takesKeyboardFocus: Bool { true }

    func update(_ object: CanvasObject) {
        let name = object.props["name"]?.string
        guard name != self.name else { return }
        self.name = name
        publishLabel()
    }

    // MARK: Host

    /// The host's connection or this tile's session changed (`TerminalHost`): while the host is
    /// offline, or its easld couldn't start the session, a banner over the top of the terminal
    /// says why, with Reconnect. The attach itself waits and reattaches on its own.
    func hostChanged() {
        guard let host else { return }
        let message: String? = switch host.state {
        case .offline(let reason): "\(host.target) is offline. \(reason)"
        case .connecting, .online: host.failures[objectID].map { "\(host.target) couldn't start this terminal's session: \($0)" }
        }
        guard let message else {
            hostBanner?.removeFromSuperview()
            hostBanner = nil
            return
        }
        if hostBanner == nil {
            let banner = HostBanner(frame: NSRect(x: 0, y: bounds.height - HostBanner.height, width: bounds.width, height: HostBanner.height))
            banner.autoresizingMask = [.width, .minYMargin]
            banner.onReconnect = { [weak self] in self?.host?.reconnect() }
            addSubview(banner)
            hostBanner = banner
        }
        guard hostBanner?.message != message else { return }
        hostBanner?.message = message
        NSLog("easl: terminal %@: %@", objectID, message)
    }
}

/// A hosted terminal's strip saying its host is offline (or its session couldn't start), and
/// Reconnect.
@MainActor
final class HostBanner: NSView {
    static let height: CGFloat = 34
    var onReconnect: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Reconnect", target: nil, action: nil)

    var message: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.toolTip = newValue
            setAccessibilityLabel(newValue)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = #selector(reconnect)
        button.sizeToFit()
        addSubview(label)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        button.frame.origin = NSPoint(x: bounds.maxX - button.frame.width - inset, y: (bounds.height - button.frame.height) / 2)
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: inset, y: (bounds.height - height) / 2, width: max(0, button.frame.minX - 2 * inset), height: height)
    }

    @objc private func reconnect() { onReconnect?() }
}

/// Retained delegate for the terminal view (its delegate reference is weak).
@MainActor
private final class TerminalEvents: NSObject, TerminalSurfaceTitleDelegate, TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceBellDelegate, TerminalSurfaceDesktopNotificationDelegate, TerminalSurfacePwdDelegate, TerminalSurfaceCloseDelegate,
    TerminalSurfaceScrollbarDelegate, TerminalSurfaceCommandFinishedDelegate, TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfaceClipboardPrivacyDelegate {
    weak var tile: TerminalTile?

    func terminalDidResize(_ size: TerminalGridMetrics) {
        tile?.resized(size)
    }

    func terminalDidChangeTitle(_ title: String) {
        tile?.titleChanged(title)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        tile?.attached(surface)
    }

    func terminalDidDetachSurface() {
        tile?.attached(nil)
    }

    func terminalDidRingBell() {
        tile?.bell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        tile?.notified(Board.noticeMessage(title: title, body: body), bell: false)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        tile?.reportedCwd = path.isEmpty ? nil : path
        // The shell reports its directory at each prompt: whatever ran has finished.
        tile?.refreshProgram()
        tile?.commands.prompt(at: Date())
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        tile?.commandFinished(exit: exitCode, durationNanos: durationNanos)
    }

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        tile?.scrollbar = scrollbar
    }

    func terminalDidClose(processAlive: Bool) {
        tile?.surfaceClosed(processAlive: processAlive)
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        tile?.openLink(url)
    }

    /// Ghostty asks before a program writes the clipboard (tiles run `clipboard-write = ask`,
    /// `TerminalConfig`): a local terminal's write lands as the user's config says; a remote one's
    /// never does (its text is the host's). A program's read and an unsafe paste stay denied, as
    /// they were with no delegate to ask.
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        let write = request.kind == .osc52Write || request.kind == .kittyWrite
        request.respond(allow: write && tile?.isRemote == false && TerminalConfig.shared.programsMayWriteClipboard)
    }

    /// The user's copy from a remote terminal is the host's text: kept to this Mac and out of
    /// clipboard managers. A local terminal's copies are ordinary.
    var terminalClipboardWritesArePrivate: Bool {
        tile?.isRemote == true
    }
}
