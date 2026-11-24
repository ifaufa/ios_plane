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
        /// 加入清单的时间（用于"按加入顺序"排序）
        var addedAt: Date = Date()

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

    enum AppendOutcome {
        /// 已加入，附带清单当前总段数
        case added(Int)
        /// 该视频已有 N 段在清单里（需要用户确认是否重复添加）
        case duplicate(Int)
        /// 无法加入（附原因）
        case unavailable(String)
    }

    /// 该条目是否有可剪辑的分片（纯 MP4 且分片已删除 → nil）
    /// 判定统一收敛到 VideoLibrary.hasPlaylist，避免两处逻辑漂移
    func playlistRelPath(for item: VideoItem) -> String? {
        guard library?.hasPlaylist(item) ?? false else { return nil }
        if item.fileName.lowercased().hasSuffix(".m3u8") { return item.fileName }
        if let dir = item.segmentDirName, !dir.isEmpty { return dir + "/index.m3u8" }
        return nil
    }

    /// 素材列表展示用的参数信息
    func signatureInfo(for item: VideoItem) -> (label: String, mixed: Bool) {
        guard let rel = playlistRelPath(for: item) else { return ("无分片", false) }
        let signature = signatureFor(rel: rel)
        return (signature?.label ?? "未知参数", isMixedProduct(rel: rel))
    }

    /// 该视频在清单里已有的段数
    func existingClipCount(for sourceID: UUID) -> Int {
        clips.filter { $0.sourceID == sourceID }.count
    }

    /// 把当前选区追加到清单（支持跨源合并）
    @discardableResult
    func appendSelection(start: Double,
                         end: Double,
                         source: VideoItem?,
                         allowDuplicate: Bool = false) -> AppendOutcome {
        guard let source else {
            notice = "当前没有正在播放的视频"
            return .unavailable("当前没有正在播放的视频")
        }
        guard let clip = makeClip(source: source, start: start, end: end) else {
            return .unavailable(notice ?? "该视频无法加入清单")
        }
        guard clip.duration >= 0.2 else {
            notice = "选区太短（至少 0.2 秒）"
            return .unavailable("选区太短（至少 0.2 秒）")
        }
        if !allowDuplicate {
            let existing = existingClipCount(for: source.id)
            if existing > 0 { return .duplicate(existing) }
        }
        clips.append(clip)
        DiagnosticsLog.write("[剪辑] 追加片段 源=" + clip.sourceTitle
                             + " " + Self.timeText(clip.start) + "–" + Self.timeText(clip.end)
                             + " 共 " + String(clips.count) + " 段")

        // 立即提示参数差异（避免导出时才发现）
        let keys = Set(clips.map { $0.signatureKey })
        if keys.count > 1 {
            notice = "注意：清单里存在不同编码参数（" + clip.signatureLabel
                + "），合并后播放可能异常，且该产物不能转 MP4。"
        }
        return .added(clips.count)
    }

    /// 整片加入清单（视频库长按菜单用）
    @discardableResult
    func appendWhole(_ item: VideoItem, allowDuplicate: Bool = false) -> AppendOutcome {
        var duration = item.duration
        if duration <= 0.5, let rel = playlistRelPath(for: item) {
            let indexURL = VideoLibrary.assetsDir.appendingPathComponent(rel)
            if let entries = HLSEditor.parsePlaylist(indexURL) {
                duration = entries.reduce(0) { $0 + $1.duration }
            }
        }
        guard duration > 0.5 else {
            notice = "无法读取该视频时长"
            return .unavailable("无法读取该视频时长")
        }
        return appendSelection(start: 0, end: duration, source: item, allowDuplicate: allowDuplicate)
    }

    struct BatchResult {
        var added = 0
        var duplicates: [VideoItem] = []
        var failures: [String] = []
        var totalDuration: Double = 0

        var exceedsTwoHours: Bool { totalDuration > 7200 }
    }

    /// 批量加入（默认整片）
    @discardableResult
    func appendBatch(_ items: [VideoItem], allowDuplicate: Bool = false) -> BatchResult {
        var result = BatchResult()
        for item in items {
            switch appendWhole(item, allowDuplicate: allowDuplicate) {
            case .added:
                result.added += 1
            case .duplicate:
                result.duplicates.append(item)
            case .unavailable(let reason):
                result.failures.append(item.title + "：" + reason)
            }
        }
        result.totalDuration = totalDuration
        DiagnosticsLog.write("[剪辑] 批量加入 提交=" + String(items.count)
                             + " 成功=" + String(result.added)
                             + " 重复=" + String(result.duplicates.count)
                             + " 失败=" + String(result.failures.count)
                             + " 清单总时长=" + String(format: "%.0f", result.totalDuration) + "s")
        return result
    }

    /// 修改清单中某个片段的起止
    func updateClip(_ id: UUID, start: Double, end: Double) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let a = max(0, start)
        let b = max(a, end)
        guard b - a >= 0.2 else {
            notice = "区间太短（至少 0.2 秒）"
            return
        }
        clips[index].start = a
        clips[index].end = b
        DiagnosticsLog.write("[剪辑] 修改片段 源=" + clips[index].sourceTitle
                             + " " + Self.timeText(a) + "–" + Self.timeText(b))
    }

    enum ClipSort {
        case titleAsc
        case titleDesc
        case added
    }

    /// 排序会覆盖手动拖动顺序（之后仍可再拖动调整）
    func sortClips(by mode: ClipSort) {
        switch mode {
        case .titleAsc:
            clips.sort { lhs, rhs in
                if lhs.sourceTitle == rhs.sourceTitle { return lhs.start < rhs.start }
                return lhs.sourceTitle.localizedStandardCompare(rhs.sourceTitle) == .orderedAscending
            }
        case .titleDesc:
            clips.sort { lhs, rhs in
                if lhs.sourceTitle == rhs.sourceTitle { return lhs.start < rhs.start }
                return lhs.sourceTitle.localizedStandardCompare(rhs.sourceTitle) == .orderedDescending
            }
        case .added:
            clips.sort { $0.addedAt < $1.addedAt }
        }
        DiagnosticsLog.write("[剪辑] 清单排序 方式=\(mode) 段数=\(clips.count)")
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
        guard let rel = playlistRelPath(for: source) else {
            notice = "该视频没有可用的分片（可能已转 MP4 且分片已删除）"
            return nil
        }
        let signature = signatureFor(rel: rel)
        return Clip(id: UUID(),
                    sourceID: source.id,
                    sourceTitle: source.title,
                    fileName: rel,
                    start: max(0, start),
                    end: max(0, end),
                    signatureKey: signature?.key ?? "unknown",
                    signatureLabel: signature?.label ?? "未知参数",
                    sourceMixed: isMixedProduct(rel: rel))
    }

    private func signatureFor(rel: String) -> HLSEditor.StreamSignature? {
        if let cached = signatureCache[rel] { return cached }
        let url = VideoLibrary.assetsDir.appendingPathComponent(rel)
        let signature = HLSEditor.probeSignature(playlistURL: url)
        if let signature { signatureCache[rel] = signature }
        return signature
    }

    /// 该条目本身是否是"混合参数"合并产物（按分片目录里的 state.json 判断）
    private func isMixedProduct(rel: String) -> Bool {
        let dir = VideoLibrary.assetsDir.appendingPathComponent((rel as NSString).deletingLastPathComponent)
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
