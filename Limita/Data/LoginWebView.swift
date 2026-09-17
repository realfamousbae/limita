import SwiftUI
import WebKit

/// Full-featured login web view with navigation toolbar, progress indicator, and OAuth popup support.
struct LoginWebView: NSViewRepresentable {
    let service: Service
    let onLoginDetected: () -> Void
    @Binding var currentURLString: String
    @Binding var isLoading: Bool
    @Binding var loadProgress: Double
    @Binding var webView: WKWebView?

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 650), configuration: config)
        wv.customUserAgent = Self.desktopUserAgent
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator

        DispatchQueue.main.async {
            self.webView = wv
        }

        context.coordinator.setupObservers(wv)

        if let url = URL(string: service.loginURL) {
            print("[LoginWebView] Loading initial URL: \(url)")
            wv.load(URLRequest(url: url))
        }

        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LoginWebView
        private var progressObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?

        init(_ parent: LoginWebView) {
            self.parent = parent
        }

        func setupObservers(_ wv: WKWebView) {
            progressObservation = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.loadProgress = wv.estimatedProgress
                }
            }
            urlObservation = wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.currentURLString = wv.url?.absoluteString ?? ""
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("[LoginWebView] Started loading: \(webView.url?.absoluteString ?? "unknown")")
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            print("[LoginWebView] Committed content: \(webView.url?.absoluteString ?? "")")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let urlString = webView.url?.absoluteString ?? ""
            print("[LoginWebView] Finished loading: \(urlString), Title: \(webView.title ?? "")")
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }

            checkLoginSuccess(urlString: urlString)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[LoginWebView] Navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[LoginWebView] Provisional navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        private func checkLoginSuccess(urlString: String) {
            let isLoggedIn: Bool
            switch parent.service {
            case .codex:
                isLoggedIn = urlString.contains("chatgpt.com") && !urlString.contains("/auth/") && !urlString.contains("/login")
            case .claude:
                isLoggedIn = urlString.contains("claude.ai") && !urlString.contains("/login")
            }

            if isLoggedIn {
                print("[LoginWebView] Login detected for \(parent.service.rawValue)!")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.parent.onLoginDetected()
                }
            }
        }

        // MARK: - WKUIDelegate (Handles target="_blank" and OAuth popups)

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

/// Sheet wrapper for the login experience
struct LoginSheet: View {
    let service: Service
    @Environment(\.dismiss) private var dismiss
    var store: LimitsStore

    @State private var currentURLString = ""
    @State private var isLoading = false
    @State private var loadProgress = 0.0
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                // Navigation controls
                HStack(spacing: 4) {
                    Button {
                        webView?.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .disabled(webView?.canGoBack == false)

                    Button {
                        webView?.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .disabled(webView?.canGoForward == false)

                    Button {
                        webView?.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.trailing, 4)

                Text(service.icon)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Авторизация в \(service.rawValue)")
                        .font(.headline)
                    if !currentURLString.isEmpty {
                        Text(currentURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Готово") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            // Progress bar
            if isLoading && loadProgress < 1.0 {
                ProgressView(value: loadProgress)
                    .progressViewStyle(.linear)
            } else {
                Divider()
            }

            // Web view
            LoginWebView(
                service: service,
                onLoginDetected: {
                    store.markLoggedIn(service)
                    dismiss()
                },
                currentURLString: $currentURLString,
                isLoading: $isLoading,
                loadProgress: $loadProgress,
                webView: $webView
            )
            .frame(minWidth: 800, minHeight: 600)
        }
        .frame(width: 960, height: 720)
    }
}
