import Foundation
import AVFoundation
import CoreMedia

/// TS 解复用后，用 AVAssetWriter 封装为 MP4（容器由系统生成，必定合规）
enum AVRemuxPipeline {
    struct RemuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func remux(state: SegmentJobState,
                      dir: URL,
                      destination: URL,
                      onProgress: ((Double) -> Void)? = nil,
                      videoOnly: Bool = false) async throws {
        try await Task.detached(priority: .userInitiated) {
            try run(state: state, dir: dir, destination: destination, progress: onProgress, videoOnly: videoOnly)
        }.value
    }

    // swiftlint:disable:next function_body_length
    private static func run(state: SegmentJobState,
                            dir: URL,
                            destination: URL,
                            progress: ((Double) -> Void)?,
                            videoOnly: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let demuxer = TSDemuxer()
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var videoFormat: CMFormatDescription?
        var audioFormat: CMFormatDescription?

        var videoOffset: Int64 = -1
        var lastVideoDTS: Int64 = -1
        var dtsAdjustCount = 0
        var pendingVideo: (data: Data, pts: Int64, dts: Int64, isKey: Bool)?
        var pendingVideoDuration: Int64 = 3000

        var audioOffset: Int64 = -1
        var audioRate = 44100
        var pendingAudio: [Data] = []
        var audioFrameIndex: Int64 = 0

        var failure: String?
        var videoFrames = 0
        var audioFrames = 0
        var currentVideoInfo: TSDemuxer.VideoInfo?
        var probeFrames: [(data: Data, pts: Int64, dts: Int64)] = []

        func ensureWriter(video info: TSDemuxer.VideoInfo) throws -> AVAssetWriter {
            if let writer { return writer }

            var videoDesc: CMFormatDescription?
            let status: OSStatus = info.sps.withUnsafeBytes { spsBuffer -> OSStatus in
                info.pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                    guard let spsPtr = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let ppsPtr = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return OSStatus(-1)
                    }
                    let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                    let sizes: [Int] = [info.sps.count, info.pps.count]
                    return pointers.withUnsafeBufferPointer { ptrBuffer -> OSStatus in
                        sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: ptrBuffer.baseAddress!,
                                parameterSetSizes: sizeBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &videoDesc
                            )
                        }
                    }
                }
            }

            DiagnosticsLog.write("[转MP4] 视频参数 \(info.width)x\(info.height) SPS=\(info.sps.count)B PPS=\(info.pps.count)B profile=\(info.profileLevel.0) level=\(info.profileLevel.1) 格式描述=\(status == noErr ? "ok" : "失败(\(status))")")
            guard status == noErr, let videoDesc else {
                throw RemuxError(message: "创建视频格式描述失败（\(status)）")
            }

            let newWriter = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            newWriter.shouldOptimizeForNetworkUse = false

            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoDesc)
            vInput.expectsMediaDataInRealTime = false
            guard newWriter.canAdd(vInput) else {
                throw RemuxError(message: "无法添加视频轨")
            }
            newWriter.add(vInput)

            if let audio = demuxer.audioInfo(), !videoOnly {
                var asbd = AudioStreamBasicDescription(
                    mSampleRate: Float64(audio.sampleRate),
                    mFormatID: kAudioFormatMPEG4AAC,
                    mFormatFlags: 2,   // AAC-LC（kMPEG4Object_AAC_LC 未在 Swift 中导出）
                    mBytesPerPacket: 0,
                    mFramesPerPacket: 1024,
                    mBytesPerFrame: 0,
                    mChannelsPerFrame: UInt32(max(1, audio.channels)),
                    mBitsPerChannel: 0,
                    mReserved: 0
                )
                var audioDesc: CMFormatDescription?
                let asc = audio.audioSpecificConfig
                let audioStatus = asc.withUnsafeBytes { buffer -> OSStatus in
                    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                   asbd: &asbd,
                                                   layoutSize: 0,
                                                   layout: nil,
                                                   magicCookieSize: asc.count,
                                                   magicCookie: buffer.baseAddress,
                                                   extensions: nil,
                                                   formatDescriptionOut: &audioDesc)
                }
                if audioStatus == noErr, let audioDesc {
                    let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioDesc)
                    aInput.expectsMediaDataInRealTime = false
                    if newWriter.canAdd(aInput) {
                        newWriter.add(aInput)
                        audioInput = aInput
                        audioFormat = audioDesc
                        audioRate = audio.sampleRate
                    }
                }
            }

            guard newWriter.startWriting() else {
                throw RemuxError(message: newWriter.error?.localizedDescription ?? "无法开始写入")
            }
            newWriter.startSession(atSourceTime: .zero)

            writer = newWriter
            videoInput = vInput
            videoFormat = videoDesc

            // 补写 writer 创建前到达的音频帧（保持索引连续）
            if audioInput != nil, !pendingAudio.isEmpty {
                for data in pendingAudio {
                    appendAudioSample(data: data,
                                      format: audioFormat!,
                                      input: audioInput!,
                                      index: audioFrameIndex,
                                      rate: audioRate,
                                      offset: 0,
                                      basePTS: 0) { message in
                        if failure == nil { failure = message }
                    }
                    audioFrameIndex += 1
                }
                pendingAudio.removeAll()
            }
            return newWriter
        }

        /// 校验 AVCC：每个 4 字节长度前缀都必须与实际数据吻合
        func validateAVCC(_ data: Data) -> Bool {
            var offset = 0
            while offset + 4 <= data.count {
                let length = (Int(data[data.startIndex + offset]) << 24)
                    | (Int(data[data.startIndex + offset + 1]) << 16)
                    | (Int(data[data.startIndex + offset + 2]) << 8)
                    | Int(data[data.startIndex + offset + 3])
                guard length > 0, offset + 4 + length <= data.count else { return false }
                offset += 4 + length
            }
            return offset == data.count
        }

        func appendVideoSample(_ sample: (data: Data, pts: Int64, dts: Int64, isKey: Bool), duration: Int64) {
            guard let input = videoInput, let format = videoFormat, var writer else { return }

            if !validateAVCC(sample.data) {
                let head = sample.data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                DiagnosticsLog.write("[转MP4] 跳过非法样本（第 \(videoFrames + 1) 帧）大小=\(sample.data.count)B 头=\(head)")
                return
            }

            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let buffer = makeSampleBuffer(data: sample.data,
                                                format: format,
                                                pts: sample.pts,
                                                dts: sample.dts,
                                                duration: duration,
                                                timescale: 90000) else {
                failure = "创建视频样本失败"
                return
            }
            if !input.append(buffer) {
                // append 返回 false 多数是"此刻不接受"，等待重试；只有 writer 真正失败才终止
                var appended = false
                for _ in 0..<300 {
                    if writer.status == .failed { break }
                    Thread.sleep(forTimeInterval: 0.01)
                    if input.append(buffer) {
                        appended = true
                        break
                    }
                }
                if !appended {
                    let error = writer.error as NSError?
                    if currentVideoInfo != nil {
                        DiagnosticsLog.write("[转MP4] 顺序解码前 \(probeFrames.count) 帧：\(H264Probe.decodeSequence(frames: probeFrames, info: currentVideoInfo!))")
                    }
                    failure = "追加视频样本失败（第 \(videoFrames + 1) 帧，PTS=\(sample.pts) DTS=\(sample.dts) 大小=\(sample.data.count)B，writer状态=\(writer.status.rawValue)）：\(error?.domain ?? "-") \(error?.code ?? 0) \(error?.localizedDescription ?? "")"
                }
            }
            videoFrames += 1
        }

        demuxer.onInfo = { _, _ in }

        demuxer.onVideoFrame = { data, pts, dts, isKey in
            guard failure == nil else { return }
            guard let info = demuxer.videoInfo() else { return }
            do {
                _ = try ensureWriter(video: info)
                currentVideoInfo = info
            } catch {
                failure = error.localizedDescription
                return
            }

            if videoFrames == 0 && pendingVideo == nil {
                DiagnosticsLog.write("[转MP4] 首帧探测 \(H264Probe.decodeFirstFrame(avcc: data, info: info))")
            }

            if videoOffset < 0 {
                videoOffset = dts >= 0 ? dts : max(0, pts)
            }
            var normalizedDTS = max(0, (dts >= 0 ? dts : pts) - videoOffset)
            // 源流个别 PES 时间戳异常（DTS 倒退），AVAssetWriter 要求 DTS 单调递增：
            // 数据本身合法（顺序解码全 OK），这里只校正时间戳，不改动样本内容
            if normalizedDTS <= lastVideoDTS {
                normalizedDTS = lastVideoDTS + 3750
                dtsAdjustCount += 1
            }
            lastVideoDTS = normalizedDTS
            // B 帧的 PTS 本来就小于 DTS（解码序 vs 显示序），不能钳位——否则合成时序被破坏
            let normalizedPTS = max(0, (pts >= 0 ? pts : dts) - videoOffset)

            if let previous = pendingVideo {
                let delta = max(1, normalizedDTS - previous.dts)
                appendVideoSample(previous, duration: delta)
                pendingVideoDuration = delta
            }
            pendingVideo = (data, normalizedPTS, normalizedDTS, isKey)
            if probeFrames.count < 12 {
                probeFrames.append((data, normalizedPTS, normalizedDTS))
            }
            lastVideoDTS = normalizedDTS
        }

        demuxer.onAudioFrame = { data, pts in
            guard failure == nil, let input = audioInput, let format = audioFormat else {
                pendingAudio.append(data)
                return
            }
            if audioOffset < 0 {
                audioOffset = pts >= 0 ? pts : 0
            }
            appendAudioSample(data: data,
                              format: format,
                              input: input,
                              index: audioFrameIndex,
                              rate: audioRate,
                              offset: audioOffset,
                              basePTS: pts) { message in
                if failure == nil { failure = message }
            }
            audioFrameIndex += 1
        }

        // 顺序读取分片
        let total = max(1, state.segmentURLs.count)
        for index in state.durations.indices {
            if failure != nil { break }
            let fileURL = dir.appendingPathComponent(LocalHLS.fileName(index: index))
            guard fm.fileExists(atPath: fileURL.path) else {
                throw RemuxError(message: "缺少分片 \(index + 1)")
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                demuxer.consume(chunk)
                if failure != nil { break }
            }
            try? handle.close()
            progress?(Double(index + 1) / Double(total))
        }
        demuxer.finish()

        if let failure {
            writer?.cancelWriting()
            try? fm.removeItem(at: destination)
            throw RemuxError(message: "转封装失败：\(failure)")
        }
        guard let writer else {
            throw RemuxError(message: "转封装失败：没有解析出视频轨道")
        }
        guard videoInput != nil, videoFrames > 0 || pendingVideo != nil else {
            writer.cancelWriting()
            try? fm.removeItem(at: destination)
            throw RemuxError(message: "转封装失败：没有可写入的视频帧")
        }

        if let pending = pendingVideo {
            appendVideoSample(pending, duration: pendingVideoDuration)
        }
        if let input = videoInput {
            input.markAsFinished()
        }
        if let input = audioInput {
            input.markAsFinished()
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 300)

        guard writer.status == .completed else {
            try? fm.removeItem(at: destination)
            throw RemuxError(message: writer.error?.localizedDescription ?? "写出失败")
        }
        DiagnosticsLog.write("[转MP4] AVAssetWriter 封装完成 视频帧=\(videoFrames) 音频帧=\(audioFrameIndex) DTS校正=\(dtsAdjustCount)次")
    }

    // MARK: - 样本构造

    private static func makeSampleBuffer(data: Data,
                                         format: CMFormatDescription,
                                         pts: Int64,
                                         dts: Int64,
                                         duration: Int64,
                                         timescale: Int32) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: data.count,
                                                 flags: 0,
                                                 blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return nil }

        let copied = data.withUnsafeBytes { buffer -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: duration, timescale: timescale),
                                        presentationTimeStamp: CMTime(value: pts, timescale: timescale),
                                        decodeTimeStamp: CMTime(value: dts, timescale: timescale))
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                          dataBuffer: blockBuffer,
                                          dataReady: true,
                                          makeDataReadyCallback: nil,
                                          refcon: nil,
                                          formatDescription: format,
                                          sampleCount: 1,
                                          sampleTimingEntryCount: 1,
                                          sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 1,
                                          sampleSizeArray: &sampleSize,
                                          sampleBufferOut: &sampleBuffer)
        return status == noErr ? sampleBuffer : nil
    }

    private static func appendAudioSample(data: Data,
                                          format: CMFormatDescription,
                                          input: AVAssetWriterInput,
                                          index: Int64,
                                          rate: Int,
                                          offset: Int64,
                                          basePTS: Int64,
                                          onError: (String) -> Void) {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let buffer = makeSampleBuffer(data: data,
                                            format: format,
                                            pts: index * 1024,
                                            dts: index * 1024,
                                            duration: 1024,
                                            timescale: Int32(max(8000, rate))) else {
            onError("创建音频样本失败")
            return
        }
        var appended = false
        for _ in 0..<300 {
            if input.append(buffer) {
                appended = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if !appended {
            onError("追加音频样本失败")
        }
    }
}
