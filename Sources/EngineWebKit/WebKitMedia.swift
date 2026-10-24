import AppKit
import BezierEngine
import WebKit

/// Watches the page's audio and video (main frame) and reports what's playing; also carries
/// out play/pause, mute, skip and picture-in-picture. Runs in the isolated world.
@MainActor
final class WebKitMedia: NSObject, WKScriptMessageHandler {
    static let handlerName = "bezierMedia"
    private unowned let engine: WebKitEngine

    init(engine: WebKitEngine) {
        self.engine = engine
    }

    func install(in controller: WKUserContentController) {
        addScript(to: controller)
        controller.add(self, contentWorld: WebKitAutofill.world, name: Self.handlerName)
    }

    func addScript(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                              in: WebKitAutofill.world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, message.frameInfo.isMainFrame, let content = engine.content(for: webView),
              let body = message.body as? [String: Any] else { return }
        guard body["present"] as? Bool == true else { content.updateMedia(nil); return }
        content.updateMedia(MediaState(isPlaying: body["playing"] as? Bool ?? false, isMuted: body["muted"] as? Bool ?? false,
                                       hasVideo: body["video"] as? Bool ?? false, title: body["title"] as? String ?? "",
                                       artist: body["artist"] as? String ?? "",
                                       artworkURL: (body["artwork"] as? String).flatMap { URL(string: $0, relativeTo: webView.url)?.absoluteURL }))
    }

    static let script = #"""
    (() => {
      if (window.__bezierMedia) return;
      const post = (m) => { try { window.webkit.messageHandlers.bezierMedia.postMessage(m); } catch (e) {} };
      let current = null;
      let timer = null;
      let last = '';
      const all = () => Array.from(document.querySelectorAll('video, audio'));
      function pick() {
        const media = all();
        return media.find((m) => !m.paused && !m.ended) || (current && current.isConnected ? current : null)
          || media.find((m) => m.currentTime > 0) || null;
      }
      function report() {
        const m = pick();
        current = m;
        let message;
        if (!m) {
          message = { present: false };
        } else {
          const meta = navigator.mediaSession && navigator.mediaSession.metadata;
          const art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : null;
          message = { present: true, playing: !m.paused && !m.ended, muted: m.muted || m.volume === 0,
                      video: m instanceof HTMLVideoElement && m.videoWidth > 0,
                      title: (meta && meta.title) || document.title, artist: (meta && meta.artist) || '', artwork: art };
        }
        const key = JSON.stringify(message);
        if (key !== last) { last = key; post(message); }
      }
      const schedule = () => { clearTimeout(timer); timer = setTimeout(report, 60); };
      // Media events don't bubble, but capturing listeners on the document still see them.
      for (const name of ['play', 'playing', 'pause', 'ended', 'volumechange', 'loadedmetadata', 'emptied'])
        document.addEventListener(name, schedule, true);
      window.__bezierMedia = {
        command(name, value) {
          const m = pick();
          if (!m) return;
          switch (name) {
            case 'play': m.play(); break;
            case 'pause': m.pause(); break;
            case 'toggle': (m.paused || m.ended) ? m.play() : m.pause(); break;
            case 'mute': for (const x of all()) x.muted = !!value; break;
            case 'skip': m.currentTime = Math.max(0, m.currentTime + value); break;
            case 'pip':
              if (m.webkitSupportsPresentationMode && m.webkitSupportsPresentationMode('picture-in-picture')) {
                m.webkitSetPresentationMode(m.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
              } else if (m.requestPictureInPicture) {
                m.requestPictureInPicture().catch(() => {});
              }
              break;
          }
          schedule();
        }
      };
    })();
    """#
}
