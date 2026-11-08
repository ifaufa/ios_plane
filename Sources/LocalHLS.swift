import Foundation
import AVFoundation

/// 本地 m3u8：分片状态即可播放（1× 空间）
enum LocalHLS {
    static let scheme = "planelocal"
    static let host = "local"

    struct VerifyResult {
        var playable: Bool
        var duration: Double
        var detail: String
    }

    // MARK: - 播放列表

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
            text += "#EXT-X-MAP:URI=\"\(absoluteURL(for: "init.mp4"))\"\n"
        }
        for (index, duration) in state.durations.enumerated() {
            text += "#EXTINF:\(String(format: "%.3f", duration)),\n"
            text += absoluteURL(for: fileName(index: index)) + "\n"
        }
        text += "#EXT-X-ENDLIST\n"

        let url = dir.appendingPathComponent("index.m3u8")
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    static func absoluteURL(for fileName: String) -> String {
        "\(scheme)://\(host)/\(fileName)"
    }

    static func fileName(index: Int) -> String {
        String(format: "seg-%06d.ts", index)
    }

    // MARK: - 播放资产

    static func makeAsset(playlistURL: URL) -> AVURLAsset {
        let dir = playlistURL.deletingLastPathComponent()
        guard var components = URLComponents(url: playlistURL, resolvingAgainstBaseURL: false) else {
            return AVURLAsset(url: playlistURL)
        }
        components.scheme = scheme
        components.host = host
        guard let localURL = components.url else { return AVURLAsset(url: playlistURL) }

        // 关键：告诉 AVFoundation 这是一个 HLS，否则它会立刻放弃解析
        let asset = AVURLAsset(url: localURL, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "application/vnd.apple.mpegurl"
        ])
        let container = detectContainer(dir: dir)
        let loader = LocalHLSLoader(baseDir: dir, container: container)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        LocalHLSLoader.retain(loader, for: asset)
        return asset
    }

    static func detectContainer(dir: URL) -> String {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("init.mp4").path) ? "mp4" : "ts"
    }

    // MARK: - 校验

    /// 以"能解析出轨道"为主要标准，时长仅作为附加信息
    static func verify(asset: AVURLAsset) async -> VerifyResult {
        let tracks = (try? await asset.load(.tracks)) ?? []
        guard !tracks.isEmpty else {
            return VerifyResult(playable: false, duration: 0, detail: "未解析出音视频轨道")
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 {
            return VerifyResult(playable: true, duration: duration.seconds, detail: "轨道 \(tracks.count) 条，时长 \(String(format: "%.1f", duration.seconds))s")
        }
        return VerifyResult(playable: true, duration: 0, detail: "轨道 \(tracks.count) 条，时长未知（可播）")
    }

    static func verify(_ url: URL) async -> VerifyResult {
        await verify(asset: AVURLAsset(url: url))
    }

    // MARK: - 合并（兜底）

    struct MergeReport {
        var url: URL
        var bytes: Int64
        var segmentSizes: [Int64]
    }

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

    /// 直接从分片态资产转封装（不经合并，省一次临时占用）；失败时调用方再走合并兜底
    static func exportMP4(from asset: AVURLAsset, to destination: URL) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw PlaylistError.network("无法创建导出会话")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw PlaylistError.network(session.error?.localizedDescription ?? "转 MP4 失败")
        }
    }

    static func exportMP4(from fileURL: URL, to destination: URL) async throws {
        try await exportMP4(from: AVURLAsset(url: fileURL), to: destination)
    }
}

/// 本地文件"喂"给 AVPlayer
final class LocalHLSLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "local.hls.loader")
    let baseDir: URL
    let container: String

    private static var holders: [ObjectIdentifier: LocalHLSLoader] = [:]
    private static let holdersLock = NSLock()

    init(baseDir: URL, container: String) {
        self.baseDir = baseDir
        self.container = container
        super.init()
    }

    static func retain(_ loader: LocalHLSLoader, for asset: AVURLAsset) {
        holdersLock.lock()
        holders[ObjectIdentifier(asset)] = loader
        holdersLock.unlock()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else { return false }
        let name = url.lastPathComponent
        guard !name.isEmpty else { return false }
        let fileURL = baseDir.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            DiagnosticsLog.write("[资源加载器] 缺少文件 \(name)")
            return false
        }

        if let info = loadingRequest.contentInformationRequest {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            info.contentLength = Int64(size)
            info.isByteRangeAccessSupported = true
            info.contentType = contentType(for: name)
        }

        if let dataRequest = loadingRequest.dataRequest {
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                let offset = UInt64(max(0, dataRequest.requestedOffset))
                guard offset < end else {
                    loadingRequest.finishLoading(with: nil)
                    return true
                }
                try handle.seek(toOffset: offset)
                var remaining: UInt64
                if dataRequest.requestsAllDataToEndOfResource {
                    remaining = end - offset
                } else {
                    remaining = UInt64(max(0, dataRequest.requestedLength))
                    remaining = min(remaining, end - offset)
                }
                while remaining > 0 {
                    let chunkSize = Int(min(remaining, 1 << 20))
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    dataRequest.respond(with: chunk)
                    remaining -= UInt64(chunk.count)
                }
                loadingRequest.finishLoading()
                return true
            } catch {
                DiagnosticsLog.write("[资源加载器] 读取 \(name) 失败：\(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return true
            }
        }

        loadingRequest.finishLoading()
        return true
    }

    private func contentType(for name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".mp4") || container == "mp4" { return "video/mp4" }
        return "video/mp2t"
    }
}
