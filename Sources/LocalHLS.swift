import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// 本地 m3u8：改写为相对路径，用资源加载器喂给 AVPlayer（分片状态即可播放，1× 空间）
enum LocalHLS {
    static let scheme = "planelocal"

    /// 生成 index.m3u8（明文，因为我们下载时已解密）
    @discardableResult
    static func writePlaylist(state: SegmentJobState, dir: URL) throws -> URL {
        let maxDuration = max(1, Int(state.durations.map { $0 }.max() ?? 6) + 1)
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        text += "#EXT-X-TARGETDURATION:\(maxDuration)\n"
        text += "#EXT-X-MEDIA-SEQUENCE:0\n"
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

    /// 用资源加载器构造可播放资产
    static func makeAsset(playlistURL: URL) -> AVURLAsset {
        let dir = playlistURL.deletingLastPathComponent()
        guard var components = URLComponents(url: playlistURL, resolvingAgainstBaseURL: false) else {
            return AVURLAsset(url: playlistURL)
        }
        components.scheme = scheme
        components.host = "local"
        guard let localURL = components.url else { return AVURLAsset(url: playlistURL) }

        let asset = AVURLAsset(url: localURL)
        let loader = LocalHLSLoader(baseDir: dir)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        LocalHLSLoader.retain(loader, for: asset)
        return asset
    }

    /// 合并为单文件（B2 兜底 / 转 MP4 用）
    static func merge(state: SegmentJobState, dir: URL, container: String) throws -> URL {
        let fm = FileManager.default
        let output = dir.appendingPathComponent(container == "mp4" ? "merged.mp4" : "merged.ts")
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw PlaylistError.network("无法创建合并文件")
        }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        if container == "mp4" {
            let initURL = dir.appendingPathComponent("init.mp4")
            if fm.fileExists(atPath: initURL.path) {
                let data = try Data(contentsOf: initURL, options: .mappedIfSafe)
                try writer.write(contentsOf: data)
            }
        }
        for (index, _) in state.durations.enumerated() {
            let fileURL = dir.appendingPathComponent(fileName(index: index))
            guard fm.fileExists(atPath: fileURL.path) else {
                throw PlaylistError.network("缺少分片 \(index + 1)")
            }
            let reader = try FileHandle(forReadingFrom: fileURL)
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
            try reader.close()
        }
        return output
    }

    /// 校验资产可播放并返回时长
    static func verify(asset: AVURLAsset) async -> Double? {
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            return nil
        }
        let tracks = (try? await asset.load(.tracks)) ?? []
        guard !tracks.isEmpty else { return nil }
        return duration.seconds
    }

    /// 校验可播放并返回时长
    static func verify(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            return nil
        }
        let tracks = (try? await asset.load(.tracks)) ?? []
        guard !tracks.isEmpty else { return nil }
        return duration.seconds
    }

    /// 转封装为 MP4（不重编码）
    static func exportMP4(from source: URL, to destination: URL) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw PlaylistError.network("无法创建导出会话")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        if session.status != .completed {
            throw PlaylistError.network(session.error?.localizedDescription ?? "转 MP4 失败")
        }
    }
}

/// 把本地文件"喂"给 AVPlayer
final class LocalHLSLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = LocalHLS.scheme
    let queue = DispatchQueue(label: "local.hls.loader")
    let baseDir: URL

    // 保持 loader 存活（AVAsset 只弱引用 delegate）
    private static var holders: [ObjectIdentifier: LocalHLSLoader] = [:]

    init(baseDir: URL) {
        self.baseDir = baseDir
        super.init()
    }

    static func retain(_ loader: LocalHLSLoader, for asset: AVURLAsset) {
        holders[ObjectIdentifier(asset)] = loader
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url else { return false }
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty else { return false }
        let fileURL = baseDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }

        if let info = loadingRequest.contentInformationRequest {
            info.isByteRangeAccessSupported = true
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            info.contentLength = Int64(size)
            info.contentType = contentType(for: fileName)
        }

        if let dataRequest = loadingRequest.dataRequest {
            if let handle = try? FileHandle(forReadingFrom: fileURL) {
                defer { try? handle.close() }
                let available = (try? handle.seekToEnd()) ?? 0
                let offset = max(0, dataRequest.requestedOffset)
                let length: UInt64
                if dataRequest.requestsAllDataToEndOfResource {
                    length = available > offset ? available - UInt64(offset) : 0
                } else {
                    length = UInt64(max(0, dataRequest.requestedLength))
                }
                try? handle.seek(toOffset: UInt64(offset))
                if length > 0, let chunk = try? handle.read(upToCount: Int(length)) {
                    dataRequest.respond(with: chunk)
                }
            }
            loadingRequest.finishLoading()
            return true
        }

        loadingRequest.finishLoading()
        return true
    }

    private func contentType(for fileName: String) -> String {
        if fileName.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if fileName.hasSuffix(".mp4") { return "video/mp4" }
        return "video/mp2t"
    }
}
