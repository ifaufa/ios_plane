import Foundation
import AVFoundation
import CoreMedia

/// 自研 TS 解复用 → AVAssetWriter 封装 MP4
/// 关键设计：
/// 1) 显示顺序由 slice_type（I/P/B）推导，不依赖可疑的 PES 时间戳
/// 2) writer 等到"视频+音频参数都就绪"再创建，保证音轨存在
/// 3) 所有就绪等待有上限，避免多轨死锁；不在单线程做大批量冲刷
enum AVRemuxPipeline {
    struct RemuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Frame {
        let data: Data
        let isKey: Bool
        let pts: Int64
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
        var audioRate = 44100

        // 帧间隔（仅用于时间轴刻度，不用于帧位置）
        var frameStep: Int64 = 3750
        var deltaSamples: [Int64] = []
        var lastRawDTS: Int64 = -1

        // 显示顺序重建（解码序分组：[参考帧, 其后引用它的 B 帧...]）
        var group: [Frame] = []
        var displayCursor: Int64 = 0
        var decodeSeq: Int64 = 0
        var waitingWrites: [Frame] = []
        var displayOrderSamples: [String] = []

        var pendingAudio: [Data] = []
        var audioFrameIndex: Int64 = 0
        var failure: String?
        var videoFrames = 0

        func appendFrame(_ frame: Frame) {
            guard let input = videoInput, let format = videoFormat, let currentWriter = writer else {
                waitingWrites.append(frame)
                return
            }
            var waited: TimeInterval = 0
            while !input.isReadyForMoreMediaData, waited < 1.0 {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 0.005
            }
            let dts = decodeSeq * frameStep
            guard let buffer = makeSampleBuffer(data: frame.data,
                                                format: format,
                                                pts: frame.pts * frameStep,
                                                dts: dts,
                                                duration: frameStep,
                                                timescale: 90000) else {
                failure = "创建视频样本失败"
                return
            }
            var appended = false
            for _ in 0..<200 {
                if currentWriter.status == .failed { break }
                if input.append(buffer) {
                    appended = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if !appended, currentWriter.status == .failed {
                let error = currentWriter.error as NSError?
                failure = "追加视频样本失败（第 \(videoFrames + 1) 帧）：\(error?.domain ?? "-") \(error?.code ?? 0) \(error?.localizedDescription ?? "")"
            }
            videoFrames += 1
            decodeSeq += 1
        }

        /// 一组结束：组内 B 帧先显示，参考帧最后显示；按解码序追加
        func finalizeGroup() {
            guard !group.isEmpty else { return }
            var ptsFor = [Int64](repeating: 0, count: group.count)
            if group.count > 1 {
                for index in 1..<group.count {
                    ptsFor[index] = displayCursor
                    displayCursor += 1
                }
            }
            ptsFor[0] = displayCursor
            displayCursor += 1

            if displayOrderSamples.count < 8 {
                displayOrderSamples.append("[\(group.count)帧 pts=\(ptsFor)]")
            }
            for (index, frame) in group.enumerated() {
                appendFrame(Frame(data: frame.data, isKey: frame.isKey, pts: ptsFor[index]))
                if failure != nil { break }
            }
            group.removeAll()
        }

        func appendAudio(_ data: Data) {
            guard let input = audioInput, let format = audioFormat else { return }
            var waited: TimeInterval = 0
            while !input.isReadyForMoreMediaData, waited < 1.0 {
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
            var appended = false
            for _ in 0..<200 {
                if input.append(buffer) {
                    appended = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if !appended, writer?.status == .failed, failure == nil {
                failure = "追加音频样本失败（writer 已失败）"
            }
            audioFrameIndex += 1
        }

        func createWriter(force: Bool) throws {
            guard writer == nil else { return }
            guard let info = demuxer.videoInfo() else { return }
            let audioInfo = videoOnly ? nil : demuxer.audioInfo()
            // 音频参数未就绪时等待（最多约 30 帧），避免音轨缺失
            if !force, audioInfo == nil, waitingWrites.count < 30 { return }

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
            DiagnosticsLog.write("[转MP4] 视频参数 \(info.width)x\(info.height) SPS=\(info.sps.count)B PPS=\(info.pps.count)B profile=\(info.profileLevel.0) 格式描述=\(status == noErr ? "ok" : "失败(\(status))")")
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

            if let audio = audioInfo {
                var asbd = AudioStreamBasicDescription(
                    mSampleRate: Float64(audio.sampleRate),
                    mFormatID: kAudioFormatMPEG4AAC,
                    mFormatFlags: 2,
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

            if !waitingWrites.isEmpty {
                let buffered = waitingWrites
                waitingWrites.removeAll()
                for frame in buffered {
                    appendFrame(frame)
                    if failure != nil { return }
                }
            }
            if audioInput != nil, !pendingAudio.isEmpty {
                for data in pendingAudio {
                    appendAudio(data)
                }
                pendingAudio.removeAll()
            }
            DiagnosticsLog.write("[转MP4] writer 创建完成 视频输入=1 音频输入=\(audioInput == nil ? 0 : 1)")
        }

        demuxer.onInfo = { _, _ in }

        demuxer.onVideoFrame = { data, pts, dts, isKey, isRef in
            guard failure == nil else { return }

            // 帧间隔学习（只取正向合理差值的中位数）
            if lastRawDTS >= 0 {
                let delta = dts - lastRawDTS
                if delta > 0, delta < 90000 {
                    deltaSamples.append(delta)
                    if deltaSamples.count > 60 { deltaSamples.removeFirst() }
                    let sorted = deltaSamples.sorted()
                    frameStep = max(1, sorted[sorted.count / 2])
                }
            }
            lastRawDTS = dts

            if isRef {
                finalizeGroup()
                group.append(Frame(data: data, isKey: isKey, pts: 0))
            } else {
                group.append(Frame(data: data, isKey: isKey, pts: 0))
            }

            if writer == nil {
                do {
                    try createWriter(force: false)
                } catch {
                    failure = error.localizedDescription
                }
            }
        }

        demuxer.onAudioFrame = { data, _ in
            guard failure == nil, !videoOnly else { return }
            if audioInput != nil {
                appendAudio(data)
            } else {
                pendingAudio.append(data)
                if pendingAudio.count > 6000 { pendingAudio.removeFirst(3000) }
                if demuxer.videoInfo() != nil {
                    do {
                        try createWriter(force: false)
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
        }

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
            // 第一个分片结束后仍无音频 → 按纯视频处理
            if index == 0, writer == nil, failure == nil {
                do {
                    try createWriter(force: true)
                } catch {
                    failure = error.localizedDescription
                }
            }
            progress?(Double(index + 1) / Double(total))
        }
        demuxer.finish()
        finalizeGroup()

        if let failure {
            writer?.cancelWriting()
            try? fm.removeItem(at: destination)
            throw RemuxError(message: "转封装失败：\(failure)")
        }
        guard let writer, videoInput != nil else {
            throw RemuxError(message: "转封装失败：没有可写入的视频帧")
        }
        if !waitingWrites.isEmpty {
            let buffered = waitingWrites
            waitingWrites.removeAll()
            for frame in buffered {
                appendFrame(frame)
            }
        }
        DiagnosticsLog.write("[转MP4] 显示顺序样例 \(displayOrderSamples.joined(separator: " "))")

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 300)

        guard writer.status == .completed else {
            try? fm.removeItem(at: destination)
            throw RemuxError(message: writer.error?.localizedDescription ?? "写出失败")
        }
        DiagnosticsLog.write("[转MP4] 封装完成 视频帧=\(videoFrames) 音频帧=\(audioFrameIndex) 帧间隔=\(frameStep)")
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
}
