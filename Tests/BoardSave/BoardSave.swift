import CoreFoundation
import Darwin
import Foundation
@testable import CanvasCore

@MainActor
private enum BoardSaveRegression {
    static var finished = false
    static var failure: String?
    static var editedAt: Double?
    static var timingReportOnly = false

    static func run(directory: URL) async throws {
        let metrics = Metrics.shared
        metrics.monitorMainThread()
        let store = BoardStore(directory: directory.appendingPathComponent("boards"), debounce: 0.01) { data, url, options in
#if !SAVE_BASELINE
            guard !Thread.isMainThread else { throw RegressionFailure("atomic write ran on main") }
#endif
            Thread.sleep(forTimeInterval: 2)
            try data.write(to: url, options: options)
        }
        let board = try await store.load(root: directory.appendingPathComponent("root"))
        let note = board.create(type: .note, props: .object(["markdown": .string("before slow save")]))
        try await Task.sleep(for: .milliseconds(100))
        metrics.reset()
        let edit = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                do {
                    try board.update(note.id, props: .object(["markdown": .string("edited while writing")]))
                    editedAt = Metrics.now()
                } catch { failure = "edit failed: \(error)" }
            }
        }
        RunLoop.main.add(edit, forMode: .default)
        let started = Metrics.now()
#if SAVE_BASELINE
        try store.saveChecked(board)
#else
        try await store.saveChecked(board)
#endif
        let saved = Metrics.now()
        try await Task.sleep(for: .milliseconds(100))
        let result = metrics.snapshot()
        try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("metrics.json"), options: .atomic)
        let persisted = try BoardStore.decoder.decode(BoardSnapshot.self, from: Data(contentsOf: store.url(for: board.id)))
        let text = persisted.objects.first { $0.id == note.id }?.props["markdown"]?.string
        let longest = result["longest"]?["ms"]?.number ?? 0
        let editedDuringWrite = editedAt.map { $0 >= started && $0 < saved } ?? false
        let report: JSONValue = .object([
            "saveMs": .number((saved - started) * 1000),
            "longestMs": .number(longest),
            "withinLimit": .bool(longest < 50),
            "assertsTiming": .bool(!timingReportOnly),
            "editedDuringWrite": .bool(editedDuringWrite),
            "persistedMarkdown": text.map(JSONValue.string) ?? .null,
            "stretch50": result["counters"]?["main.stretch50"] ?? .null,
            "stretch250": result["counters"]?["main.stretch250"] ?? .null,
        ])
        try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        guard timingReportOnly || longest < 50 else { throw RegressionFailure("main-thread stretch \(longest) ms exceeds 50 ms during slow save") }
        guard editedDuringWrite, text == "edited while writing" else { throw RegressionFailure("latest edit was not durable at save completion") }
        guard saved - started >= 1.9 else { throw RegressionFailure("save returned before the two-second write completed") }
        guard (result["counters"]?["save.write"]?["total"]?["maxMs"]?.number ?? 0) >= 1900 else {
            throw RegressionFailure("the injected two-second write did not run inside the measured interval")
        }
#if !SAVE_BASELINE
        guard (result["counters"]?["save.slow250"]?["total"]?["n"]?.int ?? 0) > 0 else {
            throw RegressionFailure("slow saves were not counted")
        }
#endif
        if let failure { throw RegressionFailure(failure) }
    }

    static func atomic(directory: URL, crash: Bool) async throws {
        let store = BoardStore(directory: directory.appendingPathComponent("boards"), debounce: 60)
        let board = try await store.load(root: directory.appendingPathComponent("root"))
        if crash {
            guard let note = board.objects.values.first else { throw RegressionFailure("missing seeded note") }
            try board.update(note.id, props: .object(["markdown": .string("crash before atomic rename")]))
        } else {
            board.create(type: .note, props: .object(["markdown": .string("previous complete file")]))
        }
#if SAVE_BASELINE
        try store.saveChecked(board)
#else
        try await store.saveChecked(board)
#endif
    }

    static var modalFinished = false

    static func modal(directory: URL) async throws {
#if SAVE_BASELINE
        throw RegressionFailure("the baseline has no asynchronous modal flush")
#else
        let store = BoardStore(directory: directory.appendingPathComponent("boards"), debounce: 60) { data, url, options in
            guard !Thread.isMainThread else { throw RegressionFailure("modal flush wrote on main") }
            Thread.sleep(forTimeInterval: 2)
            try data.write(to: url, options: options)
        }
        let first = try await store.load(root: directory.appendingPathComponent("one"))
        let second = try await store.load(root: directory.appendingPathComponent("two"))
        first.create(type: .note, props: .object(["markdown": "first pending board"]))
        second.create(type: .note, props: .object(["markdown": "second pending board"]))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let mode = RunLoop.Mode(rawValue: "NSModalPanelRunLoopMode")
                let deadline = Date(timeIntervalSinceNow: 10)
                let keepAlive = Timer(timeInterval: 10, repeats: false) { _ in }
                RunLoop.main.add(keepAlive, forMode: mode)
                defer { keepAlive.invalidate() }
                store.beginFlush([first, second]) { modalFinished = true }
                while !modalFinished, Date() < deadline {
                    _ = RunLoop.main.run(mode: mode, before: min(deadline, Date(timeIntervalSinceNow: 0.05)))
                }
                guard modalFinished else {
                    continuation.resume(throwing: RegressionFailure("deferred-quit modal loop could not drain queued board saves"))
                    return
                }
                continuation.resume(with: Result {
                    let one = try BoardStore.decoder.decode(BoardSnapshot.self, from: Data(contentsOf: store.url(for: first.id)))
                    let two = try BoardStore.decoder.decode(BoardSnapshot.self, from: Data(contentsOf: store.url(for: second.id)))
                    guard one.objects.first?.props["markdown"] == "first pending board",
                          two.objects.first?.props["markdown"] == "second pending board" else {
                        throw RegressionFailure("modal flush returned before every pending board was durable")
                    }
                })
            }
        }
        print("PASS deferred-quit modal loop drains both slow pending boards")
#endif
    }

    static func main() -> Int32 {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else { return 2 }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let mode = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "slow"
        timingReportOnly = mode == "slow-report"
        Task { @MainActor in
            do {
                if mode == "slow" || mode == "slow-report" {
                    try await run(directory: directory)
                    print("PASS delayed atomic write persists the concurrent edit; timing is recorded above")
                } else {
#if !SAVE_BASELINE
                    if mode == "modal" {
                        try await modal(directory: directory)
                    } else {
                        try await atomic(directory: directory, crash: mode == "crash")
                    }
#else
                    try await atomic(directory: directory, crash: mode == "crash")
#endif
                }
            } catch { failure = "\(error)" }
            finished = true
        }
        let deadline = Date(timeIntervalSinceNow: 15)
        while !finished, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard finished else { print("FAIL save exceeded 15 seconds"); return 1 }
        if let failure { print("FAIL \(failure)"); return 1 }
        return 0
    }
}

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
@_cdecl("EaslBoardSaveRegressionMain")
func easlBoardSaveRegressionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    BoardSaveRegression.main()
}
