import Foundation

struct VideoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var sourceURL: String
    var fileName: String   // movpkg 文件名，位于 assets 目录下
    var duration: Double   // 秒
    var fileSize: Int64
    var createdAt: Date
}

@MainActor
final class VideoLibrary: ObservableObject {
    @Published private(set) var items: [VideoItem] = []

    /// 放在 Documents 下，配合 UIFileSharingEnabled 可在「文件」App 中看到并备份
    static let assetsDir: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 旧版本存放位置，启动时迁移
    private static var legacyAssetsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Assets", isDirectory: true)
    }

    private static var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library.json")
    }

    init() {
        migrateLegacyAssets()
        load()
    }

    func localURL(for item: VideoItem) -> URL {
        Self.assetsDir.appendingPathComponent(item.fileName)
    }

    func isMissing(_ item: VideoItem) -> Bool {
        !FileManager.default.fileExists(atPath: localURL(for: item).path)
    }

    var missingItems: [VideoItem] { items.filter { isMissing($0) } }

    func add(_ item: VideoItem) {
        items.insert(item, at: 0)
        save()
    }

    /// 仅删除台账条目；文件不存在时也能正常移除
    func remove(_ item: VideoItem) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: localURL(for: item))
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([VideoItem].self, from: data)
        else { return }
        // 不再静默丢弃：文件缺失的条目保留，界面如实提示
        items = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
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
