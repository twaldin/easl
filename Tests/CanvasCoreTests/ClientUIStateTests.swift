import Foundation
import Testing
@testable import CanvasCore

/// What a client remembers about boards and about itself, in its own home and never in a board.
struct ClientUIStateTests {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("client-ui-\(UUID().uuidString)", isDirectory: true)

    private func viewport(of board: String) -> SavedViewport.Store {
        .init(url: home.appendingPathComponent("viewport/\(board).json"))
    }

    @Test func eachBoardKeepsItsOwnViewport() throws {
        let first = SavedViewport(zoom: 0.35, x: -1200.5, y: 840)
        #expect(viewport(of: "brd_a").load() == nil, "a board never opened is a first open")
        try viewport(of: "brd_a").save(first)
        try viewport(of: "brd_b").save(SavedViewport(zoom: 1, x: 10, y: 20))
        #expect(viewport(of: "brd_a").load() == first)
        // A later pan replaces the earlier one; the other board is untouched.
        try viewport(of: "brd_b").save(SavedViewport(zoom: 0.5, x: 30, y: 40))
        #expect(viewport(of: "brd_a").load() == first)
        #expect(viewport(of: "brd_b").load() == SavedViewport(zoom: 0.5, x: 30, y: 40))
    }

    @Test func aDamagedViewportFileOpensAsAFirstOpen() throws {
        let store = viewport(of: "brd_a")
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["", "not json", "{}", #"{"zoom":0,"x":1,"y":2}"#, #"{"zoom":-1,"x":1,"y":2}"#, #"{"zoom":1e999,"x":1,"y":2}"#] {
            try Data(text.utf8).write(to: store.url)
            #expect(store.load() == nil, "\(text)")
        }
    }

    @Test func aBoardThatNeverMovedStillGetsItsRecordAtTheFirstClose() {
        let placed = SavedViewport(zoom: 1, x: 400, y: -90)
        var open = SavedViewport.Recorder(store: viewport(of: "brd_a"))
        #expect(open.opened == nil, "a first open")
        // Closing, or quitting, with the view where the board put it: nothing moved, nothing was written before.
        let wrote = open.record(placed)
        #expect(wrote)
        // The next open restores it, whatever the board's content became meanwhile.
        let reopened = SavedViewport.Recorder(store: viewport(of: "brd_a"))
        #expect(reopened.opened == placed)
    }

    @Test func aFailedWriteIsTriedAgainAtTheNextCloseOrQuit() throws {
        let first = SavedViewport(zoom: 0.5, x: 1, y: 2)
        var open = SavedViewport.Recorder(store: viewport(of: "brd_a"))
        // A file where the directory should be: the write can't succeed (a full disk, a read-only home).
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent("viewport"))
        let failed = open.record(first)
        #expect(!failed)
        #expect(open.written == nil, "a failed write isn't remembered as written")
        #expect(viewport(of: "brd_a").load() == nil)
        try FileManager.default.removeItem(at: home.appendingPathComponent("viewport"))
        let retried = open.record(first)
        #expect(retried, "the next close or quit writes it")
        #expect(viewport(of: "brd_a").load() == first)
        let unchanged = open.record(first)
        #expect(unchanged, "unchanged: nothing more to write")
    }

    @Test func chromeTextScaleStepsThroughItsLevelsAndStops() {
        var scale = ChromeTextScale.normal
        var seen = [scale]
        while let next = ChromeTextScale.step(from: scale, bigger: true) {
            scale = next
            seen.append(scale)
        }
        #expect(seen == ChromeTextScale.levels)
        #expect(ChromeTextScale.step(from: ChromeTextScale.normal, bigger: false) == nil)
        #expect(ChromeTextScale.step(from: scale, bigger: false) == ChromeTextScale.levels[ChromeTextScale.levels.count - 2])
    }

    @Test func chromeTextScalePersistsAndSnapsToALevel() throws {
        let store = UISettings.Store(url: home.appendingPathComponent("ui-settings.json"))
        #expect(store.load().chromeTextScale == ChromeTextScale.normal, "no file: 100%")
        try store.update { $0.chromeTextScale = 1.3 }
        #expect(store.load().chromeTextScale == 1.3)
        // A hand-edited value in between lands on the nearest level; a damaged file means 100%.
        try Data(#"{"scale":1.42}"#.utf8).write(to: store.url)
        #expect(store.load().chromeTextScale == 1.5)
        try Data(#"{"scale":-9}"#.utf8).write(to: store.url)
        #expect(store.load().chromeTextScale == 1)
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load().chromeTextScale == ChromeTextScale.normal)
    }

    @Test func eachSettingsWriteKeepsTheOtherSetting() throws {
        let url = home.appendingPathComponent("ui-settings.json")
        #expect(UISettings.Store(url: url).load() == UISettings(chromeTextScale: 1, backgroundAttach: true), "no file: 100%, background attach on")
        // A file from before background attach holds only the scale.
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"scale":1.3}"#.utf8).write(to: url)
        #expect(UISettings.Store(url: url).load() == UISettings(chromeTextScale: 1.3, backgroundAttach: true))
        // The menu's background attach and View's chrome text size each write the one file.
        try UISettings.Store(url: url).update { $0.backgroundAttach = false }
        try UISettings.Store(url: url).update { $0.chromeTextScale = 1.5 }
        #expect(UISettings.Store(url: url).load() == UISettings(chromeTextScale: 1.5, backgroundAttach: false))
        try UISettings.Store(url: url).update { $0.backgroundAttach = true }
        #expect(UISettings.Store(url: url).load() == UISettings(chromeTextScale: 1.5, backgroundAttach: true))
        // A damaged field is that setting's default; the other one stands.
        try Data(#"{"scale":1.15,"backgroundAttach":"no"}"#.utf8).write(to: url)
        #expect(UISettings.Store(url: url).load() == UISettings(chromeTextScale: 1.15, backgroundAttach: true))
    }

    @Test func theReopenListKeepsOnlyHowToReachEachBoard() throws {
        let store = RemoteReopen.Store(url: home.appendingPathComponent("remote-boards.json"))
        #expect(store.load().isEmpty, "no file: nothing to attach")
        let first = RemoteReopen(host: "deckbox", sshTarget: "deckbox", board: "brd_a")
        let second = RemoteReopen(host: "deckbox", sshTarget: "deckbox", board: "brd_b")
        try store.remember(first)
        try store.remember(second)
        try store.remember(first)
        #expect(store.load() == [first, second], "in the order opened, once each")
        let renamed = RemoteReopen(host: "deckbox-2", sshTarget: "deckbox", board: "brd_a")
        try store.remember(renamed)
        #expect(store.load() == [renamed, second], "a host renamed keeps its board's place")
        // Another host's board with the same id is its own entry (two checkouts of one repository).
        let other = RemoteReopen(host: "work", sshTarget: "tim@work", board: "brd_a")
        try store.remember(other)
        try store.forget(sshTarget: "deckbox", board: "brd_a")
        #expect(store.load() == [second, other])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url))
        let disk = try #require(json as? [[String: Any]])
        let fields: [Set<String>] = [["host", "sshTarget", "board"], ["host", "sshTarget", "board"]]
        #expect(disk.map { Set($0.keys) } == fields, "nothing the board holds is on this Mac's disk")
    }

    @Test func aDamagedOrHandEditedReopenListAttachesNothingUnsafe() throws {
        let store = RemoteReopen.Store(url: home.appendingPathComponent("remote-boards.json"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load().isEmpty)
        let edited = #"[{"host":"x","sshTarget":"-oProxyCommand=sh","board":"brd_a"},{"host":"d","sshTarget":"deckbox","board":"../etc"},{"host":"d","sshTarget":"deckbox","board":"brd_ok"}]"#
        try Data(edited.utf8).write(to: store.url)
        #expect(store.load() == [RemoteReopen(host: "d", sshTarget: "deckbox", board: "brd_ok")], "neither an ssh option nor a non-board id is attached")
    }

    @Test func closingARemoteBoardsWindowKeepsWhatTheUserLeftOpen() {
        #expect(RemoteClose.tab.outcome(backgroundAttach: true, server: .easld) == .forget, "a tab closed beside others is done with")
        #expect(RemoteClose.tab.outcome(backgroundAttach: false, server: .easld) == .forget)
        #expect(RemoteClose.window.outcome(backgroundAttach: true, server: .easld) == .retain, "the window's only tab stays attached")
        #expect(RemoteClose.window.outcome(backgroundAttach: false, server: .easld) == .detach, "setting off: detached, still in the reopen list")
        #expect(RemoteClose.window.outcome(backgroundAttach: true, server: .app) == .detach, "a Mac host takes no client")
        #expect(RemoteClose.window.outcome(backgroundAttach: true, server: nil) == .detach)
    }

    @Test func changingSettingsDoesNotOverwriteAnUnreadableFile() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = UISettings.Store(url: home.appendingPathComponent("ui-settings.json"))
        let damaged = Data(#"{"scale":1.3,"backgroundAttach":false"#.utf8)
        try damaged.write(to: store.url)
        #expect(throws: (any Error).self) {
            try store.update { $0.chromeTextScale = 1.5 }
        }
        #expect(try Data(contentsOf: store.url) == damaged)
    }

    @Test func changingTheReopenListCannotSucceedWithoutReadingIt() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = RemoteReopen.Store(url: home.appendingPathComponent("remote-boards.json"))
        let first = RemoteReopen(host: "deckbox", sshTarget: "deckbox", board: "brd_a")
        let second = RemoteReopen(host: "home", sshTarget: "home", board: "brd_b")
        let saved = try JSONEncoder().encode([first])
        var damaged = saved
        damaged.append(contentsOf: "[".utf8)
        try damaged.write(to: store.url)
        #expect(throws: (any Error).self) {
            try store.forget(sshTarget: first.sshTarget, board: first.board)
        }
        #expect(try Data(contentsOf: store.url) == damaged)
        #expect(throws: (any Error).self) { try store.remember(second) }
        #expect(try Data(contentsOf: store.url) == damaged)
        try saved.write(to: store.url)
        #expect(store.load() == [first])
        try store.forget(sshTarget: first.sshTarget, board: first.board)
        #expect(store.load() == [])
    }
}
