import AppKit
import CanvasCore

/// Navigate Back/Forward (⌘[ / ⌘]) and Go to's Recent section: every user navigation (Go to, a
/// definition, a ⌘-clicked reference, a changes tile's line, a page's or note's code link, Open
/// All, ⌘J, ⌘9, ⌘0, Review Changes, an edge pill, an ⌥⌘-arrow step) is recorded with the view
/// before and after it, the code tile it re-aimed, and a step's selection.
extension CanvasView {
    /// Runs one user navigation: `body` moves the view and returns the code tile it re-aimed,
    /// if any; `landing` is the code location it went to, for Go to's Recent section. A
    /// navigation inside another (Go to's file row going to its tile) is part of the outer one.
    func navigating(landing: CodeAim? = nil, _ body: () -> CodeReaim?) {
        let from = viewport
        navigationDepth += 1
        let reaim = body()
        navigationDepth -= 1
        recordNavigation(from: from, reaim: reaim, landing: landing)
    }

    /// Records a navigation that already happened, from the view `from` to the current one.
    func recordNavigation(from: Viewport, reaim: CodeReaim? = nil, landing: CodeAim? = nil) {
        if let landing { recentLocations.visit(landing) }
        guard navigationDepth == 0 else { return }
        navigation.record(NavigationHistory.Entry(from: from, to: viewport, reaim: reaim))
    }

    var canNavigateBack: Bool { navigation.canGoBack }
    var canNavigateForward: Bool { navigation.canGoForward }

    /// View ▸ Back: the view where it was before the last navigation, and the tile it re-aimed
    /// back on what it showed (while it still shows where the navigation aimed it).
    func navigateBack() {
        guard let move = navigation.goBack() else { return }
        perform(move)
    }

    /// View ▸ Forward: the navigation Back undid, again.
    func navigateForward() {
        guard let move = navigation.goForward() else { return }
        perform(move)
    }

    private func perform(_ move: NavigationHistory.Move) {
        if let reaim = move.reaim { board.restoreAim(reaim) }
        show(move.viewport)
        if let selected = move.selection, board.objects[selected] != nil { setSelection([selected], cause: .user) }
    }

    /// A code tile a link, Go to or ⌘-click found already showing the lines, wherever it is:
    /// selected and shown whole like a stop stepped to (`Layout.present`: centered when it isn't
    /// in view with a margin). Call inside `navigating`.
    func goToShown(_ id: ObjectID) {
        present(id)
        setSelection([id])
    }

    /// Go to's Recent rows (with nothing typed, before "All content"): where navigation landed
    /// lately, newest first. Their targets are absolute: Go to's relative paths are the listed
    /// checkout's (`Board.workingRoot`), not necessarily the board root.
    func recentNavigatorRows() -> [NavigatorRow] {
        recentLocations.locations.prefix(Self.recentRows).map { location in
            NavigatorRow(target: .file(board.absoluteURL(location.path).path, lines: location.range), title: location.label, kind: "Recent", dot: nil, toolTip: location.path)
        }
    }

    static let recentRows = 5
}
