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

    /// 统一解析：与「自动连播」「按系列分组」共用 EpisodeIndex 这一套规则，
    /// 避免出现"连播认得出同一系列、排序/分组却认不出"的不一致
    static func parse(_ title: String) -> Parsed {
        let parsed = EpisodeIndex.parse(title)
        return Parsed(series: parsed.name, episode: parsed.episode)
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
