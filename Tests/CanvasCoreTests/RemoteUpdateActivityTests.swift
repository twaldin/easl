import Foundation
import Testing
import CanvasCore

@MainActor
struct RemoteUpdateActivityTests {
    let release = LatestRelease(version: AppVersion("0.2.10")!, url: URL(string: "https://example.com/easl.zip")!,
                                sha256: String(repeating: "a", count: 64), size: 1,
                                notes: URL(string: "https://example.com/notes")!)

    func action(_ activity: RemoteUpdateActivity, now: TimeInterval, local: TimeInterval = 600,
                phase: UpdatePhase? = nil) -> AppUpdate.AutomaticAction {
        AppUpdate.automaticAction(phase: phase ?? .ready(release), running: AppVersion("0.2.9")!,
                                  enabled: true, idleSeconds: local, remoteIdleSeconds: activity.idleSeconds(now: now))
    }

    @Test func eachRemoteSignalDefersUntilExactlyTenMinutes() {
        for kind: RemoteUpdateActivity.Kind in [.browser, .board, .terminal] {
            let activity = RemoteUpdateActivity()
            activity.record(session: "viewer", kind: kind, board: "brd_test", tile: "obj_test", now: 100)
            #expect(action(activity, now: 100) == .none)
            #expect(action(activity, now: 699.999) == .none)
            #expect(action(activity, now: 700) == .install)
            #expect(action(activity, now: 701) == .install)
        }
    }

    @Test func activeViewersDoNotPreventStaging() {
        let activity = RemoteUpdateActivity()
        activity.record(session: "viewer", kind: .browser, board: "brd_test", now: 100)
        #expect(action(activity, now: 100, local: 0, phase: .available(release)) == .stage)
        #expect(action(activity, now: 100, phase: .ready(release)) == .none)
    }

    @Test func localInputStillDefersAfterRemoteActivityExpires() {
        let activity = RemoteUpdateActivity()
        activity.record(session: "viewer", kind: .terminal, board: "brd_test", now: 100)
        #expect(action(activity, now: 700, local: 599.999) == .none)
        #expect(action(activity, now: 700, local: 600) == .install)
        #expect(action(activity, now: 699.999, local: 600) == .none)
    }

    @Test func openingAndClosingWithoutActivityDoesNotInventInput() {
        let activity = RemoteUpdateActivity()
        activity.begin(session: "stream", kind: .browser, board: "brd_test", tile: "obj_test")
        #expect(activity.sessions == .array([.object([
            "session": .string("stream"), "kind": .string("browser"),
            "board": .string("brd_test"), "tile": .string("obj_test"),
        ])]))
        #expect(action(activity, now: 100) == .install)
        activity.end(session: "stream")
        #expect(activity.sessions == .array([]))
        #expect(action(activity, now: 100) == .install)
    }

    @Test func disconnectRetainsLatestActivityUntilExactExpiry() {
        let activity = RemoteUpdateActivity()
        activity.record(session: "older", kind: .board, board: "brd_test", now: 100)
        activity.record(session: "latest", kind: .terminal, board: "brd_test", now: 200)
        activity.end(session: "latest")
        activity.end(session: "older")
        #expect(activity.sessions == .array([]))
        #expect(activity.idleSeconds(now: 799) == 599)
        #expect(action(activity, now: 799.999) == .none)
        #expect(action(activity, now: 800) == .install)
    }

    @Test func lazyDisconnectCleanupRetainsActivityWithoutWarningAboutDeadSessions() {
        let activity = RemoteUpdateActivity()
        var connected = true
        activity.record(session: "viewer", kind: .board, board: "brd_test", now: 100, isLive: { connected })
        #expect(activity.sessions.array?.count == 1)
        connected = false
        #expect(action(activity, now: 699.999) == .none)
        #expect(activity.sessions == .array([]))
        #expect(action(activity, now: 700) == .install)
    }

    @Test func delayedEarlierFrameDoesNotMoveTheLatestActivityBackwards() {
        let activity = RemoteUpdateActivity()
        activity.record(session: "input", kind: .browser, board: "brd_test", now: 200)
        activity.record(session: "frame", kind: .browser, board: "brd_test", now: 100)
        #expect(action(activity, now: 799.999) == .none)
        #expect(action(activity, now: 800) == .install)
    }
}
