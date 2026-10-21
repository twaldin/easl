@preconcurrency import AVFoundation
import Foundation

public struct PreparedVideoPlayback: @unchecked Sendable {
    public let item: AVPlayerItem
    public let transform: CGAffineTransform
    public let duration: Double
}

public enum NativeVideoPlayback {
    public static func prepare(_ source: AVAsset) async throws -> PreparedVideoPlayback {
        guard let composition = try await composition(source, mediaType: .video) else {
            throw HostFileError.unavailable("video has no playable video track")
        }
        let duration = try await composition.load(.duration).seconds
        let track = try await composition.loadTracks(withMediaType: .video).first
        let transform = try await track?.load(.preferredTransform) ?? .identity
        _ = try await composition.load(.isPlayable, .availableMediaCharacteristicsWithMediaSelectionOptions)
        try Task.checkCancellation()
        let composition = UncheckedBox(composition)
        return await offPool {
            let item = AVPlayerItem(asset: composition.value, automaticallyLoadedAssetKeys: [String]())
            // AVKit reads this synchronously when a player is attached. Never give it an audio track.
            _ = item.currentMediaSelection
            return PreparedVideoPlayback(item: item, transform: transform, duration: duration)
        }
    }

    static func composition(_ source: AVAsset, mediaType: AVMediaType) async throws -> AVComposition? {
        guard let track = try await source.loadTracks(withMediaType: mediaType).first else { return nil }
        let range = try await track.load(.timeRange)
        let transform = mediaType == .video ? try await track.load(.preferredTransform) : .identity
        try Task.checkCancellation()
        let track = UncheckedBox(track)
        return try await offPool {
            Result<UncheckedBox<AVComposition>, Error> {
                let composition = AVMutableComposition()
                guard let target = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw HostFileError.unavailable("video track could not be prepared")
                }
                try target.insertTimeRange(range, of: track.value, at: range.start)
                target.preferredTransform = transform
                return UncheckedBox(composition)
            }
        }.get().value
    }
}

public final class IsolatedVideoAudio: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case preparing
        case ready
        case silent
        case failed(String)
    }

    private struct Position: Sendable {
        var seconds: Double = 0
        var rate: Float = 0
        var hostTime = ProcessInfo.processInfo.systemUptime
    }

    private struct Control {
        var cancelled = false
        var started = false
        var composition: AVComposition?
        var prerollResult: Bool?
        var reported: State?
        var position = Position()
    }

    private static let work = VideoAudioWorkQueue()
    private let id = UUID()
    private let control = Locked(Control())
    private let changed: @MainActor @Sendable (State) -> Void
    private var preparation: Task<Void, Never>?
    private var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var prerolling = false
    private var ready = false

    public init(source: AVAsset, changed: @escaping @MainActor @Sendable (State) -> Void) {
        self.changed = changed
        preparation = Task.detached { [weak self] in
            do {
                let composition = try await NativeVideoPlayback.composition(source, mediaType: .audio)
                try Task.checkCancellation()
                guard let self, !self.cancelled else { return }
                guard let composition else { self.notify(.silent); return }
                self.control.withLock { $0.composition = composition }
                self.schedule()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.notify(.failed(error.localizedDescription))
            }
        }
    }

    deinit { preparation?.cancel() }

    private var cancelled: Bool { control.withLock { $0.cancelled } }

    public func synchronize(seconds: Double, rate: Float) {
        let active = control.withLock { control in
            guard !control.cancelled else { return false }
            control.position = Position(seconds: seconds, rate: rate, hostTime: ProcessInfo.processInfo.systemUptime)
            return true
        }
        if active { schedule() }
    }

    public func cancel() {
        let started = control.withLock { control in
            control.cancelled = true
            control.composition = nil
            return control.started
        }
        preparation?.cancel()
        if started { schedule() }
        else { Self.work.cancel(id) }
    }

    private func schedule() {
        control.withLock { control in
            guard !control.cancelled || control.started else { return }
            Self.work.schedule(id) { [self] in process() }
        }
    }

    private func process() {
        let next = control.withLock { control -> (AVComposition?, Bool?, Position)? in
            guard !control.cancelled else { return nil }
            control.started = true
            defer {
                control.composition = nil
                control.prerollResult = nil
            }
            return (control.composition, control.prerollResult, control.position)
        }
        guard let (composition, prerollResult, position) = next else {
            observation = nil
            player?.cancelPendingPrerolls()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            return
        }
        if let composition { install(composition) }
        guard !cancelled else { schedule(); return }
        if let finished = prerollResult {
            if finished {
                ready = true
            } else {
                ready = false
                notify(.failed(player?.currentItem?.error?.localizedDescription ?? "audio output could not start"))
            }
        }
        checkStatus()
        guard ready, let player else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - position.hostTime
        let seconds = max(0, position.seconds + elapsed * Double(position.rate))
        let current = player.currentTime().seconds
        if !current.isFinite || abs(current - seconds) > 0.1 || player.rate != position.rate {
            notify(.preparing)
            player.setRate(position.rate, time: CMTime(seconds: seconds, preferredTimescale: 600), atHostTime: .invalid)
        }
        notify(.ready)
    }

    private func install(_ composition: AVComposition) {
        let item = AVPlayerItem(asset: composition, automaticallyLoadedAssetKeys: [String]())
        _ = item.currentMediaSelection
        guard !cancelled else { return }
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        self.player = player
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            self?.schedule()
        }
        player.replaceCurrentItem(with: item)
    }

    private func checkStatus() {
        guard let player, let item = player.currentItem else { return }
        switch item.status {
        case .failed:
            ready = false
            notify(.failed(item.error?.localizedDescription ?? "audio could not load"))
        case .readyToPlay:
            guard !prerolling else { return }
            prerolling = true
            player.preroll(atRate: 1) { [weak self] finished in
                guard let self, !self.cancelled else { return }
                self.control.withLock { $0.prerollResult = finished }
                self.schedule()
            }
        default: break
        }
    }

    private func notify(_ state: State) {
        let report = control.withLock { control in
            guard !control.cancelled, control.reported != state else { return false }
            control.reported = state
            return true
        }
        guard report else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.cancelled else { return }
            self.changed(state)
        }
    }
}
