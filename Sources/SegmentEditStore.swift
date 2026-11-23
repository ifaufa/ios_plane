import SwiftUI

/// 分片剪辑会话：记录"要保留的区间"，并负责导出为新分片视频
@MainActor
final class SegmentEditStore: ObservableObject {
    static let shared = SegmentEditStore()

    struct Range: Identifiable, Equatable {
        let id: UUID
        var start: Double
        var end: Double

        init(id: UUID = UUID(), start: Double, end: Double) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    /// 编辑功能总开关（关闭后，所有编辑相关入口与操作一律不可用）
    static let enabledKey = "edit.featureEnabled"

    /// 当前是否启用编辑功能（集中判断，后续新增的编辑能力都走这里）
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    weak var library: VideoLibrary?

    @Published var ranges: [Range] = []
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var notice: String?

    /// 去掉 [start, end]，保留首尾（基于整片重新计算）
    func cutOut(start: Double, end: Double, duration: Double) {
        guard duration > 1 else { return }
        let a = max(0, min(start, duration))
        let b = max(a, min(end, duration))
        guard b - a >= 0.2 else {
            notice = "选区太短（至少 0.2 秒）"
            return
        }
        var result: [Range] = []
        if a >= 0.2 { result.append(Range(start: 0, end: a)) }
        if duration - b >= 0.2 { result.append(Range(start: b, end: duration)) }
        guard !result.isEmpty else {
            notice = "剪掉这段后就没有内容了"
            return
        }
        ranges = result
        DiagnosticsLog.write("[剪辑] 剪掉 " + Self.timeText(a) + "–" + Self.timeText(b)
                             + "，保留 " + String(result.count) + " 段")
    }

    /// 只保留 [start, end]
    func keepOnly(start: Double, end: Double) {
        let a = max(0, start)
        let b = max(a, end)
        guard b - a >= 0.2 else {
            notice = "选区太短（至少 0.2 秒）"
            return
        }
        ranges = [Range(start: a, end: b)]
        DiagnosticsLog.write("[剪辑] 只保留 " + Self.timeText(a) + "–" + Self.timeText(b))
    }

    func remove(_ id: UUID) {
        ranges.removeAll { $0.id == id }
    }

    func clear() {
        ranges.removeAll()
    }

    var totalDuration: Double {
        ranges.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    func export(source: VideoItem?) async {
        guard Self.isEnabled else {
            notice = "编辑功能已在「设置 → 编辑」中关闭"
            return
        }
        guard !isExporting else { return }
        guard let source else {
            notice = "当前没有正在播放的视频"
            return
        }
        guard !ranges.isEmpty else {
            notice = "请先设置要保留的区间"
            return
        }
        guard source.fileName.lowercased().hasSuffix(".m3u8") else {
            notice = "该条目已是 MP4，仅分片视频支持剪辑"
            return
        }
        isExporting = true
        progress = 0
        defer { isExporting = false }

        let assetsDir = VideoLibrary.assetsDir
        let indexURL = assetsDir.appendingPathComponent(source.fileName)
        let plan = ranges.map { (start: $0.start, end: $0.end) }
        let title = source.title
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> HLSEditor.ExportResult in
                try HLSEditor.export(sourceTitle: title,
                                     indexURL: indexURL,
                                     outputRoot: assetsDir,
                                     ranges: plan) { value in
                    Task { @MainActor in SegmentEditStore.shared.progress = value }
                }
            }.value

            let newItem = VideoItem(id: UUID(),
                                    title: source.title + " · 剪辑",
                                    sourceURL: source.sourceURL,
                                    fileName: result.fileName,
                                    duration: result.duration,
                                    fileSize: result.fileSize,
                                    createdAt: Date(),
                                    lastPosition: nil,
                                    segmentDirName: result.dirName)
            library?.add(newItem)
            ranges.removeAll()
            notice = "已生成：\(newItem.title)（\(Self.timeText(result.duration))）"
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
