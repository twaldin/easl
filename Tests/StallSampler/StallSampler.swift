import CoreFoundation
import Darwin
import Foundation
import CanvasCore

@inline(never)
func stallBusyLoop(milliseconds: Int) {
    let end = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
    while ProcessInfo.processInfo.systemUptime < end {
    }
}

@MainActor
private enum StallSamplerRegression {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let milliseconds = Int(CommandLine.arguments[2]),
              [300, 600, 1500].contains(milliseconds),
              ["busy", "blocked", "late-busy", "late-blocked"].contains(CommandLine.arguments[1]),
              let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must supply a scenario, duration and isolated home")
        }
        let kind = CommandLine.arguments[1]
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
