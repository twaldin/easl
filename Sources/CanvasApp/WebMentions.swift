import AppKit
import CanvasCore
import WebKit

/// Element-level mentions for web content (browser and HTML tiles): which DOM element is under a
/// point, a stable CSS selector for it, and where a selector is now. The script runs in its own
/// content world so pages can neither see nor tamper with it.
@MainActor
enum WebMentions {
    static let world = WKContentWorld.world(name: "canvas-mentions")

    struct Element: Equatable, Sendable {
        var selector: String
        var text: String
        /// In the web view's coordinates (CSS pixels at page zoom 1, top-left origin).
        var rect: CGRect
        /// Where the point asked about fell in a picture element's own pixels (`element(at:in:point:)`).
        var point: ElementPoint?
    }

    /// Installs the helper into every frame load of a configuration.
    static func install(on configuration: WKWebViewConfiguration) {
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
        configuration.userContentController.addUserScript(script)
    }

    /// The element at `point` (web view coordinates, top-left origin); with `pixel`, on a
    /// `<canvas>`, `<video>` or `<img>`, where the point falls in its own pixels (a Hyper-click's
    /// mention; hovering doesn't need it).
    static func element(at point: CGPoint, in webView: WKWebView, pixel: Bool = false) async -> Element? {
        await PageScript.value("return window.__canvasMentions?.at(x, y, pixel) ?? null", ["x": point.x, "y": point.y, "pixel": pixel],
                               in: world, on: webView, decode)
    }

    /// Where the element matching `selector` is now, or nil if it no longer exists.
    static func element(matching selector: String, in webView: WKWebView) async -> Element? {
        await PageScript.value("return window.__canvasMentions?.find(selector) ?? null", ["selector": selector], in: world, on: webView, decode)
    }

    /// The page's text selection: the innermost element holding all of it, `text` the selected
    /// text (whitespace collapsed); nil with nothing selected.
    static func selection(in webView: WKWebView) async -> Element? {
        await PageScript.value("return window.__canvasMentions?.selection() ?? null", in: world, on: webView, decode)
    }

    /// The elements under a rect (web view coordinates, top-left origin): the outermost ones it
    /// mostly covers that show something (text, an image, a control), in document order, else
    /// the smallest such element it touches within a line (an underline, a margin note). At
    /// most `limit`, plus how many more there are.
    static func elements(in rect: CGRect, in webView: WKWebView, limit: Int = 8) async -> (elements: [Element], more: Int)? {
        await PageScript.value("return window.__canvasMentions?.within(x, y, w, h, limit) ?? null",
                               ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height, "limit": limit], in: world, on: webView) { value in
            guard let object = value as? [String: Any], let list = object["elements"] as? [Any] else { return nil }
            return (list.compactMap(decode), (object["more"] as? NSNumber)?.intValue ?? 0)
        }
    }

    private static func decode(_ value: Any?) -> Element? {
        guard let object = value as? [String: Any], let selector = object["selector"] as? String,
              let x = object["x"] as? Double, let y = object["y"] as? Double,
              let w = object["w"] as? Double, let h = object["h"] as? Double else { return nil }
        var element = Element(selector: selector, text: object["text"] as? String ?? "", rect: CGRect(x: x, y: y, width: w, height: h))
        if let point = object["point"] as? [String: Any], let x = (point["x"] as? NSNumber)?.intValue, let y = (point["y"] as? NSNumber)?.intValue,
           let w = (point["w"] as? NSNumber)?.intValue, let h = (point["h"] as? NSNumber)?.intValue {
            element.point = ElementPoint(x: x, y: y, w: w, h: h)
        }
        return element
    }

    /// Selector preference: unique id, test ids / aria labels, then a tag:nth-of-type path up to
    /// the nearest ancestor with a unique id.
    static let source = #"""
    (() => {
      const esc = (s) => CSS.escape(s);
      const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch { return false; } };
      function selectorFor(el) {
        if (!(el instanceof Element)) return null;
        if (el.id && unique('#' + esc(el.id))) return '#' + esc(el.id);
        for (const attr of ['data-testid', 'data-test', 'aria-label', 'name']) {
          const v = el.getAttribute(attr);
          if (v) { const sel = `${el.tagName.toLowerCase()}[${attr}="${v.replace(/"/g, '\\"')}"]`; if (unique(sel)) return sel; }
        }
        const parts = [];
        let node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
          if (node !== el && node.id && unique('#' + esc(node.id))) { parts.unshift('#' + esc(node.id)); break; }
          const tag = node.tagName.toLowerCase();
          const same = node.parentElement ? [...node.parentElement.children].filter((c) => c.tagName === node.tagName) : [];
          parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
          node = node.parentElement;
        }
        return parts.join(' > ');
      }
      function describe(el) {
        const r = el.getBoundingClientRect();
        const text = (el.innerText || el.getAttribute('aria-label') || el.getAttribute('alt') || el.value || '').trim().replace(/\s+/g, ' ').slice(0, 120);
        return { selector: selectorFor(el), text, x: r.left, y: r.top, w: r.width, h: r.height };
      }
      // Overlays that ignore the pointer (HUDs, badges, labels) are still what the user sees and
      // points at: hit-test once more with pointer-events forced on, and take that element when it
      // carries text. Textless ones (scrims, vignettes) stay transparent to mentions.
      let reach;
      function hit(x, y) {
        const normal = document.elementFromPoint(x, y);
        if (!reach) { reach = new CSSStyleSheet(); reach.replaceSync('*, *::before, *::after { pointer-events: auto !important; }'); }
        const sheets = document.adoptedStyleSheets;
        let over;
        document.adoptedStyleSheets = [...sheets, reach];
        try { over = document.elementFromPoint(x, y); } finally { document.adoptedStyleSheets = sheets; }
        return over && over !== normal && !over.contains(normal) && (over.innerText || '').trim() ? over : normal;
      }
      // Shown things: text, or content without text of its own.
      const media = new Set(['IMG', 'SVG', 'svg', 'VIDEO', 'CANVAS', 'INPUT', 'BUTTON', 'SELECT', 'TEXTAREA', 'IFRAME']);
      const shows = (el) => {
        if (!(el.innerText || '').trim() && !el.getAttribute('aria-label') && !media.has(el.tagName)) return false;
        const style = getComputedStyle(el);
        return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
      };
      const overlap = (r, left, top, right, bottom) =>
        Math.max(0, Math.min(r.right, right) - Math.max(r.left, left)) * Math.max(0, Math.min(r.bottom, bottom) - Math.max(r.top, top));
      function within(x, y, w, h, limit) {
        const right = x + w, bottom = y + h;
        const all = document.body ? [...document.body.querySelectorAll('*')] : [];
        const found = [];
        // The elements it mostly covers. Document order: an ancestor comes before what it
        // contains, so only the outermost stays.
        for (const el of all) {
          const r = el.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0 || overlap(r, x, y, right, bottom) < 0.6 * r.width * r.height) continue;
          if (found.some((outer) => outer.contains(el)) || !shows(el)) continue;
          found.push(el);
        }
        if (!found.length) {
          // A stroke or note beside the content (an underline, a margin note): the smallest
          // element showing something that it touches, give or take a line.
          const pad = 12;
          let best = null, bestArea = Infinity;
          for (const el of all) {
            const r = el.getBoundingClientRect();
            const area = r.width * r.height;
            if (area <= 0 || area >= bestArea || !overlap(r, x - pad, y - pad, right + pad, bottom + pad) || !shows(el)) continue;
            best = el;
            bestArea = area;
          }
          if (best) found.push(best);
        }
        return { elements: found.slice(0, limit).map(describe), more: Math.max(0, found.length - limit) };
      }
      // The page's text selection: the element holding all of it, with the selected text.
      function selection() {
        const sel = window.getSelection();
        if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
        const text = sel.toString().trim().replace(/\s+/g, ' ');
        if (!text) return null;
        let node = sel.getRangeAt(0).commonAncestorContainer;
        if (node.nodeType !== 1) node = node.parentElement;
        if (!node) return null;
        const found = describe(node);
        found.text = text.slice(0, 500);
        return found;
      }
      // Where (x, y) falls in a picture element's own pixels: a canvas's drawing buffer, a
      // video's frame, an image's natural size, through its border, padding, object-fit and
      // object-position (a video letterboxes as if contained). Null off the picture itself.
      function pixel(el, x, y) {
        const size = el.tagName === 'CANVAS' ? [el.width, el.height] : el.tagName === 'VIDEO' ? [el.videoWidth, el.videoHeight]
          : el.tagName === 'IMG' ? [el.naturalWidth, el.naturalHeight] : null;
        if (!size || !(size[0] > 0 && size[1] > 0)) return null;
        const [w, h] = size;
        const r = el.getBoundingClientRect(), s = getComputedStyle(el), n = (v) => parseFloat(v) || 0;
        const left = r.left + n(s.borderLeftWidth) + n(s.paddingLeft), top = r.top + n(s.borderTopWidth) + n(s.paddingTop);
        const cw = r.width - n(s.borderLeftWidth) - n(s.borderRightWidth) - n(s.paddingLeft) - n(s.paddingRight);
        const ch = r.height - n(s.borderTopWidth) - n(s.borderBottomWidth) - n(s.paddingTop) - n(s.paddingBottom);
        if (!(cw > 0 && ch > 0)) return null;
        let fit = s.objectFit || 'fill';
        if (el.tagName === 'VIDEO' && fit === 'fill') fit = 'contain';
        const contain = Math.min(cw / w, ch / h), cover = Math.max(cw / w, ch / h);
        const k = fit === 'contain' ? contain : fit === 'cover' ? cover : fit === 'none' ? 1 : fit === 'scale-down' ? Math.min(1, contain) : null;
        const dw = k === null ? cw : w * k, dh = k === null ? ch : h * k;
        const [px, py] = (s.objectPosition || '50% 50%').split(/\s+/);
        const offset = (token, free) => token && token.endsWith('%') ? free * parseFloat(token) / 100 : token && token.endsWith('px') ? parseFloat(token) : free / 2;
        const ex = (x - left - offset(px, cw - dw)) * w / dw, ey = (y - top - offset(py, ch - dh)) * h / dh;
        if (ex < 0 || ey < 0 || ex >= w || ey >= h) return null;
        return { x: Math.floor(ex), y: Math.floor(ey), w, h };
      }
      window.__canvasMentions = {
        at(x, y, withPixel) {
          const el = hit(x, y);
          if (!el) return null;
          const found = describe(el);
          const point = withPixel ? pixel(el, x, y) : null;
          if (point) found.point = point;
          return found;
        },
        find(sel) { try { const el = document.querySelector(sel); return el ? describe(el) : null; } catch { return null; } },
        within,
        selection,
      };
    })();
    """#
}
