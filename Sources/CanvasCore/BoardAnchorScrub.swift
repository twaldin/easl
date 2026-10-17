import Foundation

/// Stored anchors are metadata, not edits. Reconcile before a live board can publish them.
enum BoardAnchorScrub {
    private enum Candidate: Sendable {
        case note(index: Int, markdown: String, fences: [NoteMarkdown.AnchoredFence])
        case code(index: Int, path: String)
    }

    static func normalize(_ snapshot: BoardSnapshot) -> BoardSnapshot? {
        let candidates = snapshot.objects.enumerated().compactMap { index, object -> Candidate? in
            switch object.type {
            case .note:
                guard let markdown = object.props["markdown"]?.string else { return nil }
                let fences = NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(markdown)).filter {
                    NoteFence.tokens($0.key).contains { $0.hasPrefix("anchor=") }
                }
                return fences.isEmpty ? nil : .note(index: index, markdown: markdown, fences: fences)
            case .code:
                guard let anchor = object.props["anchor"], anchor != .null,
                      let path = object.props["path"]?.string else { return nil }
                return .code(index: index, path: path)
            default:
                return nil
            }
        }
        guard !candidates.isEmpty else { return nil }
        let result = Locked<BoardSnapshot?>(nil)
        let finished = DispatchSemaphore(value: 0)
        // Load is synchronous. This task touches only Sendable snapshots and never the main actor.
        Task.detached {
            let normalized = await scrub(snapshot, candidates: candidates)
            result.withLock { $0 = normalized }
            finished.signal()
        }
        finished.wait()
        return result.withLock { $0 }
    }

    private static func scrub(_ snapshot: BoardSnapshot, candidates: [Candidate]) async -> BoardSnapshot? {
        let root = URL(fileURLWithPath: snapshot.root)
        let areas = BoardAreas(boardRoot: root)
        var normalized = snapshot
        var changed = false
        for candidate in candidates {
            switch candidate {
            case .note(let index, let markdown, let fences):
                let reading = await LinkReading.resolve(props: snapshot.objects[index].props, boardRoot: root)
                var lines: [Int] = []
                for fence in reading.fences(fences) {
                    if await refused(fence.fence, reading: reading, areas: areas) { lines += fence.lines }
                }
                let cleaned = NoteMarkdown.removingAnchors(markdown, fenceLines: lines)
                if cleaned != markdown, var props = normalized.objects[index].props.object {
                    props["markdown"] = .string(cleaned)
                    normalized.objects[index].props = .object(props)
                    changed = true
                }
            case .code(let index, let path):
                let props = snapshot.objects[index].props
                let reading: LinkReading
                if RefSource.ref(of: props) != nil {
                    reading = await LinkReading.resolve(props: props, boardRoot: root)
                } else {
                    reading = LinkReading(root: root)
                }
                var fence = NoteFence(path: path, commit: props["pinnedCommit"]?.string.flatMap { $0.isEmpty ? nil : $0 })
                if let source = reading.ref { fence = source.fence(fence) }
                else if fence.commit == nil { fence.commit = reading.commit }
                if await refused(fence, reading: reading, areas: areas), var fields = normalized.objects[index].props.object {
                    fields.removeValue(forKey: "anchor")
                    normalized.objects[index].props = .object(fields)
                    changed = true
                }
            }
        }
        return changed ? normalized : nil
    }

    private static func refused(_ fence: NoteFence, reading: LinkReading, areas: BoardAreas) async -> Bool {
        guard areas.permits(root: reading.root) else { return true }
        guard let path = fence.path else { return false }
        guard areas.written(Board.hostPath(path, under: reading.root.path)) != nil else { return true }
        do {
            let file = try await areas.authorize(path, commit: fence.commit, root: reading.root)
            if case .live(let real) = file {
                let descriptor = try BoardAreas.openNoFollow(real)
                close(descriptor)
            }
            return false
        } catch NoteSourceError.refused {
            return true
        } catch {
            return false
        }
    }
}
