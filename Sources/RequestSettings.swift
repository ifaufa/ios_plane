import Foundation

/// 可选的自定义请求头（应对防盗链站点），全局生效
enum RequestSettings {
    private static let refererKey = "req.referer"
    private static let uaKey = "req.userAgent"

    static var referer: String {
        get { UserDefaults.standard.string(forKey: refererKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: refererKey) }
    }

    static var userAgent: String {
        get { UserDefaults.standard.string(forKey: uaKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: uaKey) }
    }

    static var headers: [String: String] {
        var result: [String: String] = [:]
        if !referer.isEmpty { result["Referer"] = referer }
        if !userAgent.isEmpty { result["User-Agent"] = userAgent }
        return result
    }

    static var hasCustomHeaders: Bool { !headers.isEmpty }
}
