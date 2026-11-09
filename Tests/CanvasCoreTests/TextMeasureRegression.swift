import AppKit
import Foundation
@testable import CanvasCore

@MainActor
enum TextMeasureRegression {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Sample {
        let name: String
        let item: JSONValue

        init(_ name: String, _ kind: String, _ text: String, width: Double? = nil, textSize: Double? = nil) {
            self.name = name
            var fields: [String: JSONValue] = ["kind": .string(kind), "text": .string(text)]
            if let width { fields["width"] = .number(width) }
            if let textSize { fields["textSize"] = .number(textSize) }
            item = .object(fields)
        }
    }

    private final class Completion {
        var finished = false
        var status: Int32 = 1
    }

    @MainActor
    private final class Pulse {
        var times: [Double] = []
    }

    private final class Backend: NoteMermaidBackend {
        let success: Bool
        init(success: Bool) { self.success = success }

        func start(_ key: NoteMermaid.Key, completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void) {
            if success {
                let image = NSImage(size: CGSize(width: 173.25, height: 81.5))
                completion(.image(image))
            } else {
                completion(.fallback("deterministic regression fallback"))
            }
            return {}
        }
    }

    static func main() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        var output: URL?
        var expected: URL?
        var ciTimingReportOnly = false
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--ci-timing-report-only" {
                ciTimingReportOnly = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { return usage() }
            switch arguments[index] {
            case "--output": output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            case "--expected": expected = URL(fileURLWithPath: arguments[index + 1])
            default: return usage()
            }
            index += 2
        }
        guard let output else { return usage() }
        let completion = Completion()
        Task { @MainActor in
            do {
                try await run(output: output, expected: expected, ciTimingReportOnly: ciTimingReportOnly)
                completion.status = 0
            } catch {
                FileHandle.standardError.write(Data("FAIL text.measure regression: \(error)\n".utf8))
            }
            completion.finished = true
        }
        let deadline = Date(timeIntervalSinceNow: 60)
        while !completion.finished, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        guard completion.finished else {
            FileHandle.standardError.write(Data("FAIL text.measure regression exceeded 60 seconds\n".utf8))
            return 1
        }
        return completion.status
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("usage: CanvasCoreTests --text-measure-regression --output DIRECTORY [--expected sizes.json] [--ci-timing-report-only]\n".utf8))
        return 2
    }

    private static let timeline = """
    | UTC | event | evidence |
    |---|---|---|
    | 19:04:27.5 | First victim gets a 409 on the claim while the listing is still reserved by another buyer | incident-2026-09-26/api.jsonl:1092 |
    | 19:04:31 | Retry storm | `api.jsonl:1101` |
    """

    private static let prose = String(repeating: "The agent checks **ownership**, records `src/click/core.py:1587`, and follows [the evidence](https://example.com/evidence) before changing the board. ", count: 12)
    private static let lists = """
    - Check the current owner and record the evidence.
      - Inspect the nested state and preserve its dimensions.
    - [x] Read the incident timeline.
    - [ ] Explain the remaining failure.

    1. Parse the complete request.
    2. Measure every note without blocking input.
    """
    private static let code = """
    ```swift
    let evidence = records.map { record in record.path + ":" + String(record.line) }
    for item in evidence { print(item) }
    ```

    ```
    unanchored code, not a file read
    a long line of ordinary code with a deliberately wide identifier_that_keeps_the_original_wrapping_behavior
    ```
    """

    private static func corpus() -> [Sample] {
        var samples: [Sample] = [Sample("empty-note", "note", "")]
        for width in [160.0, 280, 340.5, 420, 1400] {
            samples.append(Sample("timeline-\(width)", "note", timeline, width: width))
        }
        let columns = (1...12).map { "column \($0)" }.joined(separator: " | ")
        let values = (1...12).map { "value \($0)" }.joined(separator: " | ")
        samples.append(Sample("table-shortfall", "note", "| \(columns) |\n|" + String(repeating: "---|", count: 12) + "\n| \(values) |", width: 300.25))
        samples += [Sample("long-prose", "note", prose, width: 317.25),
                    Sample("lists", "note", lists, width: 193.5),
                    Sample("free-fences", "note", code, width: 261.75)]
        let unicode = "AV fi e\u{301} 👩🏽‍💻 中文 العربية\nSecond line"
        for kind in ["text", "label", "arrowLabel", "caption"] {
            samples.append(Sample("\(kind)-empty", kind, ""))
            samples.append(Sample("\(kind)-unicode", kind, unicode))
            samples.append(Sample("\(kind)-long", kind, String(repeating: "AV fi wide drawing label ", count: 24)))
        }
        samples += [Sample("text-fractional", "text", unicode + prose, width: 173.25, textSize: 1.375),
                    Sample("label-fractional", "label", unicode + prose, width: 137.5),
                    Sample("caption-code", "caption", "Inspect `src/main.swift`\nand `AV fi`"),
                    Sample("note-unicode", "note", unicode, width: 187.25),
                    Sample("math-inline", "note", #"Valid $e^{i\pi}+1=0$ and invalid $\notarealcommand{x}$; costs $5 and $10."#, width: 281.5),
                    Sample("math-display", "note", "Before\n\n$$\n\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\n$$\n\nAfter", width: 320.25),
                    Sample("math-heading", "note", #"# Heading $\frac{x}{y}$ and $\notarealcommand{x}$"#, width: 219.5),
                    Sample("math-quote", "note", "> $$\n> \\frac{x}{y} > \\sqrt{2}\n> $$\n\n> $$\n> \\notarealcommand{x}\n> $$", width: 239.25),
                    Sample("math-table", "note", #"| $\frac{x}{y}$ | $\notarealcommand{x}$ |"# + "\n|---|---|\n" + #"| $\sqrt{2}$ | $x_i^2$ |"#, width: 163.25)]
        return samples
    }

    private static func heavyCorpus() -> [Sample] {
        (0..<200).map { index in
            Sample("agent-note-\(index)", "note", "## Agent \(index)\n\n" + timeline + "\n\n" + prose + "\n\n" + lists + "\n\n" + code,
                   width: [280.0, 317.25, 420.5][index % 3])
        }
    }

    private static func nextTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let timer = Timer(timeInterval: 0.001, repeats: false) { _ in continuation.resume() }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private static func oracle(_ samples: [Sample]) async throws -> JSONValue {
        var sizes: [JSONValue] = []
        for sample in samples {
            let item = sample.item
            let text = item["text"]!.string!
            let width = item["width"]?.number.map { CGFloat($0) }
            let size: CGSize
            switch item["kind"]!.string! {
            case "note":
                let document = NoteMarkdown.parse(text)
                let textWidth = (width ?? ObjectMeasure.defaultNoteWidth) - 2 * ObjectMeasure.noteInset.width
                let diagrams = await NoteMermaid.resolve(document, width: textWidth, appearance: NoteMermaid.appearance())
                let note = ObjectMeasure.note(document, markdown: text, width: width, excerpts: [:], images: [:], diagrams: diagrams)
                sizes.append(.object(["w": .number(note.size.width), "h": .number(note.size.height), "tableShortfall": .number(note.tableShortfall)]))
                continue
            case "text": size = ObjectMeasure.shapeTextBounds(text, textSize: CGFloat(item["textSize"]?.number ?? 1), width: width)
            case "label": size = ObjectMeasure.labelBounds(text, width: width)
            case "arrowLabel": size = DrawingStyle.arrowLabel(ArrowSpec(from: .point(.zero), to: .point(.zero), label: text))?.size ?? .zero
            case "caption": size = CGSize(width: ObjectMeasure.captionWidth(text), height: CodeMetrics.captionHeight)
            default: throw Failure("unknown oracle kind")
            }
            sizes.append(.object(["w": .number(size.width), "h": .number(size.height)]))
        }
        return .object(["sizes": .array(sizes)])
    }

    private static func run(output: URL, expected: URL?, ciTimingReportOnly: Bool) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let font = root.appendingPathComponent("resources").appendingPathComponent(DrawingStyle.fontAsset)
        guard FileManager.default.fileExists(atPath: font.path) else { throw Failure("missing bundled drawing font: \(font.path)") }
        DrawingStyle.registerFonts(font)
        guard DrawingStyle.font(size: 20).fontName.contains("Shantell") else { throw Failure("bundled drawing font was not registered") }
        let fixture = try DelegatedCallsTests()
        let calls = fixture.delegated()
        let previousBackend = NoteMermaid.backend
        defer { NoteMermaid.backend = previousBackend }
        NoteMermaid.backend = nil
        var results: [String: JSONValue] = [:]
        var inputs: [String: JSONValue] = [:]
        var timings: [String: JSONValue] = [:]
        var failures: [String] = []

        func measure(_ name: String, _ samples: [Sample]) async throws -> JSONValue {
            inputs[name] = .array(samples.map { .object(["name": .string($0.name), "item": $0.item]) })
            let start = Metrics.now()
            let result = try await fixture.answer(calls, "text.measure", .object(["items": .array(samples.map(\.item))])).get()
            timings[name] = .number((Metrics.now() - start) * 1000)
            guard result["sizes"]?.array?.count == samples.count else { throw Failure("\(name): incomplete sizes: \(result)") }
            results[name] = result
            return result
        }

        func compare(_ name: String, _ samples: [Sample], _ actual: JSONValue) async throws {
            let start = Metrics.now()
            let reference = try await oracle(samples)
            timings[name + "-main-oracle"] = .number((Metrics.now() - start) * 1000)
            if try encode(actual) != encode(reference) {
                let actualSizes = actual["sizes"]?.array ?? []
                let referenceSizes = reference["sizes"]?.array ?? []
                for index in samples.indices where index >= actualSizes.count || index >= referenceSizes.count || actualSizes[index] != referenceSizes[index] {
                    failures.append("\(name)[\(index)] \(samples[index].name): main-thread layout differs")
                }
                try encode(reference).write(to: output.appendingPathComponent(name + "-main-oracle.json"))
            }
        }

        let ordinary = corpus()
        let ordinaryResult = try await measure("corpus", ordinary)
        try await compare("corpus", ordinary, ordinaryResult)
        guard ordinaryResult["sizes"]?.array?.contains(where: { ($0["tableShortfall"]?.number ?? 0) > 0 }) == true else {
            throw Failure("corpus did not exercise positive tableShortfall")
        }
        let mermaid = [Sample("diagram", "note", "Before\n\n```mermaid\ngraph TD; A-->B\n```\n\nAfter", width: 237.25),
                       Sample("nested-diagram", "note", "> ```mermaid\n> graph TD; C-->D\n> ```", width: 311.5)]
        for mode in ["absent", "fallback", "success"] {
            NoteMermaid.backend = mode == "absent" ? nil : Backend(success: mode == "success")
            let result = try await measure("mermaid-" + mode, mermaid)
            try await compare("mermaid-" + mode, mermaid, result)
        }
        NoteMermaid.backend = nil
        let heavy = heavyCorpus()
        let pulse = Pulse()
        let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated { pulse.times.append(Metrics.now()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        Metrics.shared.monitorMainThread()
        Metrics.shared.reset()
        await nextTurn()
        let start = Metrics.now()
        let heavyResult = try await measure("heavy", heavy)
        let end = Metrics.now()
        await nextTurn()
        let metrics = Metrics.shared.snapshot()
        timer.invalidate()
        let during = pulse.times.filter { $0 > start && $0 < end }
        let points = [start] + during + [end]
        let maxGap = zip(points, points.dropFirst()).map { ($1 - $0) * 1000 }.max() ?? 0
        try await compare("heavy", heavy, heavyResult)
        for counter in ["main.stretch50", "main.stretch250"] {
            let count = metrics["counters"]?[counter]?["total"]?["n"]?.int ?? 0
            if counter == "main.stretch50", ciTimingReportOnly {
                print("text.measure timing: \(counter).total.n = \(count), assertsTiming: false")
                continue
            }
            if count != 0 { failures.append("\(counter).total.n = \(count), expected 0") }
        }
        if during.isEmpty { failures.append("no main-run-loop timer callback inside the heavy batch") }
        let sizes = try encode(.object(results))
        if let expected {
            do {
                if try Data(contentsOf: expected) != sizes {
                    failures.append("complete sorted size JSON differs from \(expected.path)")
                }
            } catch {
                failures.append("cannot read expected size JSON at \(expected.path): \(error)")
            }
        }
        let report: JSONValue = .object(["batchMs": .number((end - start) * 1000),
                                         "timerCallbacksInsideBatch": .number(Double(during.count)),
                                         "timerMaxGapMs": .number(maxGap),
                                         "timerCallbackOffsetsMs": .array(during.map { .number(($0 - start) * 1000) }),
                                         "metrics": metrics, "timingsMs": .object(timings),
                                         "failures": .array(failures.map(JSONValue.string))])
        try sizes.write(to: output.appendingPathComponent("sizes.json"))
        try encode(.object(inputs)).write(to: output.appendingPathComponent("corpus.json"))
        try encode(report).write(to: output.appendingPathComponent("report.json"))
        FileHandle.standardOutput.write(sizes)
        FileHandle.standardOutput.write(try encode(report))
        guard failures.isEmpty else { throw Failure(failures.joined(separator: "; ")) }
        print("PASS text.measure regression: exact main-thread parity and responsive 200-note batch")
    }
}
