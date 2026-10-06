/// The one-screen legend behind Help › easl Basics (pointing your agent at things first: it's
/// what a newcomer opens it for) and the tooltips on the things it explains,
/// in the words docs/design.md uses. `skills/easl/references/ui.md` carries the same text for
/// agents asked "what is this?".
public enum CanvasBasics {
    public struct Item: Sendable {
        /// What it is, as it looks ("Blue dot", "⌘P").
        public var term: String
        public var text: String
    }

    public struct Section: Sendable {
        public var title: String
        public var items: [Item]
    }

    /// What a terminal's lifecycle dot says, for its tooltip; nil without an agent reporting.
    public static func lifecycle(_ state: String?) -> String? {
        switch state {
        case "working": "Working: the agent is busy"
        case "blocked": "Blocked: the agent is waiting for you to approve or answer"
        case "done": "Done: the agent finished and you haven't looked yet"
        case "idle": "Idle: the agent is waiting for your next prompt"
        default: nil
        }
    }

    public static let trayTarget = "Your prompt and mentions go to these terminals: an agent you last typed in, else the only agent on the board. Click to check or uncheck terminals (⌥: only one; Edit › Send Mentions To). When you're typing in another terminal, it says so."
    public static let followTile = "Follows the file and line this agent last read or edited. Pin keeps the current view as a tile of its own."
    public static let followHistory = "Where the agent has been, newest first; a pencil marks an edit. Click one to show it."
    public static let marker = "An agent (or a program) asks you to look here. Click to go; it clears once you've seen it."
    public static let blockedBubble = "This agent is waiting for you. Click to answer in its terminal."

    public static let sections: [Section] = [
        Section(title: "Pointing your agent at things", items: [
            Item(term: "Hyper-click", text: "Hyper is ⌃⌥⇧⌘: Control+Option+Shift+Command, on a PC keyboard Ctrl+Alt+Shift+Win (a key remapper can make Caps Lock Hyper). Hyper-click a code line, page element, drawing or tile to stage it as a mention in the tray at the bottom; a group's title mentions the whole group."),
            Item(term: "⇧⌘M", text: "mention from the keyboard (Edit › Mention): the hunk or lines you're on in a changes tile, the selected text or range of a code tile, a note's block, a page's selection, a terminal's selection or last command; else the selected tiles or group."),
            Item(term: "Composer", text: "the bar at the bottom is a prompt box: ⌘I from anywhere, ⌘↩ sends, Esc leaves. Staged mentions are its purple tokens, numbered [1], [2]… as your agent gets them; a Hyper-click puts its token where you're typing, and the words after a token are its note. Delete a token to unstage it; click one to see what it points at. \"→ name\" is where it goes (check several to send to each); a question an agent is blocked on shows above, and your text answers it. ↑ in an empty composer brings back what you sent. Edit › Remove Mention or ⌥⇧⌘M (the last one) take tokens off; ⌃⌥⇧⌘V pastes them into the terminal you're typing in, and ⌘Z brings them back."),
            Item(term: "Get Started", text: "Help › Get Started walks through a first mention on a practice note: stage it, then send it with a prompt. It opens by itself only on a first launch."),
            Item(term: "Drawing", text: "the toolbar at the top draws boxes (R), ellipses (O), arrows (A), text (T) and ink (P); V selects. Hyper-click a drawing to show the agent what it marks."),
        ]),
        Section(title: "Reading a board", items: [
            Item(term: "Scroll · pinch", text: "scroll pans, pinch zooms; ⌘9 shows everything, ⌘0 is 100%."),
            Item(term: "With a mouse", text: "the wheel pans; ⌘-scroll zooms around the pointer, ⇧-scroll pans sideways."),
            Item(term: "Groups and arrows", text: "a tinted, titled region holds tiles that belong together; an arrow's label says how two things relate, and one into a code tile points at its lines."),
            Item(term: "Captions", text: "the line under a code tile's header says why those lines matter. The tile keeps them as code moves; \"⚠︎ stale\" in its header means they're gone."),
            Item(term: "⌥⌘-arrows", text: "move between tiles: ⌥⌘↑ ⌥⌘↓ ⌥⌘← ⌥⌘→ go to the nearest tile that way, and a terminal takes the keyboard. ⌥⌘→ and ⌥⌘← step along the board's next-step arrows when the selected tile has one (\"Last step\" ends the walk). A tile not in view is centered."),
            Item(term: "⌘P", text: "find a tile by its title or caption."),
            Item(term: "Links", text: "a path:line link, Go to or ⌘-click goes to the tile already showing those lines, else opens them beside you. Return enters a code tile to scroll it."),
            Item(term: "⌘[ · ⌘]", text: "back and forward through where you went: steps, links, Go to, definitions, ⌘J, Review Changes."),
            Item(term: "Hide Board Chrome", text: "⌥⌘T (View menu), for presenting: hides the toolbar, tray, selection rings, author marks, code headers and agents' markers (a blocked agent still shows). Esc brings them back."),
        ]),
        Section(title: "Agents", items: [
            Item(term: "Blue dot", text: "working: the agent is busy."),
            Item(term: "Orange dot, ring and ✋ bubble", text: "blocked: it waits for you to approve or answer. Click the bubble to answer in its terminal."),
            Item(term: "Green dot", text: "done: it finished, or an agent without an integration (aider) said it waits, and you haven't looked yet."),
            Item(term: "Grey dot", text: "idle: waiting for your next prompt. No dot: no agent reporting."),
            Item(term: "Dot on a board's tab", text: "orange: an agent there is blocked; green: one finished unseen."),
            Item(term: "Quit · closing a tab", text: "agents and shells keep running in the background and are back when you open the folder again; closing a terminal tile ends its session."),
        ]),
        Section(title: "Needs you", items: [
            Item(term: "Pink ring and bubble", text: "an attention marker: an agent (or a bell) says \"look here\". It clears when you select the tile, type in it, or look at it."),
            Item(term: "Pill at the edge", text: "something that needs you is off screen that way. Click it to go there."),
            Item(term: "Question tile", text: "an agent asks you to decide: its options (the recommended one outlined, each with why), links to what it's about, and who asks. Press a number to pick, add a note if you like, Return answers; the answer goes back to the agent. Archive hides an answered tile; a cancelled or expired one is dimmed."),
            Item(term: "Open asks", text: "the count beside the drawing toolbar: questions waiting for you on this board. Click it to go to the next one."),
            Item(term: "⌘J", text: "go to the next thing on this board that needs you: blocked agents first, then open questions, then markers, then agents that finished while you looked elsewhere."),
        ]),
        Section(title: "Agents' tiles", items: [
            Item(term: "Follow tile", text: "each agent's code tile follows the file and line it last read or edited; the strip under it lists recent places (a pencil marks an edit). Pin keeps a view; turn it off with right-click › Follow Files."),
            Item(term: "Where new tiles land", text: "next to the agent's terminal, clear of other tiles, inside your view when there's room nearby. The view never moves by itself: look for a marker, or press ⌘9. \"by name\" in a title bar says which agent made the tile."),
            Item(term: "Undo", text: "⌘Z undoes the last change, yours or an agent's, and says so when it was an agent's or changed your files or git index (a Stage or Discard); ⇧⌘Z redoes it. In a terminal, ⌘Z is the terminal's."),
        ]),
        Section(title: "Reviewing work", items: [
            Item(term: "Review Changes", text: "⇧⌘R (or right-click the board) lists what changed, file by file, in the worktree of the terminal you're in or have selected: green lines were added, red ones removed. Click the summary at its top to compare Uncommitted changes (not in a commit yet) or Branch vs main (everything the branch changed)."),
            Item(term: "Stage · Unstage", text: "Stage marks a change ready to go into the next commit; Unstage takes the mark off. Neither changes your files."),
            Item(term: "Discard", text: "throws a change away from your files. It asks first (click again, or r then ⌘⌫; any other key keeps it) and only puts back work not committed yet."),
            Item(term: "committed · Viewed", text: "committed: already saved in the branch's history, nothing to discard. Viewed folds a file you've read until it changes."),
            Item(term: "⌘Z", text: "undoes a Stage, Unstage or Discard and says which."),
        ]),
        Section(title: "Zoom", items: [
            Item(term: "⌘9 · ⌘0", text: "fit everything · actual size (100%, or the selection at 100%)."),
            Item(term: "⌘= · ⌘-", text: "zoom in and out, 10% to 100%. Zoomed far out, tiles become cards (a picture, tinted by the agent's state); zoom in to use them."),
            Item(term: "⌃⌘= · ⌃⌘- · ⌃⌘0", text: "zoom the content of the selected tile (or the one you're typing in) in, out, or back to 100% (Object › Content Zoom), in place: the tile keeps its size and its text reflows (a terminal gets fewer, bigger columns). A tile shows its zoom by its ✕: click the % for 100%, hover for − and +. Drag a corner to resize a tile; ⌥-drag keeps its proportions."),
        ]),
        Section(title: "Keyboard", items: [
            Item(term: "⌘P", text: "go to a tile, file or symbol, or a heading in a note."),
            Item(term: "⌘T", text: "new terminal; then run omp, claude, codex, gemini or opencode."),
            Item(term: "Return · Esc · Tab", text: "Return enters the selected tile (typing, scrolling code); Esc gives the keyboard back to the board, then clears the selection, then closes Get Started. In a terminal or a web page Esc goes to the program or page (a game's pause, a dialog): ⌘Esc leaves any tile. Tab never types into a tile: with Get Started open it walks its buttons (Space presses one)."),
            Item(term: "⌘W · ⌘G", text: "close the selection · group it."),
            Item(term: "⌥⌘/", text: "open or close this legend (Help › easl Basics)."),
        ]),
        Section(title: "Coming from Linux or Windows", items: [
            Item(term: "⌘ is your Ctrl", text: "⌘ (Command, the Windows key on a PC keyboard) does what Ctrl does elsewhere: ⌘T, ⌘W, ⌘Z, ⌘C, ⌘V, ⌘= and ⌘- to zoom. A Ctrl shortcut on the board says its ⌘ key."),
            Item(term: "⌃ stays the terminal's", text: "in a terminal ⌃C interrupts and ⌃D ends input; copy the selection with ⌘C and paste with ⌘V."),
            Item(term: "⌥ is Alt", text: "⌥ (Option) is the Alt key. For Alt as Meta in the shell (Alt-B, Alt-F), set macos-option-as-alt = true in your Ghostty config."),
            Item(term: "Mouse", text: "the wheel pans, ⌘-scroll zooms around the pointer, ⇧-scroll pans sideways; right-click the board or a tile for its menu."),
            Item(term: "⌥⌘-arrows", text: "move between tiles like a tiling window manager; a terminal you land on takes the keyboard, and ⌘Esc leaves it."),
        ]),
    ]
}
