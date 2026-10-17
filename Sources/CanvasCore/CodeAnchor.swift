import Foundation

/// A code tile's range kept on the code it showed (docs/contracts.md "Code tiles"): it resolves
/// through `NoteAnchor` exactly as a note fence's line range does, by `props.anchor` (the range's
/// first line, which the tile writes back) and the text the tile last saw there.
public enum CodeAnchor {
    /// The fence a code tile's range resolves as; nil for a tile that doesn't anchor: a follow
    /// tile (it re-aims itself), one pinned to a commit (its text never changes), or one without
    /// a range.
    public static func fence(_ props: JSONValue) -> NoteFence? {
        guard props["followOf"]?.string == nil, props["pinnedCommit"]?.string.map(\.isEmpty) ?? true,
              let path = props["path"]?.string, !path.isEmpty, let start = props["range"]?["start"]?.int else { return nil }
        let end = max(start, props["range"]?["end"]?.int ?? start)
        return NoteFence(path: path, lines: LineRange(start: start, end: end), anchor: props["anchor"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Resolves metadata only from a board-authorized read, never the tile's display document.
    static func excerpt(props: JSONValue, boardRoot: URL, captured: [String]? = nil) async -> NoteExcerpt? {
        guard let fence = fence(props) else { return nil }
        let areas = BoardAreas(boardRoot: boardRoot)
        if let ref = RefSource.ref(of: props) {
            do {
                let source = try await RefSource.resolve(ref: ref, lastKnownSha: props["refSha"]?.string, boardRoot: boardRoot)
                return await NoteSource.excerpt(for: source.fence(fence), root: source.root, captured: captured, within: areas)
            } catch {
                return NoteExcerpt(path: fence.path ?? "", range: nil, lines: [], status: .stale(RefSource.describe(error, ref: ref)), missing: true)
            }
        }
        return await NoteSource.excerpt(for: fence, root: boardRoot, captured: captured, within: areas)
    }

    /// The anchor written back for `range` of `source`: its first line, trimmed; nil when blank.
    public static func anchor(of range: LineRange, in source: [String]) -> String? {
        guard range.start >= 1, range.start <= source.count else { return nil }
        let text = source[range.start - 1].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
