import Foundation
import WebKit

/// Serves `view-source:<url>` as syntax-neutral, line-numbered source (WebKit has no built-in
/// view-source mode; Chromium does, so this only exists for the development engine).
@MainActor
final class ViewSourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "view-source"
    private var active: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        let raw = task.request.url?.absoluteString ?? ""
        let target = URL(string: String(raw.dropFirst(Self.scheme.count + 1)))
        Task { @MainActor in
            var body = "Could not load source."
            if let target, let (data, _) = try? await URLSession.shared.data(from: target) {
                body = String(decoding: data, as: UTF8.self)
            }
            guard active.remove(id) != nil else { return }
            let html = Self.page(title: raw, source: body)
            let response = URLResponse(url: task.request.url!, mimeType: "text/html",
                                       expectedContentLength: html.utf8.count, textEncodingName: "utf-8")
            task.didReceive(response)
            task.didReceive(Data(html.utf8))
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    private static func page(title: String, source: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let rows = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { "<tr><td class=n>\($0.offset + 1)</td><td>\(esc(String($0.element)))</td></tr>" }
            .joined()
        return """
        <!doctype html><html><head><meta charset=utf-8><title>\(esc(title))</title><style>
        :root{color-scheme:light dark}body{margin:0;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
        table{border-collapse:collapse}td{white-space:pre-wrap;word-break:break-all;padding:0 12px 0 0;vertical-align:top}
        td.n{color:#999;text-align:right;user-select:none;padding:0 12px;min-width:3ch}
        </style></head><body><table>\(rows)</table></body></html>
        """
    }
}
