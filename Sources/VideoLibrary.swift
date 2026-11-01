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

    static let assetsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library.json")
    }

    init() { load() }

    func localURL(for item: VideoItem) -> URL {
        Self.assetsDir.appendingPathComponent(item.fileName)
    }

    func add(_ item: VideoItem) {
        items.insert(item, at: 0)
        save()
    }

    func remove(_ item: VideoItem) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: localURL(for: item))
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([VideoItem].self, from: data)
        else { return }
        // 清理文件已丢失的条目
        items = decoded.filter {
            FileManager.default.fileExists(atPath: Self.assetsDir.appendingPathComponent($0.fileName).path)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
