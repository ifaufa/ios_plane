import Foundation
import AVFoundation
import CoreMedia

/// TS → MP4 无重编码转封装：AVAssetReader 读压缩样本，AVAssetWriter 直接写入
enum TSRemuxer {
    struct RemuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 只搬运 H.264/HEVC 视频 + AAC 音频的压缩样本，不重新编码
    static func remux(source: URL, destination: URL, videoOnly: Bool = false, timeout: TimeInterval = 300) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let asset = AVURLAsset(url: source)
        let tracks = await loadTracks(asset: asset)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        DiagnosticsLog.write("[转MP4] 轨道解析 视频=\(videoTracks.count) 音频=\(audioTracks.count)")
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw RemuxError(message: "源文件里没有可用的音视频轨道")
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        var startTime = CMTime.zero
        var hasStart = false

        var selectedTracks = Array(videoTracks.prefix(1))
        if !videoOnly {
            selectedTracks += Array(audioTracks.prefix(1))
        }
        for track in selectedTracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)

            // 不指定 sourceFormatHint，由首个样本推断，避免 CF 类型条件转换的编译限制
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            pairs.append((output, input))

            let range = track.timeRange
            if range.start.isValid && range.start.seconds.isFinite {
                if !hasStart || range.start < startTime {
                    startTime = range.start
                    hasStart = true
                }
            }
        }

        guard !pairs.isEmpty else {
            throw RemuxError(message: "无法创建读写通道（格式可能不被支持）")
        }

        guard reader.startReading() else {
            throw RemuxError(message: reader.error?.localizedDescription ?? "读取源文件失败")
        }
        guard writer.startWriting() else {
            throw RemuxError(message: writer.error?.localizedDescription ?? "创建输出文件失败")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ts.remux", attributes: .concurrent)
        let lock = NSLock()
        var appendFailed = false

        for (output, input) in pairs {
            group.enter()
            queue.async {
                defer { group.leave() }
                while let sample = output.copyNextSampleBuffer() {
                    while !input.isReadyForMoreMediaData {
                        if reader.status == .failed || reader.status == .cancelled { break }
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    guard let retimed = hasStart ? Self.retimed(sample, by: startTime) : sample else { continue }
                    if !input.append(retimed) {
                        lock.lock(); appendFailed = true; lock.unlock()
                        break
                    }
                }
                input.markAsFinished()
            }
        }

        _ = group.wait(timeout: .now() + timeout)

        if reader.status == .reading {
            reader.cancelReading()
        }

        lock.lock()
        let failedToAppend = appendFailed
        lock.unlock()

        if reader.status == .failed {
            try? fm.removeItem(at: destination)
            throw RemuxError(message: reader.error?.localizedDescription ?? "读取中断")
        }
        if failedToAppend {
            try? fm.removeItem(at: destination)
            throw RemuxError(message: writer.error?.localizedDescription ?? "写入样本失败")
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed else {
            try? fm.removeItem(at: destination)
            throw RemuxError(message: writer.error?.localizedDescription ?? "写出文件失败")
        }
    }

    /// HLS 资产用 load(.tracks) 会返回空数组，必须先用 AVPlayerItem 预热到 readyToPlay
    private static func loadTracks(asset: AVURLAsset, timeout: TimeInterval = 15) async -> [AVAssetTrack] {
        if let tracks = try? await asset.load(.tracks), !tracks.isEmpty {
            return tracks
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if item.status == .readyToPlay {
                let tracks = item.tracks.compactMap { $0.assetTrack }
                player.pause()
                if !tracks.isEmpty { return tracks }
                break
            }
            if item.status == .failed {
                DiagnosticsLog.write("[转MP4] 预热失败：\(item.error?.localizedDescription ?? "未知")")
                player.pause()
                return []
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        player.pause()

        // 预热后仍未拿到，尝试再次同步读取
        if let tracks = try? await asset.load(.tracks), !tracks.isEmpty {
            return tracks
        }
        return []
    }

    /// 把样本时间从"源起点"平移到 0，避免成片开头出现空白
    private static func retimed(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sample }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sample }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        let status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        guard status == noErr else { return sample }

        for index in 0..<count {
            if infos[index].presentationTimeStamp.isValid {
                infos[index].presentationTimeStamp = CMTimeSubtract(infos[index].presentationTimeStamp, offset)
            }
            if infos[index].decodeTimeStamp.isValid {
                infos[index].decodeTimeStamp = CMTimeSubtract(infos[index].decodeTimeStamp, offset)
            }
        }

        var output: CMSampleBuffer?
        let result = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sample,
                                                           sampleTimingEntryCount: count,
                                                           sampleTimingArray: &infos,
                                                           sampleBufferOut: &output)
        return result == noErr ? output : sample
    }
}
