import Foundation
import SwiftUI

struct BookmarkFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
}

struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: String
    var createdAt: Date
    /// nil = 未分组（旧数据自动落这里）
    var folderID: UUID?
}

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    @Published private(set) var items: [Bookmark] = []
    @Published private(set) var folders: [BookmarkFolder] = []
    @Published private(set) var errorMessage: String?

    private static var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bookmarks.json")
    }

    private struct Snapshot: Codable {
        var folders: [BookmarkFolder]
        var items: [Bookmark]
    }

    init() { load() }

    // MARK: - 查询

    func contains(_ url: String) -> Bool {
        items.contains { $0.url == url }
    }

    func bookmarks(in folderID: UUID?) -> [Bookmark] {
        items.filter { $0.folderID == folderID }
    }

    func count(in folderID: UUID?) -> Int {
        items.reduce(0) { $0 + ($1.folderID == folderID ? 1 : 0) }
    }

    func folderName(_ id: UUID?) -> String {
        guard let id else { return "未分组" }
        return folders.first(where: { $0.id == id })?.name ?? "未分组"
    }

    // MARK: - 收藏

    func toggle(url: String, title: String, folderID: UUID? = nil) {
        if let existing = items.first(where: { $0.url == url }) {
            remove(existing)
        } else {
            items.insert(Bookmark(id: UUID(),
                                  title: title.isEmpty ? Self.fallbackTitle(url) : title,
                                  url: url,
                                  createdAt: Date(),
                                  folderID: folderID),
                         at: 0)
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

    func move(_ bookmark: Bookmark, to folderID: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == bookmark.id }) else { return }
        items[index].folderID = folderID
        save()
    }

    // MARK: - 文件夹

    @discardableResult
    func addFolder(_ name: String) -> BookmarkFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = BookmarkFolder(id: UUID(), name: trimmed, createdAt: Date())
        folders.append(folder)
        folders.sort { $0.createdAt < $1.createdAt }
        save()
        return folder
    }

    func renameFolder(_ folder: BookmarkFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].name = trimmed
        save()
    }

    /// 删除文件夹：其中收藏一并删除（不可恢复）
    func deleteFolder(_ folder: BookmarkFolder) {
        folders.removeAll { $0.id == folder.id }
        items.removeAll { $0.folderID == folder.id }
        save()
    }

    // MARK: - 备份合并

    @discardableResult
    func merge(_ incoming: [Bookmark], folders incomingFolders: [BookmarkFolder] = []) -> Int {
        var addedFolders = 0
        for folder in incomingFolders where !folders.contains(where: { $0.id == folder.id }) {
            folders.append(folder)
            addedFolders += 1
        }
        if addedFolders > 0 { folders.sort { $0.createdAt < $1.createdAt } }

        let existing = Set(items.map { $0.url })
        let added = incoming.filter { !existing.contains($0.url) }
        guard !added.isEmpty || addedFolders > 0 else { return 0 }
        items.append(contentsOf: added)
        items.sort { $0.createdAt > $1.createdAt }
        save()
        return added.count
    }

    static func fallbackTitle(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        let name = parsed.deletingPathExtension().lastPathComponent
        return name.isEmpty ? (parsed.host ?? url) : name
    }

    // MARK: - 持久化

    private func load() {
        guard FileManager.default.fileExists(atPath: Self.storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
                folders = snapshot.folders.sorted { $0.createdAt < $1.createdAt }
                items = snapshot.items.sorted { $0.createdAt > $1.createdAt }
            } else {
                // 旧格式：[Bookmark]
                items = try decoder.decode([Bookmark].self, from: data)
                    .sorted { $0.createdAt > $1.createdAt }
                folders = []
            }
            errorMessage = nil
        } catch {
            errorMessage = "收藏夹读取失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Snapshot(folders: folders, items: items))
            try data.write(to: Self.storeURL, options: [.atomic])
            errorMessage = nil
        } catch {
            errorMessage = "收藏夹保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 收藏列表（支持分组）

struct BookmarksSheet: View {
    @ObservedObject var store: BookmarkStore
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Scope: Hashable {
        case all
        case unfiled
        case folder(UUID)
    }

    @State private var scope: Scope = .all
    @State private var renameTarget: Bookmark?
    @State private var renameText = ""
    @State private var folderRenameTarget: BookmarkFolder?
    @State private var folderNameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var deleteTarget: BookmarkFolder?
    @State private var moveTarget: Bookmark?

    var body: some View {
        NavigationStack {
            List {
                foldersSection
                bookmarksSection
            }
            .navigationTitle("收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                }
            }
            .alert("新建文件夹", isPresented: $showNewFolder) {
                TextField("名称", text: $newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    if let folder = store.addFolder(newFolderName) {
                        scope = .folder(folder.id)
                    }
                }
            }
            .alert("重命名收藏", isPresented: renameBinding) {
                TextField("标题", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    if let target = renameTarget { store.rename(target, to: renameText) }
                    renameTarget = nil
                }
            }
            .alert("重命名文件夹", isPresented: folderRenameBinding) {
                TextField("名称", text: $folderNameText)
                Button("取消", role: .cancel) { folderRenameTarget = nil }
                Button("保存") {
                    if let target = folderRenameTarget { store.renameFolder(target, to: folderNameText) }
                    folderRenameTarget = nil
                }
            }
            .confirmationDialog("删除文件夹", isPresented: deleteBinding, titleVisibility: .visible) {
                Button("删除文件夹及其中收藏", role: .destructive) {
                    if let target = deleteTarget {
                        store.deleteFolder(target)
                        scope = .all
                    }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(deleteMessage)
            }
            .sheet(item: $moveTarget) { bookmark in
                MoveToFolderSheet(store: store, bookmark: bookmark)
            }
        }
    }

    // MARK: - 分组区

    private var foldersSection: some View {
        Section("分组") {
            row(title: "全部", count: store.items.count, isSelected: scope == .all) {
                scope = .all
            }
            .swipeActions(edge: .trailing) {
                EmptyView()
            }

            row(title: "未分组", count: store.count(in: nil), isSelected: scope == .unfiled) {
                scope = .unfiled
            }

            ForEach(store.folders) { folder in
                row(title: folder.name, count: store.count(in: folder.id),
                    isSelected: scope == .folder(folder.id),
                    icon: "folder") {
                    scope = .folder(folder.id)
                }
                .swipeActions {
                    Button("删除", role: .destructive) { deleteTarget = folder }
                    Button("重命名") {
                        folderRenameTarget = folder
                        folderNameText = folder.name
                    }
                    .tint(.blue)
                }
            }
        }
    }

    private func row(title: String, count: Int, isSelected: Bool,
                     icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if let icon {
                    Image(systemName: icon).foregroundStyle(Color.accentColor)
                }
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                if isSelected {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - 收藏区

    private var visibleBookmarks: [Bookmark] {
        switch scope {
        case .all: return store.items
        case .unfiled: return store.bookmarks(in: nil)
        case .folder(let id): return store.bookmarks(in: id)
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: return "全部收藏"
        case .unfiled: return "未分组"
        case .folder(let id): return store.folderName(id)
        }
    }

    private var bookmarksSection: some View {
        Section(scopeTitle) {
            if visibleBookmarks.isEmpty {
                Text("这个分组还没有收藏。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleBookmarks) { bookmark in
                Button {
                    onOpen(bookmark.url)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bookmark.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary)
                        HStack(spacing: 6) {
                            Text(bookmark.url)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                            if scope == .all {
                                Text(store.folderName(bookmark.folderID))
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { store.remove(bookmark) }
                    Button("移动") { moveTarget = bookmark }
                        .tint(.orange)
                    Button("重命名") {
                        renameTarget = bookmark
                        renameText = bookmark.title
                    }
                    .tint(.blue)
                }
            }
        }
    }

    // MARK: - 绑定

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var folderRenameBinding: Binding<Bool> {
        Binding(get: { folderRenameTarget != nil }, set: { if !$0 { folderRenameTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var deleteMessage: String {
        guard let target = deleteTarget else { return "" }
        let count = store.count(in: target.id)
        return count > 0
            ? "将删除「\(target.name)」及其中 \(count) 条收藏，此操作不可撤销。"
            : "将删除「\(target.name)」。"
    }
}

// MARK: - 移动到文件夹

private struct MoveToFolderSheet: View {
    @ObservedObject var store: BookmarkStore
    let bookmark: Bookmark

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    store.move(bookmark, to: nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("未分组").foregroundStyle(Color.primary)
                        Spacer()
                        if bookmark.folderID == nil {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                ForEach(store.folders) { folder in
                    Button {
                        store.move(bookmark, to: folder.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(Color.accentColor)
                            Text(folder.name).foregroundStyle(Color.primary)
                            Spacer()
                            if bookmark.folderID == folder.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
