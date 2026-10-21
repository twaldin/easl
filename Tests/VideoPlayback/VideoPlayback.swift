import AppKit
@preconcurrency import AVFoundation
import AVKit
import CanvasCore
import Darwin

@testable import CanvasApp

@main
@MainActor
private enum VideoPlaybackRegression {
    private struct Failure: Error {
        let message: String
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            throw Failure(message: message)
        }
    }

    private static func marker(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static func wait(_ message: String, until condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            try require(ContinuousClock.now < deadline, "timed out: \(message)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            throw Failure(message: "run.py must provide the fixture and a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: home).appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("h264-aac.mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: path)
        let original = AVURLAsset(url: path)
        let originalAudio = try await original.loadTracks(withMediaType: .audio)
        try require(!originalAudio.isEmpty, "fixture must contain an AAC audio track")
        let board = Board(id: "video-regression", root: root)
        let props: JSONValue = .object([
            "path": .string("h264-aac.mp4"), "poster": .string(""), "loop": .bool(true), "muted": .bool(true),
            "autoplay": .bool(false), "startTime": .number(0.125), "title": .string("Muted fixture"), "key": .string("muted-fixture"),
        ])
        let object = board.create(type: .video, props: props, frame: Frame(x: 0, y: 0, w: 320, h: 210))
        marker("VIDEO_CREATE_MUTED")
        let tile = VideoTile(object: object, board: board)
        defer { tile.setLive(false) }
        guard let view = tile.subviews.compactMap({ $0 as? AVPlayerView }).first else {
            throw Failure(message: "video tile has no playback view")
        }
        try await wait("muted video attachment") { view.player?.currentItem != nil }
        guard let player = view.player, let item = player.currentItem else {
            throw Failure(message: "muted video did not attach a player item")
        }
        let audio = try await item.asset.loadTracks(withMediaType: .audio)
        try require(audio.isEmpty, "muted video must remove audio tracks before exposing the item to AVKit")
        let video = try await item.asset.loadTracks(withMediaType: .video)
        try require(!video.isEmpty, "muted preparation must preserve video")
        marker("VIDEO_MUTED_NO_AUDIO_TRACKS")
        try await wait("muted video ready") { item.status == .readyToPlay }
        try await wait("persisted start time seek") { abs(player.currentTime().seconds - 0.125) < 0.03 }
        let playing = try board.update(object.id, props: .object(["autoplay": .bool(true)]))
        tile.update(playing)
        try await wait("muted video playback") { player.rate > 0 && player.currentTime().seconds > 0.25 }
        let paused = try board.update(object.id, props: .object(["autoplay": .bool(false), "startTime": .number(1.25)]))
        tile.update(paused)
        try await wait("muted video pause and exact seek") {
            player.rate == 0 && abs(player.currentTime().seconds - 1.25) < 0.03
        }
        tile.setLive(false)
        try require(player.currentItem == nil, "parking must detach the video item")
        tile.setLive(true)
        try await wait("muted video reattachment after parking") { view.player?.currentItem != nil }
        guard let resumed = view.player, let resumedItem = resumed.currentItem else {
            throw Failure(message: "parked video did not resume")
        }
        try await wait("parked video position") {
            resumedItem.status == .readyToPlay && resumed.rate == 0 && abs(resumed.currentTime().seconds - 1.25) < 0.03
        }
        let resumedAudio = try await resumedItem.asset.loadTracks(withMediaType: .audio)
        try require(resumedAudio.isEmpty, "parking must not restore the original audio tracks")
        try require(try board.object(object.id).props == paused.props, "playback must preserve all persisted video properties")
        marker("VIDEO_MUTED_PLAY_SEEK_PARK_COMPLETE")
        marker("VIDEO_PLAYBACK_COMPLETE")
    }
}
