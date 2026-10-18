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

    @Test func abortedPreparationCannotReopenTabsOrDeleteEarlierRecovery() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let recoveryDirectory = home.appendingPathComponent("recovery")
        try store.save(.init(groups: [.init(tabs: [.local(root: "/tmp/earlier")], selected: 0, minimized: true)]))
        let earlier = try #require(try store.retainForRecovery(in: recoveryDirectory))
        try store.save(.init(groups: [.init(tabs: [.local(root: "/tmp/aborted")], selected: 0, minimized: false)]))
        try store.remove()
        try store.remove()
        #expect(try store.load() == nil)
        #expect(try store.retainForRecovery(in: recoveryDirectory)?.url == nil)
        #expect(try earlier.load()?.groups == [.init(tabs: [.local(root: "/tmp/earlier")], selected: 0, minimized: true)])
        #expect(try UpdateBoardSnapshot.Store.recoveries(in: recoveryDirectory).map { try $0.load()?.groups } == [
            [.init(tabs: [.local(root: "/tmp/earlier")], selected: 0, minimized: true)],
        ])
    }

    @Test func relaunchClaimsOnlyCurrentPreparationAndKeepsIndependentRecoveries() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let recoveryDirectory = home.appendingPathComponent("recovery")
        #expect(try UpdateBoardSnapshot.Store.recoveries(in: recoveryDirectory).isEmpty)
        try store.save(.init(groups: [.init(tabs: [.local(root: "/tmp/first")], selected: 0, minimized: false)]))
        let first = try #require(try store.retainForRecovery(in: recoveryDirectory))
        #expect(try store.load() == nil)
        try store.save(.init(groups: [.init(tabs: [.local(root: "/tmp/second")], selected: 0, minimized: true)]))
        let second = try #require(try store.retainForRecovery(in: recoveryDirectory))
        #expect(first.url != second.url)
        #expect(try second.load()?.groups == [.init(tabs: [.local(root: "/tmp/second")], selected: 0, minimized: true)])
        try second.remove()
        #expect(try first.load()?.groups == [.init(tabs: [.local(root: "/tmp/first")], selected: 0, minimized: false)])
        #expect(try UpdateBoardSnapshot.Store.recoveries(in: recoveryDirectory).map { try $0.load()?.groups } == [
            [.init(tabs: [.local(root: "/tmp/first")], selected: 0, minimized: false)],
        ])
    }

    @Test func partialRecoveryRetainsOnlyFailedTabsAndItsReason() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let recoveryDirectory = home.appendingPathComponent("recovery")
        let remote = RemoteReopen(host: "guest", sshTarget: "guest", home: "/tmp/server", board: "brd_remote")
        try store.save(.init(groups: [.init(tabs: [.local(root: "/tmp/restored"), .remote(remote)], selected: 1, minimized: false)]))
        let recovery = try #require(try store.retainForRecovery(in: recoveryDirectory))
        var failed = UpdateBoardSnapshot(groups: [.init(tabs: [.remote(remote)], selected: 0, minimized: false)])
        failed.recoveryReason = "guest is offline"
        try recovery.save(failed)
        #expect(try recovery.load()?.groups == [.init(tabs: [.remote(.init(host: "guest", sshTarget: "guest", home: "/tmp/server", board: "brd_remote"))], selected: 0, minimized: false)])
        #expect(try recovery.load()?.recoveryReason == "guest is offline")
        #expect(try store.load() == nil)
    }

    @Test func malformedRecoveryCanBeDiscardedWithoutBlockingNewPreparation() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let recoveryDirectory = home.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("damaged tabs".utf8).write(to: store.url)
        let damaged = try #require(try store.retainForRecovery(in: recoveryDirectory))
        #expect(throws: (any Error).self) { try damaged.load() }
        #expect(try Data(contentsOf: damaged.url) == Data("damaged tabs".utf8))
        try store.save(.init(groups: [.init(tabs: [.local(root: "/tmp/current")], selected: 0, minimized: false)]))
        try damaged.remove()
        #expect(try UpdateBoardSnapshot.Store.recoveries(in: recoveryDirectory).isEmpty)
        #expect(try store.load()?.groups == [.init(tabs: [.local(root: "/tmp/current")], selected: 0, minimized: false)])
    }
}
