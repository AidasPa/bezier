import WebKit

/// Pages that are just JSON get a readable view: indented, coloured, collapsible, with a
/// Raw/Pretty switch and Copy. Runs in the isolated world; the page's own scripts never see it.
@MainActor
enum WebKitJSONViewer {
    static func addScript(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                              in: WebKitAutofill.world))
    }

    static let script = #"""
    (() => {
      const type = (document.contentType || '').toLowerCase();
      if (!/(^|\+|\/)json\b/.test(type) || !document.body) return;
      const pre = document.body.querySelector(':scope > pre') || document.body;
      const raw = pre.textContent;
      if (raw.length > 8e6) return;                       // very large files stay raw
      let data;
      try { data = JSON.parse(raw); } catch (e) { return; }

      const style = document.createElement('style');
      style.textContent = `
        :root { color-scheme: light dark; --key: #a2185b; --str: #1a7f37; --num: #0b5cad; --lit: #8250df; --muted: #6e7781; --bg: #fff; --bar: rgba(0,0,0,.04); }
        @media (prefers-color-scheme: dark) { :root { --key: #ff7eb6; --str: #7ee787; --num: #79c0ff; --lit: #d2a8ff; --muted: #8b949e; --bg: #0d1117; --bar: rgba(255,255,255,.05); } }
        body { margin: 0; background: var(--bg); font: 12.5px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
        .bz-bar { position: sticky; top: 0; display: flex; gap: 6px; padding: 8px 14px; background: var(--bar); backdrop-filter: blur(12px);
                  font: 12px -apple-system, system-ui; border-bottom: 1px solid rgba(127,127,127,.15); }
        .bz-bar button { font: inherit; border: 0; border-radius: 6px; padding: 3px 10px; background: transparent; color: inherit; cursor: pointer; }
        .bz-bar button.on { background: rgba(127,127,127,.18); }
        .bz-tree { padding: 10px 16px 40px; }
        .bz-tree details { padding-left: 1.4em; }
        .bz-tree details > summary { margin-left: -1.4em; list-style: none; cursor: pointer; }
        .bz-tree details > summary::before { content: '▸'; display: inline-block; width: 1.4em; color: var(--muted); transition: transform .12s; }
        .bz-tree details[open] > summary::before { transform: rotate(90deg); }
        .bz-tree details:not([open]) > summary .bz-close { display: inline; }
        .bz-close { display: none; color: var(--muted); }
        .bz-row { padding-left: 1.4em; white-space: pre-wrap; word-break: break-word; }
        .bz-key { color: var(--key); } .bz-str { color: var(--str); } .bz-num { color: var(--num); } .bz-lit { color: var(--lit); }
        .bz-muted { color: var(--muted); }
        .bz-raw { display: none; padding: 10px 16px; margin: 0; white-space: pre-wrap; word-break: break-word; }
        body.bz-show-raw .bz-raw { display: block; } body.bz-show-raw .bz-tree { display: none; }
      `;
      document.head.appendChild(style);

      const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
      function scalar(value) {
        if (typeof value === 'string') {
          const s = el('span', 'bz-str', JSON.stringify(value));
          if (/^https?:\/\//.test(value)) { const a = el('a', 'bz-str'); a.href = value; a.textContent = JSON.stringify(value); return a; }
          return s;
        }
        if (typeof value === 'number') return el('span', 'bz-num', String(value));
        return el('span', 'bz-lit', String(value));
      }
      function node(key, value, last, depth) {
        const comma = last ? '' : ',';
        const label = (parent) => { if (key !== null) { parent.append(el('span', 'bz-key', JSON.stringify(key)), ': '); } };
        if (value && typeof value === 'object') {
          const isArray = Array.isArray(value);
          const entries = isArray ? value.map((v, i) => [null, v]) : Object.entries(value);
          if (!entries.length) { const row = el('div', 'bz-row'); label(row); row.append(isArray ? '[]' : '{}', comma); return row; }
          const details = el('details');
          details.open = depth < 3;
          const summary = el('summary');
          label(summary);
          summary.append(isArray ? '[' : '{');
          summary.append(el('span', 'bz-close', ` ${entries.length} ${isArray ? (entries.length === 1 ? 'item' : 'items') : (entries.length === 1 ? 'key' : 'keys')} ${isArray ? ']' : '}'}${comma}`));
          details.append(summary);
          entries.forEach(([k, v], i) => details.append(node(k, v, i === entries.length - 1, depth + 1)));
          details.append(el('div', null, (isArray ? ']' : '}') + comma));
          return details;
        }
        const row = el('div', 'bz-row');
        label(row);
        row.append(scalar(value), comma);
        return row;
      }

      const bar = el('div', 'bz-bar');
      const pretty = el('button', 'on', 'Pretty');
      const rawButton = el('button', null, 'Raw');
      const copy = el('button', null, 'Copy');
      pretty.onclick = () => { document.body.classList.remove('bz-show-raw'); pretty.className = 'on'; rawButton.className = ''; };
      rawButton.onclick = () => { document.body.classList.add('bz-show-raw'); rawButton.className = 'on'; pretty.className = ''; };
      copy.onclick = () => { navigator.clipboard.writeText(JSON.stringify(data, null, 2)); copy.textContent = 'Copied'; setTimeout(() => copy.textContent = 'Copy', 1200); };
      bar.append(pretty, rawButton, el('span', null, ''), copy);
      bar.children[2].style.flex = '1';
      const tree = el('div', 'bz-tree');
      tree.append(node(null, data, true, 0));
      const rawView = el('pre', 'bz-raw', raw);
      document.body.replaceChildren(bar, tree, rawView);
    })();
    """#
}
