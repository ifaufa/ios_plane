import Foundation
import AVFoundation

/// 分片态视频转 MP4：合并 → 无重编码转封装（失败才降级重编码）→ 校验 → 删分片
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
        guard let state = loadState(dir: dir) else {
            throw ConversionError(message: "缺少分片状态文件，无法转换")
        }

        // 空间预检：合并文件 + MP4 需要同时存在
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

        // 1) 本地合并成一个文件（几秒钟，无网络）
        let report = try LocalHLS.merge(state: state, dir: dir, container: state.container)
        let mergedURL = report.url
        defer { try? fm.removeItem(at: mergedURL) }
        DiagnosticsLog.write("[转MP4] 合并完成 大小=\(report.bytes)B，开始转封装")

        // 2) 优先做无重编码转封装（保留原始画质，速度最快）
        var produced = false
        if state.container == "ts" {
            do {
                let start = Date()
                try await TSRemuxer.remux(source: mergedURL, destination: outputURL)
                let cost = Date().timeIntervalSince(start)
                produced = true
                DiagnosticsLog.write(String(format: "[转MP4] 无重编码转封装成功，耗时 %.1fs", cost))
            } catch {
                DiagnosticsLog.write("[转MP4] 转封装失败：\(error.localizedDescription)，改用系统导出（可能重编码）")
            }
        }

        // 3) 兜底：系统导出（passthrough → 重编码）
        if !produced {
            try await LocalHLS.exportMP4(from: mergedURL, to: outputURL)
            produced = true
        }

        // 4) 校验通过才删分片
        let verify = await LocalHLS.verify(outputURL)
        guard verify.playable else {
            try? fm.removeItem(at: outputURL)
            throw ConversionError(message: "转换后校验失败（\(verify.detail)），原分片已保留，可重试")
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
