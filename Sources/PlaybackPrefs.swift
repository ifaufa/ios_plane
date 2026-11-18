import Foundation
import Combine

/// 连播 / 片头片尾偏好（按系列保存）
///
/// 语义（v3）：
/// - introLength：片头时长（从 0:00 起算，等价于片头结束时间点）
/// - outroLength：片尾时长（贴着结尾，由「本集总时长 − 打点位置」得到）
/// - refDuration：打点片尾时那一集的总时长，用于判定「本集是否更短（可能没有片尾）」
@MainActor
final class PlaybackPrefs: ObservableObject {
    static let shared = PlaybackPrefs()

    struct SeriesTiming: Codable, Equatable {
        var introLength: Double = 0
        var outroLength: Double = 0
        var refDuration: Double = 0
        var name: String = ""
    }

    /// 旧版本结构（v1: pbSeriesTiming / v2: pbSeriesTimingV2），仅用于迁移
    private struct LegacyTiming: Codable {
        var intro: Double?
        var outro: Double?
        var name: String?
    }

    @Published var autoNext: Bool { didSet { saveFlags() } }
    @Published var skipIntro: Bool { didSet { saveFlags() } }
    @Published var skipOutro: Bool { didSet { saveFlags() } }
    /// 开启后：本集总时长比参考总时长短出一个片尾及以上时，判定为「没有片尾」，不自动跳
    @Published var protectNoOutro: Bool { didSet { saveFlags() } }
    @Published private(set) var series: [String: SeriesTiming] = [:]

    private let defaults = UserDefaults.standard

    private init() {
        autoNext = (defaults.object(forKey: "pbAutoNext") as? Bool) ?? true
        skipIntro = (defaults.object(forKey: "pbSkipIntro") as? Bool) ?? true
        skipOutro = (defaults.object(forKey: "pbSkipOutro") as? Bool) ?? true
        protectNoOutro = (defaults.object(forKey: "pbProtectNoOutro") as? Bool) ?? true

        if let data = defaults.data(forKey: "pbSeriesTimingV3"),
           let decoded = try? JSONDecoder().decode([String: SeriesTiming].self, from: data) {
            series = decoded
        } else {
            series = Self.migrateLegacy(defaults)
            if !series.isEmpty {
                if let data = try? JSONEncoder().encode(series) {
                    defaults.set(data, forKey: "pbSeriesTimingV3")
                }
                DiagnosticsLog.write("[播放] 片头片尾配置已迁移到 v3：\(series.count) 个系列（片尾需重新打点）")
            }
        }
    }

    /// v1/v2 → v3：片头语义相同可直接沿用；片尾是绝对时间点，缺总时长无法换算 → 清空
    private static func migrateLegacy(_ defaults: UserDefaults) -> [String: SeriesTiming] {
        for key in ["pbSeriesTimingV2", "pbSeriesTiming"] {
            guard let data = defaults.data(forKey: key),
                  let legacy = try? JSONDecoder().decode([String: LegacyTiming].self, from: data) else { continue }
            var converted: [String: SeriesTiming] = [:]
            for (seriesKey, old) in legacy {
                var timing = SeriesTiming()
                timing.introLength = max(0, old.intro ?? 0)
                timing.outroLength = 0
                timing.refDuration = 0
                timing.name = old.name ?? ""
                converted[seriesKey] = timing
            }
            return converted
        }
        return [:]
    }

    // MARK: - 查询

    func timing(forTitle title: String) -> SeriesTiming? {
        series[EpisodeIndex.parse(title).key]
    }

    func displayName(forTitle title: String) -> String {
        let name = EpisodeIndex.parse(title).name
        return name.isEmpty ? title : name
    }

    func timing(forKey key: String) -> SeriesTiming? { series[key] }

    func displayName(forKey key: String) -> String {
        let name = series[key]?.name ?? ""
        return name.isEmpty ? key : name
    }

    var configuredSeries: [(key: String, timing: SeriesTiming)] {
        series.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
    }

    /// 配置是否自相矛盾（片头 + 片尾 已吃掉全部时长 → 跳过将不生效）
    func isConflicting(_ timing: SeriesTiming) -> Bool {
        timing.introLength > 0 && timing.outroLength > 0 && timing.refDuration > 0
            && timing.introLength + timing.outroLength >= timing.refDuration - 5
    }

    // MARK: - 按 key 修改（设置页）

    func setIntroLength(_ seconds: Double, forKey key: String) {
        guard !key.isEmpty else { return }
        var timing = series[key] ?? SeriesTiming()
        timing.introLength = max(0, seconds)
        series[key] = timing
        saveSeries()
    }

    func setOutroLength(_ seconds: Double, forKey key: String) {
        guard !key.isEmpty else { return }
        var timing = series[key] ?? SeriesTiming()
        timing.outroLength = max(0, seconds)
        series[key] = timing
        saveSeries()
    }

    func clear(key: String) {
        series.removeValue(forKey: key)
        saveSeries()
    }

    // MARK: - 按标题修改（播放器打点）

    func setIntroLength(_ seconds: Double, forTitle title: String) {
        let parsed = EpisodeIndex.parse(title)
        guard !parsed.key.isEmpty else { return }
        var timing = series[parsed.key] ?? SeriesTiming()
        timing.introLength = max(0, seconds)
        if timing.name.isEmpty { timing.name = parsed.name }
        series[parsed.key] = timing
        saveSeries()
    }

    func setOutroLength(_ seconds: Double, forTitle title: String, refDuration: Double) {
        let parsed = EpisodeIndex.parse(title)
        guard !parsed.key.isEmpty else { return }
        var timing = series[parsed.key] ?? SeriesTiming()
        timing.outroLength = max(0, seconds)
        if refDuration > 0 { timing.refDuration = refDuration }
        if timing.name.isEmpty { timing.name = parsed.name }
        series[parsed.key] = timing
        saveSeries()
    }

    func clearIntro(forTitle title: String) {
        let key = EpisodeIndex.parse(title).key
        guard var timing = series[key] else { return }
        timing.introLength = 0
        series[key] = timing
        saveSeries()
    }

    func clearOutro(forTitle title: String) {
        let key = EpisodeIndex.parse(title).key
        guard var timing = series[key] else { return }
        timing.outroLength = 0
        timing.refDuration = 0
        series[key] = timing
        saveSeries()
    }

    func clearIntro(forKey key: String) {
        guard var timing = series[key] else { return }
        timing.introLength = 0
        series[key] = timing
        saveSeries()
    }

    func clearOutro(forKey key: String) {
        guard var timing = series[key] else { return }
        timing.outroLength = 0
        timing.refDuration = 0
        series[key] = timing
        saveSeries()
    }

    // MARK: - 持久化

    private func saveFlags() {
        defaults.set(autoNext, forKey: "pbAutoNext")
        defaults.set(skipIntro, forKey: "pbSkipIntro")
        defaults.set(skipOutro, forKey: "pbSkipOutro")
        defaults.set(protectNoOutro, forKey: "pbProtectNoOutro")
    }

    private func saveSeries() {
        if let data = try? JSONEncoder().encode(series) {
            defaults.set(data, forKey: "pbSeriesTimingV3")
        }
    }
}
