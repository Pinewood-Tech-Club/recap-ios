import Foundation

enum CookiePersistence {
    private static let key = "pinewood_cookies_v1"

    static func save(_ cookies: [HTTPCookie]) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: cookies,
            requiringSecureCoding: false
        ) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [HTTPCookie] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cookies = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSArray.self, HTTPCookie.self],
                  from: data
              ) as? [HTTPCookie]
        else { return [] }
        return cookies
    }
}
