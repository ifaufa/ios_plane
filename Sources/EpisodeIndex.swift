import Foundation

/// 从视频标题解析「系列名 + 集数」，用于自动连播
enum EpisodeIndex {
    struct Parsed {
        /// 归一化后的系列键（用于匹配）
        let key: String
        /// 展示用系列名
        let name: String
        /// 集数（nil 表示标题里没有集数信息，不参与连播）
        let episode: Int?
    }

    /// 优先级从高到低
    /// 注意：这里是「连播 / 排序 / 分组」共用的唯一解析入口，改动会同时影响三处
    private static let patterns: [String] = [
        "第\\s*(\\d{1,4})\\s*[集话話期回部]",
        "(?i)\\bS\\d{1,2}\\s*[Ee]\\s*(\\d{1,4})",
        "(?i)\\bEP?\\.?\\s*(\\d{1,4})\\b",
        "#\\s*(\\d{1,4})"
    ]

    /// 分辨率（1080x608）或年份这类数字不应被当成集数
    private static let resolutionPattern = "\\d+\\s*[x×]\\s*\\d+"

    static func parse(_ title: String) -> Parsed {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return Parsed(key: "", name: "", episode: nil) }

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            guard let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  match.numberOfRanges > 1,
                  let epRange = Range(match.range(at: 1), in: raw),
                  let episode = Int(raw[epRange]) else { continue }

            var name = raw
            if let full = Range(match.range(at: 0), in: raw) {
                name.removeSubrange(full)
            }
            name = trimSeparators(name)
            if name.isEmpty { name = raw }
            return Parsed(key: normalize(name), name: name, episode: episode)
        }

        // 末尾独立数字（如「余红 16」）；排除分辨率写法，避免把 1080x608 当集数
        let hasResolution = raw.range(of: resolutionPattern, options: .regularExpression) != nil
        if !hasResolution,
           let regex = try? NSRegularExpression(pattern: "(\\d{1,4})\\s*$"),
           let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           match.numberOfRanges > 1,
           let epRange = Range(match.range(at: 1), in: raw),
           let episode = Int(raw[epRange]),
           episode > 0, episode < 10000 {
            var name = raw
            if let full = Range(match.range(at: 0), in: raw) {
                name.removeSubrange(full)
            }
            name = trimSeparators(name)
            if !name.isEmpty {
                return Parsed(key: normalize(name), name: name, episode: episode)
            }
        }

        return Parsed(key: normalize(raw), name: raw, episode: nil)
    }

    /// 归一化：去空白、常见分隔符、全半角差异，统一小写
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        result.reserveCapacity(lowered.count)
        for ch in lowered {
            if ch.isWhitespace { continue }
            if "·_-，,.、:：[]()（）【】－—".contains(ch) { continue }
            result.append(ch)
        }
        return result
    }

    private static func trimSeparators(_ text: String) -> String {
        let set = CharacterSet(charactersIn: " -_·，,.、:：[]()（）【】－—")
        return text.trimmingCharacters(in: set)
    }
}
