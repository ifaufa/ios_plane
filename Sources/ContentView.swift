import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var backup = BackupManager()
    @ObservedObject private var segmentRunner = SegmentRunner.shared
    @ObservedObject private var playback = PlaybackStore.shared
    @AppStorage(LibrarySortMode.storageKey) private var sortModeRaw = LibrarySortMode.timeDesc.rawValue
    @State private var toastText: String?
    @State private var pendingToast: String?
    @State private var showAdd = false
    @State private var showBrowser = false
    @State private var showHeaders = false
    @State private var showImporter = false
    @State private var selectionMode = false
    @State private var selected: Set<UUID> = []
    @State private var convertingID: UUID?
    @State private var conversionProgress: Double = 0
    @State private var shareItem: ShareItem?
    @State private var showEngineSettings = false
    @State private var showDiagnostics = false

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
                    ForEach(sortedItems) { item in
                        HStack(spacing: 12) {
                            if selectionMode {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(item.id) ? Color.accentColor : .secondary)
                            }
                            LibraryRow(item: item, isMissing: library.isMissing(item), localURL: library.localURL(for: item))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectionMode {
                                toggleSelection(item)
                            } else if !library.isMissing(item) {
                                openPlayer(item)
                            } else {
                                showToast("文件已丢失（重装 App 会清空本地数据），需重新下载")
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                library.remove(item)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if item.fileName.lowercased().hasSuffix(".m3u8") {
                                Button {
                                    convert(item)
                                } label: {
                                    Label("转 MP4", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .tint(.blue)
                                Button {
                                    exportTS(item)
                                } label: {
                                    Label("导出 TS", systemImage: "doc.badge.arrow.up")
                                }
                                .tint(.orange)
                            } else if !library.isMissing(item) {
                                Button {
                                    shareItem = ShareItem(url: library.localURL(for: item))
                                } label: {
                                    Label("导出", systemImage: "square.and.arrow.up")
                                }
                                .tint(.green)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(LibrarySortMode.allCases) { mode in
                            Button {
                                sortModeRaw = mode.rawValue
                            } label: {
                                if sortModeRaw == mode.rawValue {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .disabled(library.items.isEmpty)
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
                        Button { showEngineSettings = true } label: {
                            Label("下载引擎…", systemImage: "gearshape.2")
                        }
                        Button { showDiagnostics = true } label: {
                            Label("诊断日志…", systemImage: "doc.text.magnifyingglass")
                        }
                        Divider()
                        Button { backup.backup(items: library.items, bookmarks: BookmarkStore.shared.items, bookmarkFolders: BookmarkStore.shared.folders) } label: {
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
                    DocumentExporter(url: url) { backup.finishExport() }
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
            .overlay(alignment: .top) { toastBanner }
            .onChange(of: segmentRunner.excludedNotice) { newValue in
                guard let text = newValue else { return }
                segmentRunner.excludedNotice = nil
                if playback.isFullscreen {
                    pendingToast = text + "（退出全屏后提示）"
                } else {
                    showToast(text)
                }
            }
            .onChange(of: playback.isFullscreen) { isFullscreen in
                // 全屏消失后再展示，避免打断播放
                if !isFullscreen, let text = pendingToast {
                    pendingToast = nil
                    showToast(text.replacingOccurrences(of: "（退出全屏后提示）", with: ""))
                }
            }
            .overlay {
                if backup.isWorking {
                    ProgressView(backup.progressText)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if convertingID != nil {
                    VStack(spacing: 10) {
                        ProgressView(value: min(max(conversionProgress, 0), 1))
                            .frame(width: 220)
                        Text("正在转封装 MP4… \(Int(min(max(conversionProgress, 0), 1) * 100))%")
                            .font(.footnote)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showAdd) {
                AddDownloadView()
            }
            .onChange(of: showBrowser) { isShowing in
                if isShowing {
                    playback.prepareForExternalAudio()
                    return
                }
                // fullScreenCover dismiss 是异步的，WKWebView 随后还会动一次音频会话，
                // 因此多次延后重试恢复，覆盖这个时间窗
                for delay in [1.5, 2.5, 4.0] {
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        playback.ensurePlaying()
                    }
                }
            }
            .fullScreenCover(isPresented: $showBrowser) {
                WebSnifferBrowser()
            }
            .sheet(isPresented: $showHeaders) {
                HeadersSettingsView()
            }
            .sheet(isPresented: $showEngineSettings) {
                EngineSettingsView()
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .fullScreenCover(isPresented: $playback.isFullscreen) {
                PlayerView(store: playback)
            }
            .overlay(alignment: .topLeading) {
                if playback.isActive, !playback.isFullscreen {
                    MiniPlayerWindow(store: playback)
                }
            }
            .onAppear {
                playback.onProgress = { id, seconds in
                    library.updateProgress(id: id, seconds: seconds)
                }
            }
            .task {
                library.cleanStaleMergeFiles()
                CompletionFeedback.requestAuthorizationIfNeeded()
                await ThumbnailService.pregenerate(items: library.items) { library.localURL(for: $0) }
            }
            .onChange(of: playback.errorNotice) { notice in
                guard let notice else { return }
                playback.errorNotice = nil
                showToast(notice)
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

    private func convert(_ item: VideoItem) {
        guard convertingID == nil else { return }
        convertingID = item.id
        conversionProgress = 0
        Task {
            do {
                let result = try await MediaConverter.convertToMP4(item: item) { value in
                    Task { @MainActor in conversionProgress = value }
                }
                library.replace(item, fileName: result.fileName, duration: result.duration, fileSize: result.fileSize)
                backup.alert = .init(title: "转换完成", message: "已转为 MP4 并校验通过，原分片已删除。")
            } catch {
                backup.alert = .init(title: "转换失败", message: error.localizedDescription)
            }
            convertingID = nil
        }
    }

    @ViewBuilder
    private var toastBanner: some View {
        if let toastText {
            Text(toastText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.82), in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toastText = text }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeIn(duration: 0.2)) {
                if toastText == text { toastText = nil }
            }
        }
    }

    private var sortedItems: [VideoItem] {
        let mode = LibrarySortMode(rawValue: sortModeRaw) ?? .timeDesc
        return library.items.sorted(by: mode)
    }

    private func openPlayer(_ item: VideoItem) {
        let url = library.localURL(for: item)
        let exists = FileManager.default.fileExists(atPath: url.path)
        DiagnosticsLog.write("[播放] 点击 \(item.title) 文件=\(item.fileName) 存在=\(exists)")
        guard exists else {
            showToast("文件不存在：\(item.fileName)")
            return
        }
        playback.open(video: item, url: url)
    }

    private func exportTS(_ item: VideoItem) {
        let dir = library.localURL(for: item).deletingLastPathComponent()
        Task {
            do {
                let url = try await MediaConverter.exportMergedTS(dir: dir, title: item.title)
                shareItem = ShareItem(url: url)
            } catch {
                backup.alert = .init(title: "导出失败", message: error.localizedDescription)
            }
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

struct DownloadRow: View {
    let task: DownloadTaskInfo
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title).font(.headline).lineLimit(1)

            if let codec = task.codecStatus {
                Text(codec)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Self.codecColor(codec))
            }

            switch task.status {
            case .queued:
                Text("排队等待中（已有 \(downloads.maxConcurrent) 个任务在下载）")
                    .font(.caption).foregroundStyle(.secondary)
            case .downloading:
                ProgressView(value: task.progress)
                Text("\(Int(task.progress * 100))% · \(Self.speedText(task.speed))")
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

    static func codecColor(_ status: String) -> Color {
        if status.hasPrefix("不支持") { return .red }
        if status.hasPrefix("支持") { return .green }
        return .orange
    }

    static func speedText(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1024 else { return "--" }
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}

private struct LibraryRow: View {
    let item: VideoItem
    let isMissing: Bool
    let localURL: URL

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(isMissing ? .secondary : .primary)
            HStack(spacing: 6) {
                Text(Self.kindLabel(for: item))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Self.kindColor(for: item).opacity(0.16), in: Capsule())
                    .foregroundStyle(Self.kindColor(for: item))
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
        }
        .padding(.vertical, 4)
        .task {
            guard thumbnail == nil, !isMissing else { return }
            thumbnail = await ThumbnailService.ensureThumbnail(for: item, localURL: localURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailReady)) { note in
            guard let readyID = note.object as? UUID, readyID == item.id else { return }
            if let cached = ThumbnailService.cached(for: item.id) {
                thumbnail = cached
            }
        }
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "film")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 48)
        .clipped()
    }

    static func kindLabel(for item: VideoItem) -> String {
        let name = item.fileName.lowercased()
        if name.hasSuffix(".movpkg") { return "系统缓存" }
        if name.hasSuffix(".m3u8") { return "分片" }
        if name.hasSuffix(".mp4") { return "MP4" }
        return "文件"
    }

    static func kindColor(for item: VideoItem) -> Color {
        let name = item.fileName.lowercased()
        if name.hasSuffix(".movpkg") { return .purple }
        if name.hasSuffix(".m3u8") { return .orange }
        if name.hasSuffix(".mp4") { return .green }
        return .gray
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 下载引擎设置

struct EngineSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var segmentEnabled =
        (UserDefaults.standard.string(forKey: DownloadManager.engineKey) ?? "segment") == "segment"
    @State private var perTask =
        max(1, UserDefaults.standard.integer(forKey: SegmentRunner.perTaskKey) > 0
            ? UserDefaults.standard.integer(forKey: SegmentRunner.perTaskKey) : 8)
    @State private var globalLimit =
        max(5, UserDefaults.standard.integer(forKey: SegmentRunner.globalKey) > 0
            ? UserDefaults.standard.integer(forKey: SegmentRunner.globalKey) : 20)
    @State private var maxTasks =
        { () -> Int in
            let value = UserDefaults.standard.integer(forKey: DownloadManager.maxConcurrentKey)
            return value <= 0 ? 5 : min(5, max(1, value))
        }()
    @State private var dropKeyChanged = UserDefaults.standard.bool(forKey: AdFilter.dropKeyChangedKey)
    @State private var adFingerprint = UserDefaults.standard.bool(forKey: AdFilter.fingerprintKey)
    @State private var writeStss = (UserDefaults.standard.object(forKey: "mp4WriteStss") as? Bool) ?? true
    @State private var completionSound = (UserDefaults.standard.object(forKey: CompletionFeedback.soundKey) as? Bool) ?? true
    @State private var completionNotice = (UserDefaults.standard.object(forKey: CompletionFeedback.noticeKey) as? Bool) ?? true

    var body: some View {
        NavigationStack {
            Form {
                Section("下载引擎") {
                    Toggle("分片引擎（可断点续传）", isOn: $segmentEnabled)
                }
                if segmentEnabled {
                    Section {
                        Toggle("断点处换密钥的分片也剔除（S2）", isOn: $dropKeyChanged)
                        Toggle("判定模式升级为编码参数指纹（S1）", isOn: $adFingerprint)
                    } header: {
                        Text("广告段处理")
                    } footer: {
                        Text("默认按分辨率判定插入片段；开启「指纹」后改为比对 SPS/PPS 编码参数，可识别分辨率相同但编码器不同的广告段；S2 会一并剔除断点处更换密钥的片段。剔除结果会在下载完成时提示。")
                    }
                    Section {
                        Toggle("下载完成提示音", isOn: $completionSound)
                        Toggle("下载完成通知（后台可见）", isOn: $completionNotice)
                        if completionNotice, CompletionFeedback.authorizationDenied {
                            Text("系统通知权限未开启，请到 设置 → 通知 → PlaneM3U8 中允许")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("提示音为低音量；通知在 App 后台时显示，前台仅 Toast 与提示音。")
                    }
                    Section {
                        Toggle("转换时写入同步样本表(stss)", isOn: $writeStss)
                    } footer: {
                        Text("开启后新转换的 MP4 会写入 stss，续播/拖动/缩略图定位更可靠。若转换后出现异常可关闭该项。")
                    }
                    Section {
                        Picker("同时下载任务数", selection: $maxTasks) {
                            ForEach([1, 2, 3, 4, 5], id: \.self) { Text("\($0)").tag($0) }
                        }
                    } footer: {
                        Text("同时进行的下载任务数量（1–5），默认 5。任务越多越占带宽，弱网建议 2–3。")
                    }
                    Section {
                        Picker("每任务", selection: $perTask) {
                            ForEach([1, 4, 6, 8, 10], id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("全局", selection: $globalLimit) {
                            ForEach([5, 8, 12, 16, 20, 32], id: \.self) { Text("\($0)").tag($0) }
                        }
                    } footer: {
                        Text("并发越高越快，但更耗电、更容易被源站限流；分片较大时还会增加内存占用。建议 8 / 20，网络好且源不限流时可用 10 / 32。\n\n选 1 / 5 属于极低并发：适合弱网或被限流时保稳，但仍走分片引擎（可续传），速度会明显慢于系统引擎。全局值小于每任务值时，实际以全局为准。")
                    }
                }
                Section {
                    Text("""
                    分片引擎：自行下载 m3u8 分片，暂停或杀进程后可从断点继续；下载完成即可播放，左滑条目可转换为 MP4。

                    系统引擎：使用 AVFoundation 离线下载，稳定性好，但暂停后只能从头重下。

                    改动只对之后新建的任务生效。
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("下载引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        UserDefaults.standard.set(segmentEnabled ? "segment" : "system",
                                                  forKey: DownloadManager.engineKey)
                        UserDefaults.standard.set(perTask, forKey: SegmentRunner.perTaskKey)
                        UserDefaults.standard.set(globalLimit, forKey: SegmentRunner.globalKey)
                        UserDefaults.standard.set(maxTasks, forKey: DownloadManager.maxConcurrentKey)
                        UserDefaults.standard.set(dropKeyChanged, forKey: AdFilter.dropKeyChangedKey)
                        UserDefaults.standard.set(adFingerprint, forKey: AdFilter.fingerprintKey)
                        UserDefaults.standard.set(writeStss, forKey: "mp4WriteStss")
                        UserDefaults.standard.set(completionSound, forKey: CompletionFeedback.soundKey)
                        UserDefaults.standard.set(completionNotice, forKey: CompletionFeedback.noticeKey)
                        if completionNotice { CompletionFeedback.requestAuthorizationIfNeeded() }
                        dismiss()
                    }
                }
            }
        }
    }
}
