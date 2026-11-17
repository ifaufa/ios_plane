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
    /// 保留的分片目录（相对 assets 目录，nil 表示分片已删除）
    var segmentDirName: String?
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

    // MARK: - 连播

    /// 同系列的下一集（集数严格大于当前；文件不存在则继续往后找）
    func nextEpisode(after item: VideoItem) -> VideoItem? {
        let current = EpisodeIndex.parse(item.title)
        guard let currentEpisode = current.episode, !current.key.isEmpty else { return nil }

        let candidates: [(item: VideoItem, episode: Int)] = items.compactMap { candidate in
            guard candidate.id != item.id else { return nil }
            let parsed = EpisodeIndex.parse(candidate.title)
            guard parsed.key == current.key, let episode = parsed.episode, episode > currentEpisode else { return nil }
            return (candidate, episode)
        }.sorted { $0.episode < $1.episode }

        for candidate in candidates {
            if !isMissing(candidate.item) { return candidate.item }
        }
        return nil
    }

    /// 该条目是否还有同系列下一集
    func hasNextEpisode(after item: VideoItem) -> Bool {
        nextEpisode(after: item) != nil
    }

    // MARK: - 修改

    func add(_ item: VideoItem) {
        quarantineStoreIfNeeded()
        items.insert(item, at: 0)
        save()
    }

    /// 仅删除台账条目；文件不存在时也能正常移除
    // MARK: - 分片保留 / 清理

    /// 该条目是否仍保留分片
    func hasSegments(_ item: VideoItem) -> Bool {
        guard let name = item.segmentDirName, !name.isEmpty else { return false }
        let dir = Self.assetsDir.appendingPathComponent(name, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path)
    }

    /// 分片占用字节数
    func segmentSize(_ item: VideoItem) -> Int64 {
        guard let name = item.segmentDirName, !name.isEmpty else { return 0 }
        let dir = Self.assetsDir.appendingPathComponent(name, isDirectory: true)
        return Self.directorySize(dir)
    }

    /// 只删除分片（保留 MP4）
    func deleteSegments(for item: VideoItem) {
        guard var target = items.first(where: { $0.id == item.id }),
              let name = target.segmentDirName, !name.isEmpty else { return }
        quarantineStoreIfNeeded()
        let dir = Self.assetsDir.appendingPathComponent(name, isDirectory: true)
        let freed = Self.directorySize(dir)
        try? FileManager.default.removeItem(at: dir)
        target.segmentDirName = nil
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = target }
        save()
        DiagnosticsLog.write("[清理] 删除分片 \(item.title) 释放 \(freed / (1024 * 1024))MB")
    }

    /// 只删除 MP4（保留分片，可再次转换）
    func deleteMP4KeepingSegments(for item: VideoItem) {
        guard var target = items.first(where: { $0.id == item.id }),
              let name = target.segmentDirName, !name.isEmpty else { return }
        quarantineStoreIfNeeded()
        let mp4URL = localURL(for: target)
        try? FileManager.default.removeItem(at: mp4URL)
        target.fileName = name + "/index.m3u8"
        target.fileSize = Self.directorySize(Self.assetsDir.appendingPathComponent(name, isDirectory: true))
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = target }
        save()
        DiagnosticsLog.write("[清理] 删除 MP4 并保留分片 \(item.title)")
    }

    /// 批量清理所有保留的分片，返回释放字节数
    @discardableResult
    func cleanupAllSegments() -> Int64 {
        quarantineStoreIfNeeded()
        var freed: Int64 = 0
        var count = 0
        for index in items.indices {
            guard let name = items[index].segmentDirName, !name.isEmpty else { continue }
            let dir = Self.assetsDir.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                items[index].segmentDirName = nil
                continue
            }
            freed += Self.directorySize(dir)
            try? FileManager.default.removeItem(at: dir)
            items[index].segmentDirName = nil
            count += 1
        }
        if count > 0 {
            save()
            DiagnosticsLog.write("[清理] 批量清理分片 \(count) 个 释放 \(freed / (1024 * 1024))MB")
        }
        return freed
    }

    /// 批量删除所有 MP4（保留分片，可再次转换），返回释放字节数
    @discardableResult
    func cleanupAllMP4KeepingSegments() -> Int64 {
        quarantineStoreIfNeeded()
        let fm = FileManager.default
        var freed: Int64 = 0
        var count = 0
        for index in items.indices {
            guard !items[index].fileName.lowercased().hasSuffix(".m3u8"),
                  let name = items[index].segmentDirName, !name.isEmpty else { continue }
            let mp4URL = localURL(for: items[index])
            let size = Int64((try? mp4URL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard (try? fm.removeItem(at: mp4URL)) != nil else { continue }
            freed += size
            count += 1
            items[index].fileName = name + "/index.m3u8"
            items[index].fileSize = Self.directorySize(Self.assetsDir.appendingPathComponent(name, isDirectory: true))
        }
        if count > 0 {
            save()
            DiagnosticsLog.write("[清理] 批量删除 MP4 \(count) 个 释放 \(freed / (1024 * 1024))MB（分片已保留）")
        }
        return freed
    }

    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
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
    func replace(_ item: VideoItem, fileName: String, duration: Double, fileSize: Int64, segmentDirName: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].fileName = fileName
        items[index].duration = duration
        items[index].fileSize = fileSize
        items[index].segmentDirName = segmentDirName
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

    /// 清理历史转换失败遗留的 merged.* 中间文件（可释放大量空间）
    /// 清理转换中断产生的半成品 MP4（无 moov → 无法播放）
    func cleanIncompleteMP4s() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Self.assetsDir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return }
        var removed = 0
        var freed: Int64 = 0
        for url in items where url.pathExtension.lowercased() == "mp4" {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDir else { continue }
            guard !Self.hasMoovBox(url) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
                freed += Int64(size)
            }
        }
        if removed > 0 {
            DiagnosticsLog.write("[清理] 删除未完成的 MP4 \(removed) 个，释放 \(freed / (1024 * 1024))MB")
        }
    }

    /// 顶层 box 扫描：是否存在 moov
    private static func hasMoovBox(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return true }
        var offset: UInt64 = 0
        while offset + 8 <= size {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var boxSize = UInt64(header.u32BE(at: 0))
            let type = header.asciiText(at: 4, length: 4)
            var headerLength: UInt64 = 8
            if boxSize == 1, header.count >= 16 {
                boxSize = header.u64BE(at: 8)
                headerLength = 16
            } else if boxSize == 0 {
                boxSize = size - offset
            }
            guard boxSize >= headerLength else { break }
            if type == "moov" { return true }
            offset += boxSize
        }
        return false
    }

    func cleanStaleMergeFiles() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.assetsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var removed = 0
        var freed: Int64 = 0
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            for name in ["merged.ts", "merged.mp4"] {
                let url = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: url.path) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? fm.removeItem(at: url)) != nil {
                    removed += 1
                    freed += Int64(size)
                }
            }
        }
        if removed > 0 {
            DiagnosticsLog.write("[清理] 删除遗留中间文件 \(removed) 个，释放 \(freed / (1024 * 1024))MB")
        }
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

private extension Data {
    func u32BE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(self[startIndex + offset + index]) }
        return value
    }

    func u64BE(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(self[startIndex + offset + index]) }
        return value
    }

    func asciiText(at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "????" }
        return String(decoding: self[(startIndex + offset)..<(startIndex + offset + length)], as: UTF8.self)
    }
}
