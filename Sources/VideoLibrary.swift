import Foundation

struct VideoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var sourceURL: String
    var fileName: String   // movpkg 文件名，位于 assets 目录下
    var duration: Double   // 秒
    var fileSize: Int64
    var createdAt: Date
    /// 上次播放位置（秒）
    var lastPosition: Double?
}

@MainActor
final class VideoLibrary: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    /// 台账异常信息，非 nil 时界面必须显示
    @Published private(set) var errorMessage: String?

    /// 放在 Documents 下，配合 UIFileSharingEnabled 可在「文件」App 中看到并备份
    static let assetsDir: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var storeURL: URL { documentsDir.appendingPathComponent("library.json") }
    private static var backupURL: URL { documentsDir.appendingPathComponent("library.json.bak") }

    /// 旧版本存放位置，启动时迁移
    private static var legacyAssetsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Assets", isDirectory: true)
    }

    init() {
        migrateLegacyAssets()
        reload()
    }

    // MARK: - 读写

    /// 统一的解码入口：编码用 ISO8601，解码必须一致（历史版本这里漏设，导致每次冷启动台账清空）
    nonisolated static func decode(_ data: Data) throws -> [VideoItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([VideoItem].self, from: data)
        } catch {
            // 兼容旧格式（默认策略：数字时间戳）
            let fallback = JSONDecoder()
            fallback.dateDecodingStrategy = .deferredToDate
            return try fallback.decode([VideoItem].self, from: data)
        }
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: Self.storeURL.path) else {
            items = []
            errorMessage = nil
            return
        }
        do {
            let data = try Data(contentsOf: Self.storeURL)
            items = try Self.decode(data).sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            // 主台账解析失败：先尝试 .bak，再决定是否告警；绝不静默清空
            if let backupData = try? Data(contentsOf: Self.backupURL),
               let recovered = try? Self.decode(backupData) {
                items = recovered.sorted { $0.createdAt > $1.createdAt }
                errorMessage = "主台账已损坏，已从 library.json.bak 恢复 \(items.count) 条记录。"
            } else {
                items = []
                errorMessage = "台账读取失败：\(error.localizedDescription)。原文件已保留，重新保存时会另存为 library.corrupt-*.json。"
            }
        }
    }

    private func save() {
        do {
            if FileManager.default.fileExists(atPath: Self.storeURL.path) {
                // 把当前磁盘文件另存一份，作为下次损坏时的兜底
                try? FileManager.default.removeItem(at: Self.backupURL)
                try? FileManager.default.copyItem(at: Self.storeURL, to: Self.backupURL)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: Self.storeURL, options: [.atomic])
            errorMessage = nil
        } catch {
            errorMessage = "台账保存失败：\(error.localizedDescription)"
        }
    }

    /// 解析失败过就把可疑文件留档，避免用户数据被无声覆盖
    private func quarantineStoreIfNeeded() {
        guard errorMessage != nil, FileManager.default.fileExists(atPath: Self.storeURL.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = Self.documentsDir.appendingPathComponent("library.corrupt-\(formatter.string(from: Date())).json")
        try? FileManager.default.moveItem(at: Self.storeURL, to: target)
    }

    // MARK: - 查询

    func localURL(for item: VideoItem) -> URL {
        Self.assetsDir.appendingPathComponent(item.fileName)
    }

    func isMissing(_ item: VideoItem) -> Bool {
        !FileManager.default.fileExists(atPath: localURL(for: item).path)
    }

    var missingItems: [VideoItem] { items.filter { isMissing($0) } }

    // MARK: - 修改

    func add(_ item: VideoItem) {
        quarantineStoreIfNeeded()
        items.insert(item, at: 0)
        save()
    }

    /// 仅删除台账条目；文件不存在时也能正常移除
    func remove(_ item: VideoItem) {
        remove(ids: [item.id])
    }

    /// 批量删除
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        quarantineStoreIfNeeded()
        let fm = FileManager.default
        for item in items where ids.contains(item.id) {
            let url = localURL(for: item)
            if item.fileName.lowercased().hasSuffix(".m3u8") {
                // 分片态：删除整个工作目录（否则只删 index.m3u8，分片仍占空间）
                try? fm.removeItem(at: url.deletingLastPathComponent())
            } else {
                try? fm.removeItem(at: url)
            }
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    /// 转 MP4 成功后更新条目
    func replace(_ item: VideoItem, fileName: String, duration: Double, fileSize: Int64) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].fileName = fileName
        items[index].duration = duration
        items[index].fileSize = fileSize
        save()
    }

    /// 记录播放进度
    func updateProgress(id: UUID, seconds: Double) {
        guard seconds.isFinite, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard abs((items[idx].lastPosition ?? 0) - seconds) >= 1 else { return }
        items[idx].lastPosition = seconds
        save()
    }

    /// 合并备份里的条目（按 fileName 去重）
    func merge(_ incoming: [VideoItem]) {
        quarantineStoreIfNeeded()
        let existing = Set(items.map { $0.fileName })
        let added = incoming.filter { !existing.contains($0.fileName) }
        guard !added.isEmpty else {
            save()
            return
        }
        items.append(contentsOf: added)
        items.sort { $0.createdAt > $1.createdAt }
        save()
    }

    /// 台账彻底丢失时，扫描 Assets 目录把存在的视频重新登记
    @discardableResult
    func rebuildFromAssets() -> Int {
        quarantineStoreIfNeeded()
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: Self.assetsDir,
                                                   includingPropertiesForKeys: [.contentModificationDateKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        let existing = Set(items.map { $0.fileName })
        var added = 0
        for entry in entries where entry.pathExtension == "movpkg" {
            let name = entry.lastPathComponent
            guard !existing.contains(name) else { continue }
            let created = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            items.append(VideoItem(
                id: UUID(),
                title: name.replacingOccurrences(of: ".movpkg", with: ""),
                sourceURL: "",
                fileName: name,
                duration: 0,
                fileSize: Self.directorySize(at: entry),
                createdAt: created,
                lastPosition: nil
            ))
            added += 1
        }
        items.sort { $0.createdAt > $1.createdAt }
        save()
        return added
    }

    // MARK: - 私有

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        for case let sub as String in enumerator {
            let fileURL = url.appendingPathComponent(sub)
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func migrateLegacyAssets() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.legacyAssetsDir, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }
        for file in files {
            let dest = Self.assetsDir.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: file, to: dest)
            }
        }
    }
}
