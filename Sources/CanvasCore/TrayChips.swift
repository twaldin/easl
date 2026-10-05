import CoreGraphics
import Foundation

/// What the composer's tokens say: each token's number, which is the `[n]` its mention gets in
/// the context the tray drains into (`Board.drain` numbers the tray from 1 in token order), so
/// "[2]" in a prompt means the second token; unstaging one renumbers the tokens after it, as the
/// context would.
public enum TrayChips {
    public static func numbered(_ tray: [Mention]) -> [(number: Int, mention: Mention)] {
        tray.enumerated().map { ($0.offset + 1, $0.element) }
    }

    /// A chip's label cut to `width` (text widths as `measure` gives them). A code location
    /// keeps what tells it apart: it drops its directory first (`cart.ts:15 cart15`), then its
    /// symbol, then cuts the middle of the file name (`chec…ut.ts:10-45`), and always keeps its
    /// `:line` or `:a-b`. Anything else keeps its label whole: its chip cuts the tail, so a note
    /// keeps its title's start.
    public static func fittedLabel(_ mention: Mention, width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(mention.label) > width, case .code(_, let path, let lines, let side, let symbol, _, _) = mention.target else { return mention.label }
        let range = lines.start == lines.end ? "\(lines.start)" : "\(lines.start)-\(lines.end)"
        let suffix = ":\(range)" + (side == DiffSide.old.rawValue ? " (old)" : "")
        let name = (path as NSString).lastPathComponent
        for candidate in [symbol.map { name + suffix + " " + $0 }, name + suffix].compactMap({ $0 }) where measure(candidate) <= width {
            return candidate
        }
        let characters = Array(name)
        for kept in stride(from: characters.count - 1, through: 1, by: -1) {
            let head = String(characters.prefix((kept + 1) / 2)), tail = String(characters.suffix(kept / 2))
            let candidate = head + "…" + tail + suffix
            if measure(candidate) <= width { return candidate }
        }
        return "…" + suffix
    }

    /// The chip's number as the context writes it.
    public static func badge(_ number: Int) -> String { "[\(number)]" }

    /// The word after a chip whose target changed since it was staged: a page mention's page
    /// navigated or reloaded ("page changed", not someone's edit); anything else was edited.
    @MainActor public static func changedNote(_ mention: Mention, on board: Board) -> String? {
        guard mention.edited else { return nil }
        switch mention.target {
        case .dom, .console: return "page changed"
        case .object(let id) where board.objects[id]?.type == .browser: return "page changed"
        default: return "edited"
        }
    }

    /// The notice when a Hyper-click (or ⇧⌘M, a Mention item) on something already staged took
    /// it out, which the chip leaving alone doesn't make plain.
    public static func unstagedNotice(_ mention: Mention) -> String {
        "Removed \(mention.label) from the tray: it was already there"
    }
}

/// What a click on a tray chip shows: the objects its mention points at, selected and brought
/// into view, and whether the tile holds a part to scroll to and flash (code lines, a note
/// block) rather than the whole tile.
public struct MentionReveal: Equatable, Sendable {
    /// The mentioned objects still on the board, in the mention's order.
    public var objects: [ObjectID]
    /// The tile that has the mentioned part: a code tile still showing the mentioned file, a
    /// changes tile, a note. Nil: the objects as a whole.
    public var part: ObjectID?

    public init(objects: [ObjectID], part: ObjectID?) {
        self.objects = objects
        self.part = part
    }

    /// Nil when nothing it points at is left.
    @MainActor public init?(_ target: MentionTarget, on board: Board) {
        let objects = target.objectIDs.filter { board.objects[$0] != nil }
        guard let first = objects.first else { return nil }
        let part: ObjectID?
        switch target {
        case .code(let object, let path, _, _, _, _, _):
            // A code tile re-aimed at another file since (a follow tile, ⌘-click navigation)
            // no longer shows those lines: the tile alone.
            if let aim = board.objects[object].flatMap(CodeAim.init) { part = aim.path == path ? object : nil } else { part = object }
        case .note:
            part = first
        case .object, .group, .terminal, .dom, .console, .image:
            part = nil
        }
        self.init(objects: objects, part: part)
    }
}
