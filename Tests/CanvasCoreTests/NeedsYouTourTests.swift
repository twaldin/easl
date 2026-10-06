import Foundation
import Testing
import CanvasCore

/// ⌘J across the open boards (`NeedsYouTour`): the order boards are visited in, and what a press
/// does when the current board has nothing after the item visited last.
struct NeedsYouTourTests {
    private func item(_ id: ObjectID, _ reason: NeedsYouItem.Reason = .blocked, y: Double = 0) -> NeedsYouItem {
        NeedsYouItem(id: id, reason: reason, message: nil, frame: Frame(x: 0, y: y, w: 100, h: 100))
    }

    /// The app's side of a tour: each board remembers the item ⌘J visited on it last and what has
    /// the user's place there (`CanvasView.needsYouCursor`), a press starts from the board
    /// the user is on, and visiting a marked item acknowledges it (it leaves the board's list).
    private struct Session {
        var boards: [NeedsYouTour.Entry]
        var current: BoardID
        var last: [BoardID: NeedsYouItem] = [:]
        var placed: [BoardID: ObjectID] = [:]

        init(_ boards: [NeedsYouTour.Entry], on current: BoardID) {
            self.boards = boards
            self.current = current
        }

        /// The user moves to `board` and puts the keyboard on `id` (or nothing).
        mutating func goTo(_ board: BoardID, placing id: ObjectID? = nil) {
            current = board
            placed[board] = id
        }

        @discardableResult
        mutating func press() -> NeedsYouTour.Stop? {
            let cursor = last[current].flatMap { $0.id == placed[current] ? $0 : nil }
            guard let stop = NeedsYouTour.next(from: current, after: cursor, in: boards) else { return nil }
            current = stop.board
            last[stop.board] = stop.item
            placed[stop.board] = stop.item.id
            if stop.item.reason == .marked, let index = boards.firstIndex(where: { $0.board == stop.board }) {
                boards[index].items.removeAll { $0.id == stop.item.id }
            }
            return stop
        }

        mutating func presses(_ count: Int) -> [String] {
            (0..<count).map { _ in press().map { "\($0.board):\($0.item.id)" } ?? "nothing" }
        }
    }

    @Test func aTourVisitsEachBoardsItemsThenTheNextBoardAndWrapsAround() {
        var session = Session([
            .init(board: "A", items: [item("a1", y: 0), item("a2", .done, y: 200)]),
            .init(board: "B", items: [item("b1", y: 0)]),
            .init(board: "C", items: [item("c1", .marked, y: 0), item("c2", .done, y: 100)]),
        ], on: "A")
        #expect(session.presses(8) == ["A:a1", "A:a2", "B:b1", "C:c1", "C:c2", "A:a1", "A:a2", "B:b1"], "current board first, then the others in order, around")
    }

    @Test func theBoardsAfterTheCurrentOneComeFirstSoTheTourStaysACycle() {
        var session = Session([
            .init(board: "A", items: [item("a1")]), .init(board: "B", items: [item("b1")]), .init(board: "C", items: [item("c1")]),
        ], on: "B")
        #expect(session.presses(7) == ["B:b1", "C:c1", "A:a1", "B:b1", "C:c1", "A:a1", "B:b1"], "from the middle board: onward through the tabs, then the ones before it, never back and forth between two")
    }

    @Test func aBoardWithNothingIsSkippedAndNothingAnywhereSaysSo() {
        var session = Session([
            .init(board: "A", items: [item("a1")]), .init(board: "B", items: []), .init(board: "C", items: [item("c1", .done)]),
        ], on: "A")
        #expect(session.presses(4) == ["A:a1", "C:c1", "A:a1", "C:c1"])
        session.boards[0].items = []
        session.boards[2].items = []
        #expect(session.presses(1) == ["nothing"])
        #expect(NeedsYouTour.next(from: "A", after: nil, in: []) == nil)
    }

    @Test func aBoardWithNothingHandsOverToTheFirstBoardThatHasSomething() {
        var session = Session([
            .init(board: "A", items: []), .init(board: "B", items: []), .init(board: "C", items: [item("c1"), item("c2", y: 50)]),
        ], on: "A")
        #expect(session.presses(3) == ["C:c1", "C:c2", "C:c1"], "the other boards' items, and only a lone board with items wraps within itself")
    }

    @Test func fromAnywhereElseTheCurrentBoardStartsAtItsFirstItem() {
        let boards: [NeedsYouTour.Entry] = [
            .init(board: "A", items: [item("a1", y: 0), item("a2", y: 100)]), .init(board: "B", items: [item("b1")]),
        ]
        var session = Session(boards, on: "B")
        session.last["B"] = item("b1")
        session.placed["B"] = "elsewhere"
        #expect(session.press()?.item.id == "b1", "the keyboard isn't on what was visited last: B's first, not A's")
        session.goTo("A")
        #expect(session.press()?.item.id == "a1", "back on A with the keyboard nowhere in particular: its first item")
        session.goTo("A", placing: "a1")
        #expect(session.press()?.item.id == "a2", "on the item visited last: the one after it")
    }

    @Test func aMarkedItemAcknowledgedOnArrivalStillHasItsPlaceInTheTour() {
        var session = Session([
            .init(board: "A", items: [item("a1", .marked, y: 0), item("a2", .marked, y: 100)]), .init(board: "B", items: [item("b1", .marked, y: 0)]),
        ], on: "A")
        #expect(session.presses(5) == ["A:a1", "A:a2", "B:b1", "nothing", "nothing"], "each marker clears as it is visited, and the tour ends when none is left")
    }

    @Test func aBlockedAgentStaysListedSoALoneBoardKeepsWrappingAndOthersAreStillReached() {
        var session = Session([
            .init(board: "A", items: [item("a1")]), .init(board: "B", items: [item("b1", .marked)]),
        ], on: "A")
        #expect(session.presses(5) == ["A:a1", "B:b1", "A:a1", "A:a1", "A:a1"])
    }

    @Test func aTourStartedFromABoardThatIsNotOpenGoesToTheFirstBoardWithItems() {
        let boards: [NeedsYouTour.Entry] = [.init(board: "A", items: []), .init(board: "B", items: [item("b1")])]
        #expect(NeedsYouTour.next(from: "gone", after: item("x"), in: boards)?.item.id == "b1")
    }

    @Test func aBoardsTitleCarriesItsCountOnlyWhenSomethingNeedsTheUser() {
        #expect(NeedsYouTour.title("easl", needing: 0) == "easl")
        #expect(NeedsYouTour.title("easl", needing: 2) == "easl (2)")
    }
}
