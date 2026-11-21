import Foundation

/// 视频库分组结果（按系列折叠）
struct VideoGroup: Identifiable {
    let key: String
    /// 显示名（系列名；单条视频为标题）
    let title: String
    /// 是否折叠成组（解析出剧名且组内 ≥ 2 条）
    let isSeries: Bool
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

    /// 把视频库按「系列」聚合
    /// - 解析出剧名 + 集数的条目 → 按系列归组
    /// - 解析不出的 → 各自独立成组（单条，不折叠）
    /// - 组内排序跟随排序模式；组间排序：时间模式按组内最新时间，标题模式按剧名
    static func make(from items: [VideoItem], mode: LibrarySortMode) -> [VideoGroup] {
        struct Bucket {
            var key: String
            var title: String
            var isSeriesCandidate: Bool
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
            // 无集数 → 用自身 id 作为 key，保证永远不会被合并
            let key = hasEpisode ? "s:" + parsed.key : "i:" + item.id.uuidString

            if var bucket = buckets[key] {
                bucket.items.append(item)
                if let episode = parsed.episode { bucket.episodes.append(episode) }
                if item.createdAt > bucket.latest { bucket.latest = item.createdAt }
                buckets[key] = bucket
            } else {
                var episodes: [Int] = []
                if let episode = parsed.episode { episodes.append(episode) }
                buckets[key] = Bucket(key: key,
                                      title: hasEpisode ? parsed.name : item.title,
                                      isSeriesCandidate: hasEpisode,
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
                                     items: sortedItems,
                                     episodeRange: range,
                                     latest: bucket.latest))
        }

        switch mode {
        case .timeDesc:
            groups.sort { lhs, rhs in
                if lhs.latest == rhs.latest { return lhs.title < rhs.title }
                return lhs.latest > rhs.latest
            }
        case .timeAsc:
            groups.sort { lhs, rhs in
                if lhs.latest == rhs.latest { return lhs.title < rhs.title }
                return lhs.latest < rhs.latest
            }
        case .titleAsc, .titleDesc:
            // 与现有排序语义一致：剧名始终正序
            groups.sort { lhs, rhs in
                let result = lhs.title.localizedStandardCompare(rhs.title)
                if result == .orderedSame { return lhs.key < rhs.key }
                return result == .orderedAscending
            }
        }

        return groups
    }
}
