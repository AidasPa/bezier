import AppKit
import BezierEngine
import WebKit

/// Boosts on WebKit: one style script (isolated world, document start, so restyled pages don't
/// flash) and one script for the sites' JavaScript (page world, document end), each carrying
/// every site's rules and picking by hostname. Styles update open pages at once; scripts run on
/// the next load. Also Zap: click elements to hide them.
@MainActor
final class WebKitBoosts: NSObject, WKScriptMessageHandler {
    static let handlerName = "bezierZap"
    private unowned let engine: WebKitEngine
    private var customizations: [SiteCustomization] = []
    private var zapHandlers: [ObjectIdentifier: @MainActor (String?) -> Void] = [:]

    init(engine: WebKitEngine) {
        self.engine = engine
    }

    func installHandler(in controller: WKUserContentController) {
        controller.add(self, contentWorld: WebKitAutofill.world, name: Self.handlerName)
    }

    func addScripts(to controller: WKUserContentController) {
        guard !customizations.isEmpty else { return }
        controller.addUserScript(WKUserScript(source: styleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                              in: WebKitAutofill.world))
        if customizations.contains(where: { !$0.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            controller.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        }
    }

    func update(_ new: [SiteCustomization], webViews: [WKWebView]) {
        guard new != customizations else { return }
        customizations = new
        for webView in webViews {
            engine.rebuildUserScripts(webView.configuration.userContentController)
            webView.evaluateJavaScript(styleScript, in: nil, in: WebKitAutofill.world, completionHandler: nil)
        }
    }

    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private var styleScript: String {
        let rules = customizations.map { ["domain": $0.domain.lowercased(), "css": $0.css] }
        return """
        (() => {
          const rules = \(Self.json(rules));
          const host = location.hostname.toLowerCase();
          const css = rules.filter((r) => host === r.domain || host.endsWith('.' + r.domain)).map((r) => r.css).join('\\n');
          let style = document.getElementById('__bezier_boost');
          if (!css) { if (style) style.remove(); return; }
          if (!style) {
            style = document.createElement('style');
            style.id = '__bezier_boost';
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = css;
        })();
        """
    }

    /// The sites' code goes in as written (not eval'd), so pages' Content Security Policies
    /// don't block it.
    private var pageScript: String {
        let blocks = customizations.filter { !$0.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { site in
            let domain = Self.json([site.domain.lowercased()])
            return """
            if ((() => { const d = \(domain)[0]; const h = location.hostname.toLowerCase(); return h === d || h.endsWith('.' + d); })()) {
              try {
            \(site.js)
              } catch (error) { console.error('Boost for ' + \(domain)[0] + ':', error); }
            }
            """
        }
        return "(() => {\n" + blocks.joined(separator: "\n") + "\n})();"
    }

    // MARK: Zap

    func beginZap(in webView: WKWebView, picked: @escaping @MainActor (String?) -> Void) {
        zapHandlers[ObjectIdentifier(webView)] = picked
        webView.evaluateJavaScript(Self.zapScript, in: nil, in: WebKitAutofill.world, completionHandler: nil)
    }

    func endZap(in webView: WKWebView) {
        zapHandlers[ObjectIdentifier(webView)] = nil
        webView.evaluateJavaScript("window.__bezierZap && window.__bezierZap.stop()", in: nil, in: WebKitAutofill.world, completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let handler = zapHandlers[ObjectIdentifier(webView)] else { return }
        if body["type"] as? String == "zap", let selector = body["selector"] as? String {
            handler(selector)
        } else if body["type"] as? String == "end" {
            zapHandlers[ObjectIdentifier(webView)] = nil
            handler(nil)
        }
    }

    static let zapScript = #"""
    (() => {
      if (window.__bezierZap) return;
      const post = (m) => window.webkit.messageHandlers.bezierZap.postMessage(m);
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border-radius:5px;' +
        'background:rgba(255,69,58,.16);outline:2px solid rgba(255,69,58,.85);transition:all .07s ease-out;left:0;top:0;width:0;height:0';
      document.documentElement.appendChild(box);
      let target = null;
      const stable = (s) => s && !/\d{3,}|[:\[]/.test(s);
      function selectorFor(el) {
        const parts = [];
        while (el && el.nodeType === 1 && el !== document.documentElement && parts.length < 6) {
          if (stable(el.id)) { parts.unshift('#' + CSS.escape(el.id)); break; }
          let part = el.localName;
          const classes = Array.from(el.classList).filter(stable).slice(0, 2);
          if (classes.length) part += '.' + classes.map((c) => CSS.escape(c)).join('.');
          const parent = el.parentElement;
          if (parent) {
            const same = Array.from(parent.children).filter((c) => c.localName === el.localName);
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
          }
          parts.unshift(part);
          if (el === document.body) break;
          el = parent;
        }
        return parts.join(' > ');
      }
      const move = (e) => {
        target = e.target;
        if (!target || target === box) return;
        const r = target.getBoundingClientRect();
        Object.assign(box.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
      };
      const swallow = (e) => { e.preventDefault(); e.stopImmediatePropagation(); };
      const click = (e) => {
        swallow(e);
        if (!target || target === document.body || target === document.documentElement) return;
        const selector = selectorFor(target);
        target.style.setProperty('display', 'none', 'important');
        post({ type: 'zap', selector });
      };
      const key = (e) => { if (e.key === 'Escape') { swallow(e); stop(); post({ type: 'end' }); } };
      const events = [['mousemove', move], ['mouseover', move], ['click', click], ['mousedown', swallow], ['mouseup', swallow],
                      ['pointerdown', swallow], ['pointerup', swallow], ['keydown', key]];
      function stop() {
        for (const [name, fn] of events) document.removeEventListener(name, fn, true);
        box.remove();
        window.__bezierZap = null;
      }
      for (const [name, fn] of events) document.addEventListener(name, fn, true);
      window.__bezierZap = { stop };
    })();
    """#
}
