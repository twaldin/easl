import Foundation

/// Go to Next Needs-You (⌘J) across every open board: the app's order of visits, as a pure
/// function of what each board lists (`NeedsYouItem.all`) so it can be tested without windows.
///
/// A board is toured as it always was (blocked agents first, then the rest, each in reading
/// order, one press moving to the item after the one visited last). Once there is nothing after
/// it, the tour goes on to the next open board that has something, at its first item, and after
/// the last board it wraps around. The boards go in tab/window order starting after the board
/// the user is on, so a given board always has the same successor however the tour got there.
public enum NeedsYouTour {
    /// An open board and what needs the user on it, in its own visiting order.
    public struct Entry: Equatable, Sendable {
        public var board: BoardID
        public var items: [NeedsYouItem]

        public init(board: BoardID, items: [NeedsYouItem]) {
            self.board = board
            self.items = items
        }
    }

    /// Where the tour goes: an item of one of the boards.
    public struct Stop: Equatable, Sendable {
        public var board: BoardID
        public var item: NeedsYouItem

        public init(board: BoardID, item: NeedsYouItem) {
            self.board = board
            self.item = item
        }
    }

    /// The next stop for a press on `current` (one of `boards`, the open boards in tab/window
    /// order). `last` is the item visited last on `current` while the user is still on it, nil
    /// from anywhere else: the current board then starts at its first item, and with nothing
    /// there the tour looks at the boards after it, around to the ones before.
    ///
    /// With a `last`, the current board's next item comes first. When it has none (`last` was its
    /// final item, or marked and acknowledged since) the first item of the next board with any;
    /// when no other board has one, the current board's first, as a lone board always wrapped.
    /// Nil when no board needs the user.
    public static func next(from current: BoardID, after last: NeedsYouItem?, in boards: [Entry]) -> Stop? {
        func first(of entry: Entry) -> Stop? { entry.items.first.map { Stop(board: entry.board, item: $0) } }
        guard let start = boards.firstIndex(where: { $0.board == current }) else {
            return boards.lazy.compactMap(first(of:)).first
        }
        let here = boards[start]
        if let last {
            if let item = NeedsYouItem.following(last, in: here.items) { return Stop(board: here.board, item: item) }
        } else if let stop = first(of: here) {
            return stop
        }
        let others = boards[(start + 1)...] + boards[..<start]
        return others.lazy.compactMap(first(of:)).first ?? first(of: here)
    }

    /// A board's window or tab title with the number of things that need the user on it:
    /// "easl (2)", just the name when nothing does. The Window menu lists boards by it too.
    public static func title(_ name: String, needing count: Int) -> String {
        count > 0 ? "\(name) (\(count))" : name
    }
}

extension NeedsYouItem {
    /// The item after `last` in visiting order, nil when it was the last: `next(after:in:)`
    /// without wrapping around, for a tour that goes on to another board instead.
    static func following(_ last: NeedsYouItem, in items: [NeedsYouItem]) -> NeedsYouItem? {
        items.first { precedes(last, $0) && $0.id != last.id }
    }
}
