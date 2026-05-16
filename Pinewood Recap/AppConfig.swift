import Foundation

enum AppConfig {
    static let callbackScheme = "pinewoodrecap"
    static let recapBaseURL = "http://127.0.0.1:5002"
    static let recapURL = URL(string: "\(recapBaseURL)/recap")!
}
