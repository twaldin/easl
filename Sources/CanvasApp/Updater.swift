import AppKit
import CanvasCore

/// easl › Check for Updates… and the titlebar Update button (docs/design.md "Updates"). Checks
/// `latest.json` (`AppUpdate.source`: easl.sh, or `EASL_UPDATE_URL`) a minute after launch and
/// then daily, and offers a newer release in every board window's titlebar. Update downloads the
/// zip into the support directory's `updates/<version>/`, then `AppUpdate.prepareInstall` checks
/// it as the installer does, verifies the new app (a real folder, signature, Team ID, Gatekeeper,
/// version), copies it beside the installed app and verifies the copy. A detached helper renames
/// the copy into place once easl has quit (the way ⌘Q does) and opens it again. A failure before
/// the quit leaves this app as it is and says why; one in the helper renames the old app back,
/// and the next launch says why. A development instance (`EASL_DEV_INPUT=1`) checks only when
/// asked.
@MainActor
final class Updater {
    static let shared = Updater()

    private(set) var phase: UpdatePhase = .idle {
        didSet { if phase != oldValue { refreshButtons() } }
    }
    /// Every board window's button, in its titlebar while a release is on offer.
    private var buttons: [WindowButton] = []
    private var timer: Timer?
    private var lastCheck: Date?
    /// The check under way reports its answer (easl › Check for Updates…).
    private var reporting = false
    /// The helper waiting for this process to exit, killed if the quit doesn't happen.
    private var helper: pid_t?

    private let running = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private let override = ProcessInfo.processInfo.environment["EASL_UPDATE_URL"]
    private static let session = URLSession(configuration: .ephemeral)

    /// At launch: reports what the last update's helper did, deletes its leftovers, and starts
    /// the automatic checks (none in a development instance).
    func start() {
        cleanUp()
        guard !DevInput.enabled else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppUpdate.firstCheck))
            self?.check(manual: false)
        }
        // Hourly against the clock, so a Mac that slept still checks once a day.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let updater = Updater.shared
                if let last = updater.lastCheck, Date().timeIntervalSince(last) >= AppUpdate.checkInterval { updater.check(manual: false) }
            }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Asks `latest.json` for a newer release. `manual` (the menu item) says what it found: the
    /// confirm sheet, "easl X is up to date", or why it couldn't check.
    func check(manual: Bool) {
        guard let next = phase.after(.check) else {
            if case .checking = phase {
                reporting = reporting || manual
            } else if manual, let release = phase.offered {
                inform("easl is updating to \(release.version)", "Wait for it to finish: easl quits and reopens on its own.")
            }
            return
        }
        phase = next
        reporting = manual
        lastCheck = Date()
        Task { await runCheck() }
    }

    private func runCheck() async {
        do {
            guard let source = AppUpdate.source(override: override) else {
                throw UpdateError("EASL_UPDATE_URL isn't an http or https address: \(override ?? "")")
            }
            guard let running, let current = AppVersion(running) else {
                throw UpdateError("this easl has no version to compare (it isn't running from its app bundle)")
            }
            let release = try await fetch(source)
            // Update chosen meanwhile (from what an earlier check found): this answer comes too late.
            guard case .checking = phase else { return }
            let newer = release.isNewer(than: current)
            phase = phase.after(newer ? .found(release) : .upToDate) ?? phase
            NSLog("easl: update check: %@ offers %@, this is %@", source.absoluteString, release.version.description, running)
            guard reporting else { return }
            reporting = false
            if newer {
                offer(over: nil)
            } else {
                inform("easl \(running) is up to date", "\(release.version) is the newest version.")
            }
        } catch {
            let reason = Self.reason(error)
            NSLog("easl: update check failed: %@", reason)
            guard case .checking = phase else { return }
            phase = phase.after(.fail(reason)) ?? phase
            guard reporting else { return }
            reporting = false
            inform("Couldn't check for updates", reason)
        }
    }

    private func fetch(_ source: URL) async throws -> LatestRelease {
        let request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError("\(source.absoluteString) answered HTTP \(status)") }
        return try LatestRelease.decode(data)
    }

    // MARK: updating

    /// The confirm sheet for the release on offer, over `window` (else the board in front).
    func offer(over window: NSWindow?) {
        guard let release = phase.offered, !phase.isUpdating else { return }
        let alert = NSAlert()
        alert.messageText = "Update to \(release.version)?"
        alert.informativeText = "easl quits and reopens; your terminals keep running."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Release Notes")
        present(alert, over: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.update(over: window)
            case .alertThirdButtonReturn: ExternalOpen.open(release.notes, because: "release notes")
            default: break
            }
        }
    }

    /// Updates to the release on offer (a check may have found a newer one while the sheet was up).
    private func update(over window: NSWindow?) {
        guard let next = phase.after(.download), let release = next.offered else { return }
        phase = next
        Task {
            var incoming: URL?
            do {
                let app = try Self.replaceable()
                let staging = try AppUpdate.Staging(updates: AppPaths.updates, version: release.version.description)
                try await download(release, into: staging)
                phase = phase.after(.downloaded) ?? phase
                let team = await offPool { AppUpdate.runningTeamID() }
                // A development build updating to another, both ad hoc, which Gatekeeper refuses
                // whatever they are: the swap can be tested without notarizing.
                let gatekeeper = !(team == nil && DevInput.enabled)
                if !gatekeeper { NSLog("easl: development instance: skipping spctl for an ad hoc update") }
                incoming = try await AppUpdate.prepareInstall(staging, release: release, replacing: app, team: team, gatekeeper: gatekeeper)
                phase = phase.after(.verified) ?? phase
                try startHelper(staging, replacing: app)
                phase = phase.after(.install) ?? phase
                NSLog("easl: installing %@ from %@ over %@; quitting", release.version.description, incoming?.path ?? "", app.path)
                NSApp.terminate(nil)
                // Here while the quit waits on something (language servers ending:
                // `terminateLater`), or when it didn't happen.
                try await Task.sleep(for: .seconds(30))
                stopHelper()
                throw UpdateError("easl didn't quit, so nothing was replaced")
            } catch {
                if let incoming { await offPool { try? FileManager.default.removeItem(at: incoming) } }
                let reason = Self.reason(error)
                NSLog("easl: update to %@ failed: %@", release.version.description, reason)
                phase = phase.after(.fail(reason)) ?? phase
                inform("Couldn't update to easl \(release.version)", "\(reason). This easl wasn't changed.", over: window)
            }
        }
    }

    /// The bundle the update replaces: this app's, wherever it is, if the helper can rename it.
    private static func replaceable() throws -> URL {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { throw UpdateError("this easl isn't running from an app bundle (\(app.path))") }
        guard !app.path.contains("/AppTranslocation/") else {
            throw UpdateError("macOS runs this easl from a read-only copy (App Translocation): move easl.app to /Applications, open it from there and update again")
        }
        // Where a stopped update left it: a hidden copy the next launch deletes, or `updates/`.
        let updates = AppPaths.updates.resolvingSymlinksInPath().path + "/"
        guard !AppUpdate.isLeftover(app.lastPathComponent), !app.resolvingSymlinksInPath().path.hasPrefix(updates) else {
            throw UpdateError("this easl runs from a copy an update left (\(app.path)): rename it to easl.app, open it and update again")
        }
        let folder = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder), FileManager.default.isWritableFile(atPath: app.path) else {
            throw UpdateError("you can't write to \(folder), so easl can't replace \(app.lastPathComponent) there")
        }
        return app
    }

    /// The zip into `staging` (`Staging.prepare` empties its folder first); the file work off the
    /// main thread.
    private func download(_ release: LatestRelease, into staging: AppUpdate.Staging) async throws {
        try await offPool { Result { try staging.prepare() } }.get()
        let request = URLRequest(url: release.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let (file, response) = try await Self.session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let zip = staging.zip, url = release.url
        try await offPool {
            Result {
                defer { try? FileManager.default.removeItem(at: file) }
                guard status == 200 else { throw UpdateError("\(url.absoluteString) answered HTTP \(status)") }
                try FileManager.default.moveItem(at: file, to: zip)
            }
        }.get()
    }

    /// The helper (`AppUpdate.helperScript`) in a session of its own, so it outlives easl and
    /// nothing aimed at easl's process group reaches it, with none of easl's file descriptors
    /// (the instance lock, the sockets) and its output in `staging.log`. It relaunches with this
    /// bundle's `LSEnvironment` and `EASL_HOME`: a development or test instance comes back on its
    /// own home, never on the default one beside the user's own easl.
    private func startHelper(_ staging: AppUpdate.Staging, replacing app: URL) throws {
        var environment = Bundle.main.infoDictionary?["LSEnvironment"] as? [String: String] ?? [:]
        if let home = ProcessInfo.processInfo.environment["EASL_HOME"] { environment["EASL_HOME"] = home }
        let script = AppUpdate.helperScript(pid: getpid(), app: app, staging: staging, relaunch: AppUpdate.relaunchCommand(environment: environment))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, staging.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // easl ignores SIGTERM (it quits through its own handler); the helper must not.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let words: [String] = ["/bin/sh", "-c", script]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ)
        guard status == 0 else { throw UpdateError("couldn't start the helper that replaces easl: \(String(cString: strerror(status)))") }
        helper = pid
    }

    private func stopHelper() {
        guard let pid = helper else { return }
        helper = nil
        // Its session's group: the shell and the sleep it waits in.
        kill(-pid, SIGTERM)
        DispatchQueue.global(qos: .utility).async { waitpid(pid, nil, 0) }
    }

    /// At launch, off the main thread: logs what the helper did (and says so when it failed),
    /// deletes `updates/`'s folders, except one easl now runs from, and the hidden copies a
    /// stopped update left beside this app (`AppUpdate.isLeftover`), except this app.
    private func cleanUp() {
        let updates = AppPaths.updates
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        DispatchQueue.global(qos: .utility).async {
            let files = FileManager.default
            var failures: [String] = []
            for folder in (try? files.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil)) ?? [] {
                let version = folder.lastPathComponent
                let result = updates.appendingPathComponent(version).appendingPathComponent("result")
                if let outcome = (try? String(contentsOf: result, encoding: .utf8)).flatMap(AppUpdate.Outcome.init(result:)) {
                    if let failure = outcome.failure {
                        NSLog("easl: the update to %@ failed: %@", version, failure)
                        failures.append("easl couldn't install \(version): \(failure).")
                    } else {
                        NSLog("easl: updated to %@", version)
                    }
                }
                let path = folder.resolvingSymlinksInPath().path
                guard running.path != path, !running.path.hasPrefix(path + "/") else { continue }
                try? files.removeItem(at: folder)
            }
            let beside = running.deletingLastPathComponent()
            for name in (try? files.contentsOfDirectory(atPath: beside.path)) ?? []
            where AppUpdate.isLeftover(name) && name != running.lastPathComponent {
                NSLog("easl: removing %@, left by an update", beside.appendingPathComponent(name).path)
                try? files.removeItem(at: beside.appendingPathComponent(name))
            }
            guard !failures.isEmpty else { return }
            let message = failures.joined(separator: "\n\n")
            Task { @MainActor in
                Updater.shared.inform("easl wasn't updated", message)
            }
        }
    }

    // MARK: windows

    /// Gives a board window its Update button, in its titlebar while a release is on offer.
    func attach(to window: NSWindow) {
        buttons.removeAll { $0.window == nil }
        let entry = WindowButton(window: window, button: UpdateButton())
        buttons.append(entry)
        place(entry)
    }

    private func refreshButtons() {
        buttons.removeAll { $0.window == nil }
        buttons.forEach(place)
    }

    /// Adds or removes the button: a hidden trailing accessory still takes its place in the
    /// titlebar (`isHidden` collapses only top and bottom ones).
    private func place(_ entry: WindowButton) {
        guard let window = entry.window else { return }
        let shown = window.titlebarAccessoryViewControllers.contains { $0 === entry.button }
        if phase.offered != nil {
            entry.button.show(phase)
            if !shown { window.addTitlebarAccessoryViewController(entry.button) }
        } else if shown {
            entry.button.removeFromParent()
        }
    }

    func inform(_ title: String, _ detail: String, over window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        present(alert, over: window) { _ in }
    }

    /// A sheet on `window`, else on the board in front; a window of its own without one.
    private func present(_ alert: NSAlert, over window: NSWindow?, done: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = (window?.isVisible == true ? window : nil) ?? CanvasWindowController.frontmost?.window {
            alert.beginSheetModal(for: window) { response in done(response) }
        } else {
            done(alert.runModal())
        }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case let error as UpdateError: error.reason
        case let error as LatestRelease.Problem: error.description
        case let error as AppUpdate.DownloadProblem: error.description
        case let error as AppUpdate.InstallProblem: error.description
        default: error.localizedDescription
        }
    }
}

private struct UpdateError: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// A board window and its Update button (the window weakly: a closed one's entry goes).
private struct WindowButton {
    weak var window: NSWindow?
    let button: UpdateButton
}

/// The Update button at the top right of a board window's titlebar, while a newer release is on
/// offer (tooltip "easl X is available"); "Updating…" while it downloads, is checked and installs.
@MainActor
final class UpdateButton: NSTitlebarAccessoryViewController {
    private let button = NSButton(title: "Update", target: nil, action: nil)

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
        automaticallyAdjustsSize = false
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.bezelColor = .controlAccentColor
        button.target = self
        button.action = #selector(clicked(_:))
        // One width for both titles, so the titlebar never has to lay the accessory out again.
        let width = ["Update", "Updating…"].map { title in
            button.title = title
            button.sizeToFit()
            return button.frame.width
        }.max() ?? 0
        button.setFrameSize(NSSize(width: width, height: button.frame.height))
        // 4 pt before the button, 8 after it at the window's edge, centred in the titlebar.
        view = NSView(frame: NSRect(x: 0, y: 0, width: width + 12, height: 28))
        button.setFrameOrigin(NSPoint(x: 4, y: ((view.frame.height - button.frame.height) / 2).rounded()))
        button.autoresizingMask = [.minYMargin, .maxYMargin]
        view.addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ phase: UpdatePhase) {
        guard let release = phase.offered else { return }
        button.title = phase.isUpdating ? "Updating…" : "Update"
        button.isEnabled = !phase.isUpdating
        button.toolTip = switch phase {
        case .downloading: "Downloading easl \(release.version)"
        case .verifying, .ready: "Checking easl \(release.version)"
        case .installing: "easl quits and reopens as \(release.version)"
        case .idle, .checking, .available, .failed: "easl \(release.version) is available"
        }
    }

    @objc private func clicked(_ sender: Any?) {
        Updater.shared.offer(over: view.window)
    }
}
