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

        // 时间轴重建：源 DTS 大量倒退，按 CFR 网格重建（帧间隔取原始 DTS 差值的中位数）
        var outputIndex: Int64 = 0
        var frameStep: Int64 = 3750
        var lastDeltaSamples: [Int64] = []
        var rawDTS: Int64 = -1
        var videoBuffer: [(data: Data, isKey: Bool)] = []
        var pendingVideo: (data: Data, isKey: Bool)?

        var audioRate = 44100
        var pendingAudio: [Data] = []
        var audioFrameIndex: Int64 = 0

        var failure: String?
        var videoFrames = 0
        var audioFrames = 0
        var currentVideoInfo: TSDemuxer.VideoInfo?

        func ensureWriter(video info: TSDemuxer.VideoInfo, force: Bool) throws -> AVAssetWriter? {
            if let writer { return writer }
            // 音频参数未就绪时不急着创建（等音频轨能加入），除非强制或缓冲够多
            if !force, !videoOnly, demuxer.audioInfo() == nil, videoBuffer.count < 240 {
                return nil
            }

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
                    appendAudioFrame(data)
                    audioFrames += 1
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

        /// 用 CFR 网格时序追加一帧（pts == dts == outputIndex * frameStep）
        func appendVideoFrame(_ data: Data, isKey: Bool, duration: Int64) {
            guard let input = videoInput, let format = videoFormat, let currentWriter = writer else { return }

            if !validateAVCC(data) {
                let head = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                DiagnosticsLog.write("[转MP4] 跳过非法样本（第 \(videoFrames + 1) 帧）大小=\(data.count)B 头=\(head)")
                outputIndex += 1
                return
            }

            let gridTime = outputIndex * frameStep
            // 就绪等待必须有上限：多轨 writer 会按整体进度节流各输入，
            // 单线程里无限等待会与另一轨的追加形成死锁
            var waited: TimeInterval = 0
            while !input.isReadyForMoreMediaData, waited < 2.0 {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 0.005
            }
            if videoFrames % 1000 == 0, videoFrames > 0 {
                DiagnosticsLog.write("[转MP4] 进度 已写 \(videoFrames) 帧（缓冲 \(videoBuffer.count)）")
            }
            guard let buffer = makeSampleBuffer(data: data,
                                                format: format,
                                                pts: gridTime,
                                                dts: gridTime,
                                                duration: duration,
                                                timescale: 90000) else {
                failure = "创建视频样本失败"
                return
            }
            // appendSampleBuffer 遇到 kCMTimeInvalid 会抛 ObjC 异常（闪退），写入前先自检
            if !CMSampleBufferIsValid(buffer)
                || !CMSampleBufferGetDecodeTimeStamp(buffer).isValid
                || !CMSampleBufferGetPresentationTimeStamp(buffer).isValid
                || !CMSampleBufferGetDuration(buffer).isValid {
                DiagnosticsLog.write("[转MP4] 跳过无效时间样本（第 \(videoFrames + 1) 帧）grid=\(gridTime)")
                outputIndex += 1
                videoFrames += 1
                return
            }
            var appended = false
            for _ in 0..<300 {
                if currentWriter.status == .failed { break }
                if input.append(buffer) {
                    appended = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if !appended {
                // writer 已失败才终止；否则视为暂时性拒绝，丢弃该帧继续（避免整体卡死）
                if currentWriter.status == .failed {
                    let error = currentWriter.error as NSError?
                    failure = "追加视频样本失败（第 \(videoFrames + 1) 帧，writer状态=\(currentWriter.status.rawValue)）：\(error?.domain ?? "-") \(error?.code ?? 0) \(error?.localizedDescription ?? "")"
                } else {
                    DiagnosticsLog.write("[转MP4] 跳过追加失败帧（第 \(videoFrames + 1) 帧）")
                }
            }
            videoFrames += 1
            outputIndex += 1
        }

        func appendAudioFrame(_ data: Data) {
            guard let input = audioInput, let format = audioFormat else { return }
            var waited: TimeInterval = 0
            while !input.isReadyForMoreMediaData, waited < 2.0 {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 0.005
            }
            guard let buffer = makeSampleBuffer(data: data,
                                                format: format,
                                                pts: audioFrameIndex * 1024,
                                                dts: audioFrameIndex * 1024,
                                                duration: 1024,
                                                timescale: Int32(max(8000, audioRate))) else {
                if failure == nil { failure = "创建音频样本失败" }
                return
            }
            if !CMSampleBufferIsValid(buffer)
                || !CMSampleBufferGetDecodeTimeStamp(buffer).isValid
                || !CMSampleBufferGetPresentationTimeStamp(buffer).isValid
                || !CMSampleBufferGetDuration(buffer).isValid {
                DiagnosticsLog.write("[转MP4] 跳过无效时间音频样本（第 \(audioFrameIndex + 1) 帧）")
                audioFrameIndex += 1
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
                if writer?.status == .failed, failure == nil {
                    failure = "追加音频样本失败（writer 已失败）"
                } else {
                    DiagnosticsLog.write("[转MP4] 跳过追加失败音频帧（第 \(audioFrameIndex + 1) 帧）")
                }
            }
            audioFrameIndex += 1
        }

        demuxer.onInfo = { _, _ in }

        demuxer.onVideoFrame = { data, pts, dts, isKey in
            guard failure == nil else { return }
            guard let info = demuxer.videoInfo() else { return }
            currentVideoInfo = info

            // 学习帧间隔（原始 DTS 差值的中位数，抗异常值）
            if rawDTS >= 0 {
                let delta = dts - rawDTS
                if delta > 0, delta < 90000 {
                    lastDeltaSamples.append(delta)
                    if lastDeltaSamples.count > 50 { lastDeltaSamples.removeFirst() }
                    let sorted = lastDeltaSamples.sorted()
                    frameStep = max(1, sorted[sorted.count / 2])
                }
            }
            rawDTS = dts

            if videoFrames == 0 && videoBuffer.isEmpty && pendingVideo == nil {
                DiagnosticsLog.write("[转MP4] 首帧探测 \(H264Probe.decodeFirstFrame(avcc: data, info: info))")
            }

            do {
                _ = try ensureWriter(video: info, force: false)
            } catch {
                failure = error.localizedDescription
                return
            }

            if writer != nil {
                // writer 刚创建时，先把缓冲的视频帧按序补写
                if !videoBuffer.isEmpty {
                    for buffered in videoBuffer {
                        appendVideoFrame(buffered.data, isKey: buffered.isKey, duration: frameStep)
                        if failure != nil { return }
                    }
                    videoBuffer.removeAll()
                }
                if let previous = pendingVideo {
                    appendVideoFrame(previous.data, isKey: previous.isKey, duration: frameStep)
                    if failure != nil { return }
                }
                pendingVideo = (data, isKey)
            } else {
                videoBuffer.append((data, isKey))
            }
        }

        demuxer.onAudioFrame = { data, _ in
            guard failure == nil else { return }
            if let input = audioInput {
                appendAudioFrame(data)
                audioFrames += 1
            } else {
                pendingAudio.append(data)
                // 音频输入创建失败时缓冲会无限增长，设置上限
                if pendingAudio.count > 8000 {
                    pendingAudio.removeFirst(4000)
                    DiagnosticsLog.write("[转MP4] 音频缓冲超限，丢弃早期 \(4000) 帧")
                }
                // 视频参数未就绪时无法创建 writer（需要 avcC），继续缓冲音频
                guard demuxer.videoInfo() != nil else { return }
                do {
                    _ = try ensureWriter(video: demuxer.videoInfo()!, force: false)
                } catch {
                    if failure == nil { failure = error.localizedDescription }
                }
                if let input = audioInput {
                    for buffered in pendingAudio {
                        appendAudioFrame(buffered)
                        audioFrames += 1
                    }
                    pendingAudio.removeAll()
                }
            }
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
            // 第一个分片结束后仍无音频参数 → 强制创建（纯视频源或缓冲超限）
            if index == 0, writer == nil, failure == nil {
                do {
                    _ = try ensureWriter(video: demuxer.videoInfo() ?? currentVideoInfo
                        ?? TSDemuxer.VideoInfo(width: 0, height: 0, sps: Data(), pps: Data(), profileLevel: (0, 0)),
                        force: true)
                    if writer != nil {
                        for buffered in videoBuffer {
                            appendVideoFrame(buffered.data, isKey: buffered.isKey, duration: frameStep)
                        }
                        videoBuffer.removeAll()
                    }
                } catch {
                    if failure == nil { failure = error.localizedDescription }
                }
            }
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
        guard videoInput != nil else {
            writer.cancelWriting()
            try? fm.removeItem(at: destination)
            throw RemuxError(message: "转封装失败：没有可写入的视频帧")
        }

        if let pending = pendingVideo {
            appendVideoFrame(pending.data, isKey: pending.isKey, duration: frameStep)
        }
        // 补写仍缓冲的视频帧（音频参数始终未就绪的极端情况）
        if writer.status == .writing, !videoBuffer.isEmpty {
            for buffered in videoBuffer {
                appendVideoFrame(buffered.data, isKey: buffered.isKey, duration: frameStep)
            }
            videoBuffer.removeAll()
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
        DiagnosticsLog.write("[转MP4] AVAssetWriter 封装完成 视频帧=\(videoFrames) 音频帧=\(audioFrames) 帧间隔=\(frameStep)ticks")
    }

    // MARK: - 样本构造

    private static func makeSampleBuffer(data: Data,
                                         format: CMFormatDescription,
                                         pts: Int64,
                                         dts: Int64,
                                         duration: Int64,
                                         timescale: Int32) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }
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
