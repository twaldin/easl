import AVFoundation
import Foundation

public struct PreparedVideoPlayback: Sendable {
    public let item: AVPlayerItem
    public let transform: CGAffineTransform
    public let duration: Double
}

@MainActor
public enum NativeVideoPlayback {
    public static func prepare(_ source: AVAsset) async throws -> PreparedVideoPlayback {
        guard let prepared = try await composition(source) else {
            throw HostFileError.unavailable("video has no playable video track")
        }
        let composition = prepared.asset
        let transform = prepared.transform
        let duration = try await composition.load(.duration).seconds
        _ = try await composition.load(.isPlayable, .availableMediaCharacteristicsWithMediaSelectionOptions)
        try Task.checkCancellation()
        let item = AVPlayerItem(asset: composition, automaticallyLoadedAssetKeys: [String]())
        return await offPool {
            // AVKit reads currentMediaSelection synchronously after attachment.
            _ = item.currentMediaSelection
            return PreparedVideoPlayback(item: item, transform: transform, duration: duration)
        }
    }

    private static func composition(_ source: AVAsset) async throws -> (asset: AVComposition, transform: CGAffineTransform)? {
        let tracks = try await source.load(.tracks).filter {
            let type = $0.mediaType
            return type == .video || type == .text || type == .subtitle || type == .closedCaption
        }
        guard tracks.contains(where: { $0.mediaType == .video }) else { return nil }
        var prepared: [(track: UncheckedBox<AVAssetTrack>, mediaType: AVMediaType, range: CMTimeRange, transform: CGAffineTransform)] = []
        for track in tracks {
            let range = try await track.load(.timeRange)
            let transform = track.mediaType == .video ? try await track.load(.preferredTransform) : .identity
            prepared.append((UncheckedBox(track), track.mediaType, range, transform))
        }
        try Task.checkCancellation()
        let transform = prepared.first(where: { $0.mediaType == .video })?.transform ?? .identity
        let sourceTracks = prepared
        let composition = try await offPool {
            Result<UncheckedBox<AVComposition>, Error> {
                let composition = AVMutableComposition()
                for source in sourceTracks {
                    guard let target = composition.addMutableTrack(withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw HostFileError.unavailable("video track could not be prepared")
                    }
                    try target.insertTimeRange(source.range, of: source.track.value, at: source.range.start)
                    target.preferredTransform = source.transform
                }
                return UncheckedBox(composition)
            }
        }.get().value
        return (composition, transform)
    }
}

public final class IsolatedVideoAudio: Sendable {
    public enum State: Equatable, Sendable {
        case preparing
        case ready
        case silent
        case failed(String)
    }

    private struct Position: Sendable {
        var seconds: Double = 0
        var rate: Float = 0
        var volume: Float = 1
        var hostTime = ProcessInfo.processInfo.systemUptime
    }

    private struct Control {
        var cancelled = false
        var started = false
        var item: AVPlayerItem?
        var prerollResult: Bool?
        var reported: State?
        var position = Position()
        var preparation: Task<Void, Never>?
    }

    private let work: VideoAudioWorkQueue
    private let id = UUID()
    private let control = Locked(Control())
    private let changed: @MainActor @Sendable (State) -> Void
    private struct Playback {
        var audio: VideoAudioPlayback<AVPlayer>?
        var itemObservation: NSKeyValueObservation?
        var playerObservation: NSKeyValueObservation?
    }
    private let playback = Locked(Playback())

    @MainActor
    public init(source: AVAsset, work: VideoAudioWorkQueue, changed: @escaping @MainActor @Sendable (State) -> Void) {
        self.work = work
        self.changed = changed
        let preparation = Task { @MainActor [weak self] in
            do {
                guard !(try await source.loadTracks(withMediaType: .audio)).isEmpty else {
                    self?.notify(.silent)
                    return
                }
                _ = try await source.load(.isPlayable, .availableMediaCharacteristicsWithMediaSelectionOptions)
                try Task.checkCancellation()
                guard let self, !self.cancelled else { return }
                let item = AVPlayerItem(asset: source, automaticallyLoadedAssetKeys: [String]())
                guard !self.cancelled else { return }
                self.control.withLock { $0.item = item }
                self.schedule()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.notify(.failed(error.localizedDescription))
            }
        }
        control.withLock { $0.preparation = preparation }
    }

    deinit { control.withLock { $0.preparation?.cancel() } }

    private var cancelled: Bool { control.withLock { $0.cancelled } }

    public func synchronize(seconds: Double, rate: Float, volume: Float) {
        let active = control.withLock { control in
            guard !control.cancelled else { return false }
            control.position = Position(seconds: seconds, rate: rate, volume: volume, hostTime: ProcessInfo.processInfo.systemUptime)
            return true
        }
        if active { schedule() }
    }

    public func cancel() {
        let (started, preparation) = control.withLock { control in
            control.cancelled = true
            control.item = nil
            return (control.started, control.preparation)
        }
        preparation?.cancel()
        if started { schedule() }
        else { work.cancel(id) }
    }

    private func schedule() {
        control.withLock { control in
            guard !control.cancelled || control.started else { return }
            work.schedule(id) { [self] in process() }
        }
    }

    private func process() {
        playback.withLock { state in
            let next = control.withLock { control -> (AVPlayerItem?, Bool?, Position)? in
                guard !control.cancelled else { return nil }
                control.started = true
                defer {
                    control.item = nil
                    control.prerollResult = nil
                }
                return (control.item, control.prerollResult, control.position)
            }
            guard let (item, prerollResult, position) = next else {
                state.itemObservation = nil
                state.playerObservation = nil
                state.audio?.player.cancelPendingPrerolls()
                state.audio?.player.pause()
                state.audio?.player.replaceCurrentItem(with: nil)
                state.audio = nil
                return
            }
            if let item { install(item, into: &state) }
            guard !cancelled else { schedule(); return }
            if let finished = prerollResult {
                state.audio?.ready = finished
                if !finished {
                    notify(.failed(state.audio?.player.currentItem?.error?.localizedDescription ?? "audio output could not start"))
                }
            }
            checkStatus(&state)
            guard let audio = state.audio, audio.ready else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - position.hostTime
            let seconds = max(0, position.seconds + elapsed * Double(position.rate))
            audio.synchronize(seconds: seconds, rate: position.rate, volume: position.volume)
            notify(.ready)
        }
    }

    private func install(_ item: AVPlayerItem, into state: inout Playback) {
        _ = item.currentMediaSelection
        guard !cancelled else { return }
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        state.audio = VideoAudioPlayback(player: player)
        state.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            self?.schedule()
        }
        state.playerObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            self?.schedule()
        }
        player.replaceCurrentItem(with: item)
    }

    private func checkStatus(_ state: inout Playback) {
        guard let audio = state.audio, let item = audio.player.currentItem else { return }
        if item.status == .failed || audio.player.status == .failed {
            state.audio?.ready = false
            notify(.failed(item.error?.localizedDescription ?? audio.player.error?.localizedDescription ?? "audio could not load"))
            return
        }
        state.audio?.preroll { [weak self] finished in
            guard let self, !self.cancelled else { return }
            self.control.withLock { $0.prerollResult = finished }
            self.schedule()
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

protocol VideoAudioClockPlayer: AnyObject {
    var automaticallyWaitsToMinimizeStalling: Bool { get set }
    var isReady: Bool { get }
    var itemIsReady: Bool { get }
    var currentSeconds: Double { get }
    var rate: Float { get }
    var volume: Float { get set }
    func prepareAudio(completion: @escaping @Sendable (Bool) -> Void)
    func synchronize(rate: Float, seconds: Double)
}

struct VideoAudioPlayback<Player: VideoAudioClockPlayer> {
    let player: Player
    var ready = false
    private var prerolling = false

    init(player: Player) {
        self.player = player
        player.automaticallyWaitsToMinimizeStalling = false
    }

    mutating func preroll(completion: @escaping @Sendable (Bool) -> Void) {
        guard player.isReady, player.itemIsReady, !prerolling else { return }
        prerolling = true
        player.prepareAudio(completion: completion)
    }

    func synchronize(seconds: Double, rate: Float, volume: Float) {
        guard ready, player.isReady, player.itemIsReady else { return }
        if player.volume != volume { player.volume = volume }
        let current = player.currentSeconds
        if !current.isFinite || abs(current - seconds) > 0.1 || player.rate != rate {
            player.synchronize(rate: rate, seconds: seconds)
        }
    }
}

extension AVPlayer: VideoAudioClockPlayer {
    nonisolated var isReady: Bool { status == .readyToPlay }
    nonisolated var itemIsReady: Bool { currentItem?.status == .readyToPlay }

    nonisolated var currentSeconds: Double { currentTime().seconds }

    nonisolated func prepareAudio(completion: @escaping @Sendable (Bool) -> Void) {
        preroll(atRate: 1, completionHandler: completion)
    }

    nonisolated func synchronize(rate: Float, seconds: Double) {
        setRate(rate, time: CMTime(seconds: seconds, preferredTimescale: 600), atHostTime: .invalid)
    }
}
