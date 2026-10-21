import AVFoundation
import CryptoKit
import Foundation
import ObjectiveC
import Testing
@testable import CanvasCore

private final class MutedAudioReceipt: @unchecked Sendable {
    struct Output {
        var samples = 0
        var starts = 0
        var renderer: AVSampleBufferAudioRenderer?
        var clock: AVSampleBufferRenderSynchronizer?
    }
    let output = Locked(Output())

    func drain(_ worker: VideoAudioWorkQueue) {
        let drained = DispatchSemaphore(value: 0)
        worker.schedule(UUID()) { drained.signal() }
        guard drained.wait(timeout: .now() + 5) == .success else { _exit(92) }
    }
}

@MainActor
struct IsolatedVideoAudioTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EASL_TEST_AUDIO_FIXTURE"] != nil),
          .timeLimit(.minutes(1)))
    func mutedProductionAudioRendersAdvancesAndSeeks() async throws {
        try #require(CommandLine.arguments.contains("--no-parallel"))
        let path = try #require(ProcessInfo.processInfo.environment["EASL_TEST_AUDIO_FIXTURE"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try #require(hash == "3dea05779a4899c9e105d25b152f4c4c817d17107b2b8896c1506b0bbacb60c6")
        let receipt = MutedAudioReceipt()
        let enqueueSelector = NSSelectorFromString("enqueueSampleBuffer:")
        let rateSelector = NSSelectorFromString("setRate:time:")
        let enqueueMethod = try #require(class_getInstanceMethod(AVSampleBufferAudioRenderer.self, enqueueSelector))
        let rateMethod = try #require(class_getInstanceMethod(AVSampleBufferRenderSynchronizer.self, rateSelector))
        let enqueueIMP = method_getImplementation(enqueueMethod)
        let rateIMP = method_getImplementation(rateMethod)
        typealias Enqueue = @convention(c) (AnyObject, Selector, CMSampleBuffer) -> Void
        typealias SetRate = @convention(c) (AnyObject, Selector, Float, CMTime) -> Void
        let enqueue = unsafeBitCast(enqueueIMP, to: Enqueue.self)
        let setRate = unsafeBitCast(rateIMP, to: SetRate.self)
        let enqueueBlock: @convention(block) @Sendable (AVSampleBufferAudioRenderer, CMSampleBuffer) -> Void = { renderer, sample in
            guard renderer.volume == 0 else {
                FileHandle.standardError.write(Data("UNSAFE nonzero renderer volume before enqueue\n".utf8))
                _exit(90)
            }
            enqueue(renderer, enqueueSelector, sample)
            receipt.output.withLock { state in
                state.samples += 1
                state.renderer = renderer
            }
        }
        let rateBlock: @convention(block) @Sendable (AVSampleBufferRenderSynchronizer, Float, CMTime) -> Void = { clock, rate, time in
            if rate != 0 {
                let renderers = clock.renderers.compactMap { $0 as? AVSampleBufferAudioRenderer }
                guard !renderers.isEmpty, renderers.allSatisfy({ $0.volume == 0 }) else {
                    FileHandle.standardError.write(Data("UNSAFE nonzero renderer volume before clock start\n".utf8))
                    _exit(91)
                }
            }
            setRate(clock, rateSelector, rate, time)
            receipt.output.withLock { state in
                state.clock = clock
                if rate != 0 { state.starts += 1 }
            }
        }
        let guardedEnqueue = imp_implementationWithBlock(enqueueBlock)
        let guardedRate = imp_implementationWithBlock(rateBlock)
        method_setImplementation(enqueueMethod, guardedEnqueue)
        method_setImplementation(rateMethod, guardedRate)
        defer {
            method_setImplementation(enqueueMethod, enqueueIMP)
            method_setImplementation(rateMethod, rateIMP)
            imp_removeBlock(guardedEnqueue)
            imp_removeBlock(guardedRate)
        }
        let worker = VideoAudioWorkQueue()
        var states: [IsolatedVideoAudio.State] = []
        let audio = IsolatedVideoAudio(source: AVURLAsset(url: URL(fileURLWithPath: path)), work: worker) { states.append($0) }
        let hostStart = ProcessInfo.processInfo.systemUptime
        audio.synchronize(seconds: 0, rate: 1, volume: 0)
        defer {
            audio.cancel()
            receipt.drain(worker)
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while !states.contains(.ready), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            audio.synchronize(seconds: ProcessInfo.processInfo.systemUptime - hostStart, rate: 1, volume: 0)
        }
        try #require(states == [.ready])
        for (phase, target) in [("playing", 0.0), ("seek", 2.0)] {
            let beforeSamples = receipt.output.withLock { $0.samples }
            let beforeStarts = receipt.output.withLock { $0.starts }
            if target != 0 { audio.synchronize(seconds: target, rate: 1, volume: 0) }
            try await Task.sleep(for: .milliseconds(1_200))
            let output = receipt.output.withLock { $0 }
            let renderer = try #require(output.renderer)
            let clock = try #require(output.clock)
            let start = clock.currentTime().seconds
            audio.synchronize(seconds: start, rate: 1, volume: 0)
            try await Task.sleep(for: .milliseconds(1_200))
            let end = clock.currentTime().seconds
            #expect(renderer.volume == 0)
            #expect(renderer.status == .rendering)
            #expect(renderer.error == nil)
            #expect(clock.rate == 1)
            #expect(end - start > 1)
            #expect(output.samples > 0)
            #expect(output.starts > 0)
            if target != 0 {
                #expect(output.samples > beforeSamples)
                #expect(output.starts > beforeStarts)
                #expect(start >= target + 1 && start < target + 2)
            }
            #expect(states == [.ready])
            print("AUDIO phase=\(phase) samples=\(output.samples) starts=\(output.starts) volume=\(renderer.volume) status=\(renderer.status.rawValue) error=\(String(describing: renderer.error)) timeStart=\(start) timeEnd=\(end) rate=\(clock.rate)")
        }
        audio.cancel()
        let (drained, continuation) = AsyncStream<Void>.makeStream()
        worker.schedule(UUID()) { continuation.yield(); continuation.finish() }
        for await _ in drained { break }
        #expect(receipt.output.withLock { $0.renderer?.volume } == 0)
        print("AUDIO cancelled worker drained fixtureSHA256=\(hash) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }
}
