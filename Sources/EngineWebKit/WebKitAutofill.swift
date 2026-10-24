import AppKit
import BezierEngine
import WebKit

/// Finds login forms in every frame and reports focus, keys and submissions to the engine's
/// `CredentialProvider`. Runs in its own content world, so pages can neither see the script nor
/// post to its message handler; fills only happen when the user picks a suggestion.
@MainActor
final class WebKitAutofill: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "BezierAutofill")
    static let handlerName = "bezierAutofill"
    private unowned let engine: WebKitEngine

    init(engine: WebKitEngine) {
        self.engine = engine
    }

    func install(in controller: WKUserContentController) {
        addScript(to: controller)
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func addScript(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let provider = engine.credentialProvider, let webView = message.webView,
              let content = engine.content(for: webView), let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let frame = message.frameInfo
        let security = frame.securityOrigin
        guard security.protocol == "https" || security.protocol == "http" else { return }
        let port = security.port == 0 ? "" : ":\(security.port)"
        guard let origin = URL(string: "\(security.protocol)://\(security.host)\(port)") else { return }

        switch type {
        case "focus":
            guard let kind = body["kind"] as? String else { return }
            let field = LoginField(
                origin: origin, kind: kind == "password" ? .password : .username, typed: body["typed"] as? String ?? "",
                frame: frame.isMainFrame ? Self.viewRect(body, in: webView) : nil,
                fill: { [weak webView] username, password in
                    webView?.callAsyncJavaScript("__bezierFill(username, password, origin)",
                                                 arguments: ["username": username, "password": password, "origin": origin.absoluteString],
                                                 in: frame, in: Self.world, completionHandler: nil)
                },
                suggestions: { [weak webView] state in
                    webView?.callAsyncJavaScript("__bezierSuggesting(state)", arguments: ["state": state.rawValue],
                                                 in: frame, in: Self.world, completionHandler: nil)
                })
            provider.content(content, didFocus: field)
        case "key":
            let keys: [String: LoginField.Key] = ["up": .up, "down": .down, "enter": .enter, "escape": .escape]
            guard let key = (body["key"] as? String).flatMap({ keys[$0] }) else { return }
            let field = LoginField(origin: origin, kind: .username, typed: "", frame: nil, fill: { _, _ in }, suggestions: { _ in })
            provider.content(content, didPress: key, in: field)
        case "blur":
            provider.contentDidLeaveLoginField(content)
        case "submit":
            guard let password = body["password"] as? String, !password.isEmpty else { return }
            provider.content(content, didSubmitUsername: body["username"] as? String ?? "", password: password, origin: origin)
        default:
            break
        }
    }

    /// The field's CSS-pixel rect in the main frame's viewport, in the web view's coordinates.
    private static func viewRect(_ body: [String: Any], in webView: WKWebView) -> CGRect? {
        guard webView.magnification == 1, let x = body["x"] as? Double, let y = body["y"] as? Double,
              let width = body["width"] as? Double, let height = body["height"] as? Double else { return nil }
        let zoom = webView.pageZoom
        let rect = CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
        return webView.isFlipped ? rect : CGRect(x: rect.minX, y: webView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    static let script = #"""
    (() => {
      if (window.__bezierAutofillInstalled) return;
      window.__bezierAutofillInstalled = true;
      const handler = window.webkit.messageHandlers.bezierAutofill;
      const post = (message) => { try { handler.postMessage(message); } catch (e) {} };
      const textTypes = ['text', 'email', 'tel', 'url', ''];
      let field = null;
      let suggesting = 0;          // 0 hidden, 1 visible, 2 visible with one highlighted
      let filling = false;         // our own input events aren't typing
      let lastSubmit = '';

      const visible = (el) => {
        const r = el.getBoundingClientRect();
        const style = getComputedStyle(el);
        return r.width > 1 && r.height > 1 && style.visibility !== 'hidden' && style.display !== 'none';
      };
      const isPassword = (el) => el instanceof HTMLInputElement && el.type === 'password';
      const isText = (el) => el instanceof HTMLInputElement && textTypes.includes((el.getAttribute('type') || '').toLowerCase());
      const scopeOf = (el) => el.form || el.closest('form') || document;
      const inputs = (scope) => Array.from(scope.querySelectorAll('input')).filter(visible);
      const describe = (el) => [el.name, el.id, el.placeholder, el.getAttribute('aria-label'), el.getAttribute('autocomplete')].join(' ');

      function passwordNear(el) {
        const list = inputs(scopeOf(el));
        const i = list.indexOf(el);
        return list.slice(i + 1).find(isPassword) || list.find(isPassword) || null;
      }
      function usernameNear(pw) {
        const list = inputs(scopeOf(pw));
        for (let j = list.indexOf(pw) - 1; j >= 0; j--) if (isText(list[j])) return list[j];
        return list.find((el) => isText(el) && /user|email|login|account/i.test(describe(el))) || null;
      }
      function kind(el) {
        if (isPassword(el)) return (el.getAttribute('autocomplete') || '').includes('new-password') ? null : 'password';
        if (!isText(el) || el.type === 'search') return null;
        const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (autocomplete.includes('username') || autocomplete.split(' ').includes('email')) return 'username';
        if (passwordNear(el)) return 'username';
        return /user|e-?mail|login|sign.?in|account|identifier/i.test(describe(el)) ? 'username' : null;
      }
      function report(el) {
        const k = kind(el);
        if (!k) return;
        field = el;
        const r = el.getBoundingClientRect();
        post({ type: 'focus', kind: k, typed: k === 'username' ? el.value : '', x: r.left, y: r.top, width: r.width, height: r.height });
      }

      document.addEventListener('focusin', (e) => report(e.target), true);
      document.addEventListener('mousedown', (e) => { if (e.target === document.activeElement) report(e.target); }, true);
      document.addEventListener('input', (e) => { if (!filling && e.target === field && !isPassword(field)) report(field); }, true);
      document.addEventListener('focusout', (e) => { if (e.target === field) post({ type: 'blur' }); }, true);
      window.addEventListener('scroll', () => { if (suggesting) post({ type: 'blur' }); }, true);
      document.addEventListener('keydown', (e) => {
        if (!suggesting || e.target !== field) return;
        const key = { ArrowDown: 'down', ArrowUp: 'up', Escape: 'escape', Enter: suggesting === 2 ? 'enter' : null }[e.key];
        if (!key) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        // Arrows always land on a row, so Return straight after one picks it without waiting.
        suggesting = key === 'up' || key === 'down' ? 2 : 0;
        post({ type: 'key', key });
      }, true);

      const setValue = (el, value) => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      window.__bezierFill = (username, password, origin) => {
        suggesting = 0;
        if (!field || location.origin !== origin) return;
        const pw = isPassword(field) ? field : passwordNear(field);
        const user = isPassword(field) ? usernameNear(field) : field;
        filling = true;
        try {
          if (user && username) setValue(user, username);
          if (pw && password) setValue(pw, password);
        } finally {
          filling = false;
        }
      };
      window.__bezierSuggesting = (state) => { suggesting = state; };

      // Saving: a filled password field being sent. Sign-ins split over two pages (email first)
      // remember the username for the second page.
      function capture(scope) {
        const list = inputs(scope);
        const filled = list.filter((el) => isPassword(el) && el.value);
        if (!filled.length) {
          const user = list.find((el) => kind(el) === 'username' && el.value);
          if (user) try { sessionStorage.setItem('__bezierUsername', user.value); } catch (e) {}
          return;
        }
        const pw = filled.find((el) => (el.getAttribute('autocomplete') || '').includes('new-password')) || filled[filled.length - 1];
        const user = usernameNear(filled[0]);
        let username = user ? user.value : '';
        if (!username) try { username = sessionStorage.getItem('__bezierUsername') || ''; } catch (e) {}
        const key = username + '\n' + pw.value;
        if (key === lastSubmit) return;
        lastSubmit = key;
        post({ type: 'submit', username, password: pw.value });
      }
      document.addEventListener('submit', (e) => capture(e.target), true);
      document.addEventListener('click', (e) => {
        const button = e.target.closest && e.target.closest('button, input[type=submit], input[type=button], [role=button]');
        if (button) capture(scopeOf(button));
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target instanceof HTMLInputElement) capture(scopeOf(e.target));
      }, true);
    })();
    """#
}
