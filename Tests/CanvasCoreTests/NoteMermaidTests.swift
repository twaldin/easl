import AppKit
import Foundation
import Markdown
import Testing
@testable import CanvasCore

@Suite(.serialized)
@MainActor
struct NoteMermaidTests {
    @MainActor
    private final class Backend: NoteMermaidBackend {
        struct Request {
            let key: NoteMermaid.Key
            let completion: @MainActor (NoteMermaid.Outcome) -> Void
            let abortsAtStart: Int
        }

        var requests: [Request] = []
        var aborted: [Int] = []
        var answer: ((NoteMermaid.Key) -> NoteMermaid.Outcome?)?
        var onAbort: ((NoteMermaid.Key) -> Void)?

        func start(_ key: NoteMermaid.Key, completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void) {
            let index = requests.count
            requests.append(Request(key: key, completion: completion, abortsAtStart: aborted.count))
            if let outcome = answer?(key) { completion(outcome) }
            return { [weak self] in
                guard let self else { return }
                aborted.append(index)
                onAbort?(key)
            }
        }

        func complete(_ index: Int, with outcome: NoteMermaid.Outcome) {
            requests[index].completion(outcome)
        }
    }

    private func markdown(_ sources: [String]) -> String {
        sources.map { "```mermaid\n\($0)\n```" }.joined(separator: "\n\n")
    }

    private func image(width: Int = 100, height: Int = 50) throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    private func renderedImage(_ outcome: NoteMermaid.Outcome?) -> NSImage? {
        if case .image(let image)? = outcome { return image }
        return nil
    }

    private func fallback(_ outcome: NoteMermaid.Outcome?) -> String? {
        if case .fallback(let reason)? = outcome { return reason }
        return nil
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(predicate())
    }

    @Test func noBackendPreservesTheOrdinarySourcePath() async {
        let previous = NoteMermaid.backend
        NoteMermaid.backend = nil
        defer { NoteMermaid.backend = previous }
        let source = markdown(["graph TD; A-->B"])
        let document = NoteMarkdown.parse(source)
        #expect(await NoteMermaid.resolve(document, width: 400, appearance: .light).isEmpty)
        #expect(NoteMermaid.cached(document, width: 400, appearance: .light).isEmpty)
        let renderer = NoteRenderer(excerpts: [:], source: source, width: 400)
        let text = renderer.render(document, placeholder: "")
        #expect(text.string == "graph TD; A-->B")
        #expect(renderer.fitsWidth)
        #expect(text.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
    }

    @Test func onlyExactMermaidInfoIsAdmittedAndOpeningLinesAreStable() async throws {
        let backend = Backend()
        let picture = try image()
        backend.answer = { _ in .image(picture) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let tags = ["swift", "mermaid extra", "Mermaid", "mermaid file=src/a.swift", "mermaid"]
        let source = tags.map { "```\($0)\ngraph TD; A-->B\n```" }.joined(separator: "\n\n")
        let document = NoteMarkdown.parse(source)
        let outcomes = await NoteMermaid.resolve(document, width: 400, appearance: .light)
        #expect(Set(outcomes.keys) == [17])
        #expect(backend.requests.count == 1)
        #expect(backend.requests.first?.key.source == "graph TD; A-->B\n")
        #expect(backend.requests.first?.key.width == 392)
        let renderer = NoteRenderer(excerpts: [:], source: source, width: 400, diagrams: outcomes)
        let text = renderer.render(document, placeholder: "")
        var lines: [Int] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            if let line = text.attribute(.noteMarkdownLine, at: range.location, effectiveRange: nil) as? Int { lines.append(line) }
        }
        #expect(lines == [17])
    }

    @Test func nestedFencesUseTheSameEffectiveWidthAsTheirImageParagraphs() async throws {
        let backend = Backend()
        let picture = try image()
        backend.answer = { _ in .image(picture) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let cases: [(String, CGFloat, Int)] = [
            (markdown(["plain"]), 0, 392),
            ("> ```mermaid\n> quote\n> ```", 14, 378),
            ("- item\n\n  ```mermaid\n  unordered\n  ```", 18, 374),
            ("1. item\n\n   ```mermaid\n   ordered\n   ```", 26, 366),
            ("- [ ] item\n\n  ```mermaid\n  checkbox\n  ```", 24, 368),
            ("> - item\n>\n>   ```mermaid\n>   nested\n>   ```", 32, 360),
        ]
        for (source, indent, width) in cases {
            let document = NoteMarkdown.parse(source)
            let outcomes = await NoteMermaid.resolve(document, width: 400, appearance: .light)
            #expect(outcomes.count == 1)
            #expect(backend.requests.last?.key.width == width)
            let text = NoteRenderer(excerpts: [:], source: source, width: 400, diagrams: outcomes).render(document, placeholder: "")
            let location = (text.string as NSString).range(of: "\u{FFFC}").location
            #expect(location != NSNotFound)
            if location != NSNotFound {
                let style = try #require(text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
                #expect(style.headIndent == indent)
                #expect(CGFloat(width) + style.headIndent + 8 == 400)
            }
        }
    }

    @Test func occurrenceLimitChargesDuplicatesButDeduplicatesTheirRender() async throws {
        let backend = Backend()
        let picture = try image()
        backend.answer = { _ in .image(picture) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = NoteMarkdown.parse(markdown(Array(repeating: "same", count: 21)))
        let outcomes = await NoteMermaid.resolve(document, width: 400, appearance: .light)
        #expect(outcomes.count == 21)
        #expect(backend.requests.count == 1)
        for line in stride(from: 1, through: 77, by: 4) { #expect(renderedImage(outcomes[line]) === picture) }
        #expect(fallback(outcomes[81]) != nil)
        let cached = NoteMermaid.cached(document, width: 400, appearance: .light)
        #expect(cached.count == 21)
        #expect(fallback(cached[81]) != nil)
        let another = await NoteMermaid.resolve(NoteMarkdown.parse(markdown(["another note"])), width: 400, appearance: .light)
        #expect(renderedImage(another[1]) === picture)
        #expect(backend.requests.count == 2)
    }

    @Test func sourceAdmissionCountsUTF8BytesIncludingTheFinalNewline() async throws {
        let backend = Backend()
        let picture = try image()
        backend.answer = { _ in .image(picture) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        for body in [String(repeating: "x", count: 51_199), String(repeating: "é", count: 25_599) + "a"] {
            let accepted = await NoteMermaid.resolve(NoteMarkdown.parse(markdown([body])), width: 400, appearance: .light)
            #expect(renderedImage(accepted[1]) === picture)
        }
        #expect(backend.requests.count == 2)
        for body in [String(repeating: "x", count: 51_200), String(repeating: "é", count: 25_600)] {
            let rejected = await NoteMermaid.resolve(NoteMarkdown.parse(markdown([body])), width: 400, appearance: .light)
            #expect(fallback(rejected[1]) != nil)
        }
        #expect(backend.requests.count == 2)
    }

    @Test func widthNormalizationRejectsInvalidValuesAndBoundsFiniteValues() async throws {
        let backend = Backend()
        let picture = try image()
        backend.answer = { _ in .image(picture) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = NoteMarkdown.parse(markdown(["width"]))
        for width in [CGFloat(0), -1, .nan, .infinity, -.infinity, 8] {
            let outcomes = await NoteMermaid.resolve(document, width: width, appearance: .light)
            #expect(fallback(outcomes[1]) != nil)
        }
        #expect(backend.requests.isEmpty)
        _ = await NoteMermaid.resolve(document, width: 9, appearance: .light)
        #expect(backend.requests.last?.key.width == 1)
        _ = await NoteMermaid.resolve(document, width: 400.9, appearance: .light)
        _ = await NoteMermaid.resolve(document, width: 400.1, appearance: .light)
        #expect(backend.requests.count == 2)
        #expect(backend.requests.last?.key.width == 392)
        _ = await NoteMermaid.resolve(document, width: .greatestFiniteMagnitude, appearance: .light)
        _ = await NoteMermaid.resolve(document, width: 9000, appearance: .light)
        #expect(backend.requests.count == 3)
        #expect(backend.requests.last?.key.width == 8192)
    }

    @Test func sourceWidthAndAppearanceHaveSeparateCachedOutcomes() async throws {
        let backend = Backend()
        var response = 0
        backend.answer = { _ in
            response += 1
            return .fallback("response \(response)")
        }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let first = NoteMarkdown.parse(markdown(["first"]))
        let second = NoteMarkdown.parse(markdown(["second"]))
        #expect(NoteMermaid.cached(first, width: 400, appearance: .light).isEmpty)
        let inputs: [(Document, CGFloat, NoteMermaid.Appearance)] = [
            (first, 400, .light), (second, 400, .light), (first, 401, .light), (first, 400, .dark),
        ]
        for (index, input) in inputs.enumerated() {
            let outcome = await NoteMermaid.resolve(input.0, width: input.1, appearance: input.2)
            #expect(fallback(outcome[1]) == "response \(index + 1)")
        }
        for (index, input) in inputs.enumerated() {
            let cached = NoteMermaid.cached(input.0, width: input.1, appearance: input.2)
            #expect(fallback(cached[1]) == "response \(index + 1)")
            let resolved = await NoteMermaid.resolve(input.0, width: input.1, appearance: input.2)
            #expect(fallback(resolved[1]) == "response \(index + 1)")
        }
        #expect(backend.requests.count == 4)
    }

    @Test(.timeLimit(.minutes(1))) func aNeverFinishingBackendTimesOutReleasesItsSlotAndCannotPublishLate() async throws {
        let backend = Backend()
        let picture = try image()
        backend.answer = { key in key.source == "third\n" ? .image(picture) : nil }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = NoteMarkdown.parse(markdown(["first", "second", "third"]))
        var publishedBeforeAbort = false
        backend.onAbort = { key in
            let line = key.source == "first\n" ? 1 : 5
            if NoteMermaid.cached(document, width: 400, appearance: .light)[line] != nil { publishedBeforeAbort = true }
        }
        var result: [Int: NoteMermaid.Outcome] = [:]
        let consumer = Task { @MainActor in result = await NoteMermaid.resolve(document, width: 400, appearance: .light) }
        try await eventually { backend.requests.count == 2 }
        #expect(backend.requests.map(\.key.source) == ["first\n", "second\n"])
        await consumer.value
        #expect(!publishedBeforeAbort)
        #expect(Set(backend.aborted) == [0, 1])
        #expect(backend.requests.count == 3)
        #expect(backend.requests[2].abortsAtStart >= 1)
        let firstReason = try #require(fallback(result[1]))
        let secondReason = try #require(fallback(result[5]))
        #expect(renderedImage(result[9]) === picture)
        backend.complete(0, with: .image(picture))
        backend.complete(1, with: .fallback("late failure"))
        let cached = NoteMermaid.cached(document, width: 400, appearance: .light)
        #expect(fallback(cached[1]) == firstReason)
        #expect(fallback(cached[5]) == secondReason)
        #expect(renderedImage(cached[9]) === picture)
    }

    @Test func cancellingOneConsumerDoesNotCancelTheSharedRender() async throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let picture = try image()
        let document = NoteMarkdown.parse(markdown(["shared"]))
        var first: [Int: NoteMermaid.Outcome] = [:]
        var second: [Int: NoteMermaid.Outcome] = [:]
        var entered = 0
        let firstTask = Task { @MainActor in
            entered += 1
            first = await NoteMermaid.resolve(document, width: 400, appearance: .light)
        }
        let secondTask = Task { @MainActor in
            entered += 1
            second = await NoteMermaid.resolve(document, width: 400, appearance: .light)
        }
        try await eventually { entered == 2 && backend.requests.count == 1 }
        firstTask.cancel()
        await firstTask.value
        #expect(first.isEmpty)
        #expect(backend.aborted.isEmpty)
        backend.complete(0, with: .image(picture))
        await secondTask.value
        #expect(backend.requests.count == 1)
        #expect(renderedImage(second[1]) === picture)
        #expect(backend.aborted.isEmpty)
    }

    @Test func replacingTheBackendRejectsItsOldCallbacksEvenForTheSameKey() async throws {
        let firstBackend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = firstBackend
        defer { NoteMermaid.backend = previous }
        let document = NoteMarkdown.parse(markdown(["same key"]))
        var cancelled: [Int: NoteMermaid.Outcome] = [:]
        let consumer = Task { @MainActor in cancelled = await NoteMermaid.resolve(document, width: 400, appearance: .light) }
        try await eventually { firstBackend.requests.count == 1 }
        let secondBackend = Backend()
        let picture = try image()
        secondBackend.answer = { _ in .image(picture) }
        NoteMermaid.backend = secondBackend
        await consumer.value
        #expect(cancelled.isEmpty)
        #expect(firstBackend.aborted == [0])
        let resolved = await NoteMermaid.resolve(document, width: 400, appearance: .light)
        #expect(renderedImage(resolved[1]) === picture)
        firstBackend.complete(0, with: .fallback("old backend"))
        #expect(renderedImage(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) === picture)
    }

    @Test func cacheEvictsByRasterBytesAndKeepsTheRecentlyReadImage() async throws {
        let backend = Backend()
        let picture = try image(width: 2000, height: 2000)
        backend.answer = { _ in .image(picture) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let first = NoteMarkdown.parse(markdown(["one"]))
        let second = NoteMarkdown.parse(markdown(["two"]))
        let third = NoteMarkdown.parse(markdown(["three"]))
        _ = await NoteMermaid.resolve(first, width: 400, appearance: .light)
        _ = await NoteMermaid.resolve(second, width: 400, appearance: .light)
        #expect(renderedImage(NoteMermaid.cached(first, width: 400, appearance: .light)[1]) === picture)
        _ = await NoteMermaid.resolve(third, width: 400, appearance: .light)
        #expect(NoteMermaid.cached(second, width: 400, appearance: .light).isEmpty)
        #expect(renderedImage(NoteMermaid.cached(first, width: 400, appearance: .light)[1]) === picture)
        #expect(renderedImage(NoteMermaid.cached(third, width: 400, appearance: .light)[1]) === picture)
        _ = await NoteMermaid.resolve(second, width: 400, appearance: .light)
        #expect(backend.requests.count == 4)
    }

    @Test func sourceStorageAlsoCountsTowardTheCacheByteLimit() async throws {
        let backend = Backend()
        let picture = try image(width: 2048, height: 2040)
        backend.answer = { _ in .image(picture) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let first = NoteMarkdown.parse(markdown([String(repeating: "a", count: 51_199)]))
        let second = NoteMarkdown.parse(markdown([String(repeating: "b", count: 51_199)]))
        _ = await NoteMermaid.resolve(first, width: 400, appearance: .light)
        _ = await NoteMermaid.resolve(second, width: 400, appearance: .light)
        #expect(NoteMermaid.cached(first, width: 400, appearance: .light).isEmpty)
        #expect(renderedImage(NoteMermaid.cached(second, width: 400, appearance: .light)[1]) === picture)
    }

    @Test func failuresAreCachedWithBoundedDiagnosticStorage() async throws {
        let backend = Backend()
        backend.answer = { _ in .fallback(String(repeating: "failure", count: 100_000)) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let source = markdown(["graph TD; A-->B"])
        let document = NoteMarkdown.parse(source)
        let outcomes = await NoteMermaid.resolve(document, width: 400, appearance: .light)
        let reason = try #require(fallback(outcomes[1]))
        #expect(reason.utf8.count <= 1026)
        #expect(fallback(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) == reason)
        _ = await NoteMermaid.resolve(document, width: 400, appearance: .light)
        #expect(backend.requests.count == 1)
        let text = NoteRenderer(excerpts: [:], source: source, width: 400, diagrams: outcomes).render(document, placeholder: "")
        #expect(text.string.contains("graph TD; A-->B"))
        #expect(text.attribute(.noteMarkdownLine, at: 0, effectiveRange: nil) as? Int == 1)
    }

    @Test func rasterPixelAndDimensionBoundariesAreEnforcedBeforePublication() async throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let cases: [(Int, Int, Bool)] = [(8192, 1, true), (8193, 1, false), (2048, 2048, true), (2049, 2048, false)]
        for (width, height, accepted) in cases {
            let picture = try image(width: width, height: height)
            backend.answer = { _ in .image(picture) }
            let document = NoteMarkdown.parse(markdown(["\(width)x\(height)"]))
            let result = await NoteMermaid.resolve(document, width: 400, appearance: .light)
            if accepted {
                #expect(renderedImage(result[1]) === picture)
            } else {
                #expect(fallback(result[1]) != nil)
                #expect(fallback(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) != nil)
            }
        }
        backend.answer = { _ in .image(NSImage(size: CGSize(width: 20, height: 20))) }
        let invalid = await NoteMermaid.resolve(NoteMarkdown.parse(markdown(["no raster"])), width: 400, appearance: .light)
        #expect(fallback(invalid[1]) != nil)
    }

    @Test func fallbackRowsStayBoundedAndOrdinaryCodeIgnoresDiagramOutcomes() {
        let body = (1...405).map { "source row \($0)" }.joined(separator: "\n")
        let source = markdown([body])
        let renderer = NoteRenderer(excerpts: [:], source: source, width: 400, diagrams: [1: .fallback("unavailable")])
        let text = renderer.render(NoteMarkdown.parse(source), placeholder: "")
        #expect(text.string.contains("source row 400"))
        #expect(!text.string.contains("source row 401"))
        let ordinary = "```swift\nlet answer = 42\n```"
        let unchanged = NoteRenderer(excerpts: [:], source: ordinary, width: 400, diagrams: [1: .fallback("must not appear")])
        let plain = unchanged.render(NoteMarkdown.parse(ordinary), placeholder: "")
        #expect(plain.string == "let answer = 42")
        #expect(!unchanged.fitsWidth)
    }

    @Test func asyncObjectAndDelegatedTextMeasurementsWaitForTheSharedDiagram() async throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let fixture = try DelegatedCallsTests()
        let calls = fixture.delegated()
        let source = markdown(["graph TD; A-->B"])
        var objectSize: CGSize?
        var delegatedSize: JSONValue?
        let object = Task { @MainActor in
            objectSize = try await ObjectMeasure.size(type: .note, props: .object(["markdown": .string(source)]), width: 400, root: fixture.dir)
        }
        let delegated = Task { @MainActor in
            delegatedSize = try await calls.answer(EaslConnection.Call(method: "text.measure", params: .object(["items": [
                .object(["kind": "note", "text": .string(source), "width": 400]),
            ]]))).get()
        }
        try await eventually { backend.requests.count == 1 }
        await Task.yield()
        #expect(objectSize == nil)
        #expect(delegatedSize == nil)
        #expect(backend.requests.first?.key.width == 376)
        backend.complete(0, with: .image(try image(width: 200, height: 300)))
        try await object.value
        try await delegated.value
        let measured = try #require(objectSize)
        #expect(measured.width == 400)
        let size = try #require(delegatedSize?["sizes"]?.array?.first)
        #expect(size["w"]?.number == 400)
        #expect(size["h"]?.number == Double(measured.height))
        #expect(size["tableShortfall"]?.number == 0)
        #expect(backend.requests.count == 1)
    }

    @Test func theGlobalQueueAdmitsOnlyTwoActiveAnd128WaitingKeys() async throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let picture = try image()
        var entered = 0
        var results: [Int: [Int: NoteMermaid.Outcome]] = [:]
        let tasks = (0..<8).map { note in
            Task { @MainActor in
                let document = NoteMarkdown.parse(markdown((0..<20).map { "note \(note) fence \($0)" }))
                entered += 1
                results[note] = await NoteMermaid.resolve(document, width: 400, appearance: .light)
            }
        }
        try await eventually { entered == 8 }
        #expect(backend.requests.count == 2)
        for index in 0..<130 {
            try #require(index < backend.requests.count)
            backend.complete(index, with: .image(picture))
            #expect(backend.requests.count <= index + 3)
        }
        try #require(backend.requests.count == 130)
        for task in tasks { await task.value }
        #expect(results.count == 8)
        let outcomes = results.values.flatMap { $0.values }
        #expect(outcomes.count == 160)
        #expect(outcomes.filter { renderedImage($0) != nil }.count == 130)
        #expect(outcomes.filter { fallback($0) != nil }.count == 30)
        #expect(backend.aborted.isEmpty)
    }

    @Test func sharedConsumersAreBoundedWithoutCancellingTheirCommonJob() async throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let picture = try image()
        let document = NoteMarkdown.parse(markdown(["shared capacity"]))
        var entered = 0
        var results: [Int: [Int: NoteMermaid.Outcome]] = [:]
        let tasks = (0..<257).map { consumer in
            Task { @MainActor in
                entered += 1
                results[consumer] = await NoteMermaid.resolve(document, width: 400, appearance: .light)
            }
        }
        try await eventually { entered == 257 && results.count == 1 }
        #expect(backend.requests.count == 1)
        #expect(backend.aborted.isEmpty)
        backend.complete(0, with: .image(picture))
        for task in tasks { await task.value }
        #expect(results.count == 257)
        let outcomes = results.values.compactMap { $0[1] }
        #expect(outcomes.filter { renderedImage($0) != nil }.count == 256)
        #expect(outcomes.filter { fallback($0) != nil }.count == 1)
        #expect(backend.aborted.isEmpty)
    }

    @Test func smallCachedFailuresAlsoHaveABoundedEntryCount() async {
        let backend = Backend()
        backend.answer = { _ in .fallback("invalid diagram") }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let first = NoteMarkdown.parse(markdown(["entry 0"]))
        for index in 0..<513 {
            _ = await NoteMermaid.resolve(NoteMarkdown.parse(markdown(["entry \(index)"])), width: 400, appearance: .light)
        }
        #expect(NoteMermaid.cached(first, width: 400, appearance: .light).isEmpty)
        let latest = NoteMarkdown.parse(markdown(["entry 512"]))
        #expect(fallback(NoteMermaid.cached(latest, width: 400, appearance: .light)[1]) == "invalid diagram")
        #expect(backend.requests.count == 513)
    }

    @Test func cancellingTheLastConsumerAbortsActiveJobsDropsQueuedJobsAndReleasesPermits() async throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let picture = try image()
        let stale = NoteMarkdown.parse(markdown(["stale first", "stale second", "stale queued"]))
        let export = NoteMarkdown.parse(markdown(["export"]))
        var cancelled: [Int: NoteMermaid.Outcome] = [:]
        var exported: [Int: NoteMermaid.Outcome] = [:]
        let staleTask = Task { @MainActor in cancelled = await NoteMermaid.resolve(stale, width: 400, appearance: .light) }
        try await eventually { backend.requests.count == 2 }
        var exportEntered = false
        let exportTask = Task { @MainActor in
            exportEntered = true
            exported = await NoteMermaid.resolve(export, width: 400, appearance: .light)
        }
        try await eventually { exportEntered }
        staleTask.cancel()
        await staleTask.value
        #expect(cancelled.isEmpty)
        #expect(Set(backend.aborted) == [0, 1])
        #expect(backend.requests.map(\.key.source) == ["stale first\n", "stale second\n", "export\n"])
        #expect(NoteMermaid.cached(stale, width: 400, appearance: .light).isEmpty)
        backend.complete(0, with: .image(picture))
        backend.complete(1, with: .fallback("late cancelled result"))
        #expect(NoteMermaid.cached(stale, width: 400, appearance: .light).isEmpty)
        backend.complete(2, with: .image(picture))
        await exportTask.value
        #expect(renderedImage(exported[1]) === picture)
        #expect(backend.requests.count == 3)
    }

    @Test func fencePresenceFindsNestedMermaidWithoutAdmittingOtherCode() {
        for source in ["ordinary prose", "`mermaid`", "```swift\nlet x = 1\n```", "```mermaid extra\nx\n```"] {
            #expect(!NoteMermaid.hasFences(in: NoteMarkdown.parse(source)))
        }
        #expect(NoteMermaid.hasFences(in: NoteMarkdown.parse("> - item\n>\n>   ```mermaid\n>   graph TD; A-->B\n>   ```")))
    }

    @Test func synchronousCompletionFeedsTheSameCacheAsAsyncConsumers() async throws {
        let backend = Backend()
        let picture = try image()
        backend.answer = { _ in .image(picture) }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = NoteMarkdown.parse(markdown(["inline completion"]))
        var completions = 0
        var result: [Int: NoteMermaid.Outcome] = [:]
        let cancel = NoteMermaid.request(document, width: 400.1, appearance: .light) {
            completions += 1
            result = $0
        }
        #expect(completions == 1)
        #expect(renderedImage(result[1]) === picture)
        let exported = await NoteMermaid.resolve(document, width: 400.9, appearance: .light)
        #expect(renderedImage(exported[1]) === picture)
        #expect(backend.requests.count == 1)
        cancel()
        cancel()
        #expect(completions == 1)
        #expect(backend.aborted.isEmpty)
    }

    @Test func synchronousHandoffKeepsAnInFlightImageAcrossProseAndFractionalWidthChanges() throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let picture = try image()
        let fence = markdown(["graph TD; A-->B"])
        let oldSource = "Old prose.\n\n" + fence
        let updatedSource = "Updated prose.\n\nAnother paragraph.\n\n" + fence
        var oldCompletions = 0
        var oldResult: [Int: NoteMermaid.Outcome] = [:]
        var updatedCompletions = 0
        var updatedResult: [Int: NoteMermaid.Outcome] = [:]
        let cancelOld = NoteMermaid.request(NoteMarkdown.parse(oldSource), width: 400.1, appearance: .light) {
            oldCompletions += 1
            oldResult = $0
        }
        #expect(backend.requests.count == 1)
        let updatedDocument = NoteMarkdown.parse(updatedSource)
        let cancelUpdated = NoteMermaid.request(updatedDocument, width: 400.9, appearance: .light) {
            updatedCompletions += 1
            updatedResult = $0
        }
        cancelOld()
        #expect(oldCompletions == 1)
        #expect(oldResult.isEmpty)
        #expect(updatedCompletions == 0)
        #expect(backend.requests.count == 1)
        #expect(backend.aborted.isEmpty)
        backend.complete(0, with: .image(picture))
        #expect(updatedCompletions == 1)
        #expect(Set(updatedResult.keys) == [5])
        #expect(renderedImage(updatedResult[5]) === picture)
        let text = NoteRenderer(excerpts: [:], source: updatedSource, width: 400.9, diagrams: updatedResult)
            .render(updatedDocument, placeholder: "")
        #expect(text.string.contains("Updated prose."))
        #expect(!text.string.contains("Old prose."))
        let location = (text.string as NSString).range(of: "\u{FFFC}").location
        try #require(location != NSNotFound)
        #expect(text.attribute(.attachment, at: location, effectiveRange: nil) != nil)
        #expect(text.attribute(.noteMarkdownLine, at: location, effectiveRange: nil) as? Int == 5)
        cancelOld()
        cancelUpdated()
        #expect(oldCompletions == 1)
        #expect(updatedCompletions == 1)
        #expect(backend.aborted.isEmpty)
    }

    @Test func synchronousHandoffKeepsQueuedFencesAndAbortsOnlyRemovedWork() throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let kept = try image(width: 100)
        let queued = try image(width: 110)
        let added = try image(width: 120)
        let oldDocument = NoteMarkdown.parse(markdown(["kept", "removed", "queued"]))
        let updatedDocument = NoteMarkdown.parse("Updated prose.\n\n" + markdown(["queued", "kept", "added"]))
        var oldCompletions = 0
        var updatedCompletions = 0
        var result: [Int: NoteMermaid.Outcome] = [:]
        let cancelOld = NoteMermaid.request(oldDocument, width: 400, appearance: .light) { _ in oldCompletions += 1 }
        #expect(backend.requests.map(\.key.source) == ["kept\n", "removed\n"])
        let cancelUpdated = NoteMermaid.request(updatedDocument, width: 400, appearance: .light) {
            updatedCompletions += 1
            result = $0
        }
        cancelOld()
        #expect(oldCompletions == 1)
        #expect(backend.aborted == [1])
        #expect(backend.requests.map(\.key.source) == ["kept\n", "removed\n", "queued\n"])
        backend.complete(0, with: .image(kept))
        #expect(backend.requests.map(\.key.source) == ["kept\n", "removed\n", "queued\n", "added\n"])
        backend.complete(2, with: .image(queued))
        #expect(updatedCompletions == 0)
        backend.complete(3, with: .image(added))
        #expect(updatedCompletions == 1)
        #expect(Set(result.keys) == [3, 7, 11])
        #expect(renderedImage(result[3]) === queued)
        #expect(renderedImage(result[7]) === kept)
        #expect(renderedImage(result[11]) === added)
        backend.complete(1, with: .fallback("late removed result"))
        #expect(updatedCompletions == 1)
        cancelUpdated()
        #expect(backend.aborted == [1])
    }

    @Test func synchronousLastConsumerCancellationAbortsImmediatelyAndRejectsLateImages() throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = NoteMarkdown.parse(markdown(["cancel and retry"]))
        let stale = try image(width: 110)
        let current = try image(width: 120)
        var cancelledCompletions = 0
        var cancelledResult: [Int: NoteMermaid.Outcome] = [:]
        let cancelOld = NoteMermaid.request(document, width: 400, appearance: .light) {
            cancelledCompletions += 1
            cancelledResult = $0
        }
        cancelOld()
        #expect(backend.aborted == [0])
        #expect(cancelledCompletions == 1)
        #expect(cancelledResult.isEmpty)
        var currentCompletions = 0
        var currentResult: [Int: NoteMermaid.Outcome] = [:]
        let cancelCurrent = NoteMermaid.request(document, width: 400, appearance: .light) {
            currentCompletions += 1
            currentResult = $0
        }
        #expect(backend.requests.count == 2)
        backend.complete(0, with: .image(stale))
        #expect(currentCompletions == 0)
        #expect(NoteMermaid.cached(document, width: 400, appearance: .light).isEmpty)
        backend.complete(1, with: .image(current))
        #expect(currentCompletions == 1)
        #expect(renderedImage(currentResult[1]) === current)
        cancelOld()
        cancelCurrent()
        #expect(cancelledCompletions == 1)
        #expect(currentCompletions == 1)
        #expect(backend.aborted == [0])
    }

    @Test func cancellingASynchronousLiveConsumerLeavesAnAsyncExportSubscribed() async throws {
        let backend = Backend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let picture = try image()
        let document = NoteMarkdown.parse(markdown(["live and export"]))
        var exported: [Int: NoteMermaid.Outcome] = [:]
        let export = Task { @MainActor in exported = await NoteMermaid.resolve(document, width: 400, appearance: .light) }
        try await eventually { backend.requests.count == 1 }
        var liveCompletions = 0
        var liveResult: [Int: NoteMermaid.Outcome] = [:]
        let cancelLive = NoteMermaid.request(document, width: 400, appearance: .light) {
            liveCompletions += 1
            liveResult = $0
        }
        cancelLive()
        #expect(liveCompletions == 1)
        #expect(liveResult.isEmpty)
        #expect(backend.aborted.isEmpty)
        backend.complete(0, with: .image(picture))
        await export.value
        #expect(renderedImage(exported[1]) === picture)
        #expect(backend.requests.count == 1)
        #expect(backend.aborted.isEmpty)
        #expect(liveCompletions == 1)
    }
}
