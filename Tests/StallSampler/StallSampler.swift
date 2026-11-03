import CoreFoundation
import Darwin
import Foundation
import CanvasCore
import os
import StallCapture

@inline(never)
func stallBusyLoop(milliseconds: Int) {
    let end = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
    while ProcessInfo.processInfo.systemUptime < end {
    }
}

@MainActor
private enum StallSamplerRegression {
    private static func rejectsRetiredTurns() {
        let capture = easl_stall_create()!
        defer { easl_stall_destroy(capture) }
        easl_stall_publish(capture, 2)
        let result = OSAllocatedUnfairLock(initialState: (capture: capture, accepted: true, error: Int32(0)))
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.withLock { state in
                var record = EaslStallRecord()
                state.accepted = easl_stall_capture(state.capture, 1, &record)
                state.error = record.error
            }
            done.signal()
        }
        precondition(done.wait(timeout: .now() + 5) == .success)
        precondition(result.withLock { !$0.accepted && $0.error == EASL_STALL_ERROR_TURN_CHANGED })
        print("PASS retired turn returns cancellation, not a capture failure")
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let milliseconds = Int(CommandLine.arguments[2]),
              [300, 600, 1500].contains(milliseconds),
              ["busy", "blocked", "late-busy", "late-blocked"].contains(CommandLine.arguments[1]),
              let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must supply a scenario, duration and isolated home")
        }
        let kind = CommandLine.arguments[1]
        if kind == "busy" && milliseconds == 300 { rejectsRetiredTurns() }
        let directory = URL(fileURLWithPath: home, isDirectory: true)
        let metrics = Metrics.shared
        metrics.monitorMainThread()
        metrics.sampleStalls(into: directory.appendingPathComponent("stalls", isDirectory: true))
        let stall = { @Sendable in
            precondition(Thread.isMainThread)
            if kind.hasSuffix("busy") {
                stallBusyLoop(milliseconds: milliseconds)
            } else {
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                    semaphore.signal()
                }
                semaphore.wait()
            }
        }
        if kind.hasPrefix("late-") {
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_000) { _, _ in stall() }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        } else {
            RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in stall() }, forMode: .default)
        }
        let deadline = Date(timeIntervalSinceNow: Double(milliseconds) / 1000 + 8)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.05)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metrics.snapshot()).write(to: directory.appendingPathComponent("metrics.json"), options: .atomic)
        print("FINISHED \(kind)-\(milliseconds)")
    }
}

@MainActor
@_cdecl("EaslStallRegressionMain")
func easlStallRegressionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    do {
        try StallSamplerRegression.main()
        return 0
    } catch {
        FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
        return 1
    }
}
