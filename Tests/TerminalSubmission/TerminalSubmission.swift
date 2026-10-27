import AppKit
import CanvasCore
import GhosttyKit
import GhosttyTerminal

@testable import CanvasApp

@main
@MainActor
private enum TerminalSubmission {
    struct Failed: Error { let message: String }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failed(message: message) }
    }

    static func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw Failed(message: "terminal observation deadline expired") }
            await MainTurns.next()
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    final class Fixture: TerminalSurfaceLifecycleDelegate {
        let view = CanvasTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let window: NSWindow
        let receipt: URL
        let controller: TerminalController
        var surface: TerminalSurface?

        init(command: String? = nil) {
            receipt = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!)
                .appendingPathComponent(UUID().uuidString)
            controller = TerminalController(configSource: .generated("shell-integration = none\n"), theme: TerminalTheme())
            window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            view.configuration = TerminalSurfaceOptions(backend: .exec,
                command: command ?? ShellWords.quote(["/bin/sh", "-c", "exec /bin/cat > " + ShellWords.quote([receipt.path])]),
                waitAfterCommand: true)
            window.isReleasedWhenClosed = false
            window.contentView!.addSubview(view)
            window.orderFrontRegardless()
            view.delegate = self
            view.controller = controller
        }

        func terminalDidAttachSurface(_ surface: TerminalSurface) { self.surface = surface }
        func terminalDidDetachSurface() { surface = nil }

        var exited: Bool {
            guard let handle = surface?.handle else { return false }
            return ghostty_surface_process_exited(handle)
        }

        func close() {
            view.cancelImageInput()
            view.controller = nil
            window.close()
        }

        func text() -> String { (try? String(contentsOf: receipt, encoding: .utf8)) ?? "" }

        func submit(_ text: String, delay: Duration = .zero) async -> Bool {
            await view.submitOrdered({ [view] in view.paste(text: text) }, delay: delay)
        }
    }

    static func liveAttachmentReceivesTextAndEnterOnce() async throws {
        let f = Fixture()
        defer { f.close() }
        try await until { f.surface != nil }
        let accepted = await f.submit("submission-once")
        try require(accepted, "a live attachment must accept the full submission")
        try await until { f.text() == "submission-once\n" }
        try require(f.text() == "submission-once\n", "the attachment must receive text and exactly one Enter")
    }

    static func exitedAttachmentIsNotSuccessfulDelivery() async throws {
        let f = Fixture(command: ShellWords.quote(["/bin/sh", "-c", "exit 0"]))
        defer { f.close() }
        try await until { f.exited }
        let accepted = await f.submit("must-not-deliver")
        try require(!accepted, "exited-surface dismissal is not accepted prompt delivery")
    }

    static func replacementCannotReceiveTheOriginalEnter() async throws {
        let f = Fixture()
        defer { f.close() }
        try await until { f.surface != nil }
        let original = f.surface
        let replacementReceipt = f.receipt.appendingPathExtension("replacement")
        let accepted = await f.view.submitOrdered({
            guard f.view.paste(text: "original-only") else { return false }
            var options = f.view.configuration
            options.command = ShellWords.quote(["/bin/sh", "-c", "IFS= read -r line; printf '%s\\n' \"$line\" > " + ShellWords.quote([replacementReceipt.path]) + "; exec /bin/cat"])
            f.view.configuration = options
            return true
        }, delay: .zero)
        try require(f.surface !== original, "the fixture must replace the attachment")
        try require(!accepted, "a replaced attachment must not complete the original submission")
        let control = await f.submit("replacement-control")
        try require(control, "the replacement must accept a new explicit submission")
        try await until { FileManager.default.fileExists(atPath: replacementReceipt.path) }
        let received = try String(contentsOf: replacementReceipt, encoding: .utf8)
        try require(received == "replacement-control\n", "the replacement must not receive a stray Enter or replayed text")
    }

    static func exitedAttachmentKeepsComposerDraft() async throws {
        let f = Fixture(command: ShellWords.quote(["/bin/sh", "-c", "exit 0"]))
        defer { f.close() }
        try await until { f.exited }
        let board = Board(id: "brd_submission", root: f.receipt.deletingLastPathComponent())
        let tile = board.create(type: .terminal, props: .object([:])).id
        let bar = ComposerBar(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
        let composer = ComposerController(board: board, bar: bar, file: nil,
            state: ComposerState(draft: ComposerDraft(text: "keep-this-draft")))
        f.window.contentView!.addSubview(bar)
        composer.promptTarget = { tile }
        var notices: [String] = []
        composer.notice = { notices.append($0) }
        composer.send = { text, _, _, _ in
            guard await f.submit(text) else {
                throw ApiRouter.Failure("unavailable", "Incomplete submission; inspect the terminal before sending again")
            }
        }
        guard let completion = composer.sendDraft() else { throw Failed(message: "the composer did not start its send") }
        await completion.value
        try require(bar.draft.text == "keep-this-draft", "refused delivery must retain the draft")
        try require(composer.state.history.isEmpty, "refused delivery must not become sent history")
        try require(notices.contains { $0.contains("inspect the terminal") }, "the refusal must be visible in the composer")
    }

    static func exitedRawKeyIsRefusedVisibly() async throws {
        let f = Fixture(command: ShellWords.quote(["/bin/sh", "-c", "exit 0"]))
        defer { f.close() }
        try await until { f.exited }
        var notices: [String] = []
        f.view.onImageProblem = { notices.append($0) }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: f.window.windowNumber, context: nil,
                                    characters: "e", charactersIgnoringModifiers: "e",
                                    isARepeat: false, keyCode: 14)!
        f.view.keyDown(with: event)
        try require(notices.count == 1, "a key refused by an exited attachment needs a visible notice")
    }

    static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in await runCases() }
        app.run()
    }

    static func runCases() async {
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("live attachment receives text and Enter once", liveAttachmentReceivesTextAndEnterOnce),
            ("exited attachment refuses prompt delivery", exitedAttachmentIsNotSuccessfulDelivery),
            ("replacement cannot inherit a submission", replacementCannotReceiveTheOriginalEnter),
            ("exited raw key is refused visibly", exitedRawKeyIsRefusedVisibly),
            ("exited attachment keeps composer draft", exitedAttachmentKeepsComposerDraft),
        ]
        var failures = 0
        for (name, test) in cases {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("TERMINAL_SUBMISSION_COMPLETE")
        exit(failures == 0 ? 0 : 1)
    }
}
