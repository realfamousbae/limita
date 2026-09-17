import Foundation
import WebKit

/// Scrapes usage data from chatgpt.com using a persistent WKWebView session.
@MainActor
final class OpenAIScraper: NSObject {

    static let persistentDataStore: WKWebsiteDataStore = .default()
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    private var webView: WKWebView?

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.persistentDataStore
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 650), configuration: config)
        wv.customUserAgent = Self.desktopUserAgent
        wv.autoresizingMask = [.width, .height]
        self.webView = wv
        return wv
    }

    /// Fetch limits by loading the ChatGPT usage page and extracting data via JS.
    func fetchLimits() async -> ServiceStatus? {
        let wv = webView ?? makeWebView()
        guard let url = URL(string: "https://chatgpt.com/") else { return nil }

        do {
            try await wv.load(URLRequest(url: url))
            try await Task.sleep(for: .seconds(3))

            let js = """
            try {
                const resp = await fetch('/backend-api/usage', {credentials: 'include'});
                if (!resp.ok) return JSON.stringify({error: resp.status});
                const data = await resp.json();
                return JSON.stringify(data);
            } catch(e) {
                return JSON.stringify({error: e.message});
            }
            """
            let result = try? await wv.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
            guard let jsonStr = result as? String,
                  let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return nil }

            return parseOpenAIResponse(json)
        } catch {
            return nil
        }
    }

    private func parseOpenAIResponse(_ json: [String: Any]) -> ServiceStatus? {
        var fiveHour = ServiceLimit.placeholder
        var weekly = ServiceLimit.placeholder

        if let cap = json["message_cap"] as? [String: Any] {
            let used = (cap["messages_sent"] as? Double) ?? 0
            let total = (cap["messages_cap"] as? Double) ?? 1
            fiveHour = ServiceLimit(used: used, total: total)
        }

        if let weekly_cap = json["weekly_limit"] as? [String: Any] {
            let used = (weekly_cap["used"] as? Double) ?? 0
            let total = (weekly_cap["total"] as? Double) ?? 1
            weekly = ServiceLimit(used: used, total: total)
        }

        if json["error"] != nil {
            return ServiceStatus(fiveHour: .placeholder, weekly: .placeholder,
                                 lastUpdated: nil, isLoggedIn: false,
                                 errorMessage: "Not logged in or API changed")
        }

        return ServiceStatus(fiveHour: fiveHour, weekly: weekly,
                             lastUpdated: Date(), isLoggedIn: true, errorMessage: nil)
    }
}

// MARK: - WKWebView async extension
extension WKWebView {
    @discardableResult
    func load(_ request: URLRequest) async throws -> WKNavigation? {
        return try await withCheckedThrowingContinuation { continuation in
            class NavDelegate: NSObject, WKNavigationDelegate {
                let continuation: CheckedContinuation<WKNavigation?, Error>
                init(_ c: CheckedContinuation<WKNavigation?, Error>) { self.continuation = c }
                func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                    webView.navigationDelegate = nil
                    continuation.resume(returning: navigation)
                }
                func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                    webView.navigationDelegate = nil
                    continuation.resume(throwing: error)
                }
                func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                    webView.navigationDelegate = nil
                    continuation.resume(throwing: error)
                }
            }
            let delegate = NavDelegate(continuation)
            self.navigationDelegate = delegate
            objc_setAssociatedObject(self, "navDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            self.load(request)
        }
    }
}
