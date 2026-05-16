import AuthenticationServices
import UIKit

@MainActor
final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var currentSession: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw OAuthError.unsupportedScheme(url.scheme)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) {
                [weak self] callbackURL, error in
                self?.currentSession = nil

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain &&
                        nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: OAuthError.cancelled)
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(throwing: OAuthError.invalidResponse)
            }

            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            currentSession = session

            if !session.start() {
                currentSession = nil
                continuation.resume(throwing: OAuthError.invalidResponse)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

enum OAuthError: Error, LocalizedError {
    case unsupportedScheme(String?)
    case invalidResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let s): return "Unsupported URL scheme: \(s ?? "nil")"
        case .invalidResponse: return "Invalid OAuth response."
        case .cancelled: return "OAuth cancelled."
        }
    }
}
