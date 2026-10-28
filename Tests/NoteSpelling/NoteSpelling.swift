import AppKit
import Darwin

@testable import CanvasApp
@testable import CanvasCore

@_silgen_name("easl_spell_start")
private func spellStart(_ stacks: Bool)
@_silgen_name("easl_spell_phase")
private func spellPhase(_ phase: Int32)
@_silgen_name("easl_spell_calls")
private func spellCalls() -> UInt64
@_silgen_name("easl_spell_stop")
private func spellStop()

@MainActor
private enum NoteSpelling {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    private enum Phase: Int32 {
        case viewing = 1, otherNoteUpdates, hostClosed, hostClosedFocus, hostReopened, editing, returnToView
    }

    private static var diagnostic = false
    private static var stageSeconds = 0.0
    private static var violations: [String] = []

    private static func emit(_ record: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if condition { return }
        violations.append(message)
        emit(["event": "violation", "error": message])
        if !diagnostic { throw Failure(description: message) }
    }

    private static func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    private static func displayed(_ tile: NoteTile) throws -> NSTextView {
        guard let text = textViews(tile).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else {
            throw Failure(description: "note has no visible text view")
        }
        return text
    }

    private static func begin(_ phase: Phase) -> UInt64 {
        spellPhase(phase.rawValue)
        let count = spellCalls()
        emit(["event": "phase-begin", "phase": String(describing: phase), "phaseID": phase.rawValue,
              "singletonRequests": count])
        return count
    }

    private static func finish(_ phase: Phase, since count: UInt64, expectZero: Bool = true) async throws {
        try await Task.sleep(for: .seconds(3))
        let total = spellCalls()
        emit(["event": "phase-end", "phase": String(describing: phase), "phaseID": phase.rawValue,
              "newSingletonRequests": total - count, "singletonRequests": total])
        if expectZero {
            try check(total == count, "\(phase): viewing requested NSSpellChecker.sharedSpellChecker \(total - count) times")
        } else {
            try check(total > count, "enterKeyboard and real typing did not request spell checking")
        }
    }

    private static func stage(_ phase: Phase, window: NSWindow, directory: URL) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let record: [String: Any] = ["event": "stage", "name": String(describing: phase), "phaseID": phase.rawValue,
                                     "pid": getpid(), "windowNumber": window.windowNumber,
                                     "windowFrame": NSStringFromRect(window.frame),
                                     "backingScale": window.backingScaleFactor, "pauseSeconds": stageSeconds]
        emit(record)
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("stage.json"))
        if stageSeconds > 0 { try await Task.sleep(for: .seconds(stageSeconds)) }
    }

    private static func spellingRanges(_ text: NSTextView) throws -> [NSRange] {
        guard let layout = text.textLayoutManager, let content = layout.textContentManager else {
            throw Failure(description: "real editor lost TextKit 2")
        }
        layout.ensureLayout(for: layout.documentRange)
        var ranges: [NSRange] = []
        layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
            if let state = attributes[.spellingState] as? NSNumber, state.intValue & 1 != 0 {
                let start = content.offset(from: content.documentRange.location, to: range.location)
                let length = content.offset(from: range.location, to: range.endLocation)
                ranges.append(NSRange(location: start, length: length))
            }
            return true
        }
        return ranges
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        try require(arguments.count >= 2, "missing artifacts directory")
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        diagnostic = arguments.contains("--diagnostic")
        if let index = arguments.firstIndex(of: "--stage-seconds") {
            guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]), seconds.isFinite,
                  (0...60).contains(seconds) else { throw Failure(description: "invalid stage duration") }
            stageSeconds = seconds
        }
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            throw Failure(description: "isolated EASL_HOME is required")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        emit(["event": "identity", "pid": getpid(), "system": ProcessInfo.processInfo.operatingSystemVersionString,
              "mode": diagnostic ? "diagnostic" : "regression",
              "defaults": UserDefaults.standard.dictionaryRepresentation().filter {
                  $0.key.hasPrefix("NS") && ($0.key.contains("Checking") || $0.key.contains("Automatic"))
              }])
        spellStart(arguments.contains("--stacks"))
        defer { spellStop() }
        var before = begin(.viewing)
        let root = URL(fileURLWithPath: home).appendingPathComponent("spelling-board", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "note-spelling", root: root)
        let objects = (0..<2).map { index in
            board.create(type: .note, props: .object(["markdown": .string("Displayed note \(index). A mispelled word.")]),
                         frame: Frame(x: 0, y: 0, w: 480, h: 320))
        }
        let tiles = objects.map { NoteTile(object: $0, board: board) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        for (index, tile) in tiles.enumerated() {
            tile.setFrameOrigin(NSPoint(x: index * 490, y: 0))
            window.contentView!.addSubview(tile)
        }
        window.orderFrontRegardless()
        defer {
            for tile in tiles { tile.setLive(false); tile.removeFromSuperview() }
            window.close()
            emit(["event": "native-cleanup", "pid": getpid(),
                  "visibleWindowsRemaining": NSApp.windows.filter { $0.isVisible }.count])
        }
        try require(tiles.allSatisfy { !$0.isEditing }, "viewing unexpectedly has an active editor")
        try await stage(.viewing, window: window, directory: directory)
        try await finish(.viewing, since: before)

        before = begin(.otherNoteUpdates)
        for edit in 0..<10 {
            for tile in tiles {
                try require(!tile.isEditing, "prose update ran with an actual editor active")
                let prose = "Updated displayed prose \(edit). A mispelled word."
                tile.update(try board.update(tile.object.id, props: .object(["markdown": .string(prose)])))
                try require(try displayed(tile).string.contains("Updated displayed prose \(edit)"), "displayed prose is stale")
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await stage(.otherNoteUpdates, window: window, directory: directory)
        try await finish(.otherNoteUpdates, since: before)

        before = begin(.hostClosed)
        for tile in tiles { tile.setHostBoardClosed(true) }
        let display = try displayed(tiles[0])
        try require(display.isSelectable && !display.isEditable && !tiles[0].isEditing,
                    "host-closed note is not a selectable read-only display")
        try await stage(.hostClosed, window: window, directory: directory)
        try await finish(.hostClosed, since: before)

        before = begin(.hostClosedFocus)
        try require(tiles[0].enterKeyboard() && window.firstResponder === display,
                    "host-closed enterKeyboard did not focus selectable display")
        display.setSelectedRange(NSRange(location: 0, length: min(12, (display.string as NSString).length)))
        try require(!tiles[0].isEditing && display.selectedRange().length > 0, "host-closed selection entered editing")
        try await stage(.hostClosedFocus, window: window, directory: directory)
        try await finish(.hostClosedFocus, since: before)

        before = begin(.hostReopened)
        window.makeFirstResponder(nil)
        for tile in tiles { tile.setHostBoardClosed(false) }
        try await finish(.hostReopened, since: before)

        before = begin(.editing)
        try require(tiles[0].enterKeyboard() && tiles[0].isEditing, "real note could not enter editing")
        guard let editor = window.firstResponder as? NSTextView, editor.isEditable else {
            throw Failure(description: "enterKeyboard did not focus the real note editor")
        }
        editor.selectAll(nil)
        editor.insertText("This sentnce has a mispelled word. ", replacementRange: editor.selectedRange())
        let misspelling = (editor.string as NSString).range(of: "mispelled")
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var marked: [NSRange] = []
        repeat {
            marked = try spellingRanges(editor)
            if marked.contains(where: { NSIntersectionRange($0, misspelling).length > 0 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        emit(["event": "spelling-marks", "text": editor.string,
              "ranges": marked.map { ["location": $0.location, "length": $0.length] },
              "misspelling": ["location": misspelling.location, "length": misspelling.length]])
        try check(marked.contains { NSIntersectionRange($0, misspelling).length > 0 },
                  "real typing did not give mispelled an actual TextKit spelling-marked range")
        try await stage(.editing, window: window, directory: directory)
        try await finish(.editing, since: before, expectZero: false)

        before = begin(.returnToView)
        editor.cancelOperation(nil)
        try require(!tiles[0].isEditing && !(try displayed(tiles[0])).isEditable, "Escape did not return to viewing")
        try await stage(.returnToView, window: window, directory: directory)
        try await finish(.returnToView, since: before)
        emit(["event": "result", "status": diagnostic ? "diagnostic-only" : "passed", "violations": violations,
              "singletonRequests": spellCalls()])
    }
}

@MainActor
@_cdecl("NoteSpellingMain")
func noteSpellingMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await NoteSpelling.main()
            app.terminate(nil)
        } catch {
            let record: [String: Any] = ["event": "failure", "pid": getpid(), "error": String(describing: error)]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data("\n".utf8))
            }
            Darwin.exit(1)
        }
    }
    app.run()
    return 0
}
