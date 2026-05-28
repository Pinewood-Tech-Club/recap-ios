import Foundation

enum AppConfig {
    static let callbackScheme = "pinewoodrecap"
    static let recapBaseURL = "https://recap.pinewood.one"
    static let recapURL = URL(string: "\(recapBaseURL)/?iosapp=1")!
}
