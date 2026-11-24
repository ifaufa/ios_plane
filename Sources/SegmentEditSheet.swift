import SwiftUI

/// 剪辑面板：选区打点 → 加入清单（可跨源）→ 拖动排序 → 导出
struct SegmentEditSheet: View {
    @ObservedObject var playback: PlaybackStore
    @ObservedObject var editor = SegmentEditStore.shared
    @AppStorage(SegmentEditStore.enabledKey) private var editEnabled = true
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingClear = false
    @State private var showLibraryPicker = false
    @State private var editingClip: SegmentEditStore.Clip?
    @State private var pendingAppend: PendingAppend?
    /// 自己管理编辑态（不用 EditButton：放在 List 内容里会与行重建互相触发，造成持续闪动）
    @State private var editMode: EditMode = .inactive

    struct PendingAppend: Identifiable {
        let id = UUID()
        let item: VideoItem
        let start: Double
        let end: Double
        let existing: Int
    }

    private var totalDuration: Double {
        let value = playback.player.currentItem?.duration.seconds ?? 0
        return value.isFinite && value > 0 ? value : 0
    }

    private var selectionStart: Double? { playback.loopStart }
    private var selectionEnd: Double? { playback.loopEnd }

    var body: some View {
        NavigationStack {
            List {
                if !editEnabled {
                    Section {
                        Label("编辑功能已在「设置 → 编辑」中关闭", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if let a = selectionStart, let b = selectionEnd, b - a >= 0.2 {
                        HStack {
                            Text("当前选区")
                            Spacer()
                            Text(Self.rangeText(a, b))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button("剪掉这一段（保留其余）") {
                            editor.cutOut(start: a, end: b, duration: totalDuration, source: playback.currentVideo)
                        }
                        .disabled(!editEnabled)
                        Button("只保留这一段") {
                            editor.keepOnly(start: a, end: b, source: playback.currentVideo)
                        }
                        .disabled(!editEnabled)
                        Button("追加到清单（用于多段/跨源合并）") {
                            appendCurrentSelection(start: a, end: b)
                        }
                        .disabled(!editEnabled)
                    } else {
                        Text("请先用播放器上的「设 A / 设 B」选出区间")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        playback.isMarkingPoints = true
                        dismiss()
                    } label: {
                        Label("开始手势设点（上半屏=设A，下半屏=设B）", systemImage: "hand.tap")
                    }
                    .disabled(!editEnabled)
                } header: {
                    Text("选区")
                } footer: {
                    Text("切点吸附到最近关键帧（误差通常 ≤1 秒），不重新编码、无损。手势设点仅在设点模式下生效，退出后单击恢复显隐控制条。")
                }

                Section {
                    Button {
                        showLibraryPicker = true
                    } label: {
                        Label("从视频库添加素材…", systemImage: "text.badge.plus")
                    }
                    .disabled(!editEnabled)
                } footer: {
                    Text("可直接选择库里的分片视频（整片或指定区间）加入清单，不需要先播放它。")
                }

                Section {
                    if editor.clips.isEmpty {
                        Text("暂无片段")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editor.clips) { clip in
                            clipRow(clip)
                        }
                        .onMove { editor.move(from: $0, to: $1) }
                        .onDelete { indexSet in
                            for index in indexSet where editor.clips.indices.contains(index) {
                                editor.remove(editor.clips[index].id)
                            }
                        }
                        Button(confirmingClear ? "确认清空？（再点一次）" : "清空清单", role: .destructive) {
                            if confirmingClear {
                                editor.clear()
                                confirmingClear = false
                            } else {
                                confirmingClear = true
                            }
                        }
                    }
                } header: {
                    Text("剪辑清单（\(editor.clips.count) 段 · 共 \(PlaybackStore.timeText(editor.totalDuration))）")
                } footer: {
                    if editor.totalDuration > 7200 {
                        Text("清单总时长已超过 2 小时（\(PlaybackStore.timeText(editor.totalDuration))），导出耗时与占用会明显增加。")
                            .foregroundStyle(.orange)
                    } else {
                        Text("点片段可修改起止；点「编辑」可拖动排序。")
                    }
                }

                Section {
                    if let warning = editor.mixedWarningText {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("参数不一致", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        editor.export()
                    } label: {
                        HStack {
                            Text(exportButtonTitle)
                            Spacer()
                            if editor.isExporting { ProgressView() }
                        }
                    }
                    .disabled(editor.clips.isEmpty || editor.isExporting || !editEnabled)

                    if editor.isExporting {
                        ProgressView(value: editor.progress)
                    }
                } footer: {
                    Text("导出后会在视频库顶部生成新条目（原片保留）。跨参数合并的产物不能转 MP4。")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("剪辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !editor.clips.isEmpty {
                        Menu {
                            Button("按标题升序") { editor.sortClips(by: .titleAsc) }
                            Button("按标题降序") { editor.sortClips(by: .titleDesc) }
                            Button("按加入顺序") { editor.sortClips(by: .added) }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        Button(editMode == .active ? "完成" : "编辑") {
                            editMode = (editMode == .active ? .inactive : .active)
                        }
                    }
                }
            }
            .sheet(isPresented: $showLibraryPicker) {
                LibraryClipPicker(items: libraryItems) { item, start, end in
                    switch editor.appendSelection(start: start, end: end, source: item) {
                    case .added:
                        break
                    case .duplicate(let existing):
                        pendingAppend = PendingAppend(item: item, start: start, end: end, existing: existing)
                    case .unavailable(let reason):
                        editor.notice = reason
                    }
                }
            }
            .confirmationDialog("已在清单中",
                                isPresented: Binding(
                                    get: { pendingAppend != nil },
                                    set: { if !$0 { pendingAppend = nil } }
                                ),
                                titleVisibility: .visible,
                                presenting: pendingAppend) { pending in
                Button("仍然添加") {
                    editor.appendSelection(start: pending.start, end: pending.end,
                                           source: pending.item, allowDuplicate: true)
                    pendingAppend = nil
                }
                Button("取消", role: .cancel) { pendingAppend = nil }
            } message: { pending in
                Text("《\(pending.item.title)》已加入 \(pending.existing) 段，是否再添加一次？")
            }
            .sheet(item: $editingClip) { clip in
                ClipRangeEditor(title: clip.sourceTitle,
                                duration: clip.end > clip.start ? maxDurationHint(clip) : clip.end,
                                initialStart: clip.start,
                                initialEnd: clip.end) { start, end in
                    editor.updateClip(clip.id, start: start, end: end)
                }
            }

            .alert("剪辑", isPresented: Binding(
                get: { editor.notice != nil },
                set: { if !$0 { editor.notice = nil } }
            )) {
                Button("好") { editor.notice = nil }
            } message: {
                Text(editor.notice ?? "")
            }
        }
    }

    /// 清单行：用普通 HStack + 点击手势（编辑态下让位给拖拽手柄，避免手势冲突）
    @ViewBuilder
    private func clipRow(_ clip: SegmentEditStore.Clip) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.rangeText(clip.start, clip.end))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(clip.sourceTitle)
                        .lineLimit(1)
                    Text(clip.signatureLabel)
                    if clip.sourceMixed {
                        Text("混合参数")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(PlaybackStore.timeText(clip.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
            if editMode != .active {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard editMode != .active else { return }
            editingClip = clip
        }
    }

    private func appendCurrentSelection(start: Double, end: Double) {
        guard let item = playback.currentVideo else {
            editor.notice = "当前没有正在播放的视频"
            return
        }
        switch editor.appendSelection(start: start, end: end, source: item) {
        case .added:
            break
        case .duplicate(let existing):
            pendingAppend = PendingAppend(item: item, start: start, end: end, existing: existing)
        case .unavailable(let reason):
            editor.notice = reason
        }
    }

    /// 只要还有可剪辑分片（含"已转 MP4 但保留分片"的条目）就应出现在列表中
    private var libraryItems: [VideoItem] {
        guard let library = editor.library else { return [] }
        return library.items.filter { editor.playlistRelPath(for: $0) != nil }
    }

    private func maxDurationHint(_ clip: SegmentEditStore.Clip) -> Double {
        guard let library = editor.library,
              let item = library.items.first(where: { $0.id == clip.sourceID }) else { return clip.end }
        return max(item.duration, clip.end)
    }

    private var exportButtonTitle: String {
        if editor.isExporting { return "导出中…" }
        return editor.mixedWarningText == nil ? "导出为新的分片视频" : "仍然合并导出（参数不一致）"
    }

    private static func rangeText(_ start: Double, _ end: Double) -> String {
        PlaybackStore.timeText(start) + " – " + PlaybackStore.timeText(end)
    }
}

// MARK: - 素材选择（支持批量加入）

private struct LibraryClipPicker: View {
    let items: [VideoItem]
    let onPick: (VideoItem, Double, Double) -> Void

    @ObservedObject private var editor = SegmentEditStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var onlyUnadded = false
    @State private var summary: BatchSummary?

    struct BatchSummary: Identifiable {
        let id = UUID()
        var added: Int
        var duplicates: [VideoItem]
        var failures: [String]
        var totalDuration: Double
    }

    private var visibleItems: [VideoItem] {
        guard onlyUnadded else { return items }
        return items.filter { editor.existingClipCount(for: $0.id) == 0 }
    }

    private var allSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("仅显示未加入清单", isOn: $onlyUnadded)
                }

                Section {
                    if visibleItems.isEmpty {
                        Text(items.isEmpty ? "视频库里没有可用的分片视频" : "没有符合条件的素材")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleItems) { item in
                            row(item)
                        }
                    }
                } footer: {
                    if selecting {
                        Text("多选模式下按「整片」加入；需要局部区间时，加入后在清单里点该片段修改起止。")
                    }
                }
            }
            .navigationTitle(selecting ? "选择素材（\(selected.count)）" : "选择素材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selecting ? "完成" : "选择") {
                        selecting.toggle()
                        if !selecting { selected.removeAll() }
                    }
                    .disabled(items.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    batchBar
                }
            }
            .alert(item: $summary) { value in
                if value.duplicates.isEmpty {
                    return Alert(title: Text("已加入 \(value.added) 段"),
                                 message: Text(messageText(value)),
                                 dismissButton: .default(Text("完成")) { dismiss() })
                }
                return Alert(title: Text("已加入 \(value.added) 段"),
                             message: Text(messageText(value) + "\n跳过 \(value.duplicates.count) 个（已在清单中）"),
                             primaryButton: .default(Text("仍然加入这 \(value.duplicates.count) 个")) {
                                 editor.appendBatch(value.duplicates, allowDuplicate: true)
                                 dismiss()
                             },
                             secondaryButton: .cancel(Text("完成")) { dismiss() })
            }
        }
    }

    // MARK: 行

    @ViewBuilder
    private func row(_ item: VideoItem) -> some View {
        if selecting {
            Button {
                if selected.contains(item.id) {
                    selected.remove(item.id)
                } else {
                    selected.insert(item.id)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected.contains(item.id) ? Color.accentColor : Color.secondary)
                    rowContent(item)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                ClipRangeEditor(title: item.title,
                                duration: item.duration,
                                initialStart: 0,
                                initialEnd: item.duration) { start, end in
                    onPick(item, start, end)
                    dismiss()
                }
            } label: {
                rowContent(item)
            }
        }
    }

    private func rowContent(_ item: VideoItem) -> some View {
        let info = editor.signatureInfo(for: item)
        let existing = editor.existingClipCount(for: item.id)
        return VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .lineLimit(1)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Text(PlaybackStore.timeText(item.duration))
                Text(info.label)
                if info.mixed {
                    Text("混合参数")
                        .foregroundStyle(.orange)
                }
                if existing > 0 {
                    Text("已在清单 \(existing) 段")
                        .foregroundStyle(.blue)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: 批量

    private var batchBar: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "取消全选" : "全选") {
                if allSelected {
                    selected.removeAll()
                } else {
                    selected = Set(visibleItems.map { $0.id })
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("加入清单（\(selected.count)）") {
                commitBatch()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func commitBatch() {
        let chosen = visibleItems.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let result = editor.appendBatch(chosen)
        selected.removeAll()
        summary = BatchSummary(added: result.added,
                               duplicates: result.duplicates,
                               failures: result.failures,
                               totalDuration: result.totalDuration)
    }

    private func messageText(_ value: BatchSummary) -> String {
        var lines: [String] = []
        lines.append("清单共 \(editor.clips.count) 段，总时长 \(PlaybackStore.timeText(value.totalDuration))")
        if value.totalDuration > 7200 {
            lines.append("提示：清单已超过 2 小时，导出耗时与占用会明显增加。")
        }
        if !value.failures.isEmpty {
            lines.append("未加入：" + value.failures.prefix(3).joined(separator: "；"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 区间编辑（整片 / 指定区间）

private struct ClipRangeEditor: View {
    let title: String
    let duration: Double
    let onSave: (Double, Double) -> Void

    @State private var start: Double
    @State private var end: Double
    @Environment(\.dismiss) private var dismiss

    init(title: String, duration: Double, initialStart: Double, initialEnd: Double, onSave: @escaping (Double, Double) -> Void) {
        self.title = title
        self.duration = duration
        self.onSave = onSave
        _start = State(initialValue: max(0, initialStart))
        _end = State(initialValue: max(initialStart, initialEnd))
    }

    private var valid: Bool {
        end - start >= 0.2 && end <= max(duration, end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("起点 A")
                        Spacer()
                        TimeMaskField(seconds: start, maxSeconds: max(1, duration)) { start = $0 }
                            .frame(width: 112, height: 34)
                    }
                    HStack {
                        Text("终点 B")
                        Spacer()
                        TimeMaskField(seconds: end, maxSeconds: max(1, duration)) { end = $0 }
                            .frame(width: 112, height: 34)
                    }
                    HStack {
                        Text("区间长度")
                        Spacer()
                        Text(PlaybackStore.timeText(max(0, end - start)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button("使用整片（0 – 结束）") {
                        start = 0
                        end = duration
                    }
                } header: {
                    Text(title)
                } footer: {
                    Text("只输入数字，冒号自动补（hh:mm:ss）。区间至少 0.2 秒。")
                }

                Section {
                    Button("保存") {
                        onSave(start, end)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
            .navigationTitle("选择区间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
