import AppKit
import CanvasCore
import ObjectiveC

@testable import CanvasApp

/// Replaces the picker's native presentation on NSOpenPanel, so `openBoard` can be exercised
/// without a sheet or a modal run loop. The replacement never shows the panel; it records the
/// directory the picker chose for it and returns.
@MainActor
private enum PickerProbe {
    static var presentations: [(directory: URL?, sheet: Bool)] = []

    static func install() {
        intercept(NSSelectorFromString("beginWithCompletionHandler:"),
                  with: NSSelectorFromString("easlPickerBeginWithCompletionHandler:"))
        intercept(NSSelectorFromString("beginSheetModalForWindow:completionHandler:"),
                  with: NSSelectorFromString("easlPickerBeginSheetModalForWindow:completionHandler:"))
    }

    /// Adds an NSOpenPanel override for the presentation selector. The original implementation is
    /// never called: the regression inspects `directoryURL`, and a real panel would block here.
    private static func intercept(_ selector: Selector, with replacement: Selector) {
        guard let method = class_getInstanceMethod(NSOpenPanel.self, replacement) else {
            fatalError("Cannot intercept NSOpenPanel presentation")
        }
        class_replaceMethod(NSOpenPanel.self, selector, method_getImplementation(method), method_getTypeEncoding(method))
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message())\n".utf8))
            exit(1)
        }
    }
}

extension NSOpenPanel {
    @MainActor @objc(easlPickerBeginWithCompletionHandler:)
    fileprivate func easlPickerBegin(completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        _ = completionHandler
        PickerProbe.presentations.append((directory: directoryURL, sheet: false))
    }

    @MainActor @objc(easlPickerBeginSheetModalForWindow:completionHandler:)
    fileprivate func easlPickerBeginSheetModal(for window: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        _ = window
        _ = completionHandler
        PickerProbe.presentations.append((directory: directoryURL, sheet: true))
    }
}

@main
@MainActor
private enum BoardDirectoryPicker {
    private enum Context: String {
        case local, remote, noBoard = "no-board"
    }

    private enum Preference: String {
        case valid, unset, invalid
    }

    private static var home: URL!
    private static var localRoot: URL!
    private static var remoteRoot: URL!
    private static var preferredRoot: URL!
    private static var invalidRoot: URL!
    private static var registry: BoardRegistry!
    private static var preference: Preference = .unset

    static func main() {
        guard let homePath = ProcessInfo.processInfo.environment["EASL_HOME"], !homePath.isEmpty else {
            PickerProbe.require(false, "run.py must set EASL_HOME to a disposable directory")
            return
        }
        guard let preferenceName = ProcessInfo.processInfo.environment["EASL_PICKER_PREFERENCE"],
              let preference = Preference(rawValue: preferenceName) else {
            PickerProbe.require(false, "run.py must set EASL_PICKER_PREFERENCE to valid, unset, or invalid")
            return
        }
        guard let preferencePath = ProcessInfo.processInfo.environment["EASL_PICKER_PREFERENCE_PATH"], !preferencePath.isEmpty else {
            PickerProbe.require(false, "run.py must set EASL_PICKER_PREFERENCE_PATH")
            return
        }

        self.preference = preference
        home = URL(fileURLWithPath: homePath, isDirectory: true)
        localRoot = home.appendingPathComponent("local-board", isDirectory: true)
        remoteRoot = home.appendingPathComponent("remote-board", isDirectory: true)
        preferredRoot = URL(fileURLWithPath: preferencePath, isDirectory: true)
        invalidRoot = home.appendingPathComponent("missing-preferred-board", isDirectory: true)

        for directory in [localRoot!, remoteRoot!, preferredRoot!] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // The invalid preference names a directory that is not there: configuredBoardDirectory
        // must reject it and leave the picker where it was.
        try? FileManager.default.removeItem(at: invalidRoot)
        PickerProbe.require(!BoardStore.isDirectory(invalidRoot.path), "invalid preference path must not be a directory")

        // The preference arrives through NSArgumentDomain (`-canvas.boardDirectory` in run.py), so
        // no user preference file is read or written. Check the domain actually supplied it.
        let configured = UserDefaults.standard.string(forKey: "canvas.boardDirectory")
        switch preference {
        case .valid, .invalid:
            PickerProbe.require(configured == preferencePath,
                                "launch argument did not reach UserDefaults: \(String(describing: configured))")
        case .unset:
            PickerProbe.require(configured == nil, "canvas.boardDirectory leaked into this process: \(configured ?? "")")
        }

        let application = NSApplication.shared
        _ = application.setActivationPolicy(.accessory)
        application.finishLaunching()
        registry = BoardRegistry(store: BoardStore(directory: home.appendingPathComponent("remote-registry", isDirectory: true)))
        PickerProbe.install()

        Task { @MainActor in
            let localExpected = preference == .valid ? preferredRoot : localRoot
            await check(context: .local, expected: localExpected)
            await check(context: .remote, expected: remoteRoot)
            await check(context: .noBoard, expected: preference == .valid ? preferredRoot : nil)

            print("PASS board picker preference=\(preference.rawValue) home=\(home.path)")
            exit(0)
        }
        application.run()
    }

    private static func check(context: Context, expected: URL?) async {
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            PickerProbe.require(false, "openBoard \(context.rawValue) timed out")
        }
        defer { timeout.cancel() }
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        defer {
            NSApp.delegate = nil
            resetWindows()
        }

        var retainedController: CanvasWindowController?
        defer { withExtendedLifetime(retainedController) {} }
        let expectedSheet: Bool
        switch context {
        case .local:
            let board: Board
            do {
                board = try await delegate.open(root: localRoot)
            } catch {
                PickerProbe.require(false, "local board could not open: \(error)")
                return
            }
            guard let controller = NSApp.windows.compactMap({ $0.windowController as? CanvasWindowController })
                .first(where: { $0.board.id == board.id && $0.isBoardOpen }) else {
                PickerProbe.require(false, "local board window was not created")
                return
            }
            retainedController = controller
            await bringToFront(controller, "local")
            PickerProbe.require(controller.remote == nil, "local controller unexpectedly has a RemoteSource")
            expectedSheet = true
        case .remote:
            // A real remote window: a real BoardMirror and RemoteSource. Nothing is loaded, so no
            // host connection is needed; the picker only needs the controller's remote flag and root.
            let controller = await remoteController()
            retainedController = controller
            PickerProbe.require(controller.remote != nil, "remote controller has no RemoteSource")
            PickerProbe.require(controller.board.root.standardizedFileURL.path == remoteRoot.standardizedFileURL.path,
                                "remote controller has the wrong board root")
            controller.showWindow(nil)
            await bringToFront(controller, "remote")
            expectedSheet = true
        case .noBoard:
            expectedSheet = false
        }

        PickerProbe.presentations.removeAll()
        delegate.openBoard(nil)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while PickerProbe.presentations.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await settle()

        PickerProbe.require(PickerProbe.presentations.count == 1,
                            "openBoard \(context.rawValue) presented \(PickerProbe.presentations.count) panels, expected 1")
        guard let presentation = PickerProbe.presentations.first else { return }
        PickerProbe.require(presentation.sheet == expectedSheet,
                            "openBoard \(context.rawValue) sheet=\(presentation.sheet), expected \(expectedSheet)")
        requireSame(presentation.directory, expected,
                    "openBoard \(context.rawValue) preference=\(preference.rawValue)")
        print("PASS openBoard context=\(context.rawValue) preference=\(preference.rawValue) directory=\(presentation.directory?.path ?? "nil") sheet=\(presentation.sheet)")
    }

    /// A local board passes its own root; a remote board passes its host board's root even when a
    /// preference is configured. Without a board the preference is the only directory there is.
    private static func requireSame(_ actual: URL?, _ expected: URL?, _ stage: String) {
        let actualPath = actual?.standardizedFileURL.resolvingSymlinksInPath().path
        let expectedPath = expected?.standardizedFileURL.resolvingSymlinksInPath().path
        PickerProbe.require(actualPath == expectedPath,
                            "\(stage) expected \(expectedPath ?? "nil"), got \(actualPath ?? "nil")")
    }

    private static func remoteController() async -> CanvasWindowController {
        let host = RemoteHost(name: "picker-regression",
                              sshTarget: "picker-regression.invalid",
                              socketPath: home.appendingPathComponent("host.sock").path,
                              tmpdir: home.path,
                              easlBin: "easl")
        let board = Board(id: "picker-regression-remote", root: remoteRoot)
        // No host is contacted: the socket is absent and the retry is parked far outside this run.
        let backoff = EaslConnection.Backoff(initial: .seconds(3600), maximum: .seconds(3600))
        let absent = home.appendingPathComponent("absent.sock").path
        let mirror = BoardMirror(hostName: host.name,
                                 board: board.id,
                                 connection: EaslConnection(.unixSocket(absent), backoff: backoff, handshakeTimeout: .seconds(1)),
                                 diagrams: EaslConnection(.unixSocket(absent), backoff: backoff, handshakeTimeout: .seconds(1)))
        await CanvasWindowController.prepareWindowIcon()
        let controller = CanvasWindowController(window: CanvasWindowController.makeWindow(isRemote: true),
                                                board: board,
                                                registry: registry,
                                                viewport: nil,
                                                composerState: ComposerState(),
                                                remote: RemoteSource(host: host, mirror: mirror))
        controller.isBoardOpen = true
        return controller
    }

    /// The picker reads `CanvasWindowController.frontmost`; its window must be visible and front.
    private static func bringToFront(_ controller: CanvasWindowController, _ stage: String) async {
        guard let window = controller.window else {
            PickerProbe.require(false, "\(stage) has no window")
            return
        }
        window.makeKeyAndOrderFront(nil)
        await settle()
        if CanvasWindowController.frontmost !== controller {
            window.orderFrontRegardless()
            await settle()
        }
        PickerProbe.require(CanvasWindowController.frontmost === controller,
                            "\(stage) controller is not frontmost (visible=\(window.isVisible))")
    }

    private static func resetWindows() {
        for window in NSApp.windows {
            guard let controller = window.windowController as? CanvasWindowController else { continue }
            window.orderOut(nil)
            if controller.isBoardOpen {
                controller.isBoardOpen = false
                controller.discard()
            }
        }
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }
}
