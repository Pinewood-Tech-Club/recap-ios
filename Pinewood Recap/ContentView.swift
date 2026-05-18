import SwiftUI
import WebKit

struct ContentView: View {
    var body: some View {
        RecapWebView()
            .ignoresSafeArea()
    }
}

struct RecapWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.load(URLRequest(url: AppConfig.recapURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let oauthCoordinator = OAuthCoordinator()

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Intercept /auth/start and handle it with ASWebAuthenticationSession
            // so the user's existing Safari/Schoology session is reused (just tap Allow).
            if url.host == URL(string: AppConfig.recapBaseURL)?.host && url.path == "/auth/start" {
                decisionHandler(.cancel)
                Task { @MainActor in await self.handleMobileOAuth(webView: webView) }
                return
            }

            decisionHandler(.allow)
        }

        private func handleMobileOAuth(webView: WKWebView) async {
            // 1. Ask the server for the Schoology auth URL using the registered HTTP callback.
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

            // 2. Open Schoology in ASWebAuthenticationSession with prefersEphemeralWebBrowserSession = false
            //    so it shares the user's Safari session. They just tap Allow.
            //    The server's /auth/callback detects mobile and redirects to pinewoodrecap://auth/done?code=...
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

            // 3. Extract the temp code from pinewoodrecap://auth/done?code=...
            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  let activateURL = URL(string: "\(AppConfig.recapBaseURL)/auth/activate-code?code=\(code)&iosapp=1")
            else { return }

            // 4. Load /auth/activate-code in the WKWebView so the server sets the
            //    session cookie on the webview's cookie store, then redirects to /recap.
            webView.load(URLRequest(url: activateURL))
        }
    }
}

#Preview {
    ContentView()
}
