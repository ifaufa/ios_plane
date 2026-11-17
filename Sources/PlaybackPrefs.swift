import Foundation
import Combine

/// 连播 / 片头片尾偏好（按系列保存）
@MainActor
final class PlaybackPrefs: ObservableObject {
    static let shared = PlaybackPrefs()

    /// intro = 片头结束的绝对时间点（秒）
    /// outro = 片尾开始的绝对时间点（秒）；0 表示该系列没有片尾、不跳过
    struct SeriesTiming: Codable, Equatable {
        var intro: Double = 0
        var outro: Double = 0
        var name: String = ""
    }

    @Published var autoNext: Bool { didSet { saveFlags() } }
    @Published var skipIntro: Bool { didSet { saveFlags() } }
    @Published var skipOutro: Bool { didSet { saveFlags() } }
    @Published private(set) var series: [String: SeriesTiming] = [:]

    private let defaults = UserDefaults.standard

    private init() {
        autoNext = (defaults.object(forKey: "pbAutoNext") as? Bool) ?? true
        skipIntro = (defaults.object(forKey: "pbSkipIntro") as? Bool) ?? true
        skipOutro = (defaults.object(forKey: "pbSkipOutro") as? Bool) ?? true
        // v2：outro 语义由「剩余时长」改为「绝对时间点」，旧数据不再沿用
        if let data = defaults.data(forKey: "pbSeriesTimingV2"),
           let decoded = try? JSONDecoder().decode([String: SeriesTiming].self, from: data) {
            series = decoded
        }
    }

    // MARK: - 查询

    func timing(forTitle title: String) -> SeriesTiming? {
        series[EpisodeIndex.parse(title).key]
    }

    func displayName(forTitle title: String) -> String {
        let name = EpisodeIndex.parse(title).name
        return name.isEmpty ? title : name
    }

    var configuredSeries: [(key: String, timing: SeriesTiming)] {
        series.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
    }

    // MARK: - 按 key 访问（设置页用）

    func timing(forKey key: String) -> SeriesTiming? { series[key] }

    func displayName(forKey key: String) -> String {
        let name = series[key]?.name ?? ""
        return name.isEmpty ? key : name
    }

    func setIntro(_ seconds: Double, forKey key: String) {
        guard !key.isEmpty else { return }
        var timing = series[key] ?? SeriesTiming()
        timing.intro = max(0, seconds)
        series[key] = timing
        saveSeries()
    }

    func setOutro(_ seconds: Double, forKey key: String) {
        guard !key.isEmpty else { return }
        var timing = series[key] ?? SeriesTiming()
        timing.outro = max(0, seconds)
        series[key] = timing
        saveSeries()
    }

    func clear(key: String) {
        series.removeValue(forKey: key)
        saveSeries()
    }

    // MARK: - 修改（按标题）

    func setIntro(_ seconds: Double, forTitle title: String) {
        let parsed = EpisodeIndex.parse(title)
        guard !parsed.key.isEmpty else { return }
        var timing = series[parsed.key] ?? SeriesTiming()
        timing.intro = max(0, seconds)
        timing.name = parsed.name
        series[parsed.key] = timing
        saveSeries()
    }

    func setOutro(_ seconds: Double, forTitle title: String) {
        let parsed = EpisodeIndex.parse(title)
        guard !parsed.key.isEmpty else { return }
        var timing = series[parsed.key] ?? SeriesTiming()
        timing.outro = max(0, seconds)
        timing.name = parsed.name
        series[parsed.key] = timing
        saveSeries()
    }

    func clear(forTitle title: String) {
        series.removeValue(forKey: EpisodeIndex.parse(title).key)
        saveSeries()
    }

    // MARK: - 持久化

    private func saveFlags() {
        defaults.set(autoNext, forKey: "pbAutoNext")
        defaults.set(skipIntro, forKey: "pbSkipIntro")
        defaults.set(skipOutro, forKey: "pbSkipOutro")
    }

    private func saveSeries() {
        if let data = try? JSONEncoder().encode(series) {
            defaults.set(data, forKey: "pbSeriesTimingV2")
        }
    }
}
