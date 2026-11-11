import Foundation

/// 视频库排序模式
enum LibrarySortMode: String, CaseIterable, Identifiable {
    case timeDesc
    case timeAsc
    case titleAsc
    case titleDesc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeDesc: return "添加时间（新→旧）"
        case .timeAsc: return "添加时间（旧→新）"
        case .titleAsc: return "标题+集数（正序）"
        case .titleDesc: return "标题+集数（倒序）"
        }
    }

    static let storageKey = "library.sortMode"
}

/// 从标题中解析「剧名 + 集数」
/// 采用方案 B 语义：标题倒序 = 剧名正序、组内集数倒序
enum TitleOrdering {
    struct Parsed {
        var series: String
        var episode: Int?
    }

    static func parse(_ title: String) -> Parsed {
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return Parsed(series: "", episode: nil) }

        // 1) 第N集 / 第N话 / 第N期 / 第N部
        if let match = firstMatch(#"第\s*(\d+)\s*[集话話期部]"#, in: original),
           let episode = Int(match.number) {
            return Parsed(series: strip(match.range, from: original), episode: episode)
        }

        // 2) EP12 / Ep12 / E12
        if let match = firstMatch(#"(?i)\b(?:EP|E)\s*(\d+)"#, in: original),
           let episode = Int(match.number) {
            return Parsed(series: strip(match.range, from: original), episode: episode)
        }

        // 3) 末尾独立数字（排除 1080x608 / 2024 这类分辨率与年份）
        let hasResolution = original.range(of: #"\d+\s*[x×]\s*\d+"#, options: .regularExpression) != nil
        if !hasResolution,
           let match = firstMatch(#"(\d+)\s*$"#, in: original),
           let episode = Int(match.number), episode < 10000 {
            return Parsed(series: strip(match.range, from: original), episode: episode)
        }

        return Parsed(series: original, episode: nil)
    }

    private struct Match {
        var number: String
        var range: Range<String.Index>
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: nsRange),
              result.numberOfRanges > 1,
              let numberRange = Range(result.range(at: 1), in: text),
              let fullRange = Range(result.range(at: 0), in: text) else { return nil }
        return Match(number: String(text[numberRange]), range: fullRange)
    }

    private static func strip(_ range: Range<String.Index>, from text: String) -> String {
        var result = text
        result.removeSubrange(range)
        let separators = CharacterSet(charactersIn: " .-_·[]()（）【】")
        let cleaned = result.trimmingCharacters(in: separators)
        return cleaned.isEmpty ? text : cleaned
    }
}

extension Array where Element == VideoItem {
    func sorted(by mode: LibrarySortMode) -> [VideoItem] {
        switch mode {
        case .timeDesc:
            return sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.title < rhs.title }
                return lhs.createdAt > rhs.createdAt
            }
        case .timeAsc:
            return sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.title < rhs.title }
                return lhs.createdAt < rhs.createdAt
            }
        case .titleAsc:
            return sorted { lhs, rhs in
                compareTitles(lhs, rhs, episodeDescending: false)
            }
        case .titleDesc:
            // 方案 B：剧名仍正序，组内集数倒序
            return sorted { lhs, rhs in
                compareTitles(lhs, rhs, episodeDescending: true)
            }
        }
    }

    private func compareTitles(_ lhs: VideoItem, _ rhs: VideoItem, episodeDescending: Bool) -> Bool {
        let left = TitleOrdering.parse(lhs.title)
        let right = TitleOrdering.parse(rhs.title)

        if left.series != right.series {
            let order = left.series.localizedStandardCompare(right.series)
            if order != .orderedSame { return order == .orderedAscending }
        }

        switch (left.episode, right.episode) {
        case let (l?, r?) where l != r:
            return episodeDescending ? l > r : l < r
        case (.some, .none):
            return true          // 有集数的排前面
        case (.none, .some):
            return false
        default:
            break
        }

        let order = lhs.title.localizedStandardCompare(rhs.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.createdAt > rhs.createdAt
    }
}
