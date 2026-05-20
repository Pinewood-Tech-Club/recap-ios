import Foundation

enum AppConfig {
    static let callbackScheme = "pinewoodrecap"
    static let recapBaseURL = "https://h4p116c1-5002.usw3.devtunnels.ms"
    static let recapURL = URL(string: "\(recapBaseURL)/recap?iosapp=1")!
}
