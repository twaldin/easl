import AppKit
@testable import CanvasCore
@testable import CanvasApp

@main
@MainActor
private enum ComposerDelivery {
    struct Failed: Error { let message: String }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failed(message: message) }
    }

    static func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw Failed(message: "delivery did not settle") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    final class Fixture {
        let board: Board
        let bar: ComposerBar
        let controller: ComposerController
        let window: NSWindow
        let a: ObjectID
        let b: ObjectID

        init(draft: String = "", previous: [ComposerDraft] = [], multiple: Bool = false) {
            board = Board(id: "brd_delivery_test", root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!))
            a = board.create(type: .terminal, props: .object(["name": .string("target-A")])).id
            b = board.create(type: .terminal, props: .object(["name": .string("target-B")])).id
            bar = ComposerBar(frame: NSRect(x: 20, y: 20, width: 680, height: 120))
            controller = ComposerController(board: board, bar: bar, file: nil,
                state: ComposerState(draft: ComposerDraft(text: draft), alsoTo: multiple ? [b] : [], outgoing: previous))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView!.addSubview(bar)
            let a = a
            controller.promptTarget = { a }
            let board = board
            controller.name = { board.objects[$0]?.props["name"]?.string ?? $0 }
            window.orderFrontRegardless()
        }

        var status: NSTextField {
            bar.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Prompt delivery" }!
        }
    }

    static func currentReceiptOverridesPreviousWarning() async throws {
        let held = ComposerDraft(text: "held, never restore automatically")
        let f = Fixture(previous: [held])
        defer { f.window.close() }
        let warning = f.status.stringValue
        try require(!f.status.isHidden && f.bar.draft.isEmpty, "a previous unknown send stays visible without becoming a draft")
        f.controller.promptDeliveryChanged("current", terminal: f.a, delivery: .checking)
        try require(f.status.stringValue.contains("target-A") && f.status.stringValue != warning,
                    "the current target's checking status must not be hidden by a previous warning")
        f.controller.promptDeliveryChanged("current", terminal: f.a, delivery: .delivered)
        try require(!f.status.isHidden && f.status.textColor != .systemOrange && f.status.stringValue != warning,
                    "the current successful receipt must replace the previous warning")
        try require(f.controller.state.outgoing == [held] && f.bar.draft.isEmpty, "a new receipt must not restore or discard the held prompt")
    }

    static func dismissPreviousWarningWithoutResending() async throws {
        let held = ComposerDraft(text: "unknown previous prompt")
        let f = Fixture(previous: [held])
        defer { f.window.close() }
        let dismiss = f.bar.subviews.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "composer.dismissPreviousDelivery" && !$0.isHidden }
        try require(dismiss != nil, "the previous warning needs an explicit dismissal action")
        dismiss!.performClick(nil)
        try require(f.status.isHidden && f.controller.state.outgoing == [held] && f.bar.draft.isEmpty,
                    "dismissal hides only this window's warning, retaining unknown text outside the unsent draft")
        f.controller.promptDeliveryChanged("later", terminal: f.b, delivery: .checking)
        try require(!f.status.isHidden && f.status.stringValue.contains("target-B"), "dismissing an old warning must not hide later delivery checks")
    }

    static func refusalAppearsWhileAnotherTargetIsUnknown() async throws {
        let f = Fixture(draft: "one prompt", multiple: true)
        defer { f.window.close() }
        var notices: [String] = []
        var pending: CheckedContinuation<Void, Error>?
        f.controller.notice = { notices.append($0) }
        f.controller.send = { _, terminal, _, _ in
            if terminal == f.a { throw ApiRouter.Failure("unavailable", "refusal-A") }
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let completion = f.controller.sendDraft()!
        try await until { pending != nil }
        let deadline = ContinuousClock.now + .seconds(5)
        while !notices.contains(where: { $0.contains("target-A") && $0.contains("refusal-A") }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let reportedBeforeClose = notices.contains { $0.contains("target-A") && $0.contains("refusal-A") }
        pending!.resume(throwing: BoardMirror.PromptOutcomeUnknown())
        await completion.value
        try require(reportedBeforeClose, "target A's refusal must be reported before target B resolves or the window closes")
        try require(f.bar.draft.isEmpty && f.controller.state.outgoing.map(\.text) == ["one prompt"],
                    "unknown target B must keep the outgoing prompt held, not restore it")
    }

    static func lateTargetDoesNotDuplicateHistory() async throws {
        let f = Fixture(draft: "first prompt", multiple: true)
        defer { f.window.close() }
        var pending: CheckedContinuation<Void, Never>?
        f.controller.send = { text, terminal, _, _ in
            if text == "first prompt" && terminal == f.b {
                await withCheckedContinuation { pending = $0 }
            }
        }
        let first = f.controller.sendDraft()!
        try await until { pending != nil && f.controller.state.history.map(\.text) == ["first prompt"] }
        f.bar.show(ComposerDraft(text: "second prompt"), board: f.board)
        let second = f.controller.sendDraft()!
        await second.value
        pending!.resume()
        await first.value
        try require(f.controller.state.history.map(\.text) == ["first prompt", "second prompt"],
                    "a slow second target must not repeat or reorder the first prompt in recall history")
    }

    static func main() async {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("current receipt overrides old warning", currentReceiptOverridesPreviousWarning),
            ("dismissal retains unknown outgoing", dismissPreviousWarningWithoutResending),
            ("refusal precedes another target's unknown outcome", refusalAppearsWhileAnotherTargetIsUnknown),
            ("interleaved target completion preserves history", lateTargetDoesNotDuplicateHistory),
        ]
        var failures = 0
        for (name, test) in cases {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
