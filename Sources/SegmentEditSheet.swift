import SwiftUI

/// 剪辑面板：选区打点 → 加入清单（可跨源）→ 拖动排序 → 导出
struct SegmentEditSheet: View {
    @ObservedObject var playback: PlaybackStore
    @ObservedObject var editor = SegmentEditStore.shared
    @AppStorage(SegmentEditStore.enabledKey) private var editEnabled = true
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false

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
                            editor.appendSelection(start: a, end: b, source: playback.currentVideo)
                        }
                        .disabled(!editEnabled)
                    } else {
                        Text("请先用播放器上的「设 A / 设 B」选出区间")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("选区")
                } footer: {
                    Text("切点吸附到最近关键帧（误差通常 ≤1 秒），不重新编码、无损。切换视频后清单会保留，可继续「追加到清单」实现跨源合并。")
                }

                Section {
                    if editor.clips.isEmpty {
                        Text("暂无片段")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editor.clips) { clip in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.rangeText(clip.start, clip.end))
                                        .monospacedDigit()
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
                            }
                        }
                        .onMove { editor.move(from: $0, to: $1) }
                        .onDelete { indexSet in
                            for index in indexSet where editor.clips.indices.contains(index) {
                                editor.remove(editor.clips[index].id)
                            }
                        }
                        Button("清空清单", role: .destructive) { showClearConfirm = true }
                    }
                } header: {
                    HStack {
                        Text("剪辑清单（\(editor.clips.count) 段 · 共 \(PlaybackStore.timeText(editor.totalDuration))）")
                        Spacer()
                        EditButton()
                            .font(.caption)
                    }
                } footer: {
                    Text("点「编辑」可拖动排序；导出按清单顺序拼接。")
                }

                Section {
                    Button {
                        editor.export()
                    } label: {
                        HStack {
                            Text(editor.isExporting ? "导出中…" : "导出为新的分片视频")
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
            .navigationTitle("剪辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .confirmationDialog("清空剪辑清单？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { editor.clear() }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog(editor.pendingMixedPrompt?.title ?? "",
                                isPresented: Binding(
                                    get: { editor.pendingMixedPrompt != nil },
                                    set: { if !$0 { editor.pendingMixedPrompt = nil } }
                                ),
                                titleVisibility: .visible,
                                presenting: editor.pendingMixedPrompt) { _ in
                Button("仍然合并", role: .destructive) { editor.confirmMixedExport() }
                Button("取消", role: .cancel) { editor.pendingMixedPrompt = nil }
            } message: { prompt in
                Text(prompt.message)
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

    private static func rangeText(_ start: Double, _ end: Double) -> String {
        PlaybackStore.timeText(start) + " – " + PlaybackStore.timeText(end)
    }
}
