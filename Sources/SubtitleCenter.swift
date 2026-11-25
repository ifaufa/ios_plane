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

    private static let fontKey = "subtitle.font"
    private static let posKey = "subtitle.pos"
    private static let bgKey = "subtitle.bg"

    private init() {
        let defaults = UserDefaults.standard
        fontSizeIndex = defaults.object(forKey: Self.fontKey) as? Int ?? 1
        positionIndex = defaults.object(forKey: Self.posKey) as? Int ?? 0
        backgroundIndex = defaults.object(forKey: Self.bgKey) as? Int ?? 1
    }

    var hasSubtitles: Bool { !tracks.isEmpty }
    var isActive: Bool { primary != nil }

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
    func prepare(for video: VideoItem?) {
        guard let video else { clear(); return }
        currentVideoID = video.id
        let dir = mediaDirectory(for: video)
        rescan(directory: dir)

        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "subtitle.sel.\(video.id.uuidString)"),
           let track = tracks.first(where: { $0.fileName == saved }) {
            primary = track
        } else if primary == nil {
            primary = tracks.first
        }
        if let saved2 = defaults.string(forKey: "subtitle.sel2.\(video.id.uuidString)"),
           let track = tracks.first(where: { $0.fileName == saved2 }) {
            secondary = track
        }
        if let track = primary {
            DiagnosticsLog.write("[字幕] 载入 " + track.fileName + " 共 " + String(track.cues.count) + " 条")
        } else {
            DiagnosticsLog.write("[字幕] 该视频没有可用字幕文件")
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
                                           title: file.deletingPathExtension().lastPathComponent,
                                           fileName: rel,
                                           cues: cues))
            }
        }

        scan(directory, prefix: "")
        scan(directory.appendingPathComponent("subtitles", isDirectory: true), prefix: "subtitles/")
        tracks = found

        // 已选中的轨道用新解析结果替换
        if let current = primary, let updated = found.first(where: { $0.fileName == current.fileName }) {
            primary = updated
        }
        if let current = secondary, let updated = found.first(where: { $0.fileName == current.fileName }) {
            secondary = updated
        }
    }

    // MARK: - 选择

    func selectPrimary(_ track: SubtitleTrack?) {
        primary = track
        if let id = currentVideoID {
            UserDefaults.standard.set(track?.fileName, forKey: "subtitle.sel.\(id.uuidString)")
        }
        DiagnosticsLog.write("[字幕] 主轨=" + (track?.title ?? "关闭"))
    }

    func selectSecondary(_ track: SubtitleTrack?) {
        secondary = track
        if let id = currentVideoID {
            UserDefaults.standard.set(track?.fileName, forKey: "subtitle.sel2.\(id.uuidString)")
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
    }

    var fontSize: CGFloat {
        switch fontSizeIndex {
        case 0: return 16
        case 2: return 24
        default: return 20
        }
    }

    /// 主/次两条轨在指定时间的文本
    func texts(at time: Double) -> (primary: String?, secondary: String?) {
        (primary?.text(at: time), secondary?.text(at: time))
    }
}
