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
        let store = ChromeTextScale.Store(url: home.appendingPathComponent("ui-settings.json"))
        #expect(store.load() == ChromeTextScale.normal, "no file: 100%")
        try store.save(1.3)
        #expect(store.load() == 1.3)
        // A hand-edited value in between lands on the nearest level; a damaged file means 100%.
        try Data(#"{"scale":1.42}"#.utf8).write(to: store.url)
        #expect(store.load() == 1.5)
        try Data(#"{"scale":-9}"#.utf8).write(to: store.url)
        #expect(store.load() == 1)
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load() == ChromeTextScale.normal)
    }
}
