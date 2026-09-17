import Foundation
import WebKit

/// Scrapes usage data from claude.ai using a persistent WKWebView session.
@MainActor
final class ClaudeScraper: NSObject {

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

    func fetchLimits() async -> ServiceStatus? {
        let wv = webView ?? makeWebView()
        guard let url = URL(string: "https://claude.ai/") else { return nil }

        do {
            try await wv.load(URLRequest(url: url))
            try await Task.sleep(for: .seconds(3))

            let js = """
            try {
                const resp = await fetch('/api/organizations/usage', {credentials: 'include'});
                if (resp.ok) {
                    const data = await resp.json();
                    return JSON.stringify({source: 'api', data: data});
                }
                const state = window.__NEXT_DATA__ || window.__nuxt__ || {};
                return JSON.stringify({source: 'dom', data: state});
            } catch(e) {
                return JSON.stringify({error: e.message});
            }
            """
            let result = try? await wv.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
            guard let jsonStr = result as? String,
                  let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return nil }

            return parseClaudeResponse(json)
        } catch {
            return nil
        }
    }

    private func parseClaudeResponse(_ json: [String: Any]) -> ServiceStatus? {
        if json["error"] != nil {
            return ServiceStatus(fiveHour: .placeholder, weekly: .placeholder,
                                 lastUpdated: nil, isLoggedIn: false,
                                 errorMessage: "Not logged in or API changed")
        }

        var fiveHour = ServiceLimit.placeholder
        var weekly = ServiceLimit.placeholder

        if let data = json["data"] as? [String: Any] {
            if let messages = data["messages_remaining"] as? Double,
               let cap = data["messages_cap"] as? Double {
                fiveHour = ServiceLimit(used: cap - messages, total: cap)
            }
            if let wUsed = data["weekly_used"] as? Double,
               let wTotal = data["weekly_total"] as? Double {
                weekly = ServiceLimit(used: wUsed, total: wTotal)
            }
        }

        return ServiceStatus(fiveHour: fiveHour, weekly: weekly,
                             lastUpdated: Date(), isLoggedIn: true, errorMessage: nil)
    }
}
