import Foundation
import SwiftUI

struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: String
    var createdAt: Date
}

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    @Published private(set) var items: [Bookmark] = []
    @Published private(set) var errorMessage: String?

    private static var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bookmarks.json")
    }

    init() { load() }

    func contains(_ url: String) -> Bool {
        items.contains { $0.url == url }
    }

    /// 已收藏则取消，未收藏则新增
    func toggle(url: String, title: String) {
        if let existing = items.first(where: { $0.url == url }) {
            remove(existing)
        } else {
            items.insert(Bookmark(id: UUID(), title: title.isEmpty ? Self.fallbackTitle(url) : title,
                                  url: url, createdAt: Date()), at: 0)
            save()
        }
    }

    func remove(_ bookmark: Bookmark) {
        items.removeAll { $0.id == bookmark.id }
        save()
    }

    func rename(_ bookmark: Bookmark, to title: String) {
        guard let index = items.firstIndex(where: { $0.id == bookmark.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].title = trimmed.isEmpty ? Self.fallbackTitle(items[index].url) : trimmed
        save()
    }

    static func fallbackTitle(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        let name = parsed.deletingPathExtension().lastPathComponent
        return name.isEmpty ? (parsed.host ?? url) : name
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: Self.storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([Bookmark].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            errorMessage = "收藏夹读取失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: Self.storeURL, options: [.atomic])
            errorMessage = nil
        } catch {
            errorMessage = "收藏夹保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 收藏列表

struct BookmarksSheet: View {
    @ObservedObject var store: BookmarkStore
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renameTarget: Bookmark?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    Text("还没有收藏。浏览页面时点右上角 ☆ 即可收藏当前地址。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.items) { bookmark in
                    Button {
                        onOpen(bookmark.url)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bookmark.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.primary)
                            Text(bookmark.url)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            store.remove(bookmark)
                        }
                        Button("重命名") {
                            renameTarget = bookmark
                            renameText = bookmark.title
                        }
                        .tint(.blue)
                    }
                }
            }
            .navigationTitle("收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("标题", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    if let target = renameTarget {
                        store.rename(target, to: renameText)
                    }
                    renameTarget = nil
                }
            }
        }
    }
}
