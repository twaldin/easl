import AppKit
import CanvasCore
import CoreText

/// Draws a terminal's screen from `zmx history --vt` text for renders, cards, and
/// `view.snapshot` covers (Ghostty draws through Metal, which AppKit can't capture): the
/// tile's own grid, and the colors, font, and padding the live tile runs with (`TerminalConfig`).
@MainActor
enum TerminalRender {
    static func color(_ color: TerminalColor, style: TerminalConfig.Style, foreground: Bool) -> NSColor {
        switch color {
        case .standard: return foreground ? style.foreground : style.background
        case .indexed(let index) where index < 16: return style.palette[Int(index)]
        case .indexed(let index):
            let rgb = TerminalColor.xterm(index) ?? (0, 0, 0)
            return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    // MARK: Font

    nonisolated private static let installedFamilies = CTFontManagerCopyAvailableFontFamilyNames() as! [String]
    private static let fontPreparation = Task {
        await offPool(qos: .userInitiated) { _ = installedFamilies }
    }

    /// Resolve the font service off main before the synchronous raster and snapshot draws.
    static func prepareFonts() async {
        await fontPreparation.value
    }

    /// Font families, best first: the user's Ghostty `font-family` (matched loosely, preferring
    /// its single-width "Mono" Nerd Font variant), then any installed Nerd Font Mono, then the
    /// plain JetBrains Mono Ghostty embeds, then Menlo.
    static let families: [String] = {
        let installed = installedFamilies
        var wanted: [String] = []
        for configured in TerminalConfig.shared.fontFamilies {
            if installed.contains(configured) { wanted.append(configured) }
            let tokens = configured.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let matches = installed.filter { family in
                let name = family.lowercased()
                return tokens.allSatisfy { name.contains($0) }
            }.sorted { ($0.hasSuffix(" Mono") ? 0 : 1, $0.count) < ($1.hasSuffix(" Mono") ? 0 : 1, $1.count) }
            wanted += matches
        }
        wanted += installed.filter { $0.hasSuffix("Nerd Font Mono") }.sorted { $0.count < $1.count }
        wanted += ["JetBrains Mono", "Menlo"].filter(installed.contains)
        var seen: Set<String> = []
        return wanted.filter { seen.insert($0).inserted }
    }()

    struct Fonts {
        var regular: NSFont
        var bold: NSFont
        var italic: NSFont
        var boldItalic: NSFont
        /// Cell size in points.
        var cell: CGSize
        var ascent: CGFloat

        func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
            switch (isBold, isItalic) {
            case (true, true): boldItalic
            case (true, false): bold
            case (false, true): italic
            default: regular
            }
        }
    }

    /// Fonts at the tile's font size, or at the size whose advance fills `cellWidth` when the grid is known.
    static func fonts(size fontSize: CGFloat, cellWidth: CGFloat?) -> Fonts {
        let start = DevPerf.mark()
        defer { DevPerf.record("terminal.fonts", since: start) }
        let base = families.lazy.compactMap { NSFont(name: $0, size: fontSize) ?? NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: fontSize) }.first
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let advance = base.maximumAdvancement.width > 0 ? base.maximumAdvancement.width : base.advancement(forGlyph: base.glyph(withName: "M")).width
        let size = cellWidth.map { fontSize * $0 / max(advance, 1) } ?? fontSize
        let symbols = families.first { $0.contains("Nerd Font") }
        func variant(_ traits: NSFontTraitMask) -> NSFont {
            var font = NSFontManager.shared.convert(base, toSize: size)
            if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            // Prompt glyphs missing from the main face come from a Nerd Font.
            if let symbols, !(font.familyName ?? "").contains("Nerd Font") {
                let cascade = [NSFontDescriptor(fontAttributes: [.family: symbols])]
                font = NSFont(descriptor: font.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size) ?? font
            }
            return font
        }
        let regular = variant([])
        let cellAdvance = regular.maximumAdvancement.width > 0 ? regular.maximumAdvancement.width : size * 0.6
        let height = (regular.ascender - regular.descender + regular.leading).rounded(.up)
        return Fonts(regular: regular, bold: variant(.boldFontMask), italic: variant(.italicFontMask), boldItalic: variant([.boldFontMask, .italicFontMask]),
                     cell: CGSize(width: cellWidth ?? cellAdvance, height: height), ascent: regular.ascender)
    }

    // MARK: Drawing

    /// The grid as the tile shows it: from Ghostty's metrics (points) when known, else from the
    /// configured font filling the body.
    struct Grid {
        var columns: Int
        var rows: Int
        var cell: CGSize
    }

    static func grid(for size: CGSize, known: Grid?, style: TerminalConfig.Style) -> Grid {
        if let known { return known }
        let cell = fonts(size: style.fontSize, cellWidth: nil).cell
        let fitted = TerminalGrid.size(of: size, cell: cell, padding: style.padding)
        return Grid(columns: fitted.columns, rows: fitted.rows, cell: cell)
    }

    /// What the screen shows: the output ends on the cursor's row, and rows below it are blank.
    static func screen(_ lines: [TerminalLine], cursorRow: Int?, rows: Int) -> [TerminalLine] {
        let shown = min(rows, max(1, cursorRow ?? rows))
        return Array(lines.suffix(shown))
    }

    static func draw(_ lines: [TerminalLine], grid: Grid, in bounds: CGRect, appearance: NSAppearance) {
        let style = TerminalConfig.shared.style(for: appearance)
        style.background.setFill()
        bounds.fill()
        let fonts = fonts(size: style.fontSize, cellWidth: grid.cell.width)
        let cell = grid.cell
        for (row, line) in lines.enumerated() {
            let y = style.padding.height + CGFloat(row) * cell.height
            guard y < bounds.maxY else { break }
            var column = 0
            for run in line.runs {
                var foreground = color(run.style.foreground, style: style, foreground: true)
                var background = run.style.background == .standard ? nil : color(run.style.background, style: style, foreground: false)
                if run.style.inverse {
                    let swapped = background ?? style.background
                    background = foreground
                    foreground = swapped
                }
                if run.style.faint { foreground = foreground.withAlphaComponent(0.6) }
                let font = fonts.font(bold: run.style.bold, italic: run.style.italic)
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
                if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                for character in run.text {
                    let width = TerminalStyledTail.cellWidth(character)
                    guard width > 0 else { continue }
                    let x = style.padding.width + CGFloat(column) * cell.width
                    if let background {
                        background.setFill()
                        CGRect(x: x, y: y, width: cell.width * CGFloat(width), height: cell.height).fill()
                    }
                    if !run.style.invisible, character != " " {
                        NSAttributedString(string: String(character), attributes: attributes).draw(at: CGPoint(x: x, y: y))
                    }
                    column += width
                }
            }
        }
    }
}
