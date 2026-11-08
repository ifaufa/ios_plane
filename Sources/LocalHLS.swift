import Foundation
import AVFoundation

/// 本地 m3u8：通过回环 HTTP 服务播放（AVFoundation 对 HTTP HLS 支持最稳）
enum LocalHLS {
    struct VerifyResult {
        var playable: Bool
        var duration: Double
        var detail: String
    }

    struct MergeReport {
        var url: URL
        var bytes: Int64
        var segmentSizes: [Int64]
    }

    // MARK: - 播放列表

    /// 写入相对路径的 index.m3u8（由本地 HTTP 服务提供，相对地址可正常解析）
    @discardableResult
    static func writePlaylist(state: SegmentJobState, dir: URL) throws -> URL {
        let isMP4 = state.container == "mp4"
        let maxDuration = max(1, Int((state.durations.max() ?? 6).rounded(.up)))
        var text = "#EXTM3U\n"
        text += "#EXT-X-VERSION:\(isMP4 ? 6 : 3)\n"
        text += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        text += "#EXT-X-TARGETDURATION:\(maxDuration)\n"
        text += "#EXT-X-MEDIA-SEQUENCE:0\n"
        if isMP4 {
            text += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        }
        for (index, duration) in state.durations.enumerated() {
            text += "#EXTINF:\(String(format: "%.3f", duration)),\n"
            text += fileName(index: index) + "\n"
        }
        text += "#EXT-X-ENDLIST\n"

        let url = dir.appendingPathComponent("index.m3u8")
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    static func fileName(index: Int) -> String {
        String(format: "seg-%06d.ts", index)
    }

    // MARK: - 播放

    /// 启动本地服务并返回 http://127.0.0.1:port/index.m3u8
    static func playbackURL(playlistURL: URL) throws -> URL {
        let dir = playlistURL.deletingLastPathComponent()
        let port = try LocalHTTPServer.shared.start(root: dir)
        guard let url = URL(string: "http://127.0.0.1:\(port)/index.m3u8") else {
            throw PlaylistError.network("本地播放地址构造失败")
        }
        return url
    }

    static func stopPlayback() {
        LocalHTTPServer.shared.stop()
    }

    /// 把单个文件通过本地 HTTP 提供（用于以 video/mp2t 打开本地 TS）
    static func fileURL(_ file: URL) throws -> URL {
        let dir = file.deletingLastPathComponent()
        let port = try LocalHTTPServer.shared.start(root: dir)
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(file.lastPathComponent)") else {
            throw PlaylistError.network("本地文件地址构造失败")
        }
        return url
    }

    /// MPEG-TS 资产：必须显式声明 MIME，否则 AVFoundation 无法识别
    static func tsAsset(_ file: URL) throws -> AVURLAsset {
        let url = try fileURL(file)
        return AVURLAsset(url: url, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "video/mp2t"
        ])
    }

    // MARK: - 校验

    static func verify(asset: AVURLAsset) async -> VerifyResult {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch {
            return VerifyResult(playable: false, duration: 0, detail: "加载失败：\(error.localizedDescription)")
        }
        guard !tracks.isEmpty else {
            return VerifyResult(playable: false, duration: 0, detail: "未解析出音视频轨道")
        }
        if let duration = try? await asset.load(.duration),
           duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 {
            return VerifyResult(playable: true,
                                duration: duration.seconds,
                                detail: "轨道 \(tracks.count) 条，时长 \(String(format: "%.1f", duration.seconds))s")
        }
        return VerifyResult(playable: true, duration: 0, detail: "轨道 \(tracks.count) 条，时长未知（可播）")
    }

    static func verify(_ url: URL) async -> VerifyResult {
        await verify(asset: AVURLAsset(url: url))
    }

    /// 用 AVPlayerItem 的真实加载状态判断可播性（load(.tracks) 对 HLS 会直接返回空数组）
    static func verifyByPlayer(_ url: URL, timeout: TimeInterval = 12) async -> VerifyResult {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch item.status {
            case .readyToPlay:
                let duration = item.duration.seconds
                let value = duration.isFinite && duration > 0 ? duration : 0
                player.pause()
                return VerifyResult(playable: true, duration: value,
                                    detail: "readyToPlay，时长 \(String(format: "%.1f", value))s")
            case .failed:
                let message = item.error?.localizedDescription ?? "未知错误"
                let log = item.errorLog()?.events.last?.errorComment ?? ""
                return VerifyResult(playable: false, duration: 0,
                                    detail: "加载失败：\(message) \(log)")
            default:
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        player.pause()
        return VerifyResult(playable: false, duration: 0, detail: "超时未就绪（\(Int(timeout))s）")
    }

    /// 自检：用 URLSession 直接请求本地服务，判断服务本身是否正常
    static func selfCheck(_ url: URL) async -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return "HTTP \(status) \(data.count)B"
        } catch {
            return "请求失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 合并（仅用于转 MP4 兜底）

    static func merge(state: SegmentJobState, dir: URL, container: String) throws -> MergeReport {
        let fm = FileManager.default
        let output = dir.appendingPathComponent(container == "mp4" ? "merged.mp4" : "merged.ts")
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw PlaylistError.network("无法创建合并文件")
        }

        var total: Int64 = 0
        var sizes: [Int64] = []
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        if container == "mp4" {
            let initURL = dir.appendingPathComponent("init.mp4")
            if fm.fileExists(atPath: initURL.path) {
                let data = try Data(contentsOf: initURL, options: .mappedIfSafe)
                try writer.write(contentsOf: data)
                total += Int64(data.count)
            }
        }

        for index in state.durations.indices {
            let fileURL = dir.appendingPathComponent(fileName(index: index))
            guard fm.fileExists(atPath: fileURL.path) else {
                throw PlaylistError.network("缺少分片 \(index + 1)")
            }
            let reader = try FileHandle(forReadingFrom: fileURL)
            var written: Int64 = 0
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
            try reader.close()
            sizes.append(written)
            total += written
        }
        return MergeReport(url: output, bytes: total, segmentSizes: sizes)
    }

    // MARK: - 转 MP4

    struct ExportFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 先尝试不重编码导出；失败后自动降级为重编码（TS 源 passthrough 常报 Operation Stopped）
    static func exportMP4(from asset: AVURLAsset, to destination: URL) async throws {
        let fm = FileManager.default
        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var lastMessage = "未知错误"

        for preset in presets {
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                lastMessage = "无法创建导出会话（\(preset)）"
                continue
            }
            session.outputURL = destination
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true

            let progressTask = Task { @MainActor in
                var lastLogged = -1
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let percent = Int(session.progress * 100)
                    if percent >= lastLogged + 15 || percent >= 100 {
                        lastLogged = percent
                        DiagnosticsLog.write("[转MP4] \(preset) 进度 \(percent)%")
                    }
                }
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            progressTask.cancel()

            if session.status == .completed {
                DiagnosticsLog.write("[转MP4] 使用 \(preset) 导出成功")
                return
            }
            lastMessage = session.error?.localizedDescription ?? "导出失败"
            DiagnosticsLog.write("[转MP4] \(preset) 失败：\(lastMessage)")
        }

        throw ExportFailure(message: "导出失败：\(lastMessage)")
    }

    static func exportMP4(from fileURL: URL, to destination: URL) async throws {
        try await exportMP4(from: AVURLAsset(url: fileURL), to: destination)
    }
}
