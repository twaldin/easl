import AppKit

@testable import CanvasApp
@testable import CanvasCore

@main
@MainActor
private enum TerminalRekey {
    private struct Failure: Error { let message: String }
    private enum Owner: String, CaseIterable {
        case terminal, composer, otherTile, otherWindow, movedBeforeInitialFocus
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            throw Failure(message: message)
        }
    }

    private static func turn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func terminal(_ canvas: CanvasView, _ id: ObjectID) throws -> TerminalTile {
        guard let terminal = canvas.tiles[id]?.content as? TerminalTile else {
            throw Failure(message: "missing terminal \(id)")
        }
        return terminal
    }

    static func main() {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        Task { @MainActor in
            do {
                for owner in Owner.allCases {
                    try await exercise(owner, root: URL(fileURLWithPath: home).appendingPathComponent(owner.rawValue))
                }
                print("PASS terminal rekey: synchronous keyboard ownership, selection, and no focus theft")
                try "PASS".write(toFile: home + "/result", atomically: true, encoding: .utf8)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
                try? "FAIL \(error)".write(toFile: home + "/result", atomically: true, encoding: .utf8)
                exit(1)
            }
        }
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    private static func exercise(_ owner: Owner, root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = RemoteHost(name: "terminal-rekey", sshTarget: "terminal-rekey.invalid",
                              socketPath: root.appendingPathComponent("absent.sock").path,
                              tmpdir: root.path, easlBin: "easl")
        let mirror = BoardMirror(hostName: host.name, board: "terminal-rekey-\(owner.rawValue)",
                                 connection: EaslConnection(.unixSocket(host.socketPath)),
                                 diagrams: EaslConnection(.unixSocket(host.socketPath)))
        let remote = RemoteSource(host: host, mirror: mirror)
        let board = Board(remote: "terminal-rekey-\(owner.rawValue)", root: root, host: mirror)
        let canvas = CanvasView(board: board, viewport: nil, remote: remote)
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        window.contentView!.addSubview(composer)
        let otherWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let otherEditor = NSTextView(frame: otherWindow.contentView!.bounds)
        otherWindow.contentView!.addSubview(otherEditor)
        defer {
            board.onEvent = nil
            mirror.close()
            canvas.discard()
            otherWindow.close()
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(NSApp.isActive && window.isKeyWindow,
                    "fixture must be active and key: active=\(NSApp.isActive) key=\(window.isKeyWindow)")
        let frame = Frame(x: -350, y: -200, w: 700, h: 400)
        canvas.show(Viewport(rect: Frame(x: -450, y: -300, w: 900, h: 600), zoom: 1))
        let provisional = board.create(type: .terminal, props: .object([:]), frame: frame)
        let first = try terminal(canvas, provisional.id)
        try require(window.makeFirstResponder(canvas.document), "canvas must initially own keyboard")
        canvas.showNew(provisional)
        if owner != .movedBeforeInitialFocus {
            await turn()
            try require(window.firstResponder === first.terminal, "user flow must focus provisional terminal")
            try require(canvas.tiles[provisional.id]?.isLive == true, "fixture terminal must remain live in the viewport")
        }

        let expected: NSResponder
        switch owner {
        case .terminal:
            expected = first.terminal
        case .composer, .movedBeforeInitialFocus:
            try require(window.makeFirstResponder(composer), "composer must take keyboard")
            expected = composer
        case .otherTile:
            let other = board.create(type: .terminal, props: .object([:]), frame: frame)
            let tile = try terminal(canvas, other.id)
            tile.focus()
            expected = tile.terminal
        case .otherWindow:
            otherWindow.makeKeyAndOrderFront(nil)
            try require(otherWindow.makeFirstResponder(otherEditor), "other window editor must take keyboard")
            try require(otherWindow.isKeyWindow && !window.isKeyWindow, "other window must be key")
            expected = first.terminal
        }
        try require(canvas.selection == [provisional.id], "selection must remain provisional before rekey")
        if owner == .movedBeforeInitialFocus {
            await turn()
            try require(window.firstResponder === composer,
                        "deferred initial takeKeyboard must respect focus moved to composer before rekey")
        }
        var canonical = provisional
        canonical.id = "canonical-\(owner.rawValue)"
        canonical.rev += 1
        board.rekeyHost(provisional.id, as: canonical)
        let replacement = try terminal(canvas, canonical.id)
        try require(canvas.selection == [canonical.id], "\(owner.rawValue): selection must follow canonical id")
        try require(canvas.tiles[provisional.id] == nil, "provisional tile must be removed")
        if owner == .terminal {
            try require(window.firstResponder === replacement.terminal,
                        "canonical terminal must own keyboard synchronously when rekey returns")
        } else if owner == .otherWindow {
            try require(otherWindow.isKeyWindow && otherWindow.firstResponder === otherEditor,
                        "rekey must not take keyboard from another key window")
            try require(window.firstResponder !== replacement.terminal,
                        "inactive terminal window must not acquire canonical focus")
        } else {
            try require(window.firstResponder === expected, "\(owner.rawValue): rekey must preserve keyboard owner")
        }
        await turn()
        await turn()
        if owner == .terminal {
            try require(window.firstResponder === replacement.terminal, "canonical focus must survive queued work")
        } else if owner == .otherWindow {
            try require(otherWindow.isKeyWindow && otherWindow.firstResponder === otherEditor,
                        "queued work must not steal another window's focus")
        } else {
            try require(window.firstResponder === expected, "\(owner.rawValue): deferred initial focus must not steal keyboard")
        }
        if owner == .composer || owner == .movedBeforeInitialFocus || owner == .otherWindow {
            let targetWindow = owner == .otherWindow ? otherWindow : window
            let editor = owner == .otherWindow ? otherEditor : composer
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: targetWindow.windowNumber, context: nil,
                                         characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
            NSApp.sendEvent(event)
            try require(editor.string == "x", "\(owner.rawValue): key must route to the existing editor")
        }
        print("CHECK \(owner.rawValue)")
    }
}
