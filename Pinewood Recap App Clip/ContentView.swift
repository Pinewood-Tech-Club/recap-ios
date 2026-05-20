import SwiftUI
import WebKit

fileprivate final class WebViewStore {
    var webView: WKWebView?
}

struct ContentView: View {
    @State private var store = WebViewStore()
    @State private var currentSlide = -1
    @State private var capturedSlide: CapturedSlide?

    var body: some View {
        ZStack {
            RecapWebView(store: store, onSlideChanged: { currentSlide = $0 })
                .ignoresSafeArea()

            VStack {
                Spacer()
                HStack {
                    if currentSlide >= 0 {
                        Button {
                            if let url = URL(string: AppConfig.recapBaseURL + "/") {
                                store.webView?.load(URLRequest(url: url))
                            }
                        } label: {
                            Image(systemName: "house")
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                    }

                    Spacer()

                    Button { captureSlide() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .opacity(currentSlide > 0 ? 1 : 0)
                    .disabled(currentSlide <= 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .sheet(item: $capturedSlide) { item in
            ShareSheet(image: item.image)
        }
    }

    private func captureSlide() {
        guard let webView = store.webView else { return }
        webView.evaluateJavaScript("snapCurrent()") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                webView.takeSnapshot(with: nil) { image, _ in
                    guard let image else { return }
                    capturedSlide = CapturedSlide(image: image)
                }
            }
        }
    }
}

private struct CapturedSlide: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - WebView

struct RecapWebView: UIViewRepresentable {
    fileprivate let store: WebViewStore
    let onSlideChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSlideChanged: onSlideChanged)
    }

    func makeUIView(context: Context) -> WKWebView {
        let wkConfig = WKWebViewConfiguration()
        wkConfig.userContentController.add(context.coordinator, name: "slideChange")
        wkConfig.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('iosapp'); document.documentElement.style.setProperty('--ios-notch-offset', '1.5rem');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        wkConfig.userContentController.addUserScript(WKUserScript(
            source: Self.slideObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: wkConfig)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        store.webView = webView

        // Restore cookies before the first request so the session survives force-kill.
        // WKWebView's web content process may be killed before cookies flush to disk,
        // so we manually persist them and inject them back on each cold start.
        let savedCookies = CookiePersistence.load()
        if savedCookies.isEmpty {
            webView.load(URLRequest(url: AppConfig.recapURL))
        } else {
            let cookieStore = wkConfig.websiteDataStore.httpCookieStore
            let group = DispatchGroup()
            for cookie in savedCookies {
                group.enter()
                cookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                webView.load(URLRequest(url: AppConfig.recapURL))
            }
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private static let slideObserverScript = """
    (function() {
        var ids = ['slide1', 'slide2', 'slide3', 'slide4'];
        var els = ids.map(function(id) { return document.getElementById(id); }).filter(Boolean);
        if (els.length === 0) { window.webkit.messageHandlers.slideChange.postMessage(-1); return; }
        function postSlide() {
            var idx = els.findIndex(function(el) { return el.style.display !== 'none'; });
            window.webkit.messageHandlers.slideChange.postMessage(idx >= 0 ? idx : 0);
        }
        new MutationObserver(postSlide).observe(
            document.getElementById('main-recap-container') || document.body,
            { subtree: true, attributes: true, attributeFilter: ['style'] }
        );
        postSlide();
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let oauthCoordinator = OAuthCoordinator()
        let onSlideChanged: (Int) -> Void

        init(onSlideChanged: @escaping (Int) -> Void) {
            self.onSlideChanged = onSlideChanged
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "slideChange", let idx = message.body as? Int else { return }
            onSlideChanged(idx)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                CookiePersistence.save(cookies)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.host == URL(string: AppConfig.recapBaseURL)?.host && url.path == "/auth/start" {
                decisionHandler(.cancel)
                Task { @MainActor in await self.handleMobileOAuth(webView: webView) }
                return
            }
            decisionHandler(.allow)
        }

        private func handleMobileOAuth(webView: WKWebView) async {
            guard let mobileStartURL = URL(string: "\(AppConfig.recapBaseURL)/auth/mobile-start") else { return }

            let authURL: URL
            do {
                let (data, _) = try await URLSession.shared.data(from: mobileStartURL)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let urlString = json["auth_url"] as? String,
                      let parsed = URL(string: urlString)
                else { return }
                authURL = parsed
            } catch {
                print("[OAuth] mobile-start failed: \(error)")
                return
            }

            let callbackURL: URL
            do {
                callbackURL = try await oauthCoordinator.start(
                    url: authURL,
                    callbackScheme: AppConfig.callbackScheme
                )
            } catch OAuthError.cancelled {
                return
            } catch {
                print("[OAuth] session failed: \(error)")
                return
            }

            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  let activateURL = URL(string: "\(AppConfig.recapBaseURL)/auth/activate-code?code=\(code)&iosapp=1")
            else { return }

            webView.load(URLRequest(url: activateURL))
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
