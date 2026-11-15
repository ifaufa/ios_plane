import Foundation

/// 自定义请求头规则（按域名生效，空域名为全局默认）
struct RequestProfile: Identifiable, Codable, Equatable {
    var id: UUID
    /// 备注名，如「HHUUS」
    var name: String
    /// 匹配规则：空=所有网址；play.hhuus.com=精确；.hhuus.com=该域名及其子域
    var hostPattern: String
    var referer: String
    var userAgent: String
    var enabled: Bool
    /// 最近命中次数（用于排查规则是否生效）
    var hitCount: Int?

    var displayName: String {
        hostPattern.isEmpty ? "默认（所有网址）" : hostPattern
    }
}

enum RequestSettings {
    private static let profilesKey = "req.profiles"
    private static var cache: [RequestProfile]?
    private static let cacheLock = NSLock()
    private static var pendingHits: [UUID: Int] = [:]
    private static var flushScheduled = false
    private static let legacyRefererKey = "req.referer"
    private static let legacyUAKey = "req.userAgent"

    // MARK: - 规则存取

    static var profiles: [RequestProfile] {
        get {
            cacheLock.lock()
            if let cache {
                cacheLock.unlock()
                return cache
            }
            cacheLock.unlock()

            migrateIfNeeded()
            guard let data = UserDefaults.standard.data(forKey: profilesKey),
                  let list = try? JSONDecoder().decode([RequestProfile].self, from: data) else {
                return []
            }
            cacheLock.lock()
            cache = list
            cacheLock.unlock()
            return list
        }
        set {
            cacheLock.lock()
            cache = newValue
            cacheLock.unlock()
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: profilesKey)
            }
        }
    }

    // MARK: - 命中统计

    /// 记录一次命中（内存累计，定期落盘，避免每个分片请求都写 UserDefaults）
    private static func bumpHit(_ id: UUID) {
        cacheLock.lock()
        pendingHits[id, default: 0] += 1
        let shouldSchedule = !flushScheduled
        if shouldSchedule { flushScheduled = true }
        cacheLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            flushHitCounts()
        }
    }

    /// 把内存中的命中次数合并到规则并持久化
    static func flushHitCounts() {
        cacheLock.lock()
        let pending = pendingHits
        pendingHits.removeAll()
        flushScheduled = false
        cacheLock.unlock()
        guard !pending.isEmpty else { return }

        var list = profiles
        var changed = false
        for index in list.indices {
            if let delta = pending[list[index].id] {
                list[index].hitCount = (list[index].hitCount ?? 0) + delta
                changed = true
            }
        }
        if changed { profiles = list }
    }

    /// 旧版全局配置迁移为「默认」规则（只做一次）
    private static func migrateIfNeeded() {
        guard UserDefaults.standard.data(forKey: profilesKey) == nil else { return }
        let referer = UserDefaults.standard.string(forKey: legacyRefererKey) ?? ""
        let ua = UserDefaults.standard.string(forKey: legacyUAKey) ?? ""
        var list: [RequestProfile] = []
        if !referer.isEmpty || !ua.isEmpty {
            list.append(RequestProfile(id: UUID(),
                                       name: "默认",
                                       hostPattern: "",
                                       referer: referer,
                                       userAgent: ua,
                                       enabled: true))
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    /// 默认（全局）规则
    static var defaultProfile: RequestProfile? {
        profiles.first { $0.hostPattern.isEmpty }
    }

    /// 兼容旧接口：全局 Referer / UA 读写（作用于默认规则）
    static var referer: String {
        get { defaultProfile?.referer ?? "" }
        set { updateDefault { $0.referer = newValue } }
    }

    static var userAgent: String {
        get { defaultProfile?.userAgent ?? "" }
        set { updateDefault { $0.userAgent = newValue } }
    }

    private static func updateDefault(_ mutate: (inout RequestProfile) -> Void) {
        var list = profiles
        if let index = list.firstIndex(where: { $0.hostPattern.isEmpty }) {
            mutate(&list[index])
        } else {
            var profile = RequestProfile(id: UUID(), name: "默认", hostPattern: "",
                                         referer: "", userAgent: "", enabled: true)
            mutate(&profile)
            list.insert(profile, at: 0)
        }
        profiles = list
    }

    // MARK: - 解析

    /// 取得该 URL 应使用的请求头（精确域名 > 后缀通配 > 全局默认）
    static func headers(for url: URL?) -> [String: String] {
        guard let profile = profile(for: url) else { return [:] }
        var result: [String: String] = [:]
        let refererValue = profile.referer.trimmingCharacters(in: .whitespacesAndNewlines)
        let uaValue = profile.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !refererValue.isEmpty { result["Referer"] = refererValue }
        if !uaValue.isEmpty { result["User-Agent"] = uaValue }
        return result
    }

    static func profile(for url: URL?) -> RequestProfile? {
        let matched = matchProfile(for: url)
        if let matched { bumpHit(matched.id) }
        return matched
    }

    private static func matchProfile(for url: URL?) -> RequestProfile? {
        let host = url?.host?.lowercased() ?? ""
        let enabled = profiles.filter { $0.enabled }
        guard !enabled.isEmpty else { return nil }

        if !host.isEmpty {
            if let exact = enabled.first(where: { !$0.hostPattern.isEmpty
                && !$0.hostPattern.hasPrefix(".")
                && $0.hostPattern.lowercased() == host }) {
                return exact
            }
            if let wildcard = enabled.first(where: { matchesWildcard($0.hostPattern, host: host) }) {
                return wildcard
            }
        }
        return enabled.first { $0.hostPattern.isEmpty }
    }

    /// 备份恢复时合并规则：按域名去重（已存在则跳过），返回新增条数
    @discardableResult
    static func mergeProfiles(_ incoming: [RequestProfile]) -> Int {
        var list = profiles
        let existing = Set(list.map { $0.hostPattern.lowercased().trimmingCharacters(in: .whitespaces) })
        var added = 0
        for profile in incoming {
            let key = profile.hostPattern.lowercased().trimmingCharacters(in: .whitespaces)
            guard !existing.contains(key) else { continue }
            list.append(profile)
            added += 1
        }
        if added > 0 { profiles = list }
        return added
    }

    private static func matchesWildcard(_ pattern: String, host: String) -> Bool {
        var value = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return false }
        if value.hasPrefix("*.") { value = String(value.dropFirst()) }   // *.abc.com → .abc.com
        guard value.hasPrefix(".") else { return false }
        let bare = String(value.dropFirst())
        return host == bare || host.hasSuffix(value)
    }

    /// 兼容旧接口：无 URL 上下文时按默认规则
    static var headers: [String: String] { headers(for: nil) }

    static var hasCustomHeaders: Bool { !headers.isEmpty }

    // MARK: - UA 预设

    static let userAgentPresets: [(title: String, value: String)] = [
        ("iPhone Safari",
         "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"),
        ("iPhone Chrome",
         "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/120.0.6099.119 Mobile/15E148 Safari/604.1"),
        ("iPad Safari",
         "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"),
        ("Android Chrome",
         "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"),
        ("桌面 Chrome（Windows）",
         "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
        ("桌面 Safari（macOS）",
         "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"),
    ]
}
