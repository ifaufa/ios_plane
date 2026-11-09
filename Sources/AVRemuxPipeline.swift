import Foundation
import AVFoundation
import CoreMedia

/// 自研 TS 解复用 → AVAssetWriter 封装 MP4
/// 写入模型：解复用线程投递到有界队列，writer 通过 requestMediaDataWhenReady 主动取样本
/// （彻底避免"按帧等待 isReadyForMoreMediaData"导致的极慢与死锁）
enum AVRemuxPipeline {
    struct RemuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 最近一次解析到的音频参数（供容器修补使用）
    static var lastAudioASC: Data?
    static var lastAudioSampleRate: Int = 0
    static var lastAudioChannels: Int = 0

    private struct VideoItem {
        let data: Data
        let pts: Int64
        let dts: Int64
        let isKey: Bool
    }

    private final class ItemQueue<Element> {
        private var items: [Element] = []
        private let condition = NSCondition()
        private let capacity: Int
        private var finished = false

        init(capacity: Int) { self.capacity = capacity }

        func push(_ item: Element) {
            condition.lock()
            while items.count >= capacity, !finished {
                condition.wait(until: Date().addingTimeInterval(0.2))
            }
            items.append(item)
            condition.signal()
            condition.unlock()
        }

        func pop(waitSeconds: TimeInterval) -> Element? {
            condition.lock()
            defer { condition.unlock() }
            if items.isEmpty {
                let deadline = Date().addingTimeInterval(waitSeconds)
                while items.isEmpty, !finished {
                    if !condition.wait(until: deadline) { break }
                }
            }
            return items.isEmpty ? nil : items.removeFirst()
        }

        var isFinished: Bool {
            condition.lock()
            defer { condition.unlock() }
            return finished && items.isEmpty
        }

        func finish() {
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private static func run(state: SegmentJobState,
                            dir: URL,
                            destination: URL,
                            progress: ((Double) -> Void)?,
                            videoOnly: Bool,
                            audioFormatFlags: UInt32) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let demuxer = TSDemuxer()
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var audioRate = 44100

        let videoQueue = ItemQueue<VideoItem>(capacity: 300)
        let audioQueue = ItemQueue<Data>(capacity: 2000)
        let pumpQueue = DispatchQueue(label: "remux.pump", qos: .userInitiated)
        let doneGroup = DispatchGroup()
        let lock = NSLock()
        var failure: String?
        var videoFrames = 0
        var audioFrameIndex: Int64 = 0

        // 时间轴
        var frameStep: Int64 = 3750
        var deltaSamples: [Int64] = []
        var lastRawDTS: Int64 = -1
        var group: [Data] = []
        var groupKeys: [Bool] = []
        var displayCursor: Int64 = 0
        var decodeCursor: Int64 = 0
        var pushedBeforeWriter = 0

        func setFailure(_ message: String) {
            lock.lock()
            if failure == nil { failure = message }
            lock.unlock()
        }

        func currentFailure() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        func finalizeGroup() {
            guard !group.isEmpty else { return }
            let count = group.count
            var ptsByIndex = [Int64](repeating: 0, count: count)
            if count > 1 {
                for index in 1..<count {
                    ptsByIndex[index] = displayCursor
                    displayCursor += 1
                }
            }
            ptsByIndex[0] = displayCursor
            displayCursor += 1

            for index in 0..<count {
                let item = VideoItem(data: group[index],
                                     pts: ptsByIndex[index] * frameStep,
                                     dts: decodeCursor * frameStep,
                                     isKey: groupKeys[index])
                decodeCursor += 1
                videoQueue.push(item)
            }
            group.removeAll()
            groupKeys.removeAll()
            if currentFailure() != nil { videoQueue.finish(); return }
            // 音频参数迟迟未就绪时，缓冲到一定量就强制创建（纯视频源兜底）
            if writer == nil {
                pushedBeforeWriter += count
                if pushedBeforeWriter >= 200 {
                    do { try makeWriterIfNeeded(force: true) } catch { setFailure(error.localizedDescription) }
                }
            }
        }

        func makeWriterIfNeeded(force: Bool) throws {
            guard writer == nil else { return }
            guard let info = demuxer.videoInfo() else { return }
            let audioInfo = videoOnly ? nil : demuxer.audioInfo()
            if !force, audioInfo == nil {
                // 音频参数未就绪：视频帧继续在队列中缓冲，等音频就绪再创建 writer
                return
            }
            // 音频参数未就绪时先不创建 writer（保证音轨可用），除非强制

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
            vInput.mediaTimeScale = 90000
            guard newWriter.canAdd(vInput) else { throw RemuxError(message: "无法添加视频轨") }
            newWriter.add(vInput)

            var aInput: AVAssetWriterInput?
            var aDesc: CMFormatDescription?
            if let audio = audioInfo {
                var asbd = AudioStreamBasicDescription(mSampleRate: Float64(audio.sampleRate),
                                                       mFormatID: kAudioFormatMPEG4AAC,
                                                       mFormatFlags: audioFormatFlags,
                                                       mBytesPerPacket: 0,
                                                       mFramesPerPacket: 1024,
                                                       mBytesPerFrame: 0,
                                                       mChannelsPerFrame: UInt32(max(1, audio.channels)),
                                                       mBitsPerChannel: 0,
                                                       mReserved: 0)
                var desc: CMFormatDescription?
                let asc = audio.audioSpecificConfig
                let audioStatus = asc.withUnsafeBytes { buffer -> OSStatus in
                    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                   asbd: &asbd,
                                                   layoutSize: 0,
                                                   layout: nil,
                                                   magicCookieSize: asc.count,
                                                   magicCookie: buffer.baseAddress,
                                                   extensions: nil,
                                                   formatDescriptionOut: &desc)
                }
                // 诊断：打印音频格式描述与 magic cookie，确认 ASC 是否有效
                if let desc {
                    var cookieSize = 0
                    _ = CMAudioFormatDescriptionGetMagicCookie(desc, sizeOut: &cookieSize)
                    let ascHex = asc.map { String(format: "%02x", $0) }.joined(separator: " ")
                    DiagnosticsLog.write("[转MP4] 音频参数 rate=\(audio.sampleRate) ch=\(audio.channels) ASC=\(ascHex)(\(asc.count)B) cookie=\(cookieSize)B status=\(audioStatus)")
                }
                AVRemuxPipeline.lastAudioASC = asc
                AVRemuxPipeline.lastAudioSampleRate = audio.sampleRate
                AVRemuxPipeline.lastAudioChannels = audio.channels
                if audioStatus == noErr, let desc {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: desc)
                    input.expectsMediaDataInRealTime = false
                    input.mediaTimeScale = Int32(max(8000, audio.sampleRate))
                    if newWriter.canAdd(input) {
                        newWriter.add(input)
                        aInput = input
                        aDesc = desc
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
            audioInput = aInput
            DiagnosticsLog.write("[转MP4] writer 创建完成 视频输入=1 音频输入=\(aInput == nil ? 0 : 1)")

            // 视频泵
            var videoPumpFinished = false
            var audioPumpFinished = false
            doneGroup.enter()
            vInput.requestMediaDataWhenReady(on: pumpQueue) {
                while vInput.isReadyForMoreMediaData {
                    guard let item = videoQueue.pop(waitSeconds: 0.5) else {
                        if videoQueue.isFinished, !videoPumpFinished {
                            videoPumpFinished = true
                            vInput.markAsFinished()
                            doneGroup.leave()
                        }
                        return
                    }
                    guard let buffer = makeSampleBuffer(data: item.data,
                                                        format: videoDesc,
                                                        pts: item.pts,
                                                        dts: item.dts,
                                                        duration: frameStep,
                                                        timescale: 90000) else {
                        setFailure("创建视频样本失败")
                        if !videoPumpFinished { videoPumpFinished = true; doneGroup.leave() }
                        vInput.markAsFinished()
                        return
                    }
                    if !vInput.append(buffer) {
                        let error = newWriter.error as NSError?
                        setFailure("追加视频样本失败：\(error?.code ?? 0) \(error?.localizedDescription ?? "")")
                        if !videoPumpFinished { videoPumpFinished = true; doneGroup.leave() }
                        vInput.markAsFinished()
                        return
                    }
                    lock.lock()
                    videoFrames += 1
                    lock.unlock()
                }
            }

            // 音频泵
            if let aInput, let aDesc {
                doneGroup.enter()
                aInput.requestMediaDataWhenReady(on: pumpQueue) {
                    while aInput.isReadyForMoreMediaData {
                        guard let data = audioQueue.pop(waitSeconds: 0.5) else {
                            if audioQueue.isFinished, !audioPumpFinished {
                                audioPumpFinished = true
                                aInput.markAsFinished()
                                doneGroup.leave()
                            }
                            return
                        }
                        let index = audioFrameIndex
                        audioFrameIndex += 1
                        guard let buffer = makeSampleBuffer(data: data,
                                                            format: aDesc,
                                                            pts: index * 1024,
                                                            dts: index * 1024,
                                                            duration: 1024,
                                                            timescale: Int32(max(8000, audioRate))) else {
                            setFailure("创建音频样本失败")
                            if !audioPumpFinished { audioPumpFinished = true; doneGroup.leave() }
                            aInput.markAsFinished()
                            return
                        }
                        if !aInput.append(buffer) {
                            setFailure("追加音频样本失败")
                            if !audioPumpFinished { audioPumpFinished = true; doneGroup.leave() }
                            aInput.markAsFinished()
                            return
                        }
                    }
                }
            }
        }

        demuxer.onInfo = { _, _ in }

        demuxer.onVideoFrame = { data, pts, dts, isKey, isRef in
            guard currentFailure() == nil else { return }

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

            if isRef { finalizeGroup() }
            group.append(data)
            groupKeys.append(isKey)

            if writer == nil {
                do { try makeWriterIfNeeded(force: false) } catch { setFailure(error.localizedDescription) }
            }
        }

        demuxer.onAudioFrame = { data, _ in
            guard currentFailure() == nil, !videoOnly else { return }
            audioQueue.push(data)
            if writer == nil {
                do { try makeWriterIfNeeded(force: false) } catch { setFailure(error.localizedDescription) }
            }
        }

        let total = max(1, state.segmentURLs.count)
        for index in state.durations.indices {
            if currentFailure() != nil { break }
            let fileURL = dir.appendingPathComponent(LocalHLS.fileName(index: index))
            guard fm.fileExists(atPath: fileURL.path) else {
                throw RemuxError(message: "缺少分片 \(index + 1)")
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                demuxer.consume(chunk)
                if currentFailure() != nil { break }
            }
            try? handle.close()
            if index == 0, writer == nil, currentFailure() == nil {
                do { try makeWriterIfNeeded(force: true) } catch { setFailure(error.localizedDescription) }
            }
            progress?(Double(index + 1) / Double(total))
        }
        demuxer.finish()
        finalizeGroup()
        videoQueue.finish()
        audioQueue.finish()

        if let writer {
            _ = doneGroup.wait(timeout: .now() + 600)
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 300)
            if let failure = currentFailure() {
                writer.cancelWriting()
                try? fm.removeItem(at: destination)
                throw RemuxError(message: "转封装失败：\(failure)")
            }
            guard writer.status == .completed else {
                try? fm.removeItem(at: destination)
                throw RemuxError(message: writer.error?.localizedDescription ?? "写出失败")
            }
        } else if let failure = currentFailure() {
            throw RemuxError(message: "转封装失败：\(failure)")
        } else {
            throw RemuxError(message: "转封装失败：没有可写入的视频帧")
        }

        DiagnosticsLog.write("[转MP4] 封装完成 视频帧=\(videoFrames) 音频帧=\(audioFrameIndex) 帧间隔=\(frameStep)")
    }

    static func remux(state: SegmentJobState,
                      dir: URL,
                      destination: URL,
                      onProgress: ((Double) -> Void)? = nil,
                      videoOnly: Bool = false,
                      audioFormatFlags: UInt32 = 2) async throws {
        try await Task.detached(priority: .userInitiated) {
            try run(state: state, dir: dir, destination: destination,
                    progress: onProgress, videoOnly: videoOnly, audioFormatFlags: audioFormatFlags)
        }.value
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
        _ = CMBlockBufferAssureBlockMemory(blockBuffer)

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
