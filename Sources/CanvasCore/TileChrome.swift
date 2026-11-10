import Foundation
#if canImport(AppKit)
import AppKit
#endif


public enum TileChromeLayout {
    public enum Mode: Sendable {
        case twoTrack, folded
    }

    public struct Pill: Equatable {
        public var size: CGSize
        public var bounds: CGRect

        public init(size: CGSize, bounds: CGRect = .infinite) {
            self.size = size
            self.bounds = bounds
        }
    }

    public struct Frames {
        public var type: CGRect
        public var title: CGRect
        public var state: CGRect
        public var typing: CGRect
        public var author: CGRect
        public var needsYou: CGRect
        public var authorInTitle: Bool
    }

    public static func mode(scale: Double) -> Mode { scale >= 1.3 ? .folded : .twoTrack }

    public static func titleToolTip(path: String?, author: String?, scale: Double, authorInTitle: Bool = false) -> String? {
        let parts = [path, mode(scale: scale) == .folded || authorInTitle ? author.map { "Created by \($0)" } : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    public static func frames(width: CGFloat, trailing: CGFloat = 0, attentionTrailing: CGFloat? = nil, terminal: Bool, scale: Double,
                              state: Bool = true, typing: Bool = true, stateMinimum: CGFloat = 64, typingMinimum: CGFloat = 48,
                              needsYou: Pill? = nil) -> Frames {
        let start: CGFloat = 28
        let end = max(start, width - 32 - trailing)
        func line(x: CGFloat, width: CGFloat, center: CGFloat, height: CGFloat) -> CGRect {
            let h = (height * CGFloat(scale)).rounded()
            return CGRect(x: x, y: (center - h / 2).rounded(), width: max(0, width), height: h)
        }
        let type = CGRect(x: 8, y: (CGFloat(RenderMath.tileTitleHeight) - 14) / 2, width: 14, height: 14)
        if mode(scale: scale) == .twoTrack {
            let reservedAuthorWidth = min(88, end - start)
            var authorWidth = reservedAuthorWidth
            var authorX = end - authorWidth
            var stateWidth = terminal ? min(64, max(0, authorX - start - 6)) : 0
            var typingX = start + (terminal ? stateWidth + 4 : 0)
            var typingWidth = max(0, min(48, authorX - typingX - 6))
            let stateNeed = terminal && state ? stateMinimum : 0
            let typingNeed = typing ? typingMinimum : 0
            if stateWidth < stateNeed || typingWidth < typingNeed {
                let gap: CGFloat = stateNeed > 0 && typingNeed > 0 ? 4 : 0
                let factor = min(1, max(0, end - start - gap) / max(1, stateNeed + typingNeed))
                stateWidth = stateNeed * factor
                typingWidth = typingNeed * factor
                typingX = start + stateWidth + gap
                authorX = min(end, max(end - 88, typingX + typingWidth + 6))
                authorWidth = end - authorX
            }
            return Frames(type: type,
                          title: line(x: start, width: end - start, center: 9, height: 16),
                          state: line(x: start, width: stateWidth, center: 25, height: 15),
                          typing: line(x: typingX, width: typingWidth, center: 25, height: 15),
                          author: line(x: authorX, width: authorWidth, center: 25, height: 15), needsYou: .zero,
                          authorInTitle: authorWidth == 0 || authorWidth < reservedAuthorWidth)
        }
        let inlineEnd = max(start, width - 32 - (attentionTrailing ?? trailing))
        let available = inlineEnd - start
        let minimumTitle: CGFloat = 32
        let stateWidth = terminal && state ? 64 * CGFloat(scale) : 0
        let typingWidth = typing ? 48 * CGFloat(scale) : 0
        let labelCount = (stateWidth > 0 ? 1 : 0) + (typingWidth > 0 ? 1 : 0)
        let textWidth = minimumTitle + stateWidth + typingWidth + 6 * CGFloat(labelCount)
        let size = needsYou?.size ?? .zero
        let candidate = CGRect(x: inlineEnd - size.width, y: (CGFloat(RenderMath.tileTitleHeight) - size.height) / 2,
                               width: size.width, height: size.height)
        let fits = size.width > 0 && size.height > 0 && size.width + 6 + textWidth <= available
            && size.height <= CGFloat(RenderMath.tileTitleHeight) && (needsYou?.bounds.contains(candidate) ?? false)
        let pill = fits ? candidate : .zero
        let labelEnd = (fits ? inlineEnd : end) - pill.width - (fits ? 6 : 0)
        let gap = min(6, (labelEnd - start) / CGFloat(labelCount + 1))
        let labelsWidth = max(0, labelEnd - start - minimumTitle - gap * CGFloat(labelCount))
        let factor = min(1, labelsWidth / max(1, stateWidth + typingWidth))
        let stateW = stateWidth * factor
        let typingW = typingWidth * factor
        let typingX = labelEnd - typingW
        let stateX = typingX - (typingWidth > 0 ? gap : 0) - stateW
        let titleEnd = stateX - (stateWidth > 0 ? gap : 0)
        return Frames(type: type, title: line(x: start, width: titleEnd - start, center: 17, height: 16),
                      state: line(x: stateX, width: stateW, center: 17, height: 15),
                      typing: line(x: typingX, width: typingW, center: 17, height: 15), author: .zero,
                      needsYou: pill, authorInTitle: true)
    }
}
public enum ChromeRole: String, CaseIterable, Sendable {
    case canvas = "chrome.canvas", frame = "chrome.frame", surface = "chrome.surface"
    case bar = "chrome.bar", title = "chrome.title", type = "chrome.type", control = "chrome.control"
    case author = "chrome.author", authorYou = "chrome.author.you", authorAgent = "chrome.author.agent"
    case state = "chrome.state", typing = "chrome.state.typing", working = "chrome.state.working"
    case idle = "chrome.state.idle", blocked = "chrome.state.blocked", done = "chrome.state.done"
    case error = "chrome.state.error", needsYou = "chrome.state.needsYou"
}

#if canImport(AppKit)
extension ChromeRole {
    @MainActor public func font(scale: Double = 1) -> NSFont {
        let base: NSFont = switch self {
        case .needsYou: .systemFont(ofSize: 13, weight: .semibold)
        case .author, .authorYou, .authorAgent, .control: .systemFont(ofSize: 11)
        case .state, .typing, .working, .idle, .blocked, .done, .error:
            .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        default: .systemFont(ofSize: 12, weight: .medium)
        }
        return scale == 1 ? base : NSFont(descriptor: base.fontDescriptor, size: base.pointSize * CGFloat(scale)) ?? base
    }
}
#endif

/// Keyboard ownership and terminal status are independent facts. Attention comes only from NeedsYouItem.
public struct TileChromeState: Equatable, Sendable {
    public struct Status: Equatable, Sendable {
        public var text: String
        public var role: ChromeRole
        public var detail: String?
    }

    public struct Command: Equatable, Sendable {
        public var text: String?
        public var failed: Bool
        public var detail: String?
        public init(text: String? = nil, failed: Bool = false, detail: String? = nil) {
            self.text = text
            self.failed = failed
            self.detail = detail
        }
    }

    public var typing: Bool
    public var terminal: Status?

    public init(object: CanvasObject, focused: ObjectID?, command: Command = Command()) {
        typing = focused == object.id
        terminal = nil
        guard object.type == .terminal else { return }
        let lifecycle = object.props["lifecycle"]
        if let error = lifecycle?["error"]?.string, !error.isEmpty {
            terminal = Status(text: "error", role: .error, detail: error)
        } else if command.failed {
            terminal = Status(text: "error", role: .error, detail: command.detail ?? command.text)
        } else if let state = lifecycle?["state"]?.string, let role = Self.lifecycleRole(state) {
            terminal = Status(text: state, role: role, detail: lifecycle?["message"]?.string ?? command.detail)
        } else if let text = command.text, !text.isEmpty {
            terminal = Status(text: text, role: .state, detail: command.detail)
        }
    }

    public static func lifecycleRole(_ state: String?) -> ChromeRole? {
        switch state {
        case "working": .working
        case "idle": .idle
        case "blocked": .blocked
        case "done": .done
        default: nil
        }
    }

    public static func needsYouText(_ item: NeedsYouItem) -> String {
        let reason: String = switch item.reason {
        case .blocked: "Needs you"
        case .question: "Open question"
        case .marked: "Look here"
        case .done: "Result unseen"
        }
        let message = item.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.flatMap { $0.isEmpty ? nil : "\(reason) · \($0)" } ?? reason
    }

    public static func typeSymbol(_ type: ObjectType) -> String {
        switch type {
        case .terminal: "terminal"
        case .browser: "globe"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .note: "note.text"
        case .html: "curlybraces"
        case .changes: "arrow.triangle.branch"
        case .image: "photo"
        case .video: "play.rectangle"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .question: "questionmark.circle"
        case .shape: "square"
        case .arrow: "arrow.right"
        case .group: "rectangle.3.group"
        }
    }
}
