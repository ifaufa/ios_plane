import SwiftUI

/// 分片剪辑会话：记录「按顺序要保留的片段」（支持跨源），并负责导出
@MainActor
final class SegmentEditStore: ObservableObject {
    static let shared = SegmentEditStore()

    /// 编辑功能总开关（关闭后，所有编辑相关入口与操作一律不可用）
    static let enabledKey = "edit.featureEnabled"

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    struct Clip: Identifiable, Equatable {
        let id: UUID
        var sourceID: UUID
        var sourceTitle: String
        /// 相对 assets 目录（例如 "<UUID>/index.m3u8"）
        var fileName: String
        var start: Double
        var end: Double
        var signatureKey: String
        var signatureLabel: String
        /// 该源本身已是"混合参数"产物
        var sourceMixed: Bool

        var duration: Double { max(0, end - start) }
    }

    struct MixedPrompt: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    weak var library: VideoLibrary?

    @Published var clips: [Clip] = []
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var notice: String?
    @Published var pendingMixedPrompt: MixedPrompt?

    private var signatureCache: [String: HLSEditor.StreamSignature] = [:]
    private var pendingExportClips: [Clip] = []

    // MARK: - 清单编辑

    /// 剪掉 [start,end]（基于当前播放的整条视频重建清单）
    func cutOut(start: Double, end: Double, duration: Double, source: VideoItem?) {
        guard let source, let clip = makeClip(source: source, start: start, end: end) else {
            notice = "当前没有正在播放的视频"
            return
        }
        guard duration > 1 else { return }
        let a = max(0, min(start, duration))
        let b = max(a, min(end, duration))
        guard b - a >= 0.2 else {
            notice = "选区太短（至少 0.2 秒）"
            return
        }
        var result: [Clip] = []
        if a >= 0.2, let head = makeClip(source: source, start: 0, end: a) { result.append(head) }
        if duration - b >= 0.2, let tail = makeClip(source: source, start: b, end: duration) { result.append(tail) }
        guard !result.isEmpty else {
            notice = "剪掉这段后就没有内容了"
            return
        }
        clips = result
        DiagnosticsLog.write("[剪辑] 剪掉 " + Self.timeText(a) + "–" + Self.timeText(b)
                             + "，保留 " + String(result.count) + " 段")
    }

    /// 只保留 [start,end]
    func keepOnly(start: Double, end: Double, source: VideoItem?) {
        guard let source, let clip = makeClip(source: source, start: start, end: end) else {
            notice = "当前没有正在播放的视频"
            return
        }
        guard clip.duration >= 0.2 else {
            notice = "选区太短（至少 0.2 秒）"
            return
        }
        clips = [clip]
        DiagnosticsLog.write("[剪辑] 只保留 " + Self.timeText(clip.start) + "–" + Self.timeText(clip.end))
    }

    /// 把当前选区追加到清单（支持跨源合并）
    func appendSelection(start: Double, end: Double, source: VideoItem?) {
        guard let source, let clip = makeClip(source: source, start: start, end: end) else {
            notice = "当前没有正在播放的视频"
            return
        }
        guard clip.duration >= 0.2 else {
            notice = "选区太短（至少 0.2 秒）"
            return
        }
        clips.append(clip)
        DiagnosticsLog.write("[剪辑] 追加片段 源=" + clip.sourceTitle
                             + " " + Self.timeText(clip.start) + "–" + Self.timeText(clip.end)
                             + " 共 " + String(clips.count) + " 段")
    }

    func remove(_ id: UUID) {
        clips.removeAll { $0.id == id }
    }

    func move(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        clips.removeAll()
    }

    var totalDuration: Double {
        clips.reduce(0) { $0 + $1.duration }
    }

    var hasMultipleSources: Bool {
        Set(clips.map { $0.sourceID }).count > 1
    }

    // MARK: - 片段构造

    private func makeClip(source: VideoItem, start: Double, end: Double) -> Clip? {
        guard source.fileName.lowercased().hasSuffix(".m3u8") else {
            notice = "该条目已是 MP4，仅分片视频支持剪辑"
            return nil
        }
        let signature = signatureFor(source)
        return Clip(id: UUID(),
                    sourceID: source.id,
                    sourceTitle: source.title,
                    fileName: source.fileName,
                    start: max(0, start),
                    end: max(0, end),
                    signatureKey: signature?.key ?? "unknown",
                    signatureLabel: signature?.label ?? "未知参数",
                    sourceMixed: isMixedProduct(source))
    }

    private func signatureFor(_ source: VideoItem) -> HLSEditor.StreamSignature? {
        if let cached = signatureCache[source.fileName] { return cached }
        let url = VideoLibrary.assetsDir.appendingPathComponent(source.fileName)
        let signature = HLSEditor.probeSignature(playlistURL: url)
        if let signature { signatureCache[source.fileName] = signature }
        return signature
    }

    /// 该条目本身是否是"混合参数"合并产物
    private func isMixedProduct(_ source: VideoItem) -> Bool {
        let dir = VideoLibrary.assetsDir.appendingPathComponent((source.fileName as NSString).deletingLastPathComponent)
        let stateURL = dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SegmentJobState.self, from: data) else { return false }
        return state.mixedParams == true
    }

    // MARK: - 导出

    /// UI 调用：先做参数一致性检查，必要时弹确认
    func export() {
        guard Self.isEnabled else {
            notice = "编辑功能已在「设置 → 编辑」中关闭"
            return
        }
        guard !isExporting else { return }
        guard !clips.isEmpty else {
            notice = "请先设置要保留的片段"
            return
        }

        let keys = Set(clips.map { $0.signatureKey })
        var warnings: [String] = []
        if keys.count > 1 {
            var seen: [String: String] = [:]
            for clip in clips where seen[clip.signatureKey] == nil {
                seen[clip.signatureKey] = clip.signatureLabel
            }
            let detail = seen.values.joined(separator: " / ")
            warnings.append("检测到不同编码参数：" + detail)
            warnings.append("合并后可能出现黑屏、花屏或中途停止，且该产物不能转 MP4。")
        }
        if clips.contains(where: { $0.sourceMixed }) {
            warnings.append("清单中包含「混合参数」产物，问题可能叠加。")
        }

        guard !warnings.isEmpty else {
            pendingExportClips = clips
            Task { await performExport() }
            return
        }

        pendingExportClips = clips
        pendingMixedPrompt = MixedPrompt(title: "参数不一致", message: warnings.joined(separator: "\n"))
    }

    /// 用户在弹窗里选择"仍然合并"
    func confirmMixedExport() {
        pendingMixedPrompt = nil
        Task { await performExport() }
    }

    private func performExport() async {
        let plan = pendingExportClips
        pendingExportClips = []
        guard !plan.isEmpty else { return }
        isExporting = true
        progress = 0
        defer { isExporting = false }

        let assetsDir = VideoLibrary.assetsDir
        let exportClips = plan.map {
            HLSEditor.ExportClip(indexURL: assetsDir.appendingPathComponent($0.fileName),
                                 start: $0.start,
                                 end: $0.end,
                                 signatureKey: $0.signatureKey)
        }
        let baseTitle = (plan.first?.sourceTitle ?? "视频") + " · 剪辑"
        let willBeMixed = Set(plan.map { $0.signatureKey }).count > 1
        let title = willBeMixed ? baseTitle + "（混合参数）" : baseTitle
        let firstSource = library?.items.first(where: { $0.id == plan.first?.sourceID })
        let sourceURL = firstSource?.sourceURL ?? "edit://"

        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> HLSEditor.ExportResult in
                try HLSEditor.export(clips: exportClips,
                                     title: title,
                                     outputRoot: assetsDir) { value in
                    Task { @MainActor in SegmentEditStore.shared.progress = value }
                }
            }.value

            // 结构自检：文件齐全 + 播放列表可读
            let dir = assetsDir.appendingPathComponent(result.dirName, isDirectory: true)
            let playlistOK = FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.m3u8").path)
            let segmentsOK = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.hasSuffix(".ts") }.count ?? 0
            guard playlistOK, segmentsOK == result.segmentCount, result.fileSize > 0 else {
                try? FileManager.default.removeItem(at: dir)
                notice = "合并产物自检失败，已回滚（文件不完整）"
                DiagnosticsLog.write("[剪辑] 自检失败 段=\(segmentsOK)/\(result.segmentCount) 已删除产物")
                return
            }

            let item = VideoItem(id: UUID(),
                                 title: title,
                                 sourceURL: sourceURL,
                                 fileName: result.fileName,
                                 duration: result.duration,
                                 fileSize: result.fileSize,
                                 createdAt: Date(),
                                 lastPosition: nil,
                                 segmentDirName: result.dirName)
            library?.add(item)
            clips.removeAll()
            notice = "已生成：" + title + "（" + Self.timeText(result.duration) + "）"
        } catch {
            DiagnosticsLog.write("[剪辑] 导出失败：" + error.localizedDescription)
            notice = "剪辑失败：" + error.localizedDescription
        }
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
