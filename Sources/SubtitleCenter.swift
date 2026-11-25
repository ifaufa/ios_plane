import Foundation
import SwiftUI

/// 字幕中心：管理当前视频的可用字幕、主/次轨选择与显示样式
@MainActor
final class SubtitleCenter: ObservableObject {
    static let shared = SubtitleCenter()

    @Published private(set) var tracks: [SubtitleTrack] = []
    @Published private(set) var primary: SubtitleTrack?
    @Published private(set) var secondary: SubtitleTrack?
    @Published private(set) var currentVideoID: UUID?

    // 显示样式（0/1/2 三档）
    @Published var fontSizeIndex: Int
    @Published var positionIndex: Int
    @Published var backgroundIndex: Int
    /// 0 白 1 黄 2 青 3 绿 4 粉
    @Published var colorIndex: Int

    private static let fontKey = "subtitle.font"
    private static let posKey = "subtitle.pos"
    private static let bgKey = "subtitle.bg"
    private static let colorKey = "subtitle.color"

    private init() {
        let defaults = UserDefaults.standard
        fontSizeIndex = defaults.object(forKey: Self.fontKey) as? Int ?? 1
        positionIndex = defaults.object(forKey: Self.posKey) as? Int ?? 0
        backgroundIndex = defaults.object(forKey: Self.bgKey) as? Int ?? 1
        colorIndex = defaults.object(forKey: Self.colorKey) as? Int ?? 0
    }

    var hasSubtitles: Bool { !tracks.isEmpty }
    var isActive: Bool {
        guard let primary else { return false }
        return primary.videoID == nil || primary.videoID == currentVideoID
    }

    // MARK: - 关联视频

    func mediaDirectory(for video: VideoItem) -> URL {
        let assets = VideoLibrary.assetsDir
        if video.fileName.lowercased().hasSuffix(".m3u8") {
            return assets.appendingPathComponent((video.fileName as NSString).deletingLastPathComponent)
        }
        if let dir = video.segmentDirName, !dir.isEmpty {
            return assets.appendingPathComponent(dir, isDirectory: true)
        }
        return assets
    }

    /// 打开视频时准备字幕（自动匹配同名/目录内文件）
    private static let offSentinel = "__off__"

    func prepare(for video: VideoItem?) {
        guard let video else { clear(); return }

        // 换视频：先彻底清空上一次的轨道，避免串台
        if currentVideoID != video.id {
            primary = nil
            secondary = nil
        }
        currentVideoID = video.id
        rescan(directory: mediaDirectory(for: video))

        let defaults = UserDefaults.standard
        let primaryKey = "subtitle.sel.\(video.id.uuidString)"
        let secondaryKey = "subtitle.sel2.\(video.id.uuidString)"

        if let saved = defaults.string(forKey: primaryKey) {
            if saved == Self.offSentinel {
                primary = nil                     // 用户上次主动关闭 → 保持关闭
            } else {
                primary = tracks.first { $0.fileName == saved }
            }
        } else {
            primary = tracks.first                // 从未设置 → 自动选中第一条
        }

        if let saved2 = defaults.string(forKey: secondaryKey) {
            secondary = saved2 == Self.offSentinel ? nil : tracks.first { $0.fileName == saved2 }
        } else {
            secondary = nil
        }

        if let track = primary {
            DiagnosticsLog.write("[字幕] 载入 " + track.fileName + " 共 " + String(track.cues.count) + " 条")
        } else {
            DiagnosticsLog.write("[字幕] 当前无主字幕（文件 " + String(tracks.count) + " 条）")
        }
    }

    func clear() {
        tracks = []
        primary = nil
        secondary = nil
        currentVideoID = nil
    }

    private func rescan(directory: URL) {
        let fm = FileManager.default
        var found: [SubtitleTrack] = []
        var seen = Set<String>()

        func scan(_ folder: URL, prefix: String) {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let ext = file.pathExtension.lowercased()
                guard SubtitleParser.supportedExtensions.contains(ext) else { continue }
                let rel = prefix + file.lastPathComponent
                guard !seen.contains(rel) else { continue }
                seen.insert(rel)
                guard let cues = SubtitleParser.parse(url: file), !cues.isEmpty else { continue }
                found.append(SubtitleTrack(id: UUID(),
                                           videoID: currentVideoID,
                                           title: file.deletingPathExtension().lastPathComponent,
                                           fileName: rel,
                                           cues: cues))
            }
        }

        scan(directory, prefix: "")
        scan(directory.appendingPathComponent("subtitles", isDirectory: true), prefix: "subtitles/")
        tracks = found

        // 已选中的轨道用新解析结果替换；找不到就置空（绝不保留旧视频的轨道）
        primary = primary.flatMap { current in found.first { $0.fileName == current.fileName } }
        secondary = secondary.flatMap { current in found.first { $0.fileName == current.fileName } }
    }

    // MARK: - 选择

    func selectPrimary(_ track: SubtitleTrack?) {
        primary = track
        if let id = currentVideoID {
            UserDefaults.standard.set(track?.fileName ?? Self.offSentinel,
                                      forKey: "subtitle.sel.\(id.uuidString)")
        }
        DiagnosticsLog.write("[字幕] 主轨=" + (track?.title ?? "关闭"))
    }

    func selectSecondary(_ track: SubtitleTrack?) {
        secondary = track
        if let id = currentVideoID {
            UserDefaults.standard.set(track?.fileName ?? Self.offSentinel,
                                      forKey: "subtitle.sel2.\(id.uuidString)")
        }
        DiagnosticsLog.write("[字幕] 次轨=" + (track?.title ?? "关闭"))
    }

    /// 导入字幕文件：拷到 <视频目录>/subtitles/ 下
    @discardableResult
    func importFile(from url: URL) -> Bool {
        guard let videoID = currentVideoID,
              let video = SegmentEditStore.shared.library?.items.first(where: { $0.id == videoID }) else {
            return false
        }
        let dir = mediaDirectory(for: video).appendingPathComponent("subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            DiagnosticsLog.write("[字幕] 导入失败：" + error.localizedDescription)
            return false
        }
        rescan(directory: mediaDirectory(for: video))
        if let track = tracks.first(where: { $0.fileName == "subtitles/" + url.lastPathComponent }) {
            selectPrimary(track)
        }
        return true
    }

    // MARK: - 样式与偏移

    func adjustOffset(_ delta: Double) {
        guard var track = primary else { return }
        track.offset = max(-30, min(30, track.offset + delta))
        primary = track
        DiagnosticsLog.write("[字幕] 偏移 " + String(format: "%.1f", track.offset) + "s")
    }

    func persistStyle() {
        let defaults = UserDefaults.standard
        defaults.set(fontSizeIndex, forKey: Self.fontKey)
        defaults.set(positionIndex, forKey: Self.posKey)
        defaults.set(backgroundIndex, forKey: Self.bgKey)
        defaults.set(colorIndex, forKey: Self.colorKey)
    }

    var textColor: Color {
        switch colorIndex {
        case 1: return .yellow
        case 2: return .cyan
        case 3: return .green
        case 4: return Color(red: 1.0, green: 0.62, blue: 0.78)
        default: return .white
        }
    }

    var fontSize: CGFloat {
        switch fontSizeIndex {
        case 0: return 16
        case 2: return 24
        default: return 20
        }
    }

    /// 主/次两条轨在指定时间的文本（带归属校验，杜绝跨视频串台）
    func texts(at time: Double) -> (primary: String?, secondary: String?) {
        guard let currentVideoID else { return (nil, nil) }
        let first = (primary?.videoID == nil || primary?.videoID == currentVideoID)
            ? primary?.text(at: time) : nil
        let second = (secondary?.videoID == nil || secondary?.videoID == currentVideoID)
            ? secondary?.text(at: time) : nil
        return (first, second)
    }
}
