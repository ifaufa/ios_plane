import Foundation
import AVFoundation

/// 分片态视频转 MP4：TS 走自研无损转封装；失败再降级系统导出
enum MediaConverter {
    struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func convertToMP4(item: VideoItem,
                             onProgress: ((Double) -> Void)? = nil) async throws -> (fileName: String, duration: Double, fileSize: Int64) {
        guard item.fileName.lowercased().hasSuffix(".m3u8") else {
            throw ConversionError(message: "该视频已经是单体文件，无需转换")
        }
        let fm = FileManager.default
        let dir = VideoLibrary.assetsDir.appendingPathComponent((item.fileName as NSString).deletingLastPathComponent)
        guard let state = loadState(dir: dir) else {
            throw ConversionError(message: "缺少分片状态文件，无法转换")
        }

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

        var produced = false

        // 1) TS：自研无损转封装（不依赖 AVFoundation 解 TS）
        if state.container == "ts" {
            do {
                let start = Date()
                try await AVRemuxPipeline.remux(state: state, dir: dir, destination: outputURL, onProgress: onProgress)
                produced = true
                DiagnosticsLog.write(String(format: "[转MP4] TS→MP4（AVAssetWriter）成功，耗时 %.1fs", Date().timeIntervalSince(start)))
            } catch {
                DiagnosticsLog.write("[转MP4] AVAssetWriter 封装失败：\(error.localizedDescription)，尝试仅视频轨")
                do {
                    try await AVRemuxPipeline.remux(state: state, dir: dir, destination: outputURL,
                                                    onProgress: onProgress, videoOnly: true)
                    produced = true
                    DiagnosticsLog.write("[转MP4] 仅视频轨封装成功")
                } catch {
                    DiagnosticsLog.write("[转MP4] 仅视频轨封装也失败：\(error.localizedDescription)")
                }
            }
        }
        if !produced {
            do {
                try await TSRemuxPipeline.remux(state: state, dir: dir, destination: outputURL, progress: onProgress)
                produced = true
                DiagnosticsLog.write("[转MP4] 手写封装成功")
            } catch {
                DiagnosticsLog.write("[转MP4] 手写封装失败：\(error.localizedDescription)")
            }
        }

        // 2) fMP4 或自研失败：走 AVFoundation（HLS 资产）
        if !produced {
            do {
                let playlist = dir.appendingPathComponent("index.m3u8")
                let httpURL = try LocalHLS.playbackURL(playlistURL: playlist)
                defer { LocalHLS.stopPlayback() }
                try await TSRemuxer.remux(source: httpURL, destination: outputURL)
                produced = true
                DiagnosticsLog.write("[转MP4] AVFoundation 转封装成功")
            } catch {
                DiagnosticsLog.write("[转MP4] AVFoundation 转封装失败：\(error.localizedDescription)")
            }
        }

        // 3) 最后兜底：合并后用系统导出（可能重编码）
        if !produced {
            let report = try LocalHLS.merge(state: state, dir: dir, container: state.container)
            let mergedURL = report.url
            defer { try? fm.removeItem(at: mergedURL) }
            try await LocalHLS.exportMP4(from: mergedURL, to: outputURL)
            produced = true
        }

        DiagnosticsLog.write("[转MP4] 结构自检 \(MP4Inspector.describe(outputURL))")

        let verify = await LocalHLS.verifyByPlayer(outputURL)
        let trackInfo = await describeTracks(outputURL)
        DiagnosticsLog.write("[转MP4] 轨道信息 \(trackInfo)")

        guard verify.playable, verify.duration > 1 else {
            // 保留产物，便于导出到电脑上比对（不删除，也不入库）
            DiagnosticsLog.write("[转MP4] 校验未通过，产物已保留：\(outputURL.lastPathComponent)")
            throw ConversionError(message: "转换后校验失败（\(verify.detail)；\(trackInfo)）。原分片已保留，产物 \(outputName) 也在「文件」App 里，可导出到电脑用 VLC 验证。")
        }

        try? fm.removeItem(at: dir)
        let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        DiagnosticsLog.write("[转MP4] 完成 时长=\(String(format: "%.1f", verify.duration))s 大小=\(size)B 已删除分片")
        return (outputName, verify.duration, size)
    }

    // MARK: - 工具

    private static func describeTracks(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else {
            return "无轨道"
        }
        var parts: [String] = []
        for track in tracks {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let range = (try? await track.load(.timeRange))?.duration.seconds ?? 0
            parts.append("\(track.mediaType.rawValue) \(Int(size.width))x\(Int(size.height)) \(String(format: "%.1f", range))s")
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        return "总时长=\(String(format: "%.1f", duration))s | " + parts.joined(separator: " | ")
    }

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
