import AppKit
import Foundation
import Markdown
import Testing
@testable import CanvasCore

extension NoteMermaidTests {
    @MainActor
    private final class PreparedBackend: NoteMermaidPreparingBackend {
        struct Request {
            let key: NoteMermaid.Key
            let ready: @MainActor () -> Void
            let failed: @MainActor (String) -> Void
            let completion: @MainActor (NoteMermaid.Outcome) -> Void
        }

        var requests: [Request] = []
        var aborted: [Int] = []
        var onStart: ((Int) -> Void)?
        var onAbort: ((Int) -> Void)?

        func start(_ key: NoteMermaid.Key, ready: @escaping @MainActor () -> Void,
                   failed: @escaping @MainActor (String) -> Void,
                   completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void) {
            let index = requests.count
            requests.append(Request(key: key, ready: ready, failed: failed, completion: completion))
            onStart?(index)
            return { [weak self] in
                guard let self else { return }
                aborted.append(index)
                onAbort?(index)
            }
        }
    }

    private func lifecycleDocument(_ sources: [String] = ["graph TD; A-->B"]) -> Document {
        NoteMarkdown.parse(sources.map { "```mermaid\n\($0)\n```" }.joined(separator: "\n\n"))
    }

    private func lifecycleImage() throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 80, bitsPerPixel: 32))
        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.addRepresentation(bitmap)
        return image
    }

    private func lifecycleRaster(_ outcome: NoteMermaid.Outcome?) -> NSImage? {
        if case .image(let image)? = outcome { return image }
        return nil
    }

    private func lifecycleReason(_ outcome: NoteMermaid.Outcome?) -> String? {
        if case .fallback(let reason)? = outcome { return reason }
        return nil
    }

    private func lifecycleEventually(within duration: Duration = .seconds(1), _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + duration
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(predicate())
    }

    @Test(.timeLimit(.minutes(1))) func preparationDoesNotSpendTheWarmRenderingBudget() async throws {
        let backend = PreparedBackend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        let picture = try lifecycleImage()
        var result: [Int: NoteMermaid.Outcome]?
        let cancel = NoteMermaid.request(document, width: 400, appearance: .light) { result = $0 }
        defer { cancel() }
        try #require(backend.requests.count == 1)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(result == nil)
        #expect(backend.aborted.isEmpty)
        #expect(backend.requests.count == 1)
        backend.requests[0].ready()
        try await Task.sleep(for: .milliseconds(1100))
        #expect(result == nil)
        backend.requests[0].completion(.image(picture))
        #expect(lifecycleRaster(result?[1]) === picture)
        #expect(backend.aborted.isEmpty)
        #expect(backend.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func preparationHasAFiniteBoundAndRetriesBeforePublishing() async throws {
        let backend = PreparedBackend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        let picture = try lifecycleImage()
        var result: [Int: NoteMermaid.Outcome]?
        let cancel = NoteMermaid.request(document, width: 400, appearance: .light) { result = $0 }
        defer { cancel() }
        try await lifecycleEventually(within: .seconds(12)) { backend.requests.count == 2 }
        #expect(backend.aborted == [0])
        #expect(result == nil)
        #expect(NoteMermaid.cached(document, width: 400, appearance: .light).isEmpty)
        backend.requests[0].ready()
        backend.requests[0].completion(.fallback("stale cold result"))
        #expect(result == nil)
        backend.requests[1].ready()
        backend.requests[1].completion(.image(picture))
        #expect(lifecycleRaster(result?[1]) === picture)
        #expect(lifecycleRaster(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) === picture)
        #expect(backend.requests.count == 2)
    }

    @Test func rendererFailureRetriesOnceThenCachesOnlyTheFinalFailure() {
        let backend = PreparedBackend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        var results: [[Int: NoteMermaid.Outcome]] = []
        let cancel = NoteMermaid.request(document, width: 400, appearance: .light) { results.append($0) }
        defer { cancel() }
        backend.requests[0].failed("cold process failed")
        #expect(backend.requests.count == 2)
        #expect(results.isEmpty)
        #expect(NoteMermaid.cached(document, width: 400, appearance: .light).isEmpty)
        backend.requests[0].ready()
        backend.requests[0].failed("late first failure")
        backend.requests[0].completion(.fallback("late first completion"))
        #expect(results.isEmpty)
        #expect(backend.requests.count == 2)
        backend.requests[1].ready()
        backend.requests[1].failed("retry process failed")
        #expect(results.count == 1)
        #expect(lifecycleReason(results.first?[1]) == "retry process failed")
        #expect(lifecycleReason(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) == "retry process failed")
        _ = NoteMermaid.request(document, width: 400, appearance: .light) { results.append($0) }
        #expect(results.count == 2)
        #expect(backend.requests.count == 2)
    }

    @Test func knownContentFailureDoesNotRetry() {
        let backend = PreparedBackend()
        backend.onStart = { [weak backend] index in
            guard let backend else { return }
            backend.requests[index].ready()
            backend.requests[index].completion(.fallback("invalid Mermaid syntax"))
        }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        var result: [Int: NoteMermaid.Outcome] = [:]
        _ = NoteMermaid.request(document, width: 400, appearance: .light) { result = $0 }
        #expect(lifecycleReason(result[1]) == "invalid Mermaid syntax")
        #expect(lifecycleReason(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) == "invalid Mermaid syntax")
        #expect(backend.requests.count == 1)
        #expect(backend.aborted.isEmpty)
    }

    @Test func invalidRasterIsAContentFailureWithoutARetry() {
        let backend = PreparedBackend()
        backend.onStart = { [weak backend] index in
            backend?.requests[index].ready()
            backend?.requests[index].completion(.image(NSImage(size: NSSize(width: 20, height: 10))))
        }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        var result: [Int: NoteMermaid.Outcome] = [:]
        _ = NoteMermaid.request(document, width: 400, appearance: .light) { result = $0 }
        #expect(lifecycleReason(result[1]) != nil)
        #expect(lifecycleReason(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) != nil)
        #expect(backend.requests.count == 1)
        #expect(backend.aborted.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func warmHostileDeadlineAbortsWithoutRetryOrReadinessExtension() async throws {
        let backend = PreparedBackend()
        backend.onStart = { [weak backend] index in backend?.requests[index].ready() }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        var result: [Int: NoteMermaid.Outcome]?
        var publishedBeforeAbort = false
        backend.onAbort = { _ in
            publishedBeforeAbort = !NoteMermaid.cached(document, width: 400, appearance: .light).isEmpty
        }
        let start = ContinuousClock.now
        let cancel = NoteMermaid.request(document, width: 400, appearance: .light) { result = $0 }
        defer { cancel() }
        try await Task.sleep(for: .milliseconds(1200))
        backend.requests[0].ready()
        try await lifecycleEventually(within: .milliseconds(1500)) { result != nil }
        #expect(ContinuousClock.now - start >= .milliseconds(1900))
        #expect(backend.requests.count == 1)
        #expect(backend.aborted == [0])
        #expect(!publishedBeforeAbort)
        let reason = try #require(lifecycleReason(result?[1]))
        backend.requests[0].failed("late failure")
        #expect(lifecycleReason(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) == reason)
        #expect(backend.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func deadlineAbortCanReplaceTheBackendWithoutCachingTheOldFailure() async throws {
        let first = PreparedBackend()
        let replacement = PreparedBackend()
        let picture = try lifecycleImage()
        let document = lifecycleDocument()
        first.onStart = { [weak first] index in first?.requests[index].ready() }
        replacement.onStart = { [weak replacement] index in
            replacement?.requests[index].ready()
            replacement?.requests[index].completion(.image(picture))
        }
        var replacementResult: [Int: NoteMermaid.Outcome]?
        first.onAbort = { _ in
            NoteMermaid.backend = replacement
            _ = NoteMermaid.request(document, width: 400, appearance: .light) { replacementResult = $0 }
        }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = first
        defer { NoteMermaid.backend = previous }
        var oldResult: [Int: NoteMermaid.Outcome]?
        let cancel = NoteMermaid.request(document, width: 400, appearance: .light) { oldResult = $0 }
        defer { cancel() }
        try await lifecycleEventually(within: .seconds(3)) { replacementResult != nil }
        #expect(oldResult?.isEmpty == true)
        #expect(first.aborted == [0])
        #expect(first.requests.count == 1)
        #expect(replacement.requests.count == 1)
        #expect(lifecycleRaster(replacementResult?[1]) === picture)
        #expect(lifecycleRaster(NoteMermaid.cached(document, width: 400, appearance: .light)[1]) === picture)
    }

    @Test func sharedPreparationAndRetrySurviveOneConsumerCancelling() throws {
        let backend = PreparedBackend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        let picture = try lifecycleImage()
        var first: [Int: NoteMermaid.Outcome]?
        var second: [Int: NoteMermaid.Outcome]?
        let cancelFirst = NoteMermaid.request(document, width: 400, appearance: .light) { first = $0 }
        let cancelSecond = NoteMermaid.request(document, width: 400, appearance: .light) { second = $0 }
        defer { cancelSecond() }
        cancelFirst()
        #expect(first?.isEmpty == true)
        #expect(second == nil)
        #expect(backend.aborted.isEmpty)
        backend.requests[0].failed("restart process")
        #expect(backend.requests.count == 2)
        backend.requests[1].ready()
        backend.requests[1].completion(.image(picture))
        #expect(lifecycleRaster(second?[1]) === picture)
        #expect(first?.isEmpty == true)
    }

    @Test func cancellingTheRetryAbortsItAndRejectsEveryOldCallback() throws {
        let backend = PreparedBackend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        let picture = try lifecycleImage()
        var completions = 0
        let cancel = NoteMermaid.request(document, width: 400, appearance: .light) { outcomes in
            completions += 1
            #expect(outcomes.isEmpty)
        }
        backend.requests[0].failed("restart process")
        cancel()
        cancel()
        #expect(backend.aborted == [1])
        for request in backend.requests {
            request.ready()
            request.failed("stale process")
            request.completion(.image(picture))
        }
        #expect(completions == 1)
        #expect(backend.requests.count == 2)
        #expect(NoteMermaid.cached(document, width: 400, appearance: .light).isEmpty)
    }

    @Test func cancellationDuringSynchronousStartAbortsWhenTheHandleReturns() {
        let first = PreparedBackend()
        let replacement = PreparedBackend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = first
        defer { NoteMermaid.backend = previous }
        first.onStart = { _ in NoteMermaid.backend = replacement }
        let document = lifecycleDocument()
        var cancelled: [Int: NoteMermaid.Outcome]?
        _ = NoteMermaid.request(document, width: 400, appearance: .light) { cancelled = $0 }
        #expect(cancelled?.isEmpty == true)
        #expect(first.aborted == [0])
        var result: [Int: NoteMermaid.Outcome]?
        let cancel = NoteMermaid.request(document, width: 400, appearance: .light) { result = $0 }
        defer { cancel() }
        first.requests[0].ready()
        first.requests[0].failed("old renderer")
        first.requests[0].completion(.fallback("old content"))
        #expect(result == nil)
        #expect(replacement.requests.count == 1)
        replacement.requests[0].ready()
        replacement.requests[0].completion(.fallback("new content"))
        #expect(lifecycleReason(result?[1]) == "new content")
    }

    @Test func synchronousRetryAndReentrantCompletionUseTheReplacementBackend() throws {
        let first = PreparedBackend()
        let replacement = PreparedBackend()
        let picture = try lifecycleImage()
        first.onStart = { [weak first] index in
            guard let first else { return }
            if index == 0 {
                first.requests[index].failed("cold start failed")
            } else {
                first.requests[index].ready()
                first.requests[index].completion(.image(picture))
            }
        }
        replacement.onStart = { [weak replacement] index in
            guard let replacement else { return }
            replacement.requests[index].ready()
            replacement.requests[index].completion(.fallback("replacement content"))
        }
        let previous = NoteMermaid.backend
        NoteMermaid.backend = first
        defer { NoteMermaid.backend = previous }
        let document = lifecycleDocument()
        var firstResult: [Int: NoteMermaid.Outcome]?
        var nestedResult: [Int: NoteMermaid.Outcome]?
        _ = NoteMermaid.request(document, width: 400, appearance: .light) { result in
            firstResult = result
            NoteMermaid.backend = replacement
            _ = NoteMermaid.request(document, width: 400, appearance: .light) { nestedResult = $0 }
        }
        #expect(lifecycleRaster(firstResult?[1]) === picture)
        #expect(lifecycleReason(nestedResult?[1]) == "replacement content")
        #expect(first.requests.count == 2)
        #expect(replacement.requests.count == 1)
        #expect(first.aborted.isEmpty)
    }

    @Test func preparationAndRetriesShareTheTwoWorkerLimit() throws {
        let backend = PreparedBackend()
        let previous = NoteMermaid.backend
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let picture = try lifecycleImage()
        let document = lifecycleDocument(["first", "second", "third"])
        var result: [Int: NoteMermaid.Outcome]?
        let cancel = NoteMermaid.request(document, width: 400, appearance: .light) { result = $0 }
        defer { cancel() }
        #expect(backend.requests.map(\.key.source) == ["first\n", "second\n"])
        backend.requests[0].failed("cold first renderer")
        #expect(backend.requests.map(\.key.source) == ["first\n", "second\n", "third\n"])
        backend.requests[1].ready()
        #expect(backend.requests.count == 3)
        backend.requests[1].completion(.image(picture))
        #expect(backend.requests.map(\.key.source) == ["first\n", "second\n", "third\n", "first\n"])
        backend.requests[2].ready()
        backend.requests[3].ready()
        #expect(backend.requests.count == 4)
        backend.requests[2].completion(.image(picture))
        #expect(result == nil)
        backend.requests[3].completion(.image(picture))
        #expect(result?.count == 3)
        #expect([1, 5, 9].allSatisfy { lifecycleRaster(result?[$0]) === picture })
        #expect(backend.aborted.isEmpty)
    }
}
