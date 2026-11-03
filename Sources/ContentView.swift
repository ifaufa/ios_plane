import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var backup = BackupManager()
    @State private var showAdd = false
    @State private var showBrowser = false
    @State private var showHeaders = false
    @State private var showImporter = false
    @State private var playing: VideoItem?
    @State private var selectionMode = false
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                if let message = library.errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            HStack(spacing: 20) {
                                Button("重新读取") { library.reload() }
                                Button("扫描本地文件重建") { rebuildLibrary() }
                            }
                            .font(.footnote)
                        }
                    }
                }
                if !library.missingItems.isEmpty {
                    Section {
                        Label("有 \(library.missingItems.count) 个视频文件已丢失，条目仅作记录，可左滑删除。",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                if !downloads.tasks.isEmpty {
                    Section("下载任务 (\(downloads.activeCount)/\(downloads.maxConcurrent))") {
                        ForEach(downloads.tasks) { task in
                            DownloadRow(task: task)
                                .swipeActions {
                                    Button("删除", role: .destructive) {
                                        downloads.remove(task)
                                    }
                                }
                        }
                    }
                }
                Section("视频库 (\(library.items.count))") {
                    ForEach(library.items) { item in
                        HStack(spacing: 12) {
                            if selectionMode {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(item.id) ? Color.accentColor : .secondary)
                            }
                            LibraryRow(item: item, isMissing: library.isMissing(item))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectionMode {
                                toggleSelection(item)
                            } else if !library.isMissing(item) {
                                playing = item
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                library.remove(item)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PlaneM3U8")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(selectionMode ? "取消" : "选择") {
                        selectionMode.toggle()
                        if !selectionMode { selected.removeAll() }
                    }
                    .disabled(library.items.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    if selectionMode {
                        HStack {
                            Button(selected.count == library.items.count ? "取消全选" : "全选") {
                                if selected.count == library.items.count {
                                    selected.removeAll()
                                } else {
                                    selected = Set(library.items.map { $0.id })
                                }
                            }
                            Spacer()
                            Button("删除 \(selected.count) 项", role: .destructive) {
                                deleteSelected()
                            }
                            .disabled(selected.isEmpty)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showBrowser = true } label: {
                            Label("浏览器找视频", systemImage: "safari")
                        }
                        Button { showAdd = true } label: {
                            Label("手动填写地址", systemImage: "square.and.pencil")
                        }
                        Button { showHeaders = true } label: {
                            Label("请求头设置…", systemImage: "slider.horizontal.3")
                        }
                        Divider()
                        Button { backup.backup(items: library.items) } label: {
                            Label("备份到文件…", systemImage: "square.and.arrow.up")
                        }
                        Button { showImporter = true } label: {
                            Label("从备份恢复…", systemImage: "square.and.arrow.down")
                        }
                        Divider()
                        Button { library.reload() } label: {
                            Label("重新读取台账", systemImage: "arrow.clockwise")
                        }
                        Button { rebuildLibrary() } label: {
                            Label("扫描本地文件重建台账", systemImage: "wand.and.stars")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url):
                    backup.restore(from: url, library: library)
                case .failure(let error):
                    backup.alert = .init(title: "选择文件失败", message: error.localizedDescription)
                }
            }
            .sheet(isPresented: Binding(
                get: { backup.exportURL != nil },
                set: { if !$0 { backup.exportURL = nil } }
            )) {
                if let url = backup.exportURL {
                    DocumentExporter(url: url) { backup.exportURL = nil }
                }
            }
            .alert(backup.alert?.title ?? "", isPresented: Binding(
                get: { backup.alert != nil },
                set: { if !$0 { backup.alert = nil } }
            ), presenting: backup.alert) { _ in
                Button("好", role: .cancel) {}
            } message: { info in
                Text(info.message)
            }
            .overlay {
                if backup.isWorking {
                    ProgressView(backup.progressText)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showAdd) {
                AddDownloadView()
            }
            .sheet(isPresented: $showBrowser) {
                WebSnifferBrowser()
            }
            .sheet(isPresented: $showHeaders) {
                HeadersSettingsView()
            }
            .fullScreenCover(item: $playing) { item in
                PlayerView(
                    url: library.localURL(for: item),
                    title: item.title,
                    startPosition: item.lastPosition ?? 0
                ) { seconds in
                    library.updateProgress(id: item.id, seconds: seconds)
                }
            }
        }
    }

    private func toggleSelection(_ item: VideoItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    private func rebuildLibrary() {
        let count = library.rebuildFromAssets()
        backup.alert = .init(
            title: "重建完成",
            message: count > 0 ? "扫描本地文件，新登记 \(count) 个视频。" : "没有发现未登记的视频文件。"
        )
    }

    private func deleteSelected() {
        library.remove(ids: selected)
        selected.removeAll()
        selectionMode = false
    }
}

private struct DownloadRow: View {
    let task: DownloadTaskInfo
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title).font(.headline).lineLimit(1)

            switch task.status {
            case .queued:
                Text("排队等待中（已有 5 个任务在下载）")
                    .font(.caption).foregroundStyle(.secondary)
            case .downloading:
                ProgressView(value: task.progress)
                Text("\(Int(task.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            case .paused:
                Text("已暂停 · \(Int(task.progress * 100))%")
                    .font(.caption).foregroundStyle(.orange)
            case .failed(let message):
                Text("失败：\(message)")
                    .font(.caption).foregroundStyle(.red)
            }

            if task.stalled {
                Label("进度 \(Int(downloads.stallTimeout)) 秒无变化，疑似卡住，可重试", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if task.restartedFromZero {
                Label("该源不支持断点续传，已从头开始下载", systemImage: "arrow.counterclockwise")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 18) {
                switch task.status {
                case .downloading, .queued:
                    Button("暂停") { downloads.pause(task) }
                case .paused:
                    Button("继续") { downloads.resume(task) }
                case .failed:
                    Button("重试") { downloads.resume(task) }
                }
                Button("删除", role: .destructive) { downloads.remove(task) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

private struct LibraryRow: View {
    let item: VideoItem
    let isMissing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(isMissing ? .secondary : .primary)
            HStack {
                Text(item.duration > 0 ? Self.formatDuration(item.duration) : "--:--")
                Text(Self.formatSize(item.fileSize))
                Text(item.createdAt, style: .date)
            }
            .font(.caption).foregroundStyle(.secondary)
            if let position = item.lastPosition, position > 5,
               item.duration <= 0 || position < item.duration - 5 {
                Text("上次看到 \(Self.formatDuration(position))")
                    .font(.caption2).foregroundStyle(.blue)
            }
            if isMissing {
                Text("文件已丢失（重装 App 会清空本地数据），需重新下载")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
