import AppKit
import CanvasCore

/// A ready bundle can install without a working feed, but is verified again before handoff.
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
    private var operation: Task<Void, Never>?
    private var latest: LatestRelease?
    private var staged: StagedUpdate?
    private var failure: UpdateFailure?
    private var startupCleanupComplete = false
    private var observers: [NSObjectProtocol] = []
    private let failureURL = AppPaths.support.appendingPathComponent("update-failure.json")

    private struct StagedUpdate {
        let staging: AppUpdate.Staging
        let app: URL
        let incoming: URL
        let lease: AppUpdate.StagingLease
        let team: String?
        let gatekeeper: Bool
    }

    private struct UpdateFailure: Codable {
        let reason: String
        let sha256: String?
        let retryAfter: Date?
        var noticePending: Bool
    }
    private struct Installation {
        enum Handoff {
            case awaitingReply
            case quitting
            case aborting
        }

        let transaction: String
        var helper: pid_t?
        let delegate: AppDelegate
        let retryAfter: Date
        var handoff: Handoff
    }
    private var installation: Installation?

    private let running = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private let override = ProcessInfo.processInfo.environment["EASL_UPDATE_URL"]
    private static let session = URLSession(configuration: .ephemeral)

    func start() {
        failure = (try? Data(contentsOf: failureURL)).flatMap { try? JSONDecoder().decode(UpdateFailure.self, from: $0) }
        operation = Task {
            await cleanUp()
            operation = nil
            startupCleanupComplete = true
            showPendingFailure()
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserIdleWatch.sampled, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Updater.shared.advanceAutomatically() }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Updater.shared.showPendingFailure() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Updater.shared.showPendingFailure() }
        })
        let localFeed = override.flatMap { URL(string: $0) }?.host.map { ["127.0.0.1", "localhost", "::1"].contains($0) } ?? false
        guard !DevInput.enabled || localFeed else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppUpdate.firstCheck))
            self?.check(manual: false)
        }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let updater = Updater.shared
                if updater.lastCheck.map({ Date().timeIntervalSince($0) >= AppUpdate.checkInterval }) ?? true {
                    updater.check(manual: false)
                }
            }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var automaticEnabled: Bool {
        UISettings.Store(url: AppPaths.uiSettings).load().installUpdatesAutomatically
    }

    func automaticSettingChanged() {
        guard automaticEnabled else { return }
        if phase.offered == nil { check(manual: false) } else { advanceAutomatically() }
    }

    func check(manual: Bool) {
        if let operation {
            guard manual else { return }
            Task {
                await operation.value
                check(manual: true)
            }
            return
        }
        guard !phase.isUpdating else {
            if manual, let release = phase.offered {
                inform("easl is updating to \(release.version)", "easl quits and reopens when the update is ready.")
            }
            return
        }
        if case .ready = phase {
            if manual { offer(over: nil) }
            return
        }
        operation = Task {
            await runCheck(manual: manual)
            operation = nil
            advanceAutomatically()
        }
    }

    func apiUpdate(mode: String) async throws -> ApiRouter.UpdateReply {
        while let operation { await operation.value }
        if case .installing = phase { return ApiRouter.UpdateReply(value: status()) }
        var checkError: String?
        var acceptedTransaction: String?
        operation = Task {
            checkError = await runCheck(manual: false)
            if mode == "install", phase.name != "failed" {
                await stageIfNeeded()
                acceptedTransaction = await installReady(automatic: false, awaitingReply: true)
            }
            operation = nil
        }
        await operation?.value
        let answer = status(checkError: checkError)
        if mode == "check" { advanceAutomatically() }
        guard let acceptedTransaction else { return ApiRouter.UpdateReply(value: answer) }
        return ApiRouter.UpdateReply(value: answer) { [weak self] sent in
            self?.installReplySent(sent, transaction: acceptedTransaction)
        }
    }

    private func status(checkError: String? = nil) -> JSONValue {
        let error: String?
        switch phase {
        case .installing: error = nil
        case let .failed(reason, _): error = reason
        default: error = checkError ?? failure?.reason
        }
        return .object([
            "currentVersion": .string(running ?? ""),
            "availableVersion": latest.map { .string($0.version.description) } ?? .null,
            "installPending": .bool(phase.installPending),
            "phase": .string(phase.name),
            "error": error.map(JSONValue.string) ?? .null,
        ])
    }

    @discardableResult
    private func runCheck(manual: Bool) async -> String? {
        let ready: Bool
        if case .ready = phase { ready = true } else { ready = false }
        if !ready {
            guard let next = phase.after(.check) else { return nil }
            phase = next
        }
        lastCheck = Date()
        do {
            guard let source = AppUpdate.source(override: override) else {
                throw UpdateError("EASL_UPDATE_URL isn't an http or https address: \(override ?? "")")
            }
            guard let running, let current = AppVersion(running) else {
                throw UpdateError("this easl has no version to compare (it isn't running from its app bundle)")
            }
            let release = try await fetch(source)
            latest = release
            let newer = release.isNewer(than: current)
            if !ready { phase = phase.after(newer ? .found(release) : .upToDate) ?? phase }
            NSLog("easl: update check: %@ offers %@, this is %@", source.absoluteString, release.version.description, running)
            if manual {
                if newer { offer(over: nil) } else { inform("easl \(running) is up to date", "\(release.version) is the newest version.") }
            }
        } catch {
            let reason = Self.reason(error)
            NSLog("easl: update check failed: %@", reason)
            if !ready { phase = phase.after(.fail(reason)) ?? phase }
            if manual { inform("Couldn't check for updates", reason) }
            return reason
        }
        return nil
    }

    private func automaticAction() -> AppUpdate.AutomaticAction {
        switch phase {
        case .available, .ready: break
        default: return .none
        }
        guard let running, let current = AppVersion(running) else { return .none }
        return AppUpdate.automaticAction(phase: phase, running: current, enabled: automaticEnabled,
                                         idleSeconds: UserIdleWatch.shared.currentIdleSeconds(), rejectedSHA256: failure?.sha256,
                                         retryAfter: failure?.retryAfter, now: .now)
    }

    private func advanceAutomatically() {
        guard operation == nil, automaticAction() != .none else { return }
        operation = Task {
            if automaticAction() == .stage { await stageIfNeeded() }
            if automaticAction() == .install { await installReady(automatic: true) }
            operation = nil
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

    private func update(over window: NSWindow?) {
        if let operation {
            Task {
                await operation.value
                update(over: window)
            }
            return
        }
        guard !phase.isUpdating else { return }
        operation = Task {
            await stageIfNeeded()
            await installReady(automatic: false)
            operation = nil
        }
    }

    private func stageIfNeeded() async {
        if case .ready = phase { return }
        guard let next = phase.after(.download), let release = next.offered,
              let running, let current = AppVersion(running), release.isNewer(than: current) else { return }
        phase = next
        await discardStaged()
        var lease: AppUpdate.StagingLease?
        do {
            try persistInterruption("The download of easl \(release.version) was interrupted.")
            let app = try Self.replaceable()
            try await Self.requireSoleInstance(of: app)
            let staging = try AppUpdate.Staging(updates: AppPaths.updates, version: release.version.description)
            let stagingLease = try AppUpdate.StagingLease(incoming: staging.incoming(beside: app))
            lease = stagingLease
            try await download(release, into: staging)
            phase = phase.after(.downloaded) ?? phase
            let team = await offPool { AppUpdate.runningTeamID() }
            let gatekeeper = !(team == nil && DevInput.enabled)
            let incoming = try await AppUpdate.prepareInstall(staging, release: release, replacing: app, team: team, gatekeeper: gatekeeper)
            staged = StagedUpdate(staging: staging, app: app, incoming: incoming, lease: stagingLease, team: team, gatekeeper: gatekeeper)
            lease = nil
            try restoreFailureRecord(nil)
            phase = phase.after(.verified) ?? phase
        } catch {
            try? lease?.discard()
            await discardStaged()
            recordFailure(Self.reason(error), rejecting: Self.rejectsArtifact(error) ? release.sha256 : nil)
        }
    }

    @discardableResult
    private func installReady(automatic: Bool, awaitingReply: Bool = false) async -> String? {
        guard case let .ready(release) = phase, let staged else { return nil }
        if automatic, automaticAction() != .install { return nil }
        var prepared: AppDelegate?
        var retryAfter: Date?
        do {
            try await Self.requireSoleInstance(of: staged.app)
            try await AppUpdate.verify(staged.incoming, release: release, team: staged.team, gatekeeper: staged.gatekeeper)
            if automatic, automaticAction() != .install { return nil }
            guard let delegate = NSApp.delegate as? AppDelegate else {
                throw UpdateError("easl couldn't save its open boards before updating")
            }
            try delegate.prepareForUpdate()
            prepared = delegate
            if automatic, automaticAction() != .install {
                try delegate.cancelPreparedUpdate()
                prepared = nil
                return nil
            }
            let retryDeadline = Date.now.addingTimeInterval(AppUpdate.checkInterval)
            retryAfter = retryDeadline
            try persistInterruption("The update to easl \(release.version) was interrupted before completion.", retryAfter: retryDeadline)
            var helper: pid_t? = nil
            if !awaitingReply {
                helper = try startHelper(staged.staging, replacing: staged.app, lease: staged.lease)
            }
            let transaction = staged.staging.transaction
            installation = Installation(transaction: transaction, helper: helper, delegate: delegate,
                                        retryAfter: retryDeadline, handoff: awaitingReply ? .awaitingReply : .quitting)
            phase = phase.after(.install) ?? phase
            if !awaitingReply { quitForInstall(transaction: transaction, afterReply: false) }
            return transaction
        } catch {
            var reason = Self.reason(error)
            if let prepared {
                do { try prepared.cancelPreparedUpdate() } catch {
                    reason += ". Couldn't remove the saved update boards: \(Self.reason(error))"
                }
            }
            await discardStaged()
            recordFailure(reason, rejecting: Self.rejectsArtifact(error, localCopy: true) ? release.sha256 : nil,
                          retryAfter: retryAfter)
        }
        return nil
    }

    private func installReplySent(_ sent: Bool, transaction: String) {
        guard let installation, installation.transaction == transaction,
              case .awaitingReply = installation.handoff else { return }
        if sent {
            self.installation?.handoff = .quitting
            quitForInstall(transaction: transaction, afterReply: true)
        } else {
            abortInstallation(transaction: transaction,
                              reason: "The app.update install acknowledgment failed or did not finish within 30 seconds. easl is still running and nothing was replaced.")
        }
    }

    private func quitForInstall(transaction: String, afterReply: Bool) {
        Task {
            if afterReply { try? await Task.sleep(for: .seconds(1)) }
            guard let installation, installation.transaction == transaction,
                  case .quitting = installation.handoff else { return }
            if afterReply {
                guard let staged, staged.staging.transaction == transaction else {
                    abortInstallation(transaction: transaction, reason: "The prepared update is no longer available. Nothing was replaced.")
                    return
                }
                do { try installation.delegate.prepareForUpdate() } catch {
                    abortInstallation(transaction: transaction,
                                      reason: "Couldn't save the current open boards before updating: \(Self.reason(error))")
                    return
                }
                do {
                    self.installation?.helper = try startHelper(staged.staging, replacing: staged.app, lease: staged.lease)
                } catch {
                    abortInstallation(transaction: transaction, reason: Self.reason(error))
                    return
                }
            }
            AppDelegate.terminateNow()
            try? await Task.sleep(for: .seconds(30))
            abortInstallation(transaction: transaction, reason: "easl didn't quit, so nothing was replaced")
        }
    }

    func applicationWillTerminate() {
        guard let installation, installation.helper == nil else { return }
        abortInstallation(transaction: installation.transaction,
                          reason: "easl quit while app.update installation was waiting for its acknowledgment or display grace. Nothing was replaced or relaunched.")
    }

    private func abortInstallation(transaction: String, reason: String) {
        guard let installation, installation.transaction == transaction else { return }
        if case .aborting = installation.handoff { return }
        self.installation?.handoff = .aborting
        if let helper = installation.helper {
            Task {
                await stopHelper(helper)
                var reason = reason
                do { try installation.delegate.cancelPreparedUpdate() } catch {
                    reason += ". Couldn't remove the saved update boards: \(Self.reason(error))"
                }
                await discardStaged()
                self.installation = nil
                recordFailure(reason, rejecting: nil, retryAfter: installation.retryAfter)
            }
        } else {
            let incoming = staged?.incoming
            try? staged?.lease.discard()
            staged = nil
            var reason = reason
            do { try installation.delegate.cancelPreparedUpdate() } catch {
                reason += ". Couldn't remove the saved update boards: \(Self.reason(error))"
            }
            self.installation = nil
            recordFailure(reason, rejecting: nil, retryAfter: installation.retryAfter)
            if let incoming {
                DispatchQueue.global(qos: .utility).async {
                    try? FileManager.default.removeItem(at: incoming)
                }
            }
        }
    }

    private func discardStaged() async {
        guard let staged else { return }
        self.staged = nil
        let incoming = staged.incoming
        await offPool { try? FileManager.default.removeItem(at: incoming) }
        try? staged.lease.discard()
    }

    private func saveFailure(_ failure: UpdateFailure) throws {
        try FileManager.default.createDirectory(at: failureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(failure).write(to: failureURL, options: .atomic)
        self.failure = failure
    }

    private func persistInterruption(_ reason: String, retryAfter: Date? = nil) throws {
        let previous = failure
        try saveFailure(UpdateFailure(reason: reason, sha256: nil, retryAfter: retryAfter, noticePending: true))
        failure = previous
    }

    private func restoreFailureRecord(_ previous: UpdateFailure?) throws {
        if let previous {
            try saveFailure(previous)
        } else {
            if FileManager.default.fileExists(atPath: failureURL.path) { try FileManager.default.removeItem(at: failureURL) }
            failure = nil
        }
    }

    private func recordFailure(_ reason: String, rejecting sha256: String?, retryAfter: Date? = nil) {
        NSLog("easl: update failed: %@", reason)
        phase = phase.after(.fail(reason)) ?? .failed(reason, offered: phase.offered)
        do {
            try saveFailure(UpdateFailure(reason: reason, sha256: sha256, retryAfter: retryAfter, noticePending: true))
        } catch {
            failure = UpdateFailure(reason: "\(reason). Couldn't save update failure: \(error.localizedDescription)",
                                    sha256: sha256, retryAfter: retryAfter, noticePending: true)
        }
        refreshButtons()
        showPendingFailure()
    }

    private func showPendingFailure() {
        guard startupCleanupComplete, !phase.isUpdating, NSApp.isActive, var failure, failure.noticePending,
              let controller = CanvasWindowController.frontmost, let window = controller.window,
              !window.isMiniaturized, window.isVisible, window.isOnActiveSpace else { return }
        controller.canvas.showNotice("easl wasn't updated. \(failure.reason)")
        failure.noticePending = false
        do { try saveFailure(failure) } catch { NSLog("easl: couldn't acknowledge update failure: %@", error.localizedDescription) }
    }

    /// Refuses while another easl process (on another home: one home has one instance) runs from
    /// `app`: the swap would pull its bundle from under it.
    private static func requireSoleInstance(of app: URL) async throws {
        let running = NSWorkspace.shared.runningApplications.map { AppUpdate.RunningInstance(pid: $0.processIdentifier, bundle: $0.bundleURL) }
        let me = getpid()
        if let other = await offPool({ AppUpdate.otherInstance(sharing: app, among: running, except: me) }) {
            NSLog("easl: easl pid %d also runs from %@; not updating", other.pid, app.path)
            throw AppUpdate.InstallProblem.otherInstance(app.path)
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
    /// nothing aimed at easl's process group reaches it, with only the staging lease inherited
    /// from easl and its output in `staging.log`. It relaunches with this
    /// bundle's `LSEnvironment` and `EASL_HOME`: a development or test instance comes back on its
    /// own home, never on the default one beside the user's own easl.
    private func startHelper(_ staging: AppUpdate.Staging, replacing app: URL, lease: AppUpdate.StagingLease) throws -> pid_t {
        var environment = Bundle.main.infoDictionary?["LSEnvironment"] as? [String: String] ?? [:]
        if let home = ProcessInfo.processInfo.environment["EASL_HOME"] { environment["EASL_HOME"] = home }
        let script = AppUpdate.helperScript(pid: getpid(), app: app, staging: staging, relaunch: AppUpdate.relaunchCommand(environment: environment))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, staging.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        try lease.inherit(in: &actions)
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
        return pid
    }

    private func stopHelper(_ pid: pid_t) async {
        // Its session's group: the shell and the sleep it waits in.
        kill(-pid, SIGTERM)
        await offPool {
            while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
        }
    }

    /// At launch, off the main thread: logs what the helper did (and says so when it failed),
    /// deletes `updates/`'s folders, except one easl now runs from, and calls
    /// `AppUpdate.removeStaleLeftovers` for hidden copies and protection directories beside this
    /// app that are at least an hour old (a backup uses the newer bundle/protection date), so
    /// another home's update under way is never swept. Cleanup is deliberately best-effort,
    /// tolerates filesystem errors, and never removes this app or its protection.
    private func cleanUp() async {
        let updates = AppPaths.updates
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let (failures, installed) = await offPool {
            let files = FileManager.default
            var failures: [String] = []
            var installed = false
            let runningVersion = AppUpdate.bundleVersion(of: running)
            for folder in (try? files.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil)) ?? [] {
                let version = folder.lastPathComponent
                let result = folder.appendingPathComponent("result")
                if version == runningVersion {
                    installed = true
                } else if let outcome = (try? String(contentsOf: result, encoding: .utf8)).flatMap(AppUpdate.Outcome.init(result:)),
                          let failure = outcome.failure {
                    failures.append("easl couldn't install \(version): \(failure).")
                }
                let path = folder.resolvingSymlinksInPath().path
                guard running.path != path, !running.path.hasPrefix(path + "/") else { continue }
                try? files.removeItem(at: folder)
            }
            let beside = running.deletingLastPathComponent()
            for name in AppUpdate.removeStaleLeftovers(beside: beside, running: running.lastPathComponent) {
                NSLog("easl: removed %@, left by an update", beside.appendingPathComponent(name).path)
            }
            return (failures, installed)
        }
        if installed {
            do { try restoreFailureRecord(nil) } catch { recordFailure(Self.reason(error), rejecting: nil) }
        } else if !failures.isEmpty {
            recordFailure(failures.joined(separator: "\n\n"), rejecting: failure?.sha256, retryAfter: failure?.retryAfter)
        }
    }

    // MARK: windows

    /// Gives a board window its Update button, in its titlebar while a release is on offer.
    func attach(to window: NSWindow) {
        buttons.removeAll { $0.window == nil }
        let entry = WindowButton(window: window, button: UpdateButton())
        buttons.append(entry)
        place(entry)
        Task { showPendingFailure() }
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

    private static func rejectsArtifact(_ error: Error, localCopy: Bool = false) -> Bool {
        if error is AppUpdate.DownloadProblem { return true }
        guard let problem = error as? AppUpdate.InstallProblem else { return false }
        switch problem {
        case .signature, .team, .gatekeeper, .version, .unpack: return true
        case .noApp, .notABundle: return !localCopy
        case .outsideUpdates, .copy, .quarantine, .otherInstance: return false
        }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case let error as UpdateError: error.reason
        case let error as LatestRelease.Problem: error.description
        case let error as AppUpdate.DownloadProblem: error.description
        case let error as AppUpdate.InstallProblem: error.description
        case let error as ApiRouter.Failure: error.message
        case let error as EaslConnection.Failure: error.message
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
        case .verifying: "Checking easl \(release.version)"
        case .ready: "easl \(release.version) is verified and ready to install"
        case .installing: "easl quits and reopens as \(release.version)"
        case let .failed(reason, _): "easl wasn't updated: \(reason)"
        case .idle, .checking, .available: "easl \(release.version) is available"
        }
    }

    @objc private func clicked(_ sender: Any?) {
        Updater.shared.offer(over: view.window)
    }
}
