import Foundation
import AVFoundation
import CoreMedia

/// 全 Apple 组件转封装：预热 HLS 资产 → AVAssetReader 读压缩样本 → AVAssetWriter 写 MP4
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

        // 1) 预热：让 HLS 播放列表与轨道真正加载
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if item.status == .readyToPlay { break }
            if item.status == .failed {
                player.pause()
                throw RemuxError(message: "资产加载失败：\(item.error?.localizedDescription ?? "未知")")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        player.pause()
        guard item.status == .readyToPlay else {
            throw RemuxError(message: "预热超时：HLS 资产未能加载")
        }

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch {
            tracks = item.tracks.compactMap { $0.assetTrack }
        }
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = videoOnly ? [] : tracks.filter { $0.mediaType == .audio }
        guard !videoTracks.isEmpty else {
            throw RemuxError(message: "预热后仍无视频轨道")
        }
        DiagnosticsLog.write("[转MP4] 预热轨道 视频=\(videoTracks.count) 音频=\(audioTracks.count)")

        // 2) Reader（压缩样本直读）+ Writer（容器由系统写）
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
            throw RemuxError(message: reader.error?.localizedDescription ?? "读取 HLS 失败")
        }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "primed.remux", attributes: .concurrent)
        let lock = NSLock()
        var appendedTotal = 0

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
                        appendedTotal += 1
                        lock.unlock()
                    } else if reader.status == .failed {
                        break
                    }
                }
                input.markAsFinished()
            }
        }
        _ = group.wait(timeout: .now() + 600)
        if reader.status == .reading {
            reader.cancelReading()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            try? fm.removeItem(at: destination)
            throw RemuxError(message: writer.error?.localizedDescription ?? "写出失败")
        }
        DiagnosticsLog.write("[转MP4] Primed Reader→Writer 完成 样本=\(appendedTotal)")
    }
}
