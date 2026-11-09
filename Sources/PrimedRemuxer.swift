import Foundation
import AVFoundation
import CoreMedia

/// 全 Apple 组件转封装：预热 HLS 资产 →（AVAssetReader 读压缩样本 | AVAssetExportSession 导出）→ MP4
enum PrimedRemuxer {
    struct RemuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func remux(source: URL,
                      destination: URL,
                      videoOnly: Bool = false,
                      progress: ((Double) -> Void)? = nil) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let asset = AVURLAsset(url: source)
        let (item, player) = await prime(asset: asset)
        defer { player.pause() }

        let tracks = await loadTracks(asset: asset, item: item)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = videoOnly ? [] : tracks.filter { $0.mediaType == .audio }
        DiagnosticsLog.write("[转MP4] 预热轨道 视频=\(videoTracks.count) 音频=\(audioTracks.count) 总=\(tracks.count)")
        guard !videoTracks.isEmpty else {
            throw RemuxError(message: "预热后仍无视频轨道")
        }

        // 1) Reader → Writer（压缩样本直读，Apple 生成样本与时间戳）
        do {
            try await readerWriterRemux(asset: asset,
                                        videoTracks: videoTracks,
                                        audioTracks: audioTracks,
                                        destination: destination)
            return
        } catch {
            DiagnosticsLog.write("[转MP4] Reader→Writer 失败：\(error.localizedDescription)，改用导出会话")
        }

        // 2) 预热后的 AVAssetExportSession
        try await exportRemux(asset: asset, destination: destination)
    }

    // MARK: - 预热

    private static func prime(asset: AVURLAsset) async -> (AVPlayerItem, AVPlayer) {
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if item.status == .readyToPlay { break }
            if item.status == .failed {
                DiagnosticsLog.write("[转MP4] 预热失败：\(item.error?.localizedDescription ?? "未知")")
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return (item, player)
    }

    /// HLS 的 load(.tracks) 会返回空数组且不抛错，必须以 item.tracks 兜底
    private static func loadTracks(asset: AVURLAsset, item: AVPlayerItem) async -> [AVAssetTrack] {
        for _ in 0..<30 {
            if let loaded = try? await asset.load(.tracks), !loaded.isEmpty {
                return loaded
            }
            let fromItem = item.tracks.compactMap { $0.assetTrack }
            if !fromItem.isEmpty {
                return fromItem
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return []
    }

    // MARK: - Reader → Writer

    private static func readerWriterRemux(asset: AVURLAsset,
                                          videoTracks: [AVAssetTrack],
                                          audioTracks: [AVAssetTrack],
                                          destination: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false

        var pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for track in Array(videoTracks.prefix(1)) + Array(audioTracks.prefix(1)) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)

            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            pairs.append((output, input))
        }
        guard !pairs.isEmpty else {
            throw RemuxError(message: "无法创建读写通道")
        }

        guard writer.startWriting() else {
            throw RemuxError(message: writer.error?.localizedDescription ?? "无法开始写入")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw RemuxError(message: reader.error?.localizedDescription ?? "读取 HLS 失败")
        }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "primed.remux", attributes: .concurrent)
        let lock = NSLock()
        var appended = 0

        for (output, input) in pairs {
            group.enter()
            queue.async {
                defer { group.leave() }
                while let sample = output.copyNextSampleBuffer() {
                    var waited: TimeInterval = 0
                    while !input.isReadyForMoreMediaData, waited < 2.0 {
                        Thread.sleep(forTimeInterval: 0.005)
                        waited += 0.005
                    }
                    if input.append(sample) {
                        lock.lock()
                        appended += 1
                        lock.unlock()
                    } else if reader.status == .failed {
                        break
                    }
                }
                input.markAsFinished()
            }
        }
        _ = group.wait(timeout: .now() + 600)
        if reader.status == .reading { reader.cancelReading() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw RemuxError(message: writer.error?.localizedDescription ?? "写出失败")
        }
        DiagnosticsLog.write("[转MP4] Reader→Writer 完成 样本=\(appended)")
    }

    // MARK: - 导出会话（预热后）

    private static func exportRemux(asset: AVURLAsset, destination: URL) async throws {
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
            session.shouldOptimizeForNetworkUse = false

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            if session.status == .completed {
                DiagnosticsLog.write("[转MP4] 导出会话成功（\(preset)）")
                return
            }
            lastMessage = session.error?.localizedDescription ?? "导出失败"
            DiagnosticsLog.write("[转MP4] 导出会话失败（\(preset)）：\(lastMessage)")
        }

        try? fm.removeItem(at: destination)
        throw RemuxError(message: "导出失败：\(lastMessage)")
    }
}
