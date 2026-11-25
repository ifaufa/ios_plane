import Foundation

/// 地址栏输入规范化：允许用户只输入 example.com / 192.168.1.9:8080 这类不带协议的地址
enum AddressNormalizer {
    struct Result {
        var url: URL
        /// 是不是我们自动补的 https（失败时可自动回退 http）
        var autoHTTPS: Bool
    }

    static func resolve(_ raw: String) -> Result? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text) else { return nil }
            return Result(url: url, autoHTTPS: false)
        }

        // //example.com → 去掉前导 //
        let hostPart = text.hasPrefix("//") ? String(text.dropFirst(2)) : text
        guard !hostPart.isEmpty else { return nil }

        // 粗筛：必须像地址（含点 / localhost / 带端口）
        let hostOnly = hostPart.split(separator: "/").first.map(String.init) ?? hostPart
        let hostWithoutPort = hostOnly.split(separator: ":").first.map(String.init) ?? hostOnly
        let looksLikeHost = hostWithoutPort.contains(".")
            || hostWithoutPort.lowercased() == "localhost"
            || hostOnly.contains(":")
        guard looksLikeHost, !hostWithoutPort.contains("：") else { return nil }
        // 纯中文 / 无点且非 localhost 的输入直接拒绝（不做搜索）
        guard hostWithoutPort.rangeOfCharacter(from: .letters) != nil || hostWithoutPort.contains(".") else { return nil }

        if isLocalHost(hostWithoutPort) {
            guard let url = URL(string: "http://" + hostPart) else { return nil }
            return Result(url: url, autoHTTPS: false)
        }

        guard let url = URL(string: "https://" + hostPart) else { return nil }
        return Result(url: url, autoHTTPS: true)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value.hasSuffix(".local") { return true }
        if value == "127.0.0.1" || value == "0.0.0.0" { return true }
        if value.hasPrefix("192.168.") || value.hasPrefix("10.") { return true }
        if value.hasPrefix("172.") {
            let parts = value.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }
}
