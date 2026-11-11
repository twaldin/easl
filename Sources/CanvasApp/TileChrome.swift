import AppKit
import CanvasCore

@MainActor
enum TileChrome {
    struct Style {
        let color: NSColor
        let font: NSFont
    }

    static let roles: [ChromeRole: Style] = {
        let title = ChromeRole.title.font()
        let author = ChromeRole.author.font()
        let state = ChromeRole.state.font()
        return [
            .canvas: Style(color: .underPageBackgroundColor, font: title),
            .frame: Style(color: .separatorColor, font: title),
            .surface: Style(color: .windowBackgroundColor, font: title),
            .bar: Style(color: .controlBackgroundColor, font: title),
            .title: Style(color: .labelColor, font: title),
            .type: Style(color: .secondaryLabelColor, font: title),
            .control: Style(color: .secondaryLabelColor, font: author),
            .author: Style(color: .secondaryLabelColor, font: author),
            .authorYou: Style(color: .secondaryLabelColor, font: author),
            .authorAgent: Style(color: .secondaryLabelColor, font: author),
            .state: Style(color: .secondaryLabelColor, font: state),
            .typing: Style(color: .controlAccentColor, font: state),
            .working: Style(color: .systemBlue, font: state),
            .idle: Style(color: .systemGray, font: state),
            .blocked: Style(color: .systemOrange, font: state),
            .done: Style(color: .systemGreen, font: state),
            .error: Style(color: .systemRed, font: state),
            .needsYou: Style(color: .systemOrange, font: ChromeRole.needsYou.font()),
        ]
    }()

    static func color(_ role: ChromeRole) -> NSColor { roles[role]!.color }
    static func font(_ role: ChromeRole, scale: Double = ChromeText.scale) -> NSFont {
        ChromeText.font(roles[role]!.font, scale: scale)
    }


    static func metadataWidth(terminal: Bool) -> CGFloat { terminal ? 210 : 142 }

}
