import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var backup = BackupManager()
    @ObservedObject private var segmentRunner = SegmentRunner.shared
    @ObservedObject private var playback = PlaybackStore.shared
    @AppStorage(LibrarySortMode.storageKey) private var sortModeRaw = LibrarySortMode.timeDesc.rawValue
    @AppStorage(LibraryGrouping.groupPrefKey) private var groupBySeries = true
    @AppStorage(LibraryGrouping.collapsedKey) private var collapsedRaw = ""
    @AppStorage(LibraryGrouping.ungroupedExpandedKey) private var ungroupedExpanded = false
    @State private var pendingLibraryAction: LibraryAction?
    @State private var searchText = ""
    /// 类型筛选（并集）：segments / mp4Only / missing
    @AppStorage("library.filter.types") private var filterTypesRaw = ""
    /// 标记筛选（交集）：混合参数
    @AppStorage("library.filter.mixed") private var filterMixed = false
    /// 「最近在看」分区开关
    @AppStorage("library.recentEnabled") private var recentEnabled = true
    /// 「最近在看」显示条数
    @AppStorage("library.recentCount") private var recentCount = 5
    @State private var pendingLargeConvert: VideoItem?


    @State private var toastText: String?
    @State private var pendingToast: String?
    @State private var showAdd = false
    @State private var showBrowser = false
    @State private var showHeaders = false
    @State private var showImporter = false
    @State private var showOrphanSheet = false
    @State private var showStorage = false
    @State private var showQueueSheet = false
    @State private var restoreExpectation: String?
    @State private var selectionMode = false
    @State private var selected: Set<UUID> = []
    @State private var renameTarget: VideoItem?
    @State private var renameText = ""
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
                downloadsSection
                if recentEnabled, searchText.isEmpty, !isFiltering, !recentItems.isEmpty {
                    Section {
                        ForEach(recentItems) { item in
                            recentRow(item)
                        }
                    } header: {
                        HStack {
                            Text("最近在看")
                            Spacer()
                            Button("清空") { pendingLibraryAction = .clearRecent }
                                .font(.caption)
                        }
                    }
                }
                if sortedItems.isEmpty, isFiltering || !searchText.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("没有匹配的内容")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 14) {
                                if !searchText.isEmpty {
                                    Button("清除搜索") { searchText = "" }
                                }
                                if isFiltering {
                                    Button("重置筛选") { resetFilters() }
                                }
                            }
                            .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section(librarySectionTitle) {
                    if groupBySeries {
                        ForEach(groupedItems) { group in
                            if group.isSeries {
                                groupHeaderRow(group)
                                if !isCollapsed(group) {
                                    ForEach(group.items) { item in
                                        libraryRow(item)
                                    }
                                }
                            } else {
                                ForEach(group.items) { item in
                                    libraryRow(item)
                                }
                            }
                        }
                    } else {
                        ForEach(sortedItems) { item in
                            libraryRow(item)
                        }
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索标题")
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("标题", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    if let target = renameTarget {
                        library.rename(target, to: renameText)
                    }
                    renameTarget = nil
                }
            } message: {
                Text("保留「第N集」才能继续按系列分组与自动连播")
            }
            .navigationTitle("PlaneM3U8")
            .onAppear { SegmentEditStore.shared.library = library }
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
                        if groupBySeries {
                            Divider()
                            Button("全部展开") { setAllCollapsed(false) }
                            Button("全部折叠") { setAllCollapsed(true) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .disabled(library.items.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Section("类型（任一满足）") {
                            ForEach([LibraryFilter.segments, .mp4Only, .missing]) { filter in
                                Button {
                                    toggleTypeFilter(filter)
                                } label: {
                                    if selectedTypes.contains(filter) {
                                        Label(filter.title, systemImage: "checkmark")
                                    } else {
                                        Text(filter.title)
                                    }
                                }
                            }
                        }
                        Section("标记（需同时满足）") {
                            Button {
                                filterMixed.toggle()
                                selected.removeAll()
                            } label: {
                                if filterMixed {
                                    Label("混合参数", systemImage: "checkmark")
                                } else {
                                    Text("混合参数")
                                }
                            }
                        }
                        Divider()
                        Button("重置筛选") { resetFilters() }
                            .disabled(!isFiltering && searchText.isEmpty)
                    } label: {
                        Image(systemName: isFiltering
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
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
                        Menu {
                            Button {
                                backup.backupVideo(items: library.items)
                            } label: {
                                Label("备份视频到文件…", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                restoreExpectation = "video"
                                showImporter = true
                            } label: {
                                Label("从文件恢复视频…", systemImage: "square.and.arrow.down")
                            }
                            Divider()
                            Button {
                                backup.backupBookmarks(bookmarks: BookmarkStore.shared.items,
                                                       bookmarkFolders: BookmarkStore.shared.folders)
                            } label: {
                                Label("备份收藏到文件…", systemImage: "bookmark")
                            }
                            Button {
                                restoreExpectation = "bookmarks"
                                showImporter = true
                            } label: {
                                Label("从文件恢复收藏…", systemImage: "bookmark.fill")
                            }
                            Button {
                                backup.exportBookmarksJSON(bookmarks: BookmarkStore.shared.items,
                                                           bookmarkFolders: BookmarkStore.shared.folders)
                            } label: {
                                Label("导出收藏为 JSON…", systemImage: "curlybraces")
                            }
                            Divider()
                            Button {
                                backup.backupAll(items: library.items,
                                                 bookmarks: BookmarkStore.shared.items,
                                                 bookmarkFolders: BookmarkStore.shared.folders)
                            } label: {
                                Label("备份全部（视频+收藏）…", systemImage: "externaldrive.badge.timemachine")
                            }
                            Button {
                                restoreExpectation = nil
                                showImporter = true
                            } label: {
                                Label("从任意备份恢复…", systemImage: "arrow.down.doc")
                            }
                        } label: {
                            Label("备份与恢复", systemImage: "archivebox")
                        }
                        Divider()
                        Button { library.reload() } label: {
                            Label("重新读取台账", systemImage: "arrow.clockwise")
                        }
                        Button { rebuildLibrary() } label: {
                            Label("扫描本地文件重建台账", systemImage: "wand.and.stars")
                        }
                        Divider()
                        Menu {
                            Button {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pendingLibraryAction = .cleanupSegments }
                            } label: {
                                Label("清理所有分片", systemImage: "scissors")
                            }
                            Button {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pendingLibraryAction = .cleanupMP4 }
                            } label: {
                                Label("删除所有 MP4（保留分片）", systemImage: "film")
                            }
                            Button { showOrphanSheet = true } label: {
                                Label("清理孤立文件…", systemImage: "trash.slash")
                            }
                            Button { showStorage = true } label: {
                                Label("存储空间…", systemImage: "internaldrive")
                            }
                        } label: {
                            Label("存储清理", systemImage: "externaldrive.badge.minus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showOrphanSheet) {
                OrphanCleanupSheet(library: library)
            }
            .sheet(isPresented: $showStorage) {
                StorageSheet(library: library)
            }
            .sheet(isPresented: $showQueueSheet) {
                QueueOverviewSheet()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url):
                    backup.restore(from: url, library: library, expecting: restoreExpectation)
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
            .alert(item: $pendingLibraryAction) { action in
                Alert(title: Text(action.title),
                      message: Text(action.message),
                      primaryButton: primaryButton(for: action),
                      secondaryButton: .cancel(Text("取消")))
            }
            .confirmationDialog("该源体积较大",
                                isPresented: Binding(get: { pendingLargeConvert != nil },
                                                     set: { if !$0 { pendingLargeConvert = nil } }),
                                titleVisibility: .visible) {
                Button("继续（自研封装）") {
                    if let item = pendingLargeConvert { startConvert(item) }
                    pendingLargeConvert = nil
                }
                Button("取消", role: .cancel) { pendingLargeConvert = nil }
            } message: {
                if let item = pendingLargeConvert {
                    Text("约 \(item.fileSize / 1_000_000_000)GB。自研封装可能因内存不足而中止；若失败，可到设置里关闭「使用自研封装」，改用系统分段合并。")
                }
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
                playback.nextEpisodeProvider = { item in
                    library.nextEpisode(after: item)
                }
                playback.openEpisodeHandler = { item in
                    openPlayer(item)
                }
            }
            .task {
                library.cleanStaleMergeFiles()
                library.cleanIncompleteMP4s()
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
        let useDirect = (UserDefaults.standard.object(forKey: "mp4UseDirectMuxer") as? Bool) ?? true
        if useDirect, item.fileSize > 2_300_000_000 {
            pendingLargeConvert = item
            return
        }
        startConvert(item)
    }

    private func startConvert(_ item: VideoItem) {
        convertingID = item.id
        conversionProgress = 0
        Task {
            do {
                let result = try await MediaConverter.convertToMP4(item: item) { value in
                    Task { @MainActor in conversionProgress = value }
                }
                  library.replace(item, fileName: result.fileName, duration: result.duration, fileSize: result.fileSize, segmentDirName: result.segmentDirName)
                  let keptSegments = result.segmentDirName != nil
                  backup.alert = .init(title: "转换完成", message: keptSegments ? "已转为 MP4 并校验通过。原分片已保留（可再次转换），空间不足时可在该视频上「删分片」。" : "已转为 MP4 并校验通过，原分片已删除。")
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

    @ViewBuilder
    /// 单条视频行（分组与平铺共用）
    private func libraryRow(_ item: VideoItem) -> some View {
        HStack(spacing: 12) {
            if selectionMode {
                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(item.id) ? Color.accentColor : .secondary)
            }
            LibraryRow(item: item, isMissing: library.isMissing(item), localURL: library.localURL(for: item), isMixed: library.isMixedParams(item))
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
                let target = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    pendingLibraryAction = .deleteAll(target)
                }
            }
            if library.hasSegments(item), !item.fileName.lowercased().hasSuffix(".m3u8") {
                Button("删MP4", role: .destructive) {
                    let target = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        pendingLibraryAction = .deleteMP4(target)
                    }
                }
                .tint(.blue)
            }
            if library.hasSegments(item) {
                Button("删分片", role: .destructive) {
                    let target = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        pendingLibraryAction = .deleteSegments(target)
                    }
                }
                .tint(.orange)
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
        .contextMenu {
            Button {
                renameText = item.title
                renameTarget = item
            } label: {
                Label("重命名…", systemImage: "pencil")
            }
            if library.hasPlaylist(item) {
                Button {
                    addToClipList(item, openEditor: false)
                } label: {
                    Label("添加到剪辑素材列表", systemImage: "text.badge.plus")
                }
                Button {
                    addToClipList(item, openEditor: true)
                } label: {
                    Label("分片剪辑", systemImage: "scissors")
                }
            }
            if !library.isMissing(item) {
                Button {
                    openPlayer(item, fromBeginning: true)
                } label: {
                    Label("从头播放", systemImage: "backward.end.fill")
                }
            }
            if library.hasSegments(item), !item.fileName.lowercased().hasSuffix(".m3u8") {
                Button {
                    let target = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        pendingLibraryAction = .deleteMP4(target)
                    }
                } label: {
                    Label("删除 MP4（保留分片）", systemImage: "film")
                }
            }
            if library.hasSegments(item) {
                Button(role: .destructive) {
                    let target = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        pendingLibraryAction = .deleteSegments(target)
                    }
                } label: {
                    Label("删除分片（保留 MP4）", systemImage: "scissors")
                }
            }
            Button(role: .destructive) {
                let target = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    pendingLibraryAction = .deleteAll(target)
                }
            } label: {
                Label("全部删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 按系列分组

    private var sortMode: LibrarySortMode {
        LibrarySortMode(rawValue: sortModeRaw) ?? .timeDesc
    }

    private var groupedItems: [VideoGroup] {
        LibraryGrouping.make(from: sortedItems, mode: sortMode)
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedRaw.split(separator: "\n").map(String.init))
    }

    /// 是否折叠（「无系列」组默认折叠，单独用开关记录）
    private func isCollapsed(_ group: VideoGroup) -> Bool {
        if group.isUncategorized { return !ungroupedExpanded }
        return collapsedGroups.contains(group.key)
    }

    private func toggleCollapsed(_ group: VideoGroup) {
        if group.isUncategorized {
            ungroupedExpanded.toggle()
            return
        }
        var set = collapsedGroups
        if set.contains(group.key) { set.remove(group.key) } else { set.insert(group.key) }
        collapsedRaw = set.sorted().joined(separator: "\n")
    }

    private func setAllCollapsed(_ collapsed: Bool) {
        ungroupedExpanded = !collapsed
        if collapsed {
            collapsedRaw = groupedItems.filter { $0.isSeries && !$0.isUncategorized }
                .map { $0.key }.sorted().joined(separator: "\n")
        } else {
            collapsedRaw = ""
        }
    }

    private func isAllSelected(_ group: VideoGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy { selected.contains($0.id) }
    }

    /// 组头统计文案：`6 集 · 第1–7集（缺 6）`
    private func groupStats(_ group: VideoGroup) -> String {
        if group.isUncategorized { return "\(group.count) 个" }
        var text = "\(group.count) 集"
        if let range = group.episodeRange, range.low != range.high {
            text += " · 第\(range.low)–\(range.high)集"
        }
        if let gaps = missingEpisodeText(group) {
            text += gaps
        }
        return text
    }

    /// 集数断档：≤3 个列出具体集数，>3 个显示「缺 N 集」
    private func missingEpisodeText(_ group: VideoGroup) -> String? {
        let episodes = group.items.compactMap { EpisodeIndex.parse($0.title).episode }
        guard let low = episodes.min(), let high = episodes.max(), high > low else { return nil }
        let existing = Set(episodes)
        let gaps = (low...high).filter { !existing.contains($0) }
        guard !gaps.isEmpty else { return nil }
        if gaps.count <= 3 {
            return "（缺 " + gaps.map(String.init).joined(separator: "、") + "）"
        }
        return "（缺 \(gaps.count) 集）"
    }

    /// 同一集数出现多次的次数（重复下载）
    private func duplicateEpisodeCount(_ group: VideoGroup) -> Int {
        let episodes = group.items.compactMap { EpisodeIndex.parse($0.title).episode }
        return episodes.count - Set(episodes).count
    }

    @ViewBuilder
    private func groupHeaderRow(_ group: VideoGroup) -> some View {
        Button {
            if selectionMode {
                if isAllSelected(group) {
                    group.items.forEach { selected.remove($0.id) }
                } else {
                    group.items.forEach { selected.insert($0.id) }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.18)) { toggleCollapsed(group) }
            }
        } label: {
            HStack(spacing: 8) {
                if selectionMode {
                    Image(systemName: isAllSelected(group) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isAllSelected(group) ? Color.accentColor : .secondary)
                        .font(.caption)
                } else {
                    Image(systemName: isCollapsed(group) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(groupStats(group))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                let duplicates = duplicateEpisodeCount(group)
                if duplicates > 0 {
                    Text("重复 \(duplicates)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // 仅在折叠时提示：展开后每行都有红字，无需重复
                if isCollapsed(group) {
                    let unhealthy = group.items.filter { library.health($0) != .ok }.count
                    if unhealthy > 0 {
                        Label("\(unhealthy) 缺失", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentItems: [VideoItem] {
        library.recentlyWatched(limit: recentCount)
    }

    @ViewBuilder
    private func recentRow(_ item: VideoItem) -> some View {
        HStack(spacing: 10) {
            RecentThumbnail(item: item, localURL: library.localURL(for: item))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .lineLimit(1)
                // 观看进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.22))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(0, min(1, progressFraction(item))) * geo.size.width)
                    }
                }
                .frame(height: 3)
                HStack(spacing: 6) {
                    Text("上次看到 " + PlaybackStore.timeText(item.lastPosition ?? 0))
                    Text("·")
                    Text("还剩 " + PlaybackStore.timeText(max(0, item.duration - (item.lastPosition ?? 0))))
                    Text("·")
                    Text(Self.relativeTime(item.lastPlayedAt))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("继续播放") { openPlayer(item) }
                Button("移除记录") { library.dismissRecent(item.id, clearProgress: false) }
                Button("移除并清除进度", role: .destructive) {
                    library.dismissRecent(item.id, clearProgress: true)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if library.isMissing(item) {
                showToast("文件已丢失，需重新下载")
            } else {
                openPlayer(item)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("移除记录", role: .destructive) {
                library.dismissRecent(item.id, clearProgress: false)
            }
        }
    }

    private func progressFraction(_ item: VideoItem) -> Double {
        guard item.duration > 1 else { return 0 }
        let value = (item.lastPosition ?? 0) / item.duration
        return value.isFinite ? max(0, min(1, value)) : 0
    }

    private static func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var librarySectionTitle: String {
        var title = "视频库 (\(sortedItems.count) / 共 \(library.items.count))"
        if !filterSummary.isEmpty { title += " · " + filterSummary }
        return title
    }

    private var selectedTypes: Set<LibraryFilter> {
        Set(filterTypesRaw.split(separator: ",").compactMap { LibraryFilter(rawValue: String($0)) })
    }

    private var isFiltering: Bool {
        !selectedTypes.isEmpty || filterMixed
    }

    private var filterSummary: String {
        var parts: [String] = []
        for filter in LibraryFilter.allCases where selectedTypes.contains(filter) {
            parts.append(filter.title)
        }
        if filterMixed { parts.append("混合参数") }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("搜索「\(searchText)」")
        }
        return parts.joined(separator: "、")
    }

    private func toggleTypeFilter(_ filter: LibraryFilter) {
        var types = selectedTypes
        if types.contains(filter) { types.remove(filter) } else { types.insert(filter) }
        filterTypesRaw = types.map { $0.rawValue }.sorted().joined(separator: ",")
        selected.removeAll()
    }

    private func resetFilters() {
        filterTypesRaw = ""
        filterMixed = false
        searchText = ""
        selected.removeAll()
    }

    private var filteredItems: [VideoItem] {
        var items = library.items
        let types = selectedTypes
        if !types.isEmpty {
            items = items.filter { item in
                types.contains { filter in
                    switch filter {
                    case .segments: return library.hasPlaylist(item)
                    case .mp4Only: return item.fileName.lowercased().hasSuffix(".mp4")
                    case .missing: return library.isMissing(item)
                    case .mixed: return library.isMixedParams(item)
                    }
                }
            }
        }
        // 标记筛选：与类型取交集
        if filterMixed {
            items = items.filter { library.isMixedParams($0) }
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            items = items.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
        }
        return items
    }

    private var sortedItems: [VideoItem] {
        let mode = LibrarySortMode(rawValue: sortModeRaw) ?? .timeDesc
        return filteredItems.sorted(by: mode)
    }

    @ViewBuilder
    private var downloadsSection: some View {
                if !downloads.tasks.isEmpty {
                    Section {
                        ForEach(downloads.tasks) { task in
                            DownloadRow(task: task)
                                .swipeActions {
                                    Button("删除", role: .destructive) {
                                        let target = task
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            pendingLibraryAction = .deleteDownload(target)
                        }
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        downloads.moveTaskToTop(task.id)
                                    } label: {
                                        Label("置顶", systemImage: "arrow.up.to.line")
                                    }
                                    .disabled(!downloads.canMoveUp(task.id))
                                    Button {
                                        downloads.moveTaskUp(task.id)
                                    } label: {
                                        Label("上移", systemImage: "arrow.up")
                                    }
                                    .disabled(!downloads.canMoveUp(task.id))
                                    Button {
                                        downloads.moveTaskDown(task.id)
                                    } label: {
                                        Label("下移", systemImage: "arrow.down")
                                    }
                                    .disabled(!downloads.canMoveDown(task.id))
                                    Divider()
                                    Button(role: .destructive) {
                                        let target = task
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                            pendingLibraryAction = .deleteDownload(target)
                                        }
                                    } label: {
                                        Label("删除任务", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("下载任务 (\(downloads.activeCount)/\(downloads.maxConcurrent))")
                            Spacer()
                            Button("查看全部") { showQueueSheet = true }
                                .font(.caption)
                                .textCase(nil)
                                .buttonStyle(.borderless)
                        }
                    } footer: {
                        Text("长按任务可置顶/上移/下移（仅影响排队中的任务）；左滑可删除；点「查看全部」可拖动排序")
                            .font(.caption2)
                    }
                }
    }

    private func primaryButton(for action: LibraryAction) -> Alert.Button {
        if action.isDestructive {
            return .destructive(Text(action.confirmTitle)) { perform(action) }
        }
        return .default(Text(action.confirmTitle)) { perform(action) }
    }

    private func perform(_ action: LibraryAction) {
        switch action {
        case .deleteSegments(let item):
            DiagnosticsLog.write("[清理] 执行 删分片 \(item.title)")
            library.deleteSegments(for: item)
        case .deleteMP4(let item):
            DiagnosticsLog.write("[清理] 执行 删MP4 \(item.title)")
            library.deleteMP4KeepingSegments(for: item)
        case .deleteAll(let item):
            DiagnosticsLog.write("[清理] 执行 全部删除 \(item.title)")
            library.remove(item)
        case .cleanupSegments:
            let freed = library.cleanupAllSegments()
            showToast("已清理分片，释放 \(freed / (1024 * 1024))MB")
        case .cleanupMP4:
            let freed = library.cleanupAllMP4KeepingSegments()
            showToast("已删除 MP4，释放 \(freed / (1024 * 1024))MB（分片已保留）")
        case .deleteDownload(let task):
            DiagnosticsLog.write("[清理] 执行 删除下载任务 \(task.title)")
            downloads.remove(task)
        case .clipDuplicate(let item, let openEditor, _):
            if case .added(let total) = SegmentEditStore.shared.appendWhole(item, allowDuplicate: true) {
                showToast("已加入剪辑清单：\(item.title)（共 \(total) 段）")
                if openEditor { openClipEditor(for: item) }
            }
        case .playMixed(let item, let fromBeginning):
            actuallyOpenPlayer(item, fromBeginning: fromBeginning)
        case .clearRecent:
            library.clearRecent()
            showToast("已清空观看记录")
        }
        }

    private func openPlayer(_ item: VideoItem, fromBeginning: Bool = false) {
        // 混合参数产物：播放前先提示可能异常
        if library.isMixedParams(item) {
            pendingLibraryAction = .playMixed(item, fromBeginning: fromBeginning)
            return
        }
        actuallyOpenPlayer(item, fromBeginning: fromBeginning)
    }

    private func actuallyOpenPlayer(_ item: VideoItem, fromBeginning: Bool) {
        let url = library.localURL(for: item)
        let exists = FileManager.default.fileExists(atPath: url.path)
        DiagnosticsLog.write("[播放] 点击 \(item.title) 文件=\(item.fileName) 存在=\(exists) 从头=\(fromBeginning)")
        guard exists else {
            showToast("文件不存在：\(item.fileName)")
            return
        }
        playback.open(video: item, url: url, fromBeginning: fromBeginning)
    }

    /// 视频库长按菜单：加入剪辑清单（可选是否直接打开剪辑面板）
    private func addToClipList(_ item: VideoItem, openEditor: Bool) {
        guard SegmentEditStore.isEnabled else {
            showToast("编辑功能已在「设置 → 编辑」中关闭")
            return
        }
        switch SegmentEditStore.shared.appendWhole(item) {
        case .added(let total):
            showToast("已加入剪辑清单：\(item.title)（共 \(total) 段）")
            if openEditor { openClipEditor(for: item) }
        case .duplicate(let existing):
            pendingLibraryAction = .clipDuplicate(item, openEditor: openEditor, existing: existing)
        case .unavailable(let reason):
            showToast(reason)
        }
    }

    /// 打开该视频的播放器，并自动弹出剪辑面板
    private func openClipEditor(for item: VideoItem) {
        PlaybackStore.shared.pendingOpenEditor = true
        openPlayer(item, fromBeginning: false)
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
    var isMixed: Bool = false

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
                if isMixed {
                    Text("混合参数")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
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
        max(2, UserDefaults.standard.integer(forKey: SegmentRunner.perTaskKey) > 0
            ? UserDefaults.standard.integer(forKey: SegmentRunner.perTaskKey) : 8)
    @State private var globalLimit =
        max(4, UserDefaults.standard.integer(forKey: SegmentRunner.globalKey) > 0
            ? UserDefaults.standard.integer(forKey: SegmentRunner.globalKey) : 20)
    @State private var maxTasks =
        { () -> Int in
            let value = UserDefaults.standard.integer(forKey: DownloadManager.maxConcurrentKey)
            return value <= 0 ? 5 : min(5, max(1, value))
        }()
    @State private var dropKeyChanged = UserDefaults.standard.bool(forKey: AdFilter.dropKeyChangedKey)
    @State private var adFingerprint = UserDefaults.standard.bool(forKey: AdFilter.fingerprintKey)
    @State private var writeStss = (UserDefaults.standard.object(forKey: "mp4WriteStss") as? Bool) ?? true
    @State private var useDirectMuxer = (UserDefaults.standard.object(forKey: "mp4UseDirectMuxer") as? Bool) ?? true
    @State private var fastStart = (UserDefaults.standard.object(forKey: "mp4FastStart") as? Bool) ?? false
    @State private var autoResume = (UserDefaults.standard.object(forKey: DownloadManager.autoResumeKey) as? Bool) ?? true
    @State private var keepSegments = (UserDefaults.standard.object(forKey: "mp4KeepSegments") as? Bool) ?? true
    @State private var completionSound = (UserDefaults.standard.object(forKey: CompletionFeedback.soundKey) as? Bool) ?? true
    @State private var completionNotice = (UserDefaults.standard.object(forKey: CompletionFeedback.noticeKey) as? Bool) ?? true
    @StateObject private var playPrefs = PlaybackPrefs.shared
    @AppStorage(LibraryGrouping.groupPrefKey) private var groupBySeries = true
    @AppStorage("library.recentEnabled") private var recentEnabled = true
    @AppStorage("library.recentCount") private var recentCount = 5
    @AppStorage(PlayerView.autoLandscapeKey) private var autoLandscape = true
    @AppStorage("playback.clockMode") private var clockMode = 0
    @AppStorage("playback.gravity") private var gravityDefault = 0
    @AppStorage("playback.countdownSeconds") private var countdownSeconds = 7
    @AppStorage(SubtitleSpeaker.enabledKey) private var ttsEnabled = false
    @AppStorage(SubtitleSpeaker.trackKey) private var ttsTrack = 0
    @AppStorage(SubtitleSpeaker.queueKey) private var ttsQueue = true
    @AppStorage(SubtitleSpeaker.duckKey) private var ttsDuck = true
    @AppStorage(SubtitleSpeaker.duckLevelKey) private var ttsDuckLevel = 0.6
    @AppStorage(SubtitleSpeaker.rateKey) private var ttsRate = 0.52
    @AppStorage(SubtitleSpeaker.voiceKey) private var ttsVoice = ""
    @AppStorage(SegmentEditStore.enabledKey) private var editEnabled = true

    private func summaryText(_ timing: PlaybackPrefs.SeriesTiming) -> String {
        let intro = timing.introLength > 0 ? "片头 " + PlaybackStore.timeText(timing.introLength) : "无片头"
        let outro = timing.outroLength > 0 ? "片尾 " + PlaybackStore.timeText(timing.outroLength) : "无片尾"
        let ref = timing.refDuration > 0 ? "（参考 " + PlaybackStore.timeText(timing.refDuration) + "）" : ""
        return intro + " / " + outro + ref
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("下载引擎") {
                    Toggle("分片引擎（可断点续传）", isOn: $segmentEnabled)
                    Toggle("重启后自动继续未完成的下载", isOn: $autoResume)
                }
                Section {
                    Toggle("自动连播同系列下一集", isOn: $playPrefs.autoNext)
                    Toggle("自动跳过片头（含手动打开）", isOn: $playPrefs.skipIntro)
                    Toggle("自动跳过片尾", isOn: $playPrefs.skipOutro)
                    Toggle("无片尾保护（按参考总时长）", isOn: $playPrefs.protectNoOutro)
                    ForEach(Array(playPrefs.configuredSeries.enumerated()), id: \.offset) { entry in
                        NavigationLink {
                            SeriesTimingEditor(key: entry.element.key, prefs: playPrefs)
                        } label: {
                            HStack {
                                Text(playPrefs.displayName(forKey: entry.element.key))
                                    .lineLimit(1)
                                Spacer()
                                Text(summaryText(entry.element.timing))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("连播与片头片尾")
                } footer: {
                    Text("连播需要标题里含集数（如「第16集」）。片头/片尾都以「时长」为准：片头时长决定从哪开始播；片尾时长决定「剩余多长时」开始跳过（因此正片长短变化不影响）。无片尾保护：本集总时长比参考总长短出一个片尾及以上时，判定这集没有片尾，不自动跳。")
                }
                Section {
                    Toggle("按系列分组（可折叠）", isOn: $groupBySeries)
                    Toggle("显示「最近在看」", isOn: $recentEnabled)
                    Picker("最近在看 显示条数", selection: $recentCount) {
                        Text("3 条").tag(3)
                        Text("5 条").tag(5)
                        Text("10 条").tag(10)
                    }
                    .disabled(!recentEnabled)
                } header: {
                    Text("视频库")
                } footer: {
                    Text("开启后，同一系列的集数会折叠成一组，单条视频仍平铺显示；折叠状态会被记住。与连播共用同一套标题解析（第N集 / EP16 / S01E16 等）。关闭「最近在看」后首页不再显示该分区，播放进度仍会记录。")
                }
                Section {
                    Toggle("播放时自动旋转为横屏", isOn: $autoLandscape)
                    Picker("全屏常驻时钟", selection: $clockMode) {
                        Text("关闭").tag(0)
                        Text("仅时间").tag(1)
                        Text("时间 + 日期").tag(2)
                    }
                    Picker("默认画面比例", selection: $gravityDefault) {
                        Text("适应（完整画面）").tag(0)
                        Text("填充（铺满裁切）").tag(1)
                        Text("拉伸（铺满变形）").tag(2)
                    }
                    HStack {
                        Text("片尾倒计时")
                        Slider(value: Binding(get: { Double(countdownSeconds) },
                                              set: { countdownSeconds = Int($0.rounded()) }),
                               in: 2...20,
                               step: 1)
                        Text("\(countdownSeconds) 秒")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("播放")
                } footer: {
                    Text("开启后：横视频自动横屏、竖视频自动竖屏、近似方形跟随设备；关闭则完全跟随设备方向。播放器上的锁形按钮可临时解锁旋转。全屏时钟仅在控制条隐藏时显示在右上角（点一下屏幕出现的控制条顶部本来就显示完整日期时间）。")
                }
                Section {
                    Toggle("朗读字幕（TTS）", isOn: $ttsEnabled)
                    if ttsEnabled {
                        Picker("朗读内容", selection: $ttsTrack) {
                            Text("主字幕").tag(0)
                            Text("次字幕").tag(1)
                            Text("主 + 次").tag(2)
                        }
                        Picker("朗读策略", selection: $ttsQueue) {
                            Text("排队（不漏句）").tag(true)
                            Text("打断（紧跟画面）").tag(false)
                        }
                        Picker("语速", selection: $ttsRate) {
                            Text("慢").tag(0.42)
                            Text("正常").tag(0.52)
                            Text("快").tag(0.62)
                        }
                        NavigationLink {
                            VoicePickerView()
                        } label: {
                            HStack {
                                Text("音色")
                                Spacer()
                                Text(SubtitleSpeaker.displayName(for: ttsVoice))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Toggle("朗读时压低视频音量", isOn: $ttsDuck)
                        if ttsDuck {
                            HStack {
                                Text("压低到")
                                Slider(value: $ttsDuckLevel, in: 0.2...1.0, step: 0.05)
                                Text("\(Int(ttsDuckLevel * 100))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("字幕朗读")
                } footer: {
                    Text("开启后，播放时会把当前字幕用系统语音读出来（离线合成）。排队模式不会漏句但可能略微滞后；打断模式始终紧跟画面。朗读期间会临时压低视频音量，读完平滑恢复。若中文无声，请到 设置 → 辅助功能 → 朗读内容 → 声音 下载中文语音。")
                }
                Section {
                    Toggle("启用视频编辑功能", isOn: $editEnabled)
                } header: {
                    Text("编辑")
                } footer: {
                    Text("总开关。关闭后，所有编辑相关入口与操作（当前为分片剪辑，后续新增的编辑能力同样）一律不可用；已生成的剪辑成片不受影响。")
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
                        Toggle("使用自研封装（推荐）", isOn: $useDirectMuxer)
                        Toggle("输出 faststart（moov 前置）", isOn: $fastStart)
                        Toggle("转换成功后保留原分片（可再次转换）", isOn: $keepSegments)
                        Toggle("转换时写入同步样本表(stss)", isOn: $writeStss)
                    } footer: {
                        Text("自研封装不经过系统 AVAssetWriter，可规避部分源写入被拒的问题；若遇到异常可关闭，改用系统封装。stss 开关影响续播/拖动/缩略图定位。")
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
                            ForEach([2, 4, 6, 8, 10], id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("全局", selection: $globalLimit) {
                            ForEach([4, 8, 12, 16, 20, 32], id: \.self) { Text("\($0)").tag($0) }
                        }
                    } footer: {
                        Text("并发越高越快，但更耗电、更容易被源站限流；分片较大时还会增加内存占用。建议 8 / 20，网络好且源不限流时可用 10 / 32。\n\n最低可选 2 / 4：适合弱网或被限流时保稳，但仍走分片引擎（可续传），速度会明显慢于系统引擎。全局值小于每任务值时，实际以全局为准。")
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
                        UserDefaults.standard.set(useDirectMuxer, forKey: "mp4UseDirectMuxer")
                        UserDefaults.standard.set(fastStart, forKey: "mp4FastStart")
                        UserDefaults.standard.set(autoResume, forKey: DownloadManager.autoResumeKey)
                        UserDefaults.standard.set(keepSegments, forKey: "mp4KeepSegments")
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

enum LibraryAction: Identifiable {
    case deleteSegments(VideoItem)
    case deleteMP4(VideoItem)
    case deleteAll(VideoItem)
    case cleanupSegments
    case cleanupMP4
    case deleteDownload(DownloadTaskInfo)
    /// 该视频已在剪辑清单中，询问是否重复加入
    case clipDuplicate(VideoItem, openEditor: Bool, existing: Int)
    /// 混合参数产物：播放前提示
    case playMixed(VideoItem, fromBeginning: Bool)
    /// 清空观看记录（不删除视频）
    case clearRecent

    var id: String {
        switch self {
        case .deleteSegments(let item): return "seg-\(item.id)"
        case .deleteMP4(let item): return "mp4-\(item.id)"
        case .deleteAll(let item): return "all-\(item.id)"
        case .cleanupSegments: return "cleanup-seg"
        case .cleanupMP4: return "cleanup-mp4"
        case .deleteDownload(let task): return "task-\(task.id)"
        case .clipDuplicate(let item, _, let existing): return "clip-\(item.id)-\(existing)"
        case .playMixed(let item, _): return "play-\(item.id)-\(item.lastPlayedAt?.timeIntervalSince1970 ?? 0)"
        case .clearRecent: return "clear-recent"
        }
    }

    var title: String {
        switch self {
        case .deleteSegments: return "删除分片？"
        case .deleteMP4: return "删除 MP4？"
        case .deleteAll: return "删除这个视频？"
        case .cleanupSegments: return "清理所有分片？"
        case .cleanupMP4: return "删除所有 MP4？"
        case .deleteDownload: return "删除这个下载任务？"
        case .clipDuplicate: return "已在剪辑清单中"
        case .playMixed: return "该视频为混合参数产物"
        case .clearRecent: return "清空观看记录？"
        }
    }

    var message: String {
        switch self {
        case .deleteSegments: return "将删除该视频的原始分片，只保留 MP4。删除后无法再次转换。"
        case .deleteMP4: return "将删除已转换的 MP4，原始分片保留，之后可再次转换。"
        case .deleteAll: return "将同时删除 MP4 与原始分片，不可恢复。"
        case .cleanupSegments: return "将删除所有已保留的原始分片，只保留 MP4。此操作不可恢复。"
        case .cleanupMP4: return "将删除所有已转换的 MP4，原始分片全部保留，可随时再次转换。"
        case .deleteDownload: return "将删除该任务已下载的分片与任务记录，且不可恢复。视频库中已转换的成品不受影响。"
        case .clipDuplicate(let item, _, let existing):
            return "《\(item.title)》已在剪辑清单中 \(existing) 段，是否再添加一次？"
        case .playMixed(let item, _):
            return "《\(item.title)》由不同编码参数的片段合并而成，播放可能出现黑屏/花屏/中途停止，且不能转 MP4。"
        case .clearRecent:
            return "仅移除观看记录，视频与播放进度都不受影响。"
        }
    }

    var confirmTitle: String {
        switch self {
        case .deleteSegments: return "删除分片"
        case .deleteMP4: return "删除 MP4"
        case .deleteAll: return "删除"
        case .cleanupSegments: return "清理"
        case .cleanupMP4: return "删除 MP4"
        case .deleteDownload: return "删除"
        case .clipDuplicate: return "仍然添加"
        case .playMixed: return "继续播放"
        case .clearRecent: return "清空记录"
        }
    }

    /// 「仍然添加」「继续播放」不是破坏性操作，用普通按钮样式
    var isDestructive: Bool {
        switch self {
        case .clipDuplicate, .playMixed: return false
        default: return true
        }
    }
}

// MARK: - 系列片头片尾编辑

private struct SeriesTimingEditor: View {
    let key: String
    @ObservedObject var prefs: PlaybackPrefs
    @Environment(\.dismiss) private var dismiss

    private var timing: PlaybackPrefs.SeriesTiming { prefs.timing(forKey: key) ?? PlaybackPrefs.SeriesTiming() }

    var body: some View {
        Form {
            Section {
                Stepper(value: Binding(
                    get: { timing.introLength },
                    set: { prefs.setIntroLength(max(0, min($0, 7200)), forKey: key) }
                ), in: 0...7200, step: 5) {
                    HStack {
                        Text("片头时长")
                        Spacer()
                        Text(timing.introLength > 0 ? PlaybackStore.timeText(timing.introLength) : "不跳过")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if timing.introLength > 0 {
                    Button("清除片头", role: .destructive) { prefs.clearIntro(forKey: key) }
                }
            } header: {
                Text("片头")
            } footer: {
                Text("打开该系列任意一集（含手动点开）时，从这个时长位置开始播放；有续播位置时以续播位置优先。每次 ±5 秒。")
            }

            Section {
                Stepper(value: Binding(
                    get: { timing.outroLength },
                    set: { prefs.setOutroLength(max(0, min($0, 7200)), forKey: key) }
                ), in: 0...7200, step: 5) {
                    HStack {
                        Text("片尾时长")
                        Spacer()
                        Text(timing.outroLength > 0 ? PlaybackStore.timeText(timing.outroLength) : "无片尾")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if timing.outroLength > 0 {
                    Button("清除片尾", role: .destructive) { prefs.clearOutro(forKey: key) }
                }
            } header: {
                Text("片尾")
            } footer: {
                Text("当「剩余时长 ≤ 片尾时长」时进入 7 秒倒计时（可取消）。因为按剩余时长判定，正片长短变化也能准确跳过片尾。")
            }

            if timing.refDuration > 0 {
                Section {
                    HStack {
                        Text("参考总时长")
                        Spacer()
                        Text(PlaybackStore.timeText(timing.refDuration))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if prefs.isConflicting(timing) {
                        Text("片头 + 片尾 已吃掉全部时长，跳过不会生效，请调整。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("参考")
                } footer: {
                    Text("打点片尾时记录的那一集总时长，用于判定「本集是否更短（可能没有片尾）」。")
                }
            }

            Section {
                Button("重置本系列", role: .destructive) {
                    prefs.clear(key: key)
                    dismiss()
                }
            }
        }
        .navigationTitle(prefs.displayName(forKey: key))
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case segments, mp4Only, missing, mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .segments: return "有分片"
        case .mp4Only: return "仅 MP4"
        case .missing: return "文件缺失"
        case .mixed: return "混合参数"
        }
    }
}

// MARK: - 最近在看 缩略图（按观看进度取帧）

private struct RecentThumbnail: View {
    let item: VideoItem
    let localURL: URL

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
            if let image {
                Image(uiImage: image)
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
        .task(id: item.lastPosition) {
            if image == nil, let cached = ThumbnailService.cached(for: item.id) {
                image = cached
            }
            guard item.duration > 1, let position = item.lastPosition, position > 0 else { return }
            let fraction = position / item.duration
            if let frame = await ThumbnailService.progressThumbnail(for: item,
                                                                    localURL: localURL,
                                                                    fraction: fraction) {
                image = frame
            }
        }
    }
}