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
        _ = try await composition.load(.isPlayable, .availableMediaCharacteristicsWithMediaSelectionOptions, .tracks, .hasProtectedContent)
        try Task.checkCancellation()
        let item = AVPlayerItem(asset: composition)
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
        var prepared: [(track: UncheckedBox<AVAssetTrack>, mediaType: AVMediaType, range: CMTimeRange, transform: CGAffineTransform, enabled: Bool, language: String?, languageTag: String?)] = []
        for track in tracks {
            let range = try await track.load(.timeRange)
            let transform = track.mediaType == .video ? try await track.load(.preferredTransform) : .identity
            let (enabled, language, languageTag) = try await track.load(.isEnabled, .languageCode, .extendedLanguageTag)
            prepared.append((UncheckedBox(track), track.mediaType, range, transform, enabled, language, languageTag))
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
                    target.isEnabled = source.enabled
                    target.languageCode = source.language
                    target.extendedLanguageTag = source.languageTag
                }
                return UncheckedBox(composition)
            }
        }.get().value
        return (composition, transform)
    }
}

// AVPlayerItem's internal notifications use main even when its player is created on a worker.
public final class IsolatedVideoAudio: Sendable {
    public enum State: Equatable, Sendable {
        case ready
        case silent
        case failed(String)
    }

    private struct Input: Sendable {
        let asset: AVURLAsset
        let track: UncheckedBox<AVAssetTrack>
        let duration: Double
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
        var input: Input?
        var reported: State?
        var position = Position()
        var preparation: Task<Void, Never>?
    }

    private struct Playback {
        var input: Input?
        var renderer: AVSampleBufferAudioRenderer?
        var clock: AVSampleBufferRenderSynchronizer?
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var pending: CMSampleBuffer?
        var previous: Position?
        var rate: Float = 0
        var ended = false
    }

    private let work: VideoAudioWorkQueue
    private let id = UUID()
    private let control = Locked(Control())
    private let playback = Locked(Playback())
    private let changed: @MainActor @Sendable (State) -> Void

    @MainActor
    public init(source: AVURLAsset, work: VideoAudioWorkQueue, changed: @escaping @MainActor @Sendable (State) -> Void) {
        self.work = work
        self.changed = changed
        let preparation = Task { @MainActor [weak self] in
            do {
                let tracks = try await source.loadTracks(withMediaType: .audio)
                var selected: AVAssetTrack?
                for track in tracks {
                    if try await track.load(.isEnabled) {
                        selected = track
                        break
                    }
                }
                guard let selected else { self?.notify(.silent); return }
                let duration = try await source.load(.duration).seconds
                try Task.checkCancellation()
                guard let self, !self.cancelled else { return }
                self.control.withLock { $0.input = Input(asset: source, track: UncheckedBox(selected), duration: duration) }
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
            control.input = nil
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
            let next = control.withLock { control -> (Input?, Position)? in
                guard !control.cancelled else { return nil }
                control.started = true
                defer { control.input = nil }
                return (control.input, control.position)
            }
            guard let (input, position) = next else {
                state.reader?.cancelReading()
                state.renderer?.flush()
                if let renderer = state.renderer, let clock = state.clock {
                    clock.setRate(0, time: .zero)
                    clock.removeRenderer(renderer, at: .negativeInfinity, completionHandler: nil)
                }
                state = Playback()
                return
            }
            do {
                if let input {
                    state.input = input
                    let renderer = AVSampleBufferAudioRenderer()
                    let clock = AVSampleBufferRenderSynchronizer()
                    state.renderer = renderer
                    state.clock = clock
                    clock.addRenderer(renderer)
                }
                guard !cancelled else { schedule(); return }
                try synchronize(position, state: &state)
            } catch {
                notify(.failed(error.localizedDescription))
            }
        }
    }

    private func synchronize(_ position: Position, state: inout Playback) throws {
        guard let input = state.input, let renderer = state.renderer, let clock = state.clock else { return }
        guard position.rate >= 0 else { throw HostFileError.unavailable("reverse audio playback is unavailable") }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - position.hostTime)
        let seconds = max(0, position.seconds + elapsed * Double(position.rate))
        let current = clock.currentTime().seconds
        let discontinuity = state.previous.map {
            abs(position.seconds - ($0.seconds + (position.hostTime - $0.hostTime) * Double($0.rate))) > 0.1
        } ?? true
        state.previous = position
        if state.reader == nil || discontinuity {
            state.reader?.cancelReading()
            renderer.flush()
            clock.setRate(0, time: CMTime(seconds: seconds, preferredTimescale: 600))
            state.rate = 0
            state.pending = nil
            state.ended = seconds >= input.duration
            let reader = try AVAssetReader(asset: input.asset)
            let output = AVAssetReaderTrackOutput(track: input.track.value, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw HostFileError.unavailable("audio samples cannot be read") }
            reader.add(output)
            let remaining = input.duration.isFinite
                ? CMTime(seconds: max(0, input.duration - seconds), preferredTimescale: 600) : .positiveInfinity
            reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: remaining)
            guard state.ended || reader.startReading() else {
                throw reader.error ?? HostFileError.unavailable("audio samples could not start")
            }
            state.reader = reader
            state.output = output
        }
        if renderer.volume != position.volume { renderer.volume = position.volume }
        let limit = (current.isFinite && !discontinuity ? current : seconds) + 2
        for _ in 0..<256 {
            guard !state.ended, renderer.isReadyForMoreMediaData else { break }
            guard let sample = state.pending ?? state.output?.copyNextSampleBuffer() else {
                if let error = state.reader?.error { throw error }
                state.ended = true
                break
            }
            if sample.presentationTimeStamp.seconds > limit {
                state.pending = sample
                break
            }
            state.pending = nil
            renderer.enqueue(sample)
        }
        if renderer.status == .failed { throw renderer.error ?? HostFileError.unavailable("audio output could not start") }
        if state.rate != position.rate || (current.isFinite && abs(current - seconds) > 0.1) {
            let anchor = max(0, position.seconds + max(0, ProcessInfo.processInfo.systemUptime - position.hostTime) * Double(position.rate))
            clock.setRate(position.rate, time: CMTime(seconds: anchor, preferredTimescale: 600))
            state.rate = position.rate
        }
        if renderer.status == .rendering && renderer.hasSufficientMediaDataForReliablePlaybackStart { notify(.ready) }
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

