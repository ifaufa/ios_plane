import Foundation

/// 视频库分组结果（按系列折叠）
struct VideoGroup: Identifiable {
    let key: String
    /// 显示名（系列名；单条视频为标题；未分组为「无系列」）
    let title: String
    /// 是否折叠成组（解析出剧名且组内 ≥ 2 条）
    let isSeries: Bool
    /// 是否为「无系列」（解析不出剧名 + 集数）的合集组
    let isUncategorized: Bool
    var items: [VideoItem]
    /// 集数范围（仅系列组有）
    var episodeRange: (low: Int, high: Int)?
    /// 组内最新添加时间（用于组间排序）
    let latest: Date

    var id: String { key }
    var count: Int { items.count }
}

enum LibraryGrouping {
    /// 是否按系列分组
    static let groupPrefKey = "library.groupBySeries"
    /// 折叠状态（组 key，用换行分隔；不存 = 展开）
    static let collapsedKey = "library.collapsedGroups"
    /// 「无系列」组是否展开（默认折叠）
    static let ungroupedExpandedKey = "library.ungroupedExpanded"
    /// 「无系列」组的固定 key
    static let ungroupedKey = "u:ungrouped"

    /// 把视频库按「系列」聚合
    /// - 解析出剧名 + 集数的条目 → 按系列归组
    /// - 解析不出的 → 统一归入「无系列」组（≥2 条时折叠，否则平铺）
    /// - 组内排序跟随排序模式；组间排序：时间模式按组内最新时间，标题模式按剧名
    /// - 「无系列」组固定排在最后
    static func make(from items: [VideoItem], mode: LibrarySortMode) -> [VideoGroup] {
        struct Bucket {
            var key: String
            var title: String
            var isSeriesCandidate: Bool
            var isUncategorized: Bool
            var items: [VideoItem]
            var episodes: [Int]
            var latest: Date
        }

        var buckets: [String: Bucket] = [:]
        var order: [String] = []
        order.reserveCapacity(items.count)

        for item in items {
            let parsed = EpisodeIndex.parse(item.title)
            let hasEpisode = (parsed.episode != nil) && !parsed.name.isEmpty
            let key = hasEpisode ? "s:" + parsed.key : ungroupedKey

            if var bucket = buckets[key] {
                bucket.items.append(item)
                if let episode = parsed.episode { bucket.episodes.append(episode) }
                if item.createdAt > bucket.latest { bucket.latest = item.createdAt }
                buckets[key] = bucket
            } else {
                var episodes: [Int] = []
                if let episode = parsed.episode { episodes.append(episode) }
                buckets[key] = Bucket(key: key,
                                      title: hasEpisode ? parsed.name : "无系列",
                                      isSeriesCandidate: true,
                                      isUncategorized: !hasEpisode,
                                      items: [item],
                                      episodes: episodes,
                                      latest: item.createdAt)
                order.append(key)
            }
        }

        var groups: [VideoGroup] = []
        groups.reserveCapacity(order.count)

        for key in order {
            guard let bucket = buckets[key] else { continue }
            var sortedItems = bucket.items

            switch mode {
            case .timeDesc, .timeAsc:
                let descending = (mode == .timeDesc)
                sortedItems.sort { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    }
                    return descending ? lhs.createdAt > rhs.createdAt : lhs.createdAt < rhs.createdAt
                }
            case .titleAsc, .titleDesc:
                let descending = (mode == .titleDesc)
                sortedItems.sort { lhs, rhs in
                    let left = EpisodeIndex.parse(lhs.title).episode ?? Int.max
                    let right = EpisodeIndex.parse(rhs.title).episode ?? Int.max
                    if left != right { return descending ? left > right : left < right }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }

            let episodes = bucket.episodes
            let range: (low: Int, high: Int)? = episodes.isEmpty
                ? nil
                : (episodes.min() ?? 0, episodes.max() ?? 0)

            groups.append(VideoGroup(key: bucket.key,
                                     title: bucket.title,
                                     isSeries: bucket.isSeriesCandidate && bucket.items.count >= 2,
                                     isUncategorized: bucket.isUncategorized,
                                     items: sortedItems,
                                     episodeRange: range,
                                     latest: bucket.latest))
        }

        // 组间排序：「无系列」永远最后
        func isLast(_ lhs: VideoGroup, _ rhs: VideoGroup) -> Bool? {
            if lhs.isUncategorized == rhs.isUncategorized { return nil }
            return !lhs.isUncategorized
        }

        switch mode {
        case .timeDesc:
            groups.sort { lhs, rhs in
                if let last = isLast(lhs, rhs) { return last }
                if lhs.latest == rhs.latest { return lhs.title < rhs.title }
                return lhs.latest > rhs.latest
            }
        case .timeAsc:
            groups.sort { lhs, rhs in
                if let last = isLast(lhs, rhs) { return last }
                if lhs.latest == rhs.latest { return lhs.title < rhs.title }
                return lhs.latest < rhs.latest
            }
        case .titleAsc, .titleDesc:
            // 与现有排序语义一致：剧名始终正序
            groups.sort { lhs, rhs in
                if let last = isLast(lhs, rhs) { return last }
                let result = lhs.title.localizedStandardCompare(rhs.title)
                if result == .orderedSame { return lhs.key < rhs.key }
                return result == .orderedAscending
            }
        }

        return groups
    }
}
