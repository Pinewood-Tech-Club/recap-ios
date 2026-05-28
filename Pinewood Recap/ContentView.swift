import LinkPresentation
import SafariServices
import SwiftUI
import WebKit

fileprivate final class WebViewStore {
    var webView: WKWebView?
}

struct ContentView: View {
    @State private var store = WebViewStore()
    @State private var currentSlide = -1
    @State private var capturedSlide: CapturedSlide?
    @State private var externalURL: URL?
    @State private var isCapturing = false
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showingPhotos = false   // ← native photos

    var body: some View {
        ZStack {
            RecapWebView(
                store: store,
                onSlideChanged: { currentSlide = $0 },
                onExternalURL: { externalURL = $0 },
                onSlideCaptured: { image in
                    isCapturing = false
                    if let image { capturedSlide = CapturedSlide(image: image) }
                },
                onLoadStarted: {
                    isLoading = true
                    loadFailed = false
                },
                onLoadFinished: { isLoading = false },
                onLoadFailed: {
                    isLoading = false
                    loadFailed = true
                },
                onPhotosRoute: { showingPhotos = true }   // ← intercept
            )
            .ignoresSafeArea()

            if isLoading && !loadFailed {
                ZStack {
                    Color(UIColor.systemBackground).ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                }
            }

            if loadFailed {
                ZStack {
                    Color(UIColor.systemBackground).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Couldn't connect")
                            .font(.headline)
                        Text("Check your internet connection and try again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            isLoading = true
                            loadFailed = false
                            store.webView?.load(URLRequest(url: AppConfig.recapURL))
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .padding(32)
                }
            }

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
                        ZStack {
                            Image(systemName: "square.and.arrow.up")
                                .opacity(isCapturing ? 0 : 1)
                            ProgressView()
                                .controlSize(.small)
                                .opacity(isCapturing ? 1 : 0)
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .opacity(currentSlide > 0 ? 1 : 0)
                    .disabled(currentSlide <= 0 || isCapturing)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .statusBarHidden(true)
        .sheet(item: $capturedSlide) { item in
            ShareSheet(image: item.image)
        }
        .sheet(item: $externalURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showingPhotos) {
            RecapPhotosView()
        }
    }

    private func captureSlide() {
        guard let webView = store.webView, !isCapturing else { return }
        isCapturing = true
        webView.evaluateJavaScript("captureSlideForIOS()")
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
    let onExternalURL: (URL) -> Void
    let onSlideCaptured: (UIImage?) -> Void
    let onLoadStarted: () -> Void
    let onLoadFinished: () -> Void
    let onLoadFailed: () -> Void
    let onPhotosRoute: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSlideChanged: onSlideChanged, onExternalURL: onExternalURL, onSlideCaptured: onSlideCaptured, onLoadStarted: onLoadStarted, onLoadFinished: onLoadFinished, onLoadFailed: onLoadFailed, onPhotosRoute: onPhotosRoute)
    }

    func makeUIView(context: Context) -> WKWebView {
        let wkConfig = WKWebViewConfiguration()
        wkConfig.userContentController.add(context.coordinator, name: "slideChange")
        wkConfig.userContentController.add(context.coordinator, name: "slideCapture")
        // Always flag every page as the iOS app so web buttons stay hidden
        // and the notch offset applies, regardless of whether ?iosapp=1 is in the URL.
        wkConfig.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('iosapp');",
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

    // Injected into every page load; exits silently on non-recap pages.
    // Preferred contract for future web UI:
    // window.dispatchEvent(new CustomEvent('recap:slidechange', { detail: { index: 0 } }))
    // Fallback discovery supports current numeric slide IDs plus class/data markers.
    private static let slideObserverScript = """
    (function() {
        var lastPosted = null;

        function post(index) {
            if (index === lastPosted) { return; }
            lastPosted = index;
            window.webkit.messageHandlers.slideChange.postMessage(index);
        }

        function unique(elements) {
            var seen = new Set();
            return elements.filter(function(el) {
                if (!el || seen.has(el)) { return false; }
                seen.add(el);
                return true;
            });
        }

        function slideElements() {
            return unique(Array.prototype.slice.call(document.querySelectorAll(
                '[data-recap-slide], [data-ios-slide], .recap-slide, [id^="slide"]'
            ))).filter(function(el) {
                return el.matches('[data-recap-slide], [data-ios-slide], .recap-slide') ||
                    /^slide\\d+$/.test(el.id || '');
            });
        }

        function isVisible(el) {
            if (el.hidden || el.getAttribute('aria-hidden') === 'true') { return false; }
            var style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') { return false; }
            var rect = el.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
        }

        function postSlide() {
            var els = slideElements();
            if (els.length === 0) { post(-1); return; }
            var idx = els.findIndex(isVisible);
            post(idx >= 0 ? idx : 0);
        }

        window.addEventListener('recap:slidechange', function(event) {
            var detail = event.detail;
            var idx = typeof detail === 'number' ? detail : detail && detail.index;
            if (Number.isInteger(idx)) { post(idx); }
            else { postSlide(); }
        });

        new MutationObserver(postSlide).observe(document.body || document.documentElement, {
            subtree: true,
            childList: true,
            attributes: true,
            attributeFilter: ['class', 'style', 'hidden', 'aria-hidden', 'data-active']
        });
        postSlide();
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let oauthCoordinator = OAuthCoordinator()
        let onSlideChanged: (Int) -> Void
        let onExternalURL: (URL) -> Void
        let onSlideCaptured: (UIImage?) -> Void
        let onLoadStarted: () -> Void
        let onLoadFinished: () -> Void
        let onLoadFailed: () -> Void
        let onPhotosRoute: () -> Void

        init(onSlideChanged: @escaping (Int) -> Void, onExternalURL: @escaping (URL) -> Void, onSlideCaptured: @escaping (UIImage?) -> Void, onLoadStarted: @escaping () -> Void, onLoadFinished: @escaping () -> Void, onLoadFailed: @escaping () -> Void, onPhotosRoute: @escaping () -> Void) {
            self.onSlideChanged = onSlideChanged
            self.onExternalURL = onExternalURL
            self.onSlideCaptured = onSlideCaptured
            self.onLoadStarted = onLoadStarted
            self.onLoadFinished = onLoadFinished
            self.onLoadFailed = onLoadFailed
            self.onPhotosRoute = onPhotosRoute
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "slideChange", let idx = message.body as? Int {
                onSlideChanged(idx)
            } else if message.name == "slideCapture" {
                guard let dataURL = message.body as? String,
                      let commaIdx = dataURL.firstIndex(of: ",") else {
                    onSlideCaptured(nil)
                    return
                }
                let base64 = String(dataURL[dataURL.index(after: commaIdx)...])
                guard let data = Data(base64Encoded: base64),
                      let image = UIImage(data: data) else {
                    onSlideCaptured(nil)
                    return
                }
                onSlideCaptured(image)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadStarted()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadFinished()
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                CookiePersistence.save(cookies)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 500 {
                decisionHandler(.cancel)
                onLoadFailed()
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadFailed()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadFailed()
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
            let recapHost = URL(string: AppConfig.recapBaseURL)?.host
            if url.host == recapHost && url.path == "/auth/start" {
                decisionHandler(.cancel)
                Task { @MainActor in await self.handleMobileOAuth(webView: webView) }
                return
            }
            // Intercept navigation to the photos section → native SwiftUI experience
            let isPhotosPath = url.path.hasPrefix("/photos") || url.path.hasPrefix("/static/photos")
            let isPhotosHost = url.host?.contains("photos.") == true
            if (isPhotosPath && url.host == recapHost) || isPhotosHost {
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.onPhotosRoute() }
                return
            }
            // Open external links (different host) in a Safari sheet instead of the main WebView.
            if let scheme = url.scheme, (scheme == "http" || scheme == "https"), url.host != recapHost {
                decisionHandler(.cancel)
                onExternalURL(url)
                return
            }
            // Hand mailto: links off to Mail.
            if url.scheme == "mailto" {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
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
        UIActivityViewController(activityItems: [ShareItemSource(image: image)], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private final class ShareItemSource: NSObject, UIActivityItemSource {
    let image: UIImage
    init(image: UIImage) { self.image = image }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { image }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { image }
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let meta = LPLinkMetadata()
        meta.title = "Pinewood Recap"
        meta.imageProvider = NSItemProvider(object: image)
        return meta
    }
}

// MARK: - Safari sheet

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    ContentView()
}
