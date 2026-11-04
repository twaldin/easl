import CoreFoundation
import Darwin
import Foundation
@testable import CanvasCore

@MainActor
private enum BoardSaveRegression {
    static var finished = false
    static var failure: String?
    static var editedDuringWrite = false

    static func run(directory: URL) async throws {
        let metrics = Metrics.shared
        metrics.monitorMainThread()
        let store = BoardStore(directory: directory.appendingPathComponent("boards"), debounce: 0.01) { data, url, options in
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
                    editedDuringWrite = true
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
        let report: JSONValue = .object([
            "saveMs": .number((saved - started) * 1000),
            "longestMs": .number(longest),
            "editedDuringWrite": .bool(editedDuringWrite),
            "persistedMarkdown": text.map(JSONValue.string) ?? .null,
            "stretch50": result["counters"]?["main.stretch50"] ?? .null,
            "stretch250": result["counters"]?["main.stretch250"] ?? .null,
        ])
        try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        guard longest < 50 else { throw RegressionFailure("main-thread stretch \(longest) ms exceeds 50 ms during slow save") }
        guard editedDuringWrite, text == "edited while writing" else { throw RegressionFailure("latest edit was not durable at save completion") }
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

    static func main() -> Int32 {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else { return 2 }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let mode = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "slow"
        Task { @MainActor in
            do {
                if mode == "slow" {
                    try await run(directory: directory)
                    print("PASS slow atomic write leaves main responsive and persists concurrent edit")
                } else {
                    try await atomic(directory: directory, crash: mode == "crash")
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
