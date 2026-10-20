import AppKit
import CanvasCore

@testable import CanvasApp

@main
@MainActor
private enum ComposerInput {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!)
        let board = Board(id: "brd_composer_input", root: root)
        let code = board.create(type: .code, props: .object(["path": .string("sample.swift")]))
        try board.stage(.code(object: code.id, path: "sample.swift", lines: LineRange(start: 1, end: 1)))
        let bar = ComposerBar(frame: NSRect(x: 0, y: 0, width: 680, height: 100))
        let controller = ComposerController(board: board, bar: bar, file: nil, state: ComposerState())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(bar)
        window.makeFirstResponder(bar.text)
        window.orderFrontRegardless()
        defer { window.close() }
        board.onEvent = { _ in controller.trayChanged() }
        defer { board.onEvent = nil }
        try await Task.sleep(for: .milliseconds(50))
        require(bar.draft.prompt == "[1]", "the staged code appears as a token")
        let undo = bar.text.undoManager!
        bar.text.selectAll(nil)
        bar.text.deleteBackward(nil)
        bar.text.breakUndoCoalescing()
        require(bar.draft.isEmpty && board.tray.isEmpty, "deleting the token unstages its mention")
        require(undo.canUndo, "deleting the token is undoable")
        FileHandle.standardOutput.write(Data("CHECK undo deleted native token\n".utf8))
        undo.undo()
        require(bar.draft.prompt == "[1]" && board.tray.count == 1, "undo restores the token and its mention")
        require(bar.draft.tokens.map(\.id) == board.tray.map(\.id), "restored tokens identify the staged mentions")
        require(undo.canRedo, "undo preserves redo for the deleted token")
        undo.redo()
        require(bar.draft.isEmpty && board.tray.isEmpty, "redo removes the restored token and mention")
        undo.undo()
        require(bar.draft.prompt == "[1]" && board.tray.count == 1, "a second undo restores the mention again")
        require(bar.draft.tokens.map(\.id) == board.tray.map(\.id), "repeated undo keeps token identities synchronized")
        print("PASS native token delete, undo, redo, and repeated undo")
        bar.text.selectAll(nil)
        bar.text.deleteBackward(nil)
        require(bar.subviews.compactMap { $0 as? NSTextField }.contains { !$0.isHidden && !$0.stringValue.isEmpty },
                "an empty composer shows its placeholder")
        bar.text.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        require(bar.text.hasMarkedText(), "Japanese preedit remains marked until commit")
        let visibleLabels = bar.subviews.compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && !$0.stringValue.isEmpty }
        require(visibleLabels.isEmpty, "the placeholder must not overlap Japanese marked text")
        bar.text.insertText("日本", replacementRange: bar.text.markedRange())
        require(bar.draft.text == "日本", "committing Japanese composition keeps its text")
        print("PASS Japanese marked text hides the placeholder and commits without loss")
        bar.text.selectAll(nil)
        bar.text.deleteBackward(nil)
        try board.stage(.code(object: code.id, path: "sample.swift", lines: LineRange(start: 1, end: 1)))
        bar.text.selectAll(nil)
        bar.text.deleteBackward(nil)
        bar.text.breakUndoCoalescing()
        try board.delete(code.id)
        require(undo.canUndo, "deleting the referenced tile leaves the token deletion undoable")
        FileHandle.standardOutput.write(Data("CHECK undo token whose tile was deleted\n".utf8))
        undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        require(bar.draft.isEmpty && board.tray.isEmpty, "undo cannot restore a mention of a deleted tile")
        if undo.canRedo { undo.redo() }
        try await Task.sleep(for: .milliseconds(50))
        require(bar.draft.isEmpty && board.tray.isEmpty, "redo keeps the missing-tile mention absent")
        print("PASS undo and redo after the referenced tile is deleted")
    }
}
