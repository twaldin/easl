import Foundation

/// A press in painted text the user selects and copies, whose web links open on a click (a
/// question tile's text, `QuestionTile`). Released where it went down, it is a click, and a click
/// on a link follows it. Once the pointer moves `dragDistance` away it is a drag, which selects
/// from where the press went down, on a link too. ⇧ extends the selection there was (from its end
/// away from the press, as in a code tile): a drag at once.
public struct TextPress: Equatable, Sendable {
    /// How far the pointer moves, in window points (screen points at any board zoom), before a
    /// press is a drag: a hand's tremor during a click on a link still opens it.
    public static let dragDistance: Double = 4

    /// The caret offset (UTF-16) a drag selects from.
    public let anchor: Int
    /// The link the press went down on.
    public let link: WebLink.Match?
    private let start: CGPoint
    /// Whether the press has become a drag (it selects, and follows no link).
    public private(set) var dragging: Bool

    /// A press at window point `start`, over caret offset `offset` and `link` (nil: not on one).
    /// `extending`: the selection there was, which a ⇧-press extends (`move` gives its range at once).
    public init(at start: CGPoint, offset: Int, on link: WebLink.Match?, extending selection: NSRange? = nil) {
        self.start = start
        if let selection, selection.length > 0 {
            anchor = offset < selection.location ? selection.location + selection.length : selection.location
            self.link = nil
            dragging = true
        } else {
            anchor = offset
            self.link = link
            dragging = false
        }
    }

    /// The pointer at window point `point`, over caret offset `offset` of `text`: the range it
    /// selects, nil while the press is still a click.
    public mutating func move(to point: CGPoint, offset: Int, in text: String) -> NSRange? {
        if !dragging, hypot(point.x - start.x, point.y - start.y) < Self.dragDistance { return nil }
        dragging = true
        return Self.range(from: anchor, to: offset, in: text)
    }

    /// The link a release follows: the one the press went down on, unless it became a drag.
    public var follows: WebLink.Match? { dragging ? nil : link }

    /// The text between two caret offsets of `text`, in either order, widened to whole
    /// characters: an emoji, or a letter and its accent, is never cut in two.
    public static func range(from anchor: Int, to offset: Int, in text: String) -> NSRange {
        let string = text as NSString
        let low = max(0, min(anchor, offset, string.length)), high = min(string.length, max(anchor, offset, 0))
        guard high > low else { return NSRange(location: low, length: 0) }
        return string.rangeOfComposedCharacterSequences(for: NSRange(location: low, length: high - low))
    }
}
