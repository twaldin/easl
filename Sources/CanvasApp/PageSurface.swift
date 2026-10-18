import CanvasCore
import WebKit

/// What a web page's background looks like to drawings over its tile (`InkContrast`): read from
/// the page's computed styles once it has loaded, in an isolated world.
@MainActor
enum PageSurface {
    struct Probe: Sendable {
        /// Relative luminance of the body's (else the root element's) opaque background; nil
        /// when the page leaves both transparent.
        var luminance: Double?
        /// A transparent page that asks for dark colors in a dark appearance, which WebKit then
        /// paints dark rather than white.
        var darkDefault: Bool
    }

    private static let script = """
    const parse = c => {
      const m = /rgba?\\(([^)]*)\\)/.exec(c || '');
      if (!m) return null;
      const p = m[1].split(/[\\s,\\/]+/).filter(Boolean).map(parseFloat);
      return p.length >= 3 && (p.length < 4 || p[3] > 0.5) ? p.slice(0, 3) : null;
    };
    let rgb = null;
    for (const e of [document.body, document.documentElement]) {
      if (!e) continue;
      rgb = parse(getComputedStyle(e).backgroundColor);
      if (rgb) break;
    }
    const scheme = getComputedStyle(document.documentElement).colorScheme || '';
    return { rgb, darkDefault: scheme.includes('dark') && matchMedia('(prefers-color-scheme: dark)').matches };
    """

    static func probe(_ web: WKWebView) async -> Probe? {
        await PageScript.value(script, in: .defaultClient, on: web) { value in
            guard let result = value as? [String: Any] else { return nil }
            let rgb = (result["rgb"] as? [NSNumber])?.map { $0.doubleValue / 255 }
            let luminance = rgb.flatMap { $0.count >= 3 ? InkContrast.luminance(red: $0[0], green: $0[1], blue: $0[2]) : nil }
            return Probe(luminance: luminance, darkDefault: (result["darkDefault"] as? Bool) ?? false)
        }
    }
}
