import WebKit

/// Page-side half of the cmux subset. Runs in its own content world so pages can neither see
/// nor break it, while acting on the same DOM (events it dispatches reach page listeners).
@MainActor
enum BrowserScripts {
    static let world = WKContentWorld.world(name: "canvas-cmux")
    /// Message handler (in `world`) for page activity: `changed`, `ready`, `load`.
    static let messageName = "canvasBrowser"
    /// Message handler (in `world`) for a select menu a streamed page relays (`BrowserSurface`).
    static let selectMessageName = "canvasSelect"
    static let fileMessageName = "canvasFile"

    /// Prefix for calls into the helper: installs it first on documents that loaded before the
    /// user script could run (the initial about:blank, pages restored from the back cache).
    static let ensure = "if (!window.__canvasCmux) {\n\(source)\n}\n"

    static let source = #"""
    (() => {
      if (window.__canvasCmux) return;
      const post = (kind) => { try { window.webkit.messageHandlers.canvasBrowser.postMessage(kind); } catch {} };
      const fail = (code, message) => { const error = new Error(message); error.name = code; throw error; };

      // Snapshot refs (e1, e2, …) name elements until the next snapshot replaces them.
      let refs = new Map();

      function resolve(selector) {
        const ref = /^@?(e\d+)$/.exec(selector);
        if (ref) {
          const element = refs.get(ref[1])?.deref();
          if (!element || !element.isConnected) fail('not_found', `ref ${selector} is gone; take a new snapshot`);
          return element;
        }
        let element;
        try { element = document.querySelector(selector); } catch { fail('invalid_params', `invalid selector ${selector}`); }
        if (!element) fail('not_found', `no element matches ${selector}`);
        return element;
      }

      function exists(selector) {
        try { return !!resolve(selector); } catch (error) { if (error.name === 'not_found') return false; throw error; }
      }

      // MARK: roles and names (enough of ARIA for agents to pick targets)

      const inputRoles = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
        image: 'button', range: 'slider', number: 'spinbutton', search: 'searchbox', email: 'textbox', tel: 'textbox',
        url: 'textbox', text: 'textbox', password: 'textbox', '': 'textbox' };
      const tagRoles = { A: (el) => el.hasAttribute('href') ? 'link' : null, BUTTON: () => 'button',
        SELECT: (el) => el.multiple || el.size > 1 ? 'listbox' : 'combobox', TEXTAREA: () => 'textbox',
        INPUT: (el) => el.type === 'hidden' ? null : (inputRoles[el.type] ?? 'textbox'), SUMMARY: () => 'button',
        H1: () => 'heading', H2: () => 'heading', H3: () => 'heading', H4: () => 'heading', H5: () => 'heading', H6: () => 'heading',
        IMG: (el) => el.getAttribute('alt') === '' ? null : 'img', NAV: () => 'navigation', MAIN: () => 'main',
        HEADER: () => 'banner', FOOTER: () => 'contentinfo', ASIDE: () => 'complementary', FORM: () => 'form',
        UL: () => 'list', OL: () => 'list', LI: () => 'listitem', TABLE: () => 'table', TR: () => 'row',
        TD: () => 'cell', TH: () => 'columnheader', LABEL: () => 'label', P: () => 'paragraph', DIALOG: () => 'dialog',
        FIELDSET: () => 'group', LEGEND: () => 'legend', OPTION: () => 'option', IFRAME: () => 'iframe' };
      const interactiveRoles = new Set(['link', 'button', 'checkbox', 'radio', 'textbox', 'searchbox', 'combobox', 'listbox',
        'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'option', 'menuitemcheckbox', 'menuitemradio', 'treeitem']);

      const roleOf = (el) => el.getAttribute('role')?.split(' ')[0] || tagRoles[el.tagName]?.(el) || null;
      const clean = (text, limit = 100) => (text || '').replace(/\s+/g, ' ').trim().slice(0, limit);

      function nameOf(el) {
        const labelled = el.getAttribute('aria-labelledby');
        if (labelled) {
          const text = labelled.split(' ').map((id) => document.getElementById(id)?.innerText || '').join(' ');
          if (clean(text)) return clean(text);
        }
        const direct = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title');
        if (clean(direct)) return clean(direct);
        if (el.labels && el.labels.length) return clean([...el.labels].map((label) => label.innerText).join(' '));
        if (el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(el.type)) return clean(el.value || el.type);
        if (el.placeholder) return clean(el.placeholder);
        if (['INPUT', 'SELECT', 'TEXTAREA'].includes(el.tagName)) return clean(el.name);
        return clean(el.innerText);
      }

      // Nothing under these renders, so the walk skips the whole subtree.
      const hidesSubtree = (el, style) => el.getAttribute('aria-hidden') === 'true' || style.display === 'none';

      // Whether the element itself has a visible box. Layoutless `display: contents` wrappers and
      // `visibility: hidden` elements don't, though their children still may.
      function rendersBox(el, style) {
        if (style.display === 'contents' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      }

      const isVisible = (el) => { const style = getComputedStyle(el); return !hidesSubtree(el, style) && rendersBox(el, style); };

      const isInteractive = (el, role) => interactiveRoles.has(role) || el.isContentEditable
        || (el.hasAttribute('onclick') && !['BODY', 'HTML'].includes(el.tagName))
        || (el.tabIndex >= 0 && el.hasAttribute('tabindex'));

      function describe(el, role) {
        let line = `${role || 'generic'}`;
        const name = nameOf(el);
        if (name) line += ` ${JSON.stringify(name)}`;
        if (role === 'heading') line += ` [level=${el.tagName[1] || el.getAttribute('aria-level') || 2}]`;
        if ('checked' in el && (role === 'checkbox' || role === 'radio')) line += el.checked ? ' [checked]' : '';
        if (el.disabled) line += ' [disabled]';
        if (['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider'].includes(role) && 'value' in el && el.value && el.type !== 'password') {
          line += `: ${JSON.stringify(clean(el.value, 200))}`;
        }
        return line;
      }

      // Interactive: a flat list of what an agent can act on. Otherwise: the semantic outline.
      function snapshot(interactive, maxDepth) {
        refs = new Map();
        const entries = {};
        const lines = [];
        let next = 1;
        const add = (el, role, depth) => {
          const ref = `e${next++}`;
          refs.set(ref, new WeakRef(el));
          entries[ref] = { role: role || 'generic', name: nameOf(el) };
          lines.push(`${'  '.repeat(depth)}- ${describe(el, role)} [ref=${ref}]`);
        };
        const walk = (el, depth) => {
          if (!interactive && depth >= (maxDepth ?? Infinity)) return;
          for (const child of el.children) {
            const style = getComputedStyle(child);
            if (hidesSubtree(child, style)) continue;
            const role = roleOf(child);
            const actionable = isInteractive(child, role);
            const listed = interactive ? actionable : (actionable || (role && !['generic', 'none', 'presentation', 'label', 'legend'].includes(role)));
            const shown = listed && rendersBox(child, style);
            if (shown) add(child, role, interactive ? 0 : depth);
            if (child.shadowRoot) walk(child.shadowRoot, shown ? depth + 1 : depth);
            if (!shown || !['SELECT', 'BUTTON', 'A'].includes(child.tagName)) walk(child, shown ? depth + 1 : depth);
          }
        };
        if (document.body) walk(document.body, 0);
        const page = { title: document.title, url: location.href, ready_state: document.readyState };
        if (!interactive) {
          page.text = document.body ? document.body.innerText : '';
          page.html = document.documentElement.outerHTML;
        }
        return { snapshot: lines.join('\n'), refs: entries, page, url: location.href, title: document.title, ready_state: document.readyState };
      }

      // MARK: actions

      const center = (el) => { const r = el.getBoundingClientRect(); return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }; };
      const mouse = (el, type, extra = {}) => {
        const Kind = type.startsWith('pointer') ? PointerEvent : MouseEvent;
        return el.dispatchEvent(new Kind(type, { bubbles: true, cancelable: true, composed: true, view: window, button: 0, buttons: type.endsWith('down') ? 1 : 0, ...center(el), ...extra }));
      };
      const fire = (el, type) => el.dispatchEvent(new Event(type, { bubbles: true, cancelable: type !== 'change' && type !== 'input' ? true : false }));
      const focusable = (el) => typeof el.focus === 'function';

      function click(el, detail = 1) {
        el.scrollIntoView({ block: 'center', inline: 'center' });
        mouse(el, 'pointerdown', { detail }); mouse(el, 'mousedown', { detail });
        if (focusable(el)) el.focus({ preventScroll: true });
        mouse(el, 'pointerup', { detail }); mouse(el, 'mouseup', { detail });
        // SVG and MathML elements have no click(); dispatch the event itself.
        if (typeof el.click === 'function') el.click(); else mouse(el, 'click', { detail });
      }

      // Sets a form control's value the way user input does, so framework listeners see it.
      function setValue(el, value) {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
          : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        if (setter) setter.call(el, value); else el.value = value;
      }

      const textTypes = new Set(['text', 'search', 'url', 'tel', 'email', 'password', 'number']);
      const isTextField = (el) => el instanceof HTMLTextAreaElement || (el instanceof HTMLInputElement && textTypes.has(el.type));
      const editingHost = (el) => { while (el.parentElement?.isContentEditable) el = el.parentElement; return el; };

      // [anchor, focus] of a text field's selection. Types without a selection API (email,
      // number) behave as if the caret sat at the end.
      function selectionOf(el) {
        try {
          if (el.selectionStart !== null) {
            return el.selectionDirection === 'backward' ? [el.selectionEnd, el.selectionStart] : [el.selectionStart, el.selectionEnd];
          }
        } catch {}
        return [el.value.length, el.value.length];
      }

      function setSelection(el, anchor, focus) {
        try { el.setSelectionRange(Math.min(anchor, focus), Math.max(anchor, focus), focus < anchor ? 'backward' : 'forward'); } catch {}
      }

      // Replaces `from`..`to` of a text field the way typing or deleting does.
      function replaceRange(el, from, to, text, inputType) {
        const init = { bubbles: true, inputType, data: text || null };
        if (!el.dispatchEvent(new InputEvent('beforeinput', { ...init, cancelable: true }))) return;
        setValue(el, el.value.slice(0, from) + text + el.value.slice(to));
        setSelection(el, from + text.length, from + text.length);
        el.dispatchEvent(new InputEvent('input', init));
      }

      function insertText(el, text) {
        if (el.isContentEditable) {
          document.execCommand('insertText', false, text);
          return;
        }
        if (!('value' in el) || typeof el.value !== 'string') fail('invalid_params', `${el.tagName.toLowerCase()} does not take text`);
        const [anchor, focus] = selectionOf(el);
        replaceRange(el, Math.min(anchor, focus), Math.max(anchor, focus), text, 'insertText');
      }

      function key(el, type, init) {
        return el.dispatchEvent(new KeyboardEvent(type, { bubbles: true, cancelable: true, composed: true, ...init }));
      }

      // MARK: keyboard defaults (synthetic key events carry none, so the editing ones are done here)

      const lineStart = (value, i) => (i === 0 ? 0 : value.lastIndexOf('\n', i - 1) + 1);
      const lineEnd = (value, i) => { const end = value.indexOf('\n', i); return end < 0 ? value.length : end; };
      const wordBefore = (value, i) => { while (i > 0 && /\s/.test(value[i - 1])) i--; while (i > 0 && !/\s/.test(value[i - 1])) i--; return i; };
      const wordAfter = (value, i) => { while (i < value.length && /\s/.test(value[i])) i++; while (i < value.length && !/\s/.test(value[i])) i++; return i; };

      // Where a caret key puts the focus end of a text field's selection (macOS conventions).
      function caretTarget(el, name, mods, focus) {
        const value = el.value;
        const multiline = el instanceof HTMLTextAreaElement;
        const start = multiline ? lineStart(value, focus) : 0;
        const end = multiline ? lineEnd(value, focus) : value.length;
        switch (name) {
          case 'ArrowLeft': return mods.meta ? start : mods.alt ? wordBefore(value, focus) : Math.max(0, focus - 1);
          case 'ArrowRight': return mods.meta ? end : mods.alt ? wordAfter(value, focus) : Math.min(value.length, focus + 1);
          case 'Home': return start;
          case 'End': return end;
          case 'PageUp': return 0;
          case 'PageDown': return value.length;
          case 'ArrowUp': {
            if (mods.meta || start === 0) return 0;
            const previous = lineStart(value, start - 1);
            return Math.min(previous + focus - start, start - 1);
          }
          case 'ArrowDown': {
            if (mods.meta || end === value.length) return value.length;
            return Math.min(end + 1 + focus - start, lineEnd(value, end + 1));
          }
        }
      }

      function moveCaret(el, name, mods) {
        if (el.isContentEditable) {
          const backward = ['ArrowLeft', 'ArrowUp', 'Home', 'PageUp'].includes(name);
          const vertical = ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown'].includes(name);
          const granularity = mods.alt ? 'word'
            : mods.meta ? (vertical ? 'documentboundary' : 'lineboundary')
            : name === 'Home' || name === 'End' ? 'lineboundary'
            : name.startsWith('Page') ? 'documentboundary'
            : vertical ? 'line' : 'character';
          getSelection().modify(mods.shift ? 'extend' : 'move', backward ? 'backward' : 'forward', granularity);
          return;
        }
        const [anchor, focus] = selectionOf(el);
        if (!mods.shift && !mods.alt && !mods.meta && anchor !== focus && (name === 'ArrowLeft' || name === 'ArrowRight')) {
          const edge = name === 'ArrowLeft' ? Math.min(anchor, focus) : Math.max(anchor, focus);
          return setSelection(el, edge, edge);
        }
        const to = caretTarget(el, name, mods, focus);
        setSelection(el, mods.shift ? anchor : to, to);
      }

      function deleteText(el, name, mods) {
        const backward = name === 'Backspace';
        if (el.isContentEditable) {
          const selection = getSelection();
          if (selection.isCollapsed && (mods.alt || mods.meta)) {
            selection.modify('extend', backward ? 'backward' : 'forward', mods.alt ? 'word' : 'lineboundary');
          }
          document.execCommand(backward ? 'delete' : 'forwardDelete');
          return;
        }
        const value = el.value;
        const [anchor, focus] = selectionOf(el);
        let from = Math.min(anchor, focus), to = Math.max(anchor, focus);
        if (from === to) {
          const multiline = el instanceof HTMLTextAreaElement;
          if (backward) from = mods.meta ? (multiline ? lineStart(value, from) : 0) : mods.alt ? wordBefore(value, from) : Math.max(0, from - 1);
          else to = mods.meta ? (multiline ? lineEnd(value, to) : value.length) : mods.alt ? wordAfter(value, to) : Math.min(value.length, to + 1);
        }
        if (from !== to) replaceRange(el, from, to, '', backward ? 'deleteContentBackward' : 'deleteContentForward');
      }

      function selectAll(el) {
        if (isTextField(el)) return el.select();
        getSelection().selectAllChildren(el.isContentEditable ? editingHost(el) : document.body);
      }

      function scrollPage(name, mods) {
        const line = 40, page = innerHeight * 0.875;
        switch (name) {
          case 'ArrowUp': return mods.meta ? scrollTo(scrollX, 0) : scrollBy(0, -line);
          case 'ArrowDown': return mods.meta ? scrollTo(scrollX, document.documentElement.scrollHeight) : scrollBy(0, line);
          case 'ArrowLeft': return scrollBy(-line, 0);
          case 'ArrowRight': return scrollBy(line, 0);
          case 'PageUp': return scrollBy(0, -page);
          case 'PageDown': return scrollBy(0, page);
          case ' ': return scrollBy(0, mods.shift ? -page : page);
          case 'Home': return scrollTo(scrollX, 0);
          case 'End': return scrollTo(scrollX, document.documentElement.scrollHeight);
        }
      }

      const tabbable = () => [...document.querySelectorAll('a[href], button, input, select, textarea, [tabindex], [contenteditable=""], [contenteditable="true"]')]
        .filter((el) => !el.disabled && el.tabIndex >= 0 && isVisible(el));

      // Enter in a form field submits the way the browser's implicit submission does: through
      // the default button when there is one, so its click handlers run.
      function submitImplicitly(input) {
        const submitter = input.form.querySelector('button:not([type]), button[type="submit"], input[type="submit"], input[type="image"]');
        if (submitter) { if (!submitter.disabled) submitter.click(); return; }
        input.form.requestSubmit();
      }

      function defaultAction(target, name, mods, shortcut) {
        const editable = isTextField(target) || target.isContentEditable;
        const keys = { shift: mods.shift, alt: mods.alt, meta: shortcut };
        if (shortcut && name.toLowerCase() === 'a') return selectAll(target);
        if (caretKeys.has(name)) return editable ? moveCaret(target, name, keys) : scrollPage(name, keys);
        if (name === 'Backspace' || name === 'Delete') return editable ? deleteText(target, name, keys) : undefined;
        // Other shortcuts belong to the page: its key handlers are the whole effect.
        if (shortcut || mods.alt) return;
        switch (name) {
          case 'Enter':
            if (target instanceof HTMLTextAreaElement || target.isContentEditable) return insertText(target, '\n');
            if (target instanceof HTMLInputElement && target.form) return submitImplicitly(target);
            if (target instanceof HTMLButtonElement || target instanceof HTMLAnchorElement) return target.click();
            return;
          case 'Tab': {
            const order = tabbable();
            if (!order.length) return;
            const index = order.indexOf(target);
            const step = mods.shift ? -1 : 1;
            order[index < 0 ? (step > 0 ? 0 : order.length - 1) : (index + step + order.length) % order.length].focus();
            return;
          }
          case ' ':
            if (target instanceof HTMLButtonElement || (target instanceof HTMLInputElement && ['checkbox', 'radio', 'button', 'submit', 'reset'].includes(target.type))) return target.click();
            return editable ? insertText(target, ' ') : scrollPage(' ', keys);
        }
        if (name.length === 1 && editable) insertText(target, name);
      }

      const keyNames = { Return: 'Enter', Esc: 'Escape', Space: ' ', Del: 'Delete', Up: 'ArrowUp', Down: 'ArrowDown', Left: 'ArrowLeft', Right: 'ArrowRight' };
      const modifierNames = { control: 'ctrl', ctrl: 'ctrl', shift: 'shift', alt: 'alt', option: 'alt', meta: 'meta', command: 'meta', cmd: 'meta', controlormeta: 'meta' };
      const caretKeys = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown']);
      const namedKeys = new Set([...caretKeys, 'Enter', 'Tab', 'Escape', 'Backspace', 'Delete', 'Insert', 'ContextMenu',
        'Shift', 'Control', 'Alt', 'Meta', ...Array.from({ length: 12 }, (_, i) => `F${i + 1}`)]);
      // Shortcuts whose default is the clipboard or undo history, which synthetic events can't reach.
      const clipboardLetters = new Set(['c', 'x', 'v', 'z', 'y']);

      // `Enter`, `Shift+Tab`, `Meta+a`, `Alt+ArrowLeft`, `x`, …: page key handlers see the events,
      // and the editing/focus/scroll default is applied unless one of them prevents it.
      function press(combo) {
        const parts = combo === '+' || combo.endsWith('++') ? [...combo.slice(0, -1).split('+').filter(Boolean), '+'] : combo.split('+');
        const name = keyNames[parts.at(-1)] ?? parts.at(-1);
        const mods = { ctrl: false, shift: false, alt: false, meta: false };
        for (const part of parts.slice(0, -1)) {
          const modifier = modifierNames[part.toLowerCase()];
          if (!modifier) fail('invalid_params', `unknown modifier ${part} in ${combo}`);
          mods[modifier] = true;
        }
        if (name.length !== 1 && !namedKeys.has(name)) fail('invalid_params', `unsupported key ${name}`);
        // Control and Meta both mean the platform shortcut key (Playwright's ControlOrMeta).
        const shortcut = mods.ctrl || mods.meta;
        if (shortcut && clipboardLetters.has(name.toLowerCase())) {
          fail('invalid_params', `${combo} needs the clipboard or undo history, which this browser surface can't drive; use fill or type`);
        }
        const init = { key: name, code: name.length === 1 ? (/\d/.test(name) ? `Digit${name}` : /[a-z]/i.test(name) ? `Key${name.toUpperCase()}` : '') : name,
          ctrlKey: mods.ctrl, shiftKey: mods.shift, altKey: mods.alt, metaKey: mods.meta };
        const target = document.activeElement || document.body;
        if (key(target, 'keydown', init)) defaultAction(target, name, mods, shortcut);
        key(target, 'keyup', init);
        return {};
      }

      function act(action, selector, text) {
        const el = resolve(selector);
        switch (action) {
          case 'click': click(el); break;
          case 'dblclick': click(el, 1); click(el, 2); mouse(el, 'dblclick', { detail: 2 }); break;
          case 'hover':
            el.scrollIntoView({ block: 'center', inline: 'center' });
            for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) mouse(el, type);
            break;
          case 'focus': if (focusable(el)) el.focus(); break;
          case 'check': case 'uncheck': {
            const want = action === 'check';
            if (!('checked' in el)) fail('invalid_params', `${selector} is not a checkbox or radio`);
            if (el.checked !== want) click(el);
            if (el.checked !== want) { el.checked = want; fire(el, 'input'); fire(el, 'change'); }
            break;
          }
          case 'scroll_into_view': el.scrollIntoView({ block: 'center', inline: 'center' }); break;
          case 'type':
            if (focusable(el)) el.focus();
            for (const character of text) {
              const init = { key: character };
              if (key(el, 'keydown', init)) { key(el, 'keypress', init); insertText(el, character); }
              key(el, 'keyup', init);
            }
            break;
          case 'fill':
            if (focusable(el)) el.focus();
            if (el.isContentEditable) {
              el.textContent = text;
              fire(el, 'input');
            } else {
              if (!('value' in el)) fail('invalid_params', `${selector} is not a form field`);
              setValue(el, text);
              el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: text }));
              fire(el, 'change');
            }
            break;
          default: fail('invalid_params', `unknown action ${action}`);
        }
        return {};
      }

      // Resolves when the selector matches, or false after `timeout` ms.
      function waitFor(selector, timeout) {
        if (exists(selector)) return Promise.resolve(true);
        return new Promise((done) => {
          const observer = new MutationObserver(() => { if (exists(selector)) { observer.disconnect(); clearTimeout(timer); done(true); } });
          const timer = setTimeout(() => { observer.disconnect(); done(false); }, timeout);
          observer.observe(document, { subtree: true, childList: true, attributes: true });
        });
      }

      // Page activity, coalesced, so a visible tile can refresh its snapshot. The tile turns this
      // on only while it is on screen, so detached pages run no observer, timers, or messages.
      let observer = null, pending = null;
      const changed = () => { if (!pending) pending = setTimeout(() => { pending = null; post('changed'); }, 300); };
      const activityEvents = ['input', 'change', 'scroll', 'resize'];
      function setActivity(on) {
        if (on && !observer) {
          observer = new MutationObserver(changed);
          observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
          for (const type of activityEvents) addEventListener(type, changed, { capture: true, passive: true });
        } else if (!on && observer) {
          observer.disconnect();
          observer = null;
          for (const type of activityEvents) removeEventListener(type, changed, { capture: true });
          clearTimeout(pending);
          pending = null;
        }
        return {};
      }

      // MARK: a page another Mac streams (BrowserSurface)

      // The selected text for the viewer's explicit copy: a text field's own selection
      // isn't in the document's, and a password field's is never copied.
      function selectedText() {
        const el = document.activeElement;
        if (el && isTextField(el)) {
          if (el.type === 'password') return '';
          try { if (el.selectionStart !== null) return el.value.slice(el.selectionStart, el.selectionEnd); } catch {}
          return '';
        }
        return getSelection()?.toString() ?? '';
      }

      // A select's menu would open on this Mac, where nobody sees it and its tracking holds the
      // app's event queue: while streamed, the choices go to the viewer, and the choice it makes
      // reaches the page as untrusted input and change events.
      let surfaceRelay = false, relayed = null, relayToken = 0;
      const relayable = (el) => el instanceof HTMLSelectElement && !el.multiple && el.size <= 1 && !el.disabled;
      const menuKeys = new Set([' ', 'ArrowUp', 'ArrowDown']);
      function relaySelect(event) {
        const el = event.target;
        if (!surfaceRelay || !relayable(el)) return;
        if (event.type === 'mousedown' ? event.button !== 0 : !menuKeys.has(event.key)) return;
        event.preventDefault();
        el.focus({ preventScroll: true });
        relayed = { token: ++relayToken, element: new WeakRef(el) };
        try {
          window.webkit.messageHandlers.canvasSelect.postMessage({ token: relayToken, choices: [...el.options].map((option) => option.label), selected: el.selectedIndex });
        } catch {}
      }
      addEventListener('mousedown', relaySelect, true);
      addEventListener('keydown', relaySelect, true);
      function setSurfaceRelay(on) {
        surfaceRelay = on;
        if (!on) { relayed = null; fileChoice = null; }
        return {};
      }
      function chooseSelect(token, index) {
        const el = relayed?.token === token ? relayed.element.deref() : null;
        relayed = null;
        if (!el || !el.isConnected || !relayable(el) || index < 0 || index >= el.options.length || el.options[index].disabled) return false;
        if (el.selectedIndex !== index) { el.selectedIndex = index; fire(el, 'input'); fire(el, 'change'); }
        return true;
      }

      const fileDocument = Array.from(crypto.getRandomValues(new Uint32Array(4))).join('-');
      let fileSequence = 0, fileChoice = null;
      addEventListener('click', (event) => {
        const input = event.composedPath()[0];
        if (!surfaceRelay || !(input instanceof HTMLInputElement) || input.type !== 'file' || input.disabled) return;
        if ((!event.isTrusted && !navigator.userActivation.isActive) || input.webkitdirectory || input.hasAttribute('directory')) return;
        event.preventDefault();
        const token = `${fileDocument}-${++fileSequence}`;
        fileChoice = { token, element: new WeakRef(input), multiple: input.multiple };
        try {
          window.webkit.messageHandlers.canvasFile.postMessage({
            token, multiple: input.multiple, accept: input.accept.split(',').map(s => s.trim()).filter(Boolean)
          });
        } catch { fileChoice = null; }
      }, true);
      function setFiles(token, files) {
        if (fileChoice?.token !== token) return false;
        const choice = fileChoice;
        fileChoice = null;
        const input = choice.element.deref();
        if (!surfaceRelay || !input || !input.isConnected || input.type !== 'file' || input.disabled || input.ownerDocument !== document ||
            input.webkitdirectory || input.hasAttribute('directory') || input.multiple !== choice.multiple) return false;
        if (files === null) { input.dispatchEvent(new Event('cancel', { bubbles: true })); return true; }
        if (!files.length || files.length > 32 || (!input.multiple && files.length !== 1)) return false;
        const transfer = new DataTransfer();
        for (const file of files) {
          const bytes = Uint8Array.from(atob(file.data), c => c.charCodeAt(0));
          const options = { type: file.type };
          if (file.modified !== undefined) options.lastModified = file.modified;
          transfer.items.add(new File([bytes], file.name, options));
        }
        input.files = transfer.files;
        fire(input, 'input');
        fire(input, 'change');
        return true;
      }

      // Load milestones wake automation waits whether or not the tile is visible.
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => post('ready'), { once: true });
      else post('ready');
      if (document.readyState !== 'complete') addEventListener('load', () => post('load'), { once: true });
      addEventListener('pageshow', (event) => { if (event.persisted) post('ready'); });

      window.__canvasCmux = { snapshot, act, press, waitFor, setActivity, selectedText, setSurfaceRelay, chooseSelect, setFiles,
        scroll(dx, dy) { scrollBy(dx, dy); return { scroll_x: scrollX, scroll_y: scrollY }; } };
    })();
    """#
}
