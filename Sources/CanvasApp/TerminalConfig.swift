import AppKit
import CanvasCore
import GhosttyKit
import GhosttyTerminal

/// The Ghostty configuration every terminal tile runs with: the user's own (`GhosttyConfig`:
/// config files, includes, theme), validated line by line, over easl's defaults, one text per
/// color scheme. Renders and cards (`TerminalRender`) draw with the same colors, font and padding.
@MainActor
final class TerminalConfig {
    static let shared = TerminalConfig()

    /// What a tile's text looks like under one color scheme, for drawing it without Ghostty.
    struct Style {
        var background: NSColor
        var foreground: NSColor
        /// The 16 ANSI colors.
        var palette: [NSColor]
        var fontSize: CGFloat
        /// Space between the tile's edge and the grid, in points (left, top).
        var padding: CGSize
    }

    let controller: TerminalController
    let light: Style
    let dark: Style
    /// The user's `font-family` values, in order.
    let fontFamilies: [String]
    /// Chords the user bound to Ghostty window, tab and split actions, which easl performs
    /// instead (`GhosttyConfig.remaps`; the keybinds themselves never reach the library).
    let remaps: [GhosttyConfig.KeyChord: GhosttyConfig.AppAction]
    /// Ghostty's shell integration for tiles to load (`TerminalShellIntegration`): nil when the
    /// user's config says `shell-integration = none`.
    let shellIntegration: String?
    /// Whether a program in a local terminal may write the clipboard (OSC 52, Kitty's OSC 5522):
    /// the user's `clipboard-write` is `allow`, Ghostty's default. Tiles run with `ask` instead
    /// (`askBeforeClipboardWrite`), and each tile's delegate answers (`TerminalEvents`).
    let programsMayWriteClipboard: Bool

    private init() {
        // easl's base: the library's defaults (14 pt, block cursor); without a user theme, its
        // Alabaster (light) and Afterglow (dark) colors. Program clipboard writes are asked about
        // even when the user's config is rejected and tiles fall back to this.
        let base = TerminalConfiguration.default.rendered + "\n" + Self.askBeforeClipboardWrite.line
        // The controller initializes Ghostty's runtime, which the config API below needs.
        controller = TerminalController(configSource: .generated(base), theme: TerminalTheme())

        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let user = GhosttyConfig.load(files: GhosttyConfig.defaultFiles(home: home, environment: environment)) { try? String(contentsOf: $0, encoding: .utf8) }
        let themes = GhosttyConfig.themeDirectories(home: home, environment: environment)
        func theme(_ name: String?, fallback: TerminalConfiguration) -> [GhosttyConfig.Entry] {
            guard let name else { return GhosttyConfig.parse(fallback.rendered) }
            guard let file = GhosttyConfig.themeFile(name, directories: themes, isFile: TerminalReferences.isFile),
                  let text = try? String(contentsOf: file, encoding: .utf8) else {
                NSLog("easl: Ghostty theme %@ not found (looked in %@)", name, themes.map(\.path).joined(separator: ", "))
                return GhosttyConfig.parse(fallback.rendered)
            }
            return GhosttyConfig.parse(text)
        }
        let lightSettings = Self.validated(user.settings(theme: theme(user.lightTheme, fallback: .alabaster)), base: base)
        let darkSettings = Self.validated(user.settings(theme: theme(user.darkTheme, fallback: .afterglow)), base: base)
        // A remote terminal's program must never write this Mac's clipboard, so Ghostty asks the
        // tile before every program write; the user's `deny` refuses them all in Ghostty already.
        let clipboardWrite = GhosttyConfig.value("clipboard-write", in: darkSettings) ?? "allow"
        programsMayWriteClipboard = clipboardWrite == "allow"
        let asked = clipboardWrite == "deny" ? [] : [Self.askBeforeClipboardWrite]
        func configuration(_ settings: [GhosttyConfig.Entry]) -> TerminalConfiguration {
            TerminalConfiguration { builder in (settings + asked).forEach { builder.withCustom($0.key, $0.value) } }
        }
        if !controller.setTheme(TerminalTheme(light: configuration(lightSettings), dark: configuration(darkSettings))) || controller.lastConfigurationIssue != nil {
            NSLog("easl: Ghostty config rejected, tiles use the defaults: %@", controller.lastConfigurationIssue ?? "unknown")
        }
        light = Self.style(base: base, settings: lightSettings)
        dark = Self.style(base: base, settings: darkSettings)
        fontFamilies = GhosttyConfig.values("font-family", in: darkSettings)
        let loaded = GhosttyConfig.defaultFiles(home: home, environment: environment).filter { TerminalReferences.isFile($0.path) }.map(\.path)
        NSLog("easl: Ghostty config from %@: %d settings, theme %@ / %@, font %@ %.0f pt",
              loaded.isEmpty ? "(none)" : loaded.joined(separator: ", "), user.entries.count,
              user.lightTheme ?? "(default)", user.darkTheme ?? "(default)", fontFamilies.first ?? "(default)", Double(dark.fontSize))
        remaps = user.remaps
        let integrationSetting = GhosttyConfig.value("shell-integration", in: user.entries)
        shellIntegration = TerminalShellIntegration.directory(setting: integrationSetting, resources: GhosttyRuntimeResources.directoryURL) { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
        NSLog("easl: shell integration %@", shellIntegration ?? (integrationSetting == "none" ? "off (shell-integration = none)" : "missing from the bundle"))
        for keybind in user.appKeybinds {
            if let action = keybind.action, keybind.chord != nil {
                NSLog("easl: Ghostty keybind `%@` runs easl's %@", keybind.entry.value, action == .newTerminal ? "New Terminal" : "Close Terminal")
            } else {
                NSLog("easl: dropped Ghostty keybind `%@`: %@", keybind.entry.value, keybind.action == nil ? "an app action easl doesn't have" : "a key sequence easl can't match")
            }
        }
    }

    func style(for appearance: NSAppearance) -> Style {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    /// Ghostty hands each program clipboard write to the tile's delegate (`TerminalEvents`), which
    /// allows a local terminal's as the user's config says (`programsMayWriteClipboard`) and
    /// refuses a remote one's. The copy bindings write without asking.
    private static let askBeforeClipboardWrite = GhosttyConfig.Entry("clipboard-write", "ask")

    // MARK: Ghostty's config API

    /// `settings` minus the lines Ghostty rejects (an unknown key, a bad value, a key this
    /// build doesn't have): one bad line would otherwise make the library drop the whole config.
    private static func validated(_ settings: [GhosttyConfig.Entry], base: String) -> [GhosttyConfig.Entry] {
        if diagnostics(base + "\n" + settings.map(\.line).joined(separator: "\n")).isEmpty { return settings }
        return settings.filter { entry in
            let problems = diagnostics(entry.line)
            if !problems.isEmpty { NSLog("easl: ignoring Ghostty setting `%@`: %@", entry.line, problems.joined(separator: "; ")) }
            return problems.isEmpty
        }
    }

    private static func diagnostics(_ text: String) -> [String] {
        withConfig(text) { config in
            (0..<ghostty_config_diagnostics_count(config)).compactMap { index in
                ghostty_config_get_diagnostic(config, index).message.map { String(cString: $0) }
            }
        } ?? ["could not load"]
    }

    /// A finalized Ghostty config of `text`, freed after `body`.
    private static func withConfig<T>(_ text: String, _ body: (ghostty_config_t) -> T) -> T? {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-ghostty-\(getpid())-\(UUID().uuidString).conf")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil, let config = ghostty_config_new() else { return nil }
        defer {
            ghostty_config_free(config)
            try? FileManager.default.removeItem(at: file)
        }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        return body(config)
    }

    /// The colors and font size Ghostty resolves from `settings` (names, `#rgb`, a theme's
    /// palette), and the padding the user set.
    private static func style(base: String, settings: [GhosttyConfig.Entry]) -> Style {
        func color(_ value: ghostty_config_color_s) -> NSColor {
            NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255, blue: CGFloat(value.b) / 255, alpha: 1)
        }
        let padding = CGSize(width: padding(GhosttyConfig.value("window-padding-x", in: settings)),
                             height: padding(GhosttyConfig.value("window-padding-y", in: settings)))
        let resolved = withConfig(base + "\n" + settings.map(\.line).joined(separator: "\n")) { config -> Style in
            var background = ghostty_config_color_s(), foreground = ghostty_config_color_s()
            var palette = ghostty_config_palette_s()
            var size: Float = 14
            _ = ghostty_config_get(config, &background, "background", UInt("background".utf8.count))
            _ = ghostty_config_get(config, &foreground, "foreground", UInt("foreground".utf8.count))
            _ = ghostty_config_get(config, &palette, "palette", UInt("palette".utf8.count))
            _ = ghostty_config_get(config, &size, "font-size", UInt("font-size".utf8.count))
            let colors = withUnsafeBytes(of: palette.colors) { Array($0.bindMemory(to: ghostty_config_color_s.self).prefix(16)) }
            return Style(background: color(background), foreground: color(foreground), palette: colors.map(color), fontSize: CGFloat(size), padding: padding)
        }
        return resolved ?? Style(background: .black, foreground: .white, palette: Array(repeating: .white, count: 16), fontSize: 14, padding: padding)
    }

    /// `window-padding-x`/`-y`: `N` or `N,M` (the first side is left/top); Ghostty's default is 2.
    private static func padding(_ value: String?) -> CGFloat {
        value.flatMap { Double($0.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? "") }.map { CGFloat($0) } ?? 2
    }
}
