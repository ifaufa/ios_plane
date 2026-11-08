import Foundation
import AVFoundation

/// 分片态视频转 MP4：合并/转封装 → 校验 → 入库 → 删分片
enum MediaConverter {
    struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 返回转换后的新文件名、时长、大小
    static func convertToMP4(item: VideoItem) async throws -> (fileName: String, duration: Double, fileSize: Int64) {
        guard item.fileName.lowercased().hasSuffix(".m3u8") else {
            throw ConversionError(message: "该视频已经是单体文件，无需转换")
        }
        let fm = FileManager.default
        let dir = VideoLibrary.assetsDir.appendingPathComponent((item.fileName as NSString).deletingLastPathComponent)
        let stateURL = dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL) else {
            throw ConversionError(message: "缺少分片状态文件，无法转换")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SegmentJobState.self, from: data)

        // 1) 先合并成单体（fMP4 源直接出 mp4，TS 源出 ts 再转封装）
        let merged = try LocalHLS.merge(state: state, dir: dir, container: state.container)

        // 2) 目标是 mp4
        let outputName = UUID().uuidString + ".mp4"
        let outputURL = VideoLibrary.assetsDir.appendingPathComponent(outputName)
        if fm.fileExists(atPath: outputURL.path) {
            try? fm.removeItem(at: outputURL)
        }

        if merged.pathExtension.lowercased() == "mp4" {
            try fm.moveItem(at: merged, to: outputURL)
        } else {
            try await LocalHLS.exportMP4(from: merged, to: outputURL)
            try? fm.removeItem(at: merged)
        }

        // 3) 校验，失败则清理并保留分片
        guard let duration = await LocalHLS.verify(outputURL), duration > 0 else {
            try? fm.removeItem(at: outputURL)
            throw ConversionError(message: "转换后校验失败，已保留分片，可重试")
        }

        // 4) 校验通过才删分片目录
        try? fm.removeItem(at: dir)

        let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        return (outputName, duration, size)
    }
}
