import Foundation
import AVFoundation

/// 分片态视频转 MP4：优先直接转封装 → 校验 → 入库 → 删分片
enum MediaConverter {
    struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func convertToMP4(item: VideoItem) async throws -> (fileName: String, duration: Double, fileSize: Int64) {
        guard item.fileName.lowercased().hasSuffix(".m3u8") else {
            throw ConversionError(message: "该视频已经是单体文件，无需转换")
        }
        let fm = FileManager.default
        let dir = VideoLibrary.assetsDir.appendingPathComponent((item.fileName as NSString).deletingLastPathComponent)
        let playlist = dir.appendingPathComponent("index.m3u8")
        guard fm.fileExists(atPath: playlist.path) else {
            throw ConversionError(message: "缺少本地播放列表，无法转换")
        }

        // 空间预检：转 MP4 期间需要分片 + 成品并存
        let dirSize = directorySize(dir)
        if let available = availableCapacity(),
           available < Int64(Double(dirSize) * 1.1) + 200 * 1024 * 1024 {
            let need = Double(dirSize) * 1.1 / 1_073_741_824
            let left = Double(available) / 1_073_741_824
            throw ConversionError(message: String(format: "空间不足：转 MP4 约需 %.1f GB，当前仅剩 %.1f GB。原分片已保留。", need, left))
        }

        let outputName = UUID().uuidString + ".mp4"
        let outputURL = VideoLibrary.assetsDir.appendingPathComponent(outputName)
        if fm.fileExists(atPath: outputURL.path) {
            try? fm.removeItem(at: outputURL)
        }

        // 1) 直接从分片态转封装（不经合并，省一次临时占用）
        var exported = false
        do {
            let httpURL = try LocalHLS.playbackURL(playlistURL: playlist)
            defer { LocalHLS.stopPlayback() }
            let asset = AVURLAsset(url: httpURL)
            try await LocalHLS.exportMP4(from: asset, to: outputURL)
            exported = true
            DiagnosticsLog.write("[转MP4] 直接转封装成功 大小=\((try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)B")
        } catch {
            DiagnosticsLog.write("[转MP4] 直接转封装失败：\(error.localizedDescription)，尝试合并后转封装")
        }

        // 2) 兜底：先合并成单文件再转封装
        if !exported {
            guard let state = loadState(dir: dir) else {
                throw ConversionError(message: "缺少分片状态文件，无法转换")
            }
            let report = try LocalHLS.merge(state: state, dir: dir, container: state.container)
            defer { try? fm.removeItem(at: report.url) }
            try await LocalHLS.exportMP4(from: report.url, to: outputURL)
        }

        // 3) 校验通过才删分片
        let verify = await LocalHLS.verify(outputURL)
        guard verify.playable else {
            try? fm.removeItem(at: outputURL)
            throw ConversionError(message: "转换后校验失败（未解析出音轨/视频轨），原分片已保留，可重试")
        }

        try? fm.removeItem(at: dir)
        let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        DiagnosticsLog.write("[转MP4] 完成 时长=\(String(format: "%.1f", verify.duration))s 大小=\(size)B 已删除分片")
        return (outputName, verify.duration, size)
    }

    // MARK: - 工具

    private static func loadState(dir: URL) -> SegmentJobState? {
        let stateURL = dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SegmentJobState.self, from: data)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        for case let sub as String in enumerator {
            let fileURL = url.appendingPathComponent(sub)
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func availableCapacity() -> Int64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
