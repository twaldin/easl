import Foundation

@MainActor
enum HtmlHostRuntime {
    static let script = #"""
    <script>
    (() => {
      if (globalThis.__canvasHostHTTP) return;
      Object.defineProperty(globalThis, '__canvasHostHTTP', { value: true });
      const channel = globalThis.webkit?.messageHandlers?.canvas;
      if (!channel) return;
      const route = async value => {
        const reply = await channel.postMessage({ type: 'network.url', url: value });
        if (!reply?.url) throw new TypeError('Host URL is not allowed');
        return reply.url;
      };
      const originalFetch = globalThis.fetch.bind(globalThis);
      globalThis.fetch = async (input, options) => {
        const request = input instanceof Request ? input : null;
        const url = new URL(request ? request.url : input, document.baseURI);
        if (!['http:', 'https:'].includes(url.protocol)) return originalFetch(input, options);
        const proxy = await route(url.href);
        return originalFetch(request ? new Request(proxy, request) : proxy, options);
      };
      const rewrite = node => {
        if (!(node instanceof Element)) return;
        for (const name of ['src', 'href', 'poster']) {
          const value = node.getAttribute(name);
          if (!value || !/^https?:/i.test(value)) continue;
          route(new URL(value, document.baseURI).href).then(proxy => {
            if (node.getAttribute(name) !== value) return;
            if (node.tagName === 'SCRIPT' && name === 'src') {
              const replacement = node.cloneNode(true);
              replacement.setAttribute(name, proxy);
              node.replaceWith(replacement);
            } else node.setAttribute(name, proxy);
          });
        }
      };
      new MutationObserver(changes => {
        for (const change of changes) {
          if (change.type === 'attributes') rewrite(change.target);
          for (const node of change.addedNodes) {
            rewrite(node);
            if (node instanceof Element) node.querySelectorAll('[src],[href],[poster]').forEach(rewrite);
          }
        }
      }).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['src', 'href', 'poster'] });
    })();
    </script>
    """#

    static func document(_ html: String, base: URL) -> String {
        let escaped = base.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let head = "<base href=\"\(escaped)\">" + script
        let range = html.range(of: "<head(?:\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive])
            ?? html.range(of: "<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive])
        guard let range else { return head + html }
        var result = html
        result.insert(contentsOf: head, at: range.upperBound)
        return result
    }
}
