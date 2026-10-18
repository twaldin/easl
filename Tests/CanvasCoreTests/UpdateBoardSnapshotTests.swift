import Foundation
import Testing
@testable import CanvasCore

struct UpdateBoardSnapshotTests {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("update-tabs-\(UUID().uuidString)", isDirectory: true)
    private var store: UpdateBoardSnapshot.Store { .init(url: home.appendingPathComponent("update-boards.json")) }

    @Test func mixedOpenTabsKeepTheirOrderSelectionGroupsAndMinimizedState() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try store.load() == nil)
        let remote = RemoteReopen(host: "guest", sshTarget: "tim@guest", home: "/tmp/scratch-easld", board: "brd_remote")
        let background = RemoteReopen.Store(url: home.appendingPathComponent("remote-boards.json"))
        try background.remember(RemoteReopen(host: "closed", sshTarget: "closed", home: "/tmp/server", board: "brd_closed"))
        try store.save(.init(groups: [
            .init(tabs: [.local(root: "/tmp/first"), .remote(remote), .local(root: "/tmp/last")], selected: 1, minimized: false),
            .init(tabs: [.local(root: "/tmp/minimized")], selected: 0, minimized: true),
        ]))
        let restored = try #require(try store.load())
        #expect(restored.groups == [
            .init(tabs: [.local(root: "/tmp/first"), .remote(.init(host: "guest", sshTarget: "tim@guest", home: "/tmp/scratch-easld", board: "brd_remote")), .local(root: "/tmp/last")], selected: 1, minimized: false),
            .init(tabs: [.local(root: "/tmp/minimized")], selected: 0, minimized: true),
        ])
        #expect(background.load() == [.init(host: "closed", sshTarget: "closed", home: "/tmp/server", board: "brd_closed")])
        #expect(try store.load()?.groups == restored.groups, "reading does not consume a snapshot before reconnects finish")
        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test func noOpenTabsIsDifferentFromNoUpdateSnapshot() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try store.save(.init(groups: []))
        #expect(try store.load() == UpdateBoardSnapshot(groups: []))
        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test func damagedSnapshotIsReportedAndPreservedForRetry() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let invalid = [
            "not json",
            #"{"version":2,"groups":[]}"#,
            #"{"version":1,"groups":[{"tabs":[],"selected":0,"minimized":false}]}"#,
            #"{"version":1,"groups":[{"tabs":[{"local":{"root":"relative"}}],"selected":0,"minimized":false}]}"#,
            #"{"version":1,"groups":[{"tabs":[{"local":{"root":"/tmp/board"}}],"selected":1,"minimized":false}]}"#,
            #"{"version":1,"groups":[{"tabs":[{"local":{"root":"/tmp/board"}},{"local":{"root":"/tmp/board"}}],"selected":0,"minimized":false}]}"#,
            #"{"version":1,"groups":[{"tabs":[{"remote":{"_0":{"host":"guest","sshTarget":"-oProxyCommand=sh","home":"/tmp/server","board":"brd_remote"}}}],"selected":0,"minimized":false}]}"#,
            #"{"version":1,"groups":[{"tabs":[{"remote":{"_0":{"host":"guest","sshTarget":"guest","home":"relative","board":"brd_remote"}}}],"selected":0,"minimized":false}]}"#,
            #"{"version":1,"groups":[{"tabs":[{"remote":{"_0":{"host":"guest","sshTarget":"guest","home":"/tmp/server","board":"../bad"}}}],"selected":0,"minimized":false}]}"#,
        ]
        for text in invalid {
            let data = Data(text.utf8)
            try data.write(to: store.url)
            #expect(throws: (any Error).self) { try store.load() }
            #expect(try Data(contentsOf: store.url) == data)
        }
        try Data(#"{"version":1,"groups":[{"tabs":[{"local":{"root":"/tmp/board"}}],"selected":0,"minimized":true}]}"#.utf8).write(to: store.url)
        #expect(try store.load()?.groups == [.init(tabs: [.local(root: "/tmp/board")], selected: 0, minimized: true)])
    }

    @Test func snapshotSaveFailureThrowsInsteadOfLosingOpenTabs() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let blocked = home.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        let blockedStore = UpdateBoardSnapshot.Store(url: blocked.appendingPathComponent("update-boards.json"))
        #expect(throws: (any Error).self) {
            try blockedStore.save(.init(groups: [.init(tabs: [.local(root: "/tmp/board")], selected: 0, minimized: false)]))
        }
        #expect(try Data(contentsOf: blocked) == Data("keep".utf8))
        try store.save(.init(groups: [.init(tabs: [.local(root: "/tmp/board")], selected: 0, minimized: false)]))
        #expect(try store.load()?.groups == [.init(tabs: [.local(root: "/tmp/board")], selected: 0, minimized: false)])
    }
}
