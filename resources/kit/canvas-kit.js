// The HTML kit: preloaded into every HTML tile. Themes Tailwind to the app, renders Mermaid
// diagrams, and defines the kit's web components. The page's only native access is the
// `canvas` message channel; the app validates every message (Sources/CanvasCore/HtmlMessage.swift).
(() => {
  const handler = window.webkit?.messageHandlers?.canvas;
  const post = (message) => handler ? handler.postMessage(message) : Promise.reject(new Error('no canvas channel'));

  // Tailwind v4 theme: the app palette as utilities (bg-background, text-muted-foreground, …).
  const theme = document.createElement('style');
  theme.type = 'text/tailwindcss';
  theme.textContent = `@theme inline {
    --color-background: var(--canvas-background);
    --color-foreground: var(--canvas-foreground);
    --color-muted: var(--canvas-muted);
    --color-muted-foreground: var(--canvas-muted-foreground);
    --color-border: var(--canvas-border);
    --color-card: var(--canvas-card);
    --color-accent: var(--canvas-accent);
    --color-accent-foreground: var(--canvas-accent-foreground);
    --color-code: var(--canvas-code);
    --color-warn: var(--canvas-warn);
    --color-ok: var(--canvas-ok);
    --font-sans: var(--canvas-font);
    --font-mono: var(--canvas-mono);
  }`;
  document.head.append(theme);

  // Rendering bookkeeping: the app refreshes the tile snapshot when the page settles, and
  // restores the scroll position across re-renders once async content has laid out.
  let pending = 0;
  let restoreY = null;
  let settleTimer = 0;
  const settle = () => {
    clearTimeout(settleTimer);
    settleTimer = setTimeout(() => {
      if (pending > 0) return;
      // Async components can introduce a font's first use after the initial font load.
      document.documentElement.getBoundingClientRect();
      if (document.fonts.status === 'loading') {
        track(document.fonts.ready);
        return;
      }
      if (restoreY !== null) { window.scrollTo(0, restoreY); restoreY = null; }
      post({ type: 'view.rendered', scrollY: Math.max(0, Math.round(window.scrollY)) }).catch(() => {});
    }, 200);
  };
  const track = async (work) => {
    pending++;
    try { return await work; } finally { pending--; settle(); }
  };
  let initialLoad = document.readyState !== 'complete';
  const initialFiles = new WeakSet();
  const fetch = window.fetch;
  window.fetch = function (...args) {
    const work = fetch.apply(this, args);
    if (!initialLoad) return work;
    try {
      const url = new URL(args[0]?.url ?? args[0], document.baseURI);
      if (url.protocol !== 'canvas-kit:' || url.host !== location.host) return work;
    } catch { return work; }
    return track(work.then((response) => { initialFiles.add(response); return response; }));
  };
  for (const method of ['arrayBuffer', 'blob', 'formData', 'json', 'text']) {
    const read = Response.prototype[method];
    Response.prototype[method] = function (...args) {
      const work = read.apply(this, args);
      return initialFiles.has(this) ? track(work) : work;
    };
  }
  const clone = Response.prototype.clone;
  Response.prototype.clone = function (...args) {
    const response = clone.apply(this, args);
    if (initialFiles.has(this)) initialFiles.add(response);
    return response;
  };
  if (initialLoad) {
    track(new Promise((resolve) => addEventListener('load', () => setTimeout(() => { initialLoad = false; resolve(); }), { once: true })));
  }
  addEventListener('scroll', settle, { passive: true });
  addEventListener('resize', settle);

  // Tile state (props.state), kept in sync by the app when it changes elsewhere.
  let state = null;
  const stateListeners = new Set();
  const loadState = () => state ? Promise.resolve(state) : post({ type: 'state.get' }).then((reply) => (state = reply.value || {}));

  const canvasKit = {
    openCode(path, { line, lines, symbol } = {}) {
      const message = { type: 'code.open', path };
      if (lines || line) message.lines = String(lines || line);
      if (symbol) message.symbol = symbol;
      return post(message);
    },
    excerpt(path, { lines, symbol } = {}) {
      const message = { type: 'code.excerpt', path };
      if (lines) message.lines = String(lines);
      if (symbol) message.symbol = symbol;
      return post(message);
    },
    // Queues `payload` (any JSON value, at most 64 KiB) for the agent terminal that created
    // this tile. The page cannot name a sender or a gesture. easl treats the payload as
    // untrusted page content. Resolves with {terminal, message} once queued, else rejects
    // with the refusal (a user-created tile, a creator that is gone or below protocol 3,
    // a remote board, or a cap).
    send(payload) {
      return post({ type: 'send', payload: payload === undefined ? null : payload });
    },
    async getState(key) {
      const all = await loadState();
      return key === undefined ? all : all[key];
    },
    async setState(key, value) {
      await post({ type: 'state.set', key, value: value === undefined ? null : value });
      state = { ...(state || {}) };
      if (value === undefined || value === null) delete state[key]; else state[key] = value;
      stateListeners.forEach((fn) => fn(state));
      settle();
    },
    onState(fn) { stateListeners.add(fn); return () => stateListeners.delete(fn); },
    // Called by the app when props.state changed outside the page.
    receiveState(next) {
      state = next || {};
      stateListeners.forEach((fn) => fn(state));
      settle();
    },
    // Called by the app after a re-render with the previous scroll position.
    restoreScroll(y) { restoreY = y; window.scrollTo(0, y); settle(); },
    renderMermaid: () => renderMermaid(),
  };
  window.canvasKit = canvasKit;

  // Elements defined before the parser reaches them connect before their children exist;
  // components that read their children wait for the document to finish parsing.
  const whenParsed = (fn) => {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fn, { once: true });
    else fn();
  };

  // ---- Syntax highlighting (lexical, per language family) ----

  const keywordSets = {
    swift: 'actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while',
    typescript: 'abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let new null of private protected public readonly return set static super switch this throw true try type typeof undefined var void while yield',
    python: 'and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return self True try while with yield',
    rust: 'as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while',
    go: 'break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var',
    c: 'auto break case char class const continue default delete do double else enum extern false float for goto if inline int long namespace new nullptr private protected public return short signed sizeof static struct switch template this true typedef typename union unsigned using virtual void volatile while',
    shell: 'case do done elif else esac export fi for function if in local return then until while',
  };
  keywordSets.javascript = keywordSets.typescript;
  keywordSets.cpp = keywordSets.objc = keywordSets.java = keywordSets.kotlin = keywordSets.csharp = keywordSets.zig = keywordSets.c;
  const keywords = Object.fromEntries(Object.entries(keywordSets).map(([k, v]) => [k, new Set(v.split(' '))]));
  const hashComments = new Set(['python', 'shell', 'ruby', 'yaml', 'toml']);

  const escapeHTML = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  function highlight(line, language) {
    const words = keywords[language];
    const comment = hashComments.has(language) ? '#.*' : language === 'sql' || language === 'lua' ? '--.*' : '\\/\\/.*|\\/\\*.*?(?:\\*\\/|$)';
    const token = new RegExp(`(${comment})|("(?:\\\\.|[^"\\\\])*"?|'(?:\\\\.|[^'\\\\])*'?|\`(?:\\\\.|[^\`\\\\])*\`?)|(\\b\\d[\\d_]*(?:\\.\\d+)?\\b)|([A-Za-z_$][\\w$]*)`, 'g');
    let out = '';
    let last = 0;
    for (const m of line.matchAll(token)) {
      out += escapeHTML(line.slice(last, m.index));
      const text = escapeHTML(m[0]);
      if (m[1]) out += `<span class="tok-c">${text}</span>`;
      else if (m[2]) out += `<span class="tok-s">${text}</span>`;
      else if (m[3]) out += `<span class="tok-n">${text}</span>`;
      else if (words?.has(m[4])) out += `<span class="tok-k">${text}</span>`;
      else if (words && /^[A-Z]/.test(m[4])) out += `<span class="tok-t">${text}</span>`;
      else out += text;
      last = m.index + m[0].length;
    }
    return out + escapeHTML(line.slice(last));
  }

  // ---- <canvas-code path="…" lines="10-40" symbol="Name"> ----

  class CanvasCode extends HTMLElement {
    static observedAttributes = ['path', 'lines', 'symbol'];

    connectedCallback() {
      if (!this.hasAttribute('title')) this.title = 'Open in a code tile';
      if (!this.listening) {
        this.listening = true;
        this.addEventListener('click', (event) => {
          if (event.target.closest('a, canvas-link')) return;
          const path = this.getAttribute('path');
          if (!path) return;
          const resolved = this.excerpt && this.excerpt.start > 0 ? `${this.excerpt.start}-${this.excerpt.end}` : this.getAttribute('lines');
          canvasKit.openCode(path, { lines: resolved, symbol: this.getAttribute('symbol') }).catch((error) => this.showError(error));
        });
      }
      this.load();
    }

    attributeChangedCallback() { if (this.isConnected) this.load(); }

    load() {
      const path = this.getAttribute('path');
      if (!path) {
        this.request = (this.request || 0) + 1;
        this.loadedKey = this.excerpt = null;
        return this.showError(new Error('<canvas-code> needs a path'));
      }
      const lines = this.getAttribute('lines');
      const symbol = this.getAttribute('symbol');
      const key = `${path}|${lines}|${symbol}`;
      if (key === this.loadedKey) return;
      this.loadedKey = key;
      // A new target: drop the old excerpt so clicks and a late reply can't mix the two.
      const request = (this.request = (this.request || 0) + 1);
      this.excerpt = null;
      this.innerHTML = `<div class="ck-head"><span class="ck-path">${escapeHTML(path)}</span></div>`;
      const current = () => request === this.request;
      track(canvasKit.excerpt(path, { lines, symbol }).then((excerpt) => current() && this.render(excerpt), (error) => current() && this.showError(error)));
    }

    render(excerpt) {
      this.excerpt = excerpt;
      const range = excerpt.start > 0 ? (excerpt.start === excerpt.end ? `:${excerpt.start}` : `:${excerpt.start}-${excerpt.end}`) : '';
      const head = `<div class="ck-head"><span class="ck-path">${escapeHTML(excerpt.path + range)}</span>`
        + (excerpt.symbol ? `<span class="ck-symbol">${escapeHTML(excerpt.symbol)}</span>` : '')
        + (excerpt.stale ? `<span class="ck-stale" title="${escapeHTML(excerpt.reason || '')}">stale</span>` : '')
        + '</div>';
      // Long lines soft-wrap like a code tile's rows: continuations indented by the line's own
      // indentation (tabs to 4 columns) plus 2 columns.
      const indent = (text) => {
        let column = 0;
        for (const ch of text) {
          if (ch === ' ') column += 1;
          else if (ch === '\t') column += 4 - (column % 4);
          else break;
        }
        return column + 2;
      };
      const rows = excerpt.lines.map((text, i) => `<div class="ck-line" data-line="${excerpt.start + i}"><span class="ck-ln">${excerpt.start + i}</span><span class="ck-text" style="--ck-indent:${indent(text)}ch">${highlight(text, excerpt.language)}</span></div>`).join('');
      const notes = (excerpt.stale && excerpt.reason ? `<div class="ck-note">${escapeHTML(excerpt.reason)}</div>` : '')
        + (excerpt.truncated ? `<div class="ck-note">… truncated</div>` : '');
      this.innerHTML = `${head}<div class="ck-body">${rows}${notes}</div>`;
    }

    showError(error) {
      const path = escapeHTML(this.getAttribute('path') || '');
      this.innerHTML = `<div class="ck-head"><span class="ck-path">${path}</span><span class="ck-error">error</span></div><div class="ck-note">${escapeHTML(error.message || String(error))}</div>`;
    }
  }

  // ---- <canvas-link path="…" line="N"> ----

  class CanvasLink extends HTMLElement {
    connectedCallback() {
      if (this.listening) return;
      this.listening = true;
      whenParsed(() => {
        const path = this.getAttribute('path') || '';
        const line = this.getAttribute('line') || this.getAttribute('lines');
        if (!this.textContent.trim()) this.textContent = line ? `${path}:${line}` : path;
      });
      this.setAttribute('role', 'link');
      this.tabIndex = 0;
      const open = (event) => {
        event.preventDefault();
        event.stopPropagation();
        const target = this.getAttribute('line') || this.getAttribute('lines');
        canvasKit.openCode(this.getAttribute('path'), { lines: target, symbol: this.getAttribute('symbol') }).catch((error) => { this.title = error.message; });
      };
      this.addEventListener('click', open);
      this.addEventListener('keydown', (event) => { if (event.key === 'Enter') open(event); });
    }
  }

  // ---- <canvas-decisions key="…" question="…"><canvas-option value="…" label="…">detail</canvas-option> ----

  class CanvasDecisions extends HTMLElement {
    connectedCallback() {
      if (this.built) return;
      this.built = true;
      whenParsed(() => this.build());
    }

    build() {
      this.key = this.getAttribute('key') || this.id;
      const options = [...this.querySelectorAll(':scope > canvas-option')];
      const question = this.getAttribute('question');
      const list = document.createElement('div');
      list.className = 'ck-options';
      list.setAttribute('role', 'radiogroup');
      for (const option of options) {
        const label = option.getAttribute('label') || option.getAttribute('value') || '';
        const detail = option.innerHTML;
        option.setAttribute('role', 'radio');
        option.innerHTML = `<div class="ck-label"><span>${escapeHTML(label)}</span><span class="ck-mark">✓ chosen</span></div>` + (detail.trim() ? `<div class="ck-detail">${detail}</div>` : '');
        option.addEventListener('click', () => this.choose(option.getAttribute('value')));
        list.append(option);
      }
      this.replaceChildren();
      if (question) {
        const heading = document.createElement('div');
        heading.className = 'ck-question';
        heading.textContent = question;
        this.append(heading);
      }
      this.append(list);
      if (!this.key) return this.append(Object.assign(document.createElement('div'), { className: 'ck-note', textContent: '<canvas-decisions> needs a key' }));
      canvasKit.onState((next) => this.show(next[this.key]));
      track(canvasKit.getState(this.key).then((value) => this.show(value), () => {}));
    }

    show(value) {
      for (const option of this.querySelectorAll('canvas-option')) {
        option.setAttribute('aria-checked', String(value != null && option.getAttribute('value') === value));
      }
    }

    choose(value) {
      if (!this.key || value == null) return;
      const current = this.querySelector('canvas-option[aria-checked="true"]')?.getAttribute('value');
      canvasKit.setState(this.key, current === value ? null : value).catch(() => {});
    }
  }

  customElements.define('canvas-code', CanvasCode);
  customElements.define('canvas-link', CanvasLink);
  customElements.define('canvas-decisions', CanvasDecisions);

  // ---- Mermaid: loaded only when the page has diagrams (it is large) ----

  let mermaidReady = null;
  function mermaidBlocks() {
    for (const code of document.querySelectorAll('pre > code.language-mermaid')) {
      const div = document.createElement('div');
      div.className = 'mermaid';
      div.textContent = code.textContent;
      code.parentElement.replaceWith(div);
    }
    for (const pre of document.querySelectorAll('pre:not(.mermaid)')) {
      const text = pre.textContent.trim();
      if (!text.startsWith('```mermaid')) continue;
      const div = document.createElement('div');
      div.className = 'mermaid';
      div.textContent = text.replace(/^```mermaid[^\n]*\n?/, '').replace(/```$/, '');
      pre.replaceWith(div);
    }
    return [...document.querySelectorAll('.mermaid:not([data-processed])')];
  }

  function renderMermaid() {
    const nodes = mermaidBlocks();
    if (!nodes.length) return Promise.resolve();
    mermaidReady ||= new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = '/kit/vendor/mermaid.min.js';
      script.onload = () => {
        const dark = matchMedia('(prefers-color-scheme: dark)').matches;
        window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default', fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--canvas-font') });
        resolve(window.mermaid);
      };
      script.onerror = () => reject(new Error('mermaid failed to load'));
      document.head.append(script);
    });
    return track(mermaidReady.then((mermaid) => mermaid.run({ nodes })).catch((error) => console.error(error)));
  }

  // ---- Math: KaTeX loaded only when the page has formulas (it is large) ----

  let katexReady = null;
  function loadKatex() {
    katexReady ||= new Promise((resolve, reject) => {
      const style = document.createElement('link');
      style.rel = 'stylesheet';
      style.href = '/kit/vendor/katex/katex.min.css';
      document.head.append(style);
      const script = document.createElement('script');
      script.src = '/kit/vendor/katex/katex.min.js';
      script.onload = () => resolve(window.katex);
      script.onerror = () => reject(new Error('katex failed to load'));
      document.head.append(script);
    });
    return katexReady;
  }

  // The formulas in one text node, in order: `$…$` and `$$…$$` (Pandoc's rule keeps `$5 and $10`
  // prose), plus `\(…\)` and `\[…\]`. `\$` is a literal dollar.
  function mathSpans(text) {
    const spans = [];
    let i = 0;
    while (i < text.length) {
      if (text[i] === '\\') {
        const opener = text[i + 1];
        if (opener === '(' || opener === '[') {
          const close = opener === '(' ? '\\)' : '\\]';
          const end = text.indexOf(close, i + 2);
          if (end > i + 2) {
            spans.push({ start: i, end: end + 2, latex: text.slice(i + 2, end), display: opener === '[' });
            i = end + 2;
            continue;
          }
        }
        i += 2;
        continue;
      }
      if (text[i] !== '$') { i++; continue; }
      if (text[i + 1] === '$') {
        const end = text.indexOf('$$', i + 2);
        const latex = end > i + 2 ? text.slice(i + 2, end).trim() : '';
        if (latex) {
          spans.push({ start: i, end: end + 2, latex, display: true });
          i = end + 2;
          continue;
        }
        i += 2;
        continue;
      }
      if (i + 1 >= text.length || /\s/.test(text[i + 1])) { i++; continue; }
      let close = -1;
      for (let j = i + 1; j < text.length; j++) {
        if (text[j] === '\\') { j++; continue; }
        if (text[j] === '$') {
          // A `$` that can't close here can't be inside math either: the formula would have
          // swallowed currency (`$5 and $10 … $x$`), so this candidate is prose.
          if (!/\s/.test(text[j - 1]) && !/[0-9]/.test(text[j + 1] ?? '')) close = j;
          break;
        }
      }
      if (close < 0) { i++; continue; }
      spans.push({ start: i, end: close + 1, latex: text.slice(i + 1, close), display: false });
      i = close + 1;
    }
    return spans;
  }

  function mathNode(node, spans, katex) {
    const value = node.nodeValue;
    const fragment = document.createDocumentFragment();
    let cursor = 0;
    for (const span of spans) {
      if (span.start > cursor) fragment.append(value.slice(cursor, span.start));
      const holder = document.createElement('span');
      holder.className = span.display ? 'canvas-math-display' : 'canvas-math';
      holder.innerHTML = katex.renderToString(span.latex, { displayMode: span.display, throwOnError: false });
      fragment.append(holder);
      cursor = span.end;
    }
    if (cursor < value.length) fragment.append(value.slice(cursor));
    node.replaceWith(fragment);
  }

  function renderMath() {
    if (!document.body) return Promise.resolve();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const value = node.nodeValue;
        if (!value.includes('$') && !value.includes('\\(') && !value.includes('\\[')) return NodeFilter.FILTER_REJECT;
        if (node.parentElement?.closest('pre, code, script, style, textarea, canvas-code, .mermaid, .katex, .canvas-math')) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    const jobs = [];
    while (walker.nextNode()) {
      const spans = mathSpans(walker.currentNode.nodeValue);
      if (spans.length) jobs.push([walker.currentNode, spans]);
    }
    if (!jobs.length) return Promise.resolve();
    return track(loadKatex().then((katex) => {
      for (const [node, spans] of jobs) mathNode(node, spans, katex);
    }).catch((error) => console.error(error)));
  }

  const start = () => {
    const images = [...document.images].map((image) => new Promise((resolve) => {
      const done = () => {
        image.removeEventListener('load', done);
        image.removeEventListener('error', done);
        resolve();
      };
      image.addEventListener('load', done, { once: true });
      image.addEventListener('error', done, { once: true });
      // Exact offscreen sizes need images even outside the one-point measure viewport.
      image.loading = 'eager';
      if (image.complete) done();
    }));
    track(Promise.all(images));
    renderMermaid();
    renderMath();
    settle();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
