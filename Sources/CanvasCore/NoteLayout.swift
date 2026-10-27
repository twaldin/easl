import AppKit

extension NSAttributedString.Key {
    /// `NoteBlock` raw value on every paragraph that draws a full-width decoration.
    public static let noteBlock = NSAttributedString.Key("canvas.note.block")
    /// A link target (`NoteLink.encoded`); the note draws and handles links itself because its
    /// display view is not selectable (it never takes keyboard focus).
    public static let noteLink = NSAttributedString.Key("canvas.note.link")
    /// `NoteCodeRow` on each row of an excerpt or proposal that maps to a real source line.
    public static let noteCodeRow = NSAttributedString.Key("canvas.note.codeRow")
    /// 1-based markdown line a rendered paragraph came from, to put the caret there on edit.
    public static let noteMarkdownLine = NSAttributedString.Key("canvas.note.markdownLine")
    /// `NSImage` composited by the display; its attachment reserves a TextKit frame without painting.
    public static let noteDiagramImage = NSAttributedString.Key("canvas.note.diagramImage")
}

/// Paragraph decorations, drawn behind the text by `NoteBlockFragment`.
public enum NoteBlock: String, Sendable {
    /// A grounded row read from a real file.
    case excerpt
    /// A free-written (authored) fence row.
    case authored
    case added
    case removed
    /// The header row above an excerpt or proposal.
    case caption
    case quote
    case rule
    case tableHeader

    public var fill: NSColor? {
        switch self {
        case .excerpt: NSColor.textBackgroundColor.withAlphaComponent(0.85)
        case .authored: NSColor.systemOrange.withAlphaComponent(0.10)
        case .added: NSColor.systemGreen.withAlphaComponent(0.18)
        case .removed: NSColor.systemRed.withAlphaComponent(0.16)
        case .caption: NSColor.textBackgroundColor.withAlphaComponent(0.45)
        case .tableHeader: NSColor.labelColor.withAlphaComponent(0.08)
        case .quote, .rule: nil
        }
    }
}

/// The source line under an excerpt or proposal row: what a Hyper-click there mentions.
public final class NoteCodeRow: NSObject {
    public let path: String
    public let line: Int
    public let symbol: String?
    /// The excerpt is pinned to this revision.
    public let commit: String?

    public init(path: String, line: Int, symbol: String?, commit: String?) {
        self.path = path
        self.line = line
        self.symbol = symbol
        self.commit = commit
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NoteCodeRow else { return false }
        return path == other.path && line == other.line && symbol == other.symbol && commit == other.commit
    }

    public override var hash: Int { path.hashValue ^ line }
}

/// Where a click on a rendered link goes.
public enum NoteLink: Equatable {
    /// Open a code tile beside the note.
    case code(path: String, lines: LineRange?)
    case web(URL)

    public var encoded: String {
        switch self {
        case .code(let path, let lines): "code:" + path + (lines.map { "#L\($0.start)-\($0.end)" } ?? "")
        case .web(let url): url.absoluteString
        }
    }

    public init?(encoded: String) {
        if encoded.hasPrefix("code:") {
            self = Self.code(String(encoded.dropFirst(5)))
        } else if let url = URL(string: encoded), url.scheme != nil {
            self = .web(url)
        } else if !encoded.isEmpty, !encoded.hasPrefix("#") {
            // A scheme-less markdown link is a path in the repo: `docs/design.md`, `src/a.ts#L10-20`.
            self = Self.code(encoded)
        } else {
            return nil
        }
    }

    private static func code(_ value: String) -> NoteLink {
        guard let hash = value.lastIndex(of: "#") else { return .code(path: value, lines: nil) }
        let fence = NoteFence(info: "file=" + value)
        return .code(path: fence.path ?? String(value[..<hash]), lines: fence.lines)
    }
}

/// Hands `NoteBlockFragment`s to paragraphs that carry a `.noteBlock` decoration.
public final class NoteLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    public override init() {}

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let raw = paragraph.attributedString.attribute(.noteBlock, at: 0, effectiveRange: nil) as? String,
           let block = NoteBlock(rawValue: raw) {
            return NoteBlockFragment(textElement: textElement, range: textElement.elementRange, block: block)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// A paragraph with a full-width band (code rows, diff rows, captions), a quote bar, or a rule.
/// Bands cover only the typographic lines, not paragraph spacing, so consecutive rows join
/// into one block and the block ends where its spacing begins.
public final class NoteBlockFragment: NSTextLayoutFragment {
    public static let inset: CGFloat = 6
    private let block: NoteBlock

    init(textElement: NSTextElement, range: NSTextRange?, block: NoteBlock) {
        self.block = block
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The band in fragment coordinates.
    private var band: CGRect {
        let lines = textLineFragments
        let top = lines.first?.typographicBounds.minY ?? 0
        let bottom = lines.last?.typographicBounds.maxY ?? layoutFragmentFrame.height
        return CGRect(x: Self.inset - layoutFragmentFrame.minX, y: top, width: max(0, containerWidth - 2 * Self.inset), height: bottom - top)
    }

    public override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(band)
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        let rect = band.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        switch block {
        case .quote:
            context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            context.fill(CGRect(x: rect.minX + 2, y: rect.minY, width: 3, height: rect.height))
        case .rule:
            context.setFillColor(NSColor.separatorColor.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1))
        default:
            if let fill = block.fill {
                context.setFillColor(fill.cgColor)
                context.fill(rect)
            }
        }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
