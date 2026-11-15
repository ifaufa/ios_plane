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
    static var collectedAudioFrames: [Data] = []
    /// 音频帧落盘文件（避免全部驻留内存）
    static var lastAudioSpoolURL: URL?
    static var lastAudioFrameSizes: [Int] = []
    /// 关键帧样本序号（0-based），用于补写 stss
    static var lastKeyframeIndices: [Int32] = []
    /// 每个样本的字节数（用于分段合并时重建 stsz）
    static var lastVideoSizes: [Int32] = []
    /// 每个样本的 ctts 偏移（pts - dts，单位 90000）
    static var lastCtts: [Int32] = []
    /// 帧间隔（ticks）
    static var lastFrameStep: Int64 = 3750
    /// 视频参数（分段合并重建 stsd 用）
    static var lastVideoWidth: Int = 0
    static var lastVideoHeight: Int = 0
    static var lastVideoSPS: Data = Data()
    static var lastVideoPPS: Data = Data()
    private static let keyframeLock = NSLock()
    private static let spoolLock = NSLock()
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

        var depth: Int {
            condition.lock()
            defer { condition.unlock() }
            return items.count
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
                            audioFormatFlags: UInt32,
                            collectAudio: Bool,
                            segmentRange: Range<Int>?,
                            resetAudioSpool: Bool,
                            useDirect: Bool = false) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let spooling = collectAudio || useDirect
        var directMuxer: DirectMuxer?
        if useDirect {
            directMuxer = try DirectMuxer(destination: destination)
            DiagnosticsLog.write("[转MP4] 使用自研封装（不经 AVAssetWriter），目标=\(destination.lastPathComponent)")
        }

        let demuxer = TSDemuxer()
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var audioRate = 44100

        var collected: [Data] = []
        var spoolURL: URL?
        var spoolHandle: FileHandle?
        var spoolSizes: [Int] = []
        if spooling {
            if resetAudioSpool {
                if let previous = AVRemuxPipeline.lastAudioSpoolURL { try? FileManager.default.removeItem(at: previous) }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("audio-spool-" + UUID().uuidString + ".aac")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                spoolURL = url
                spoolHandle = try? FileHandle(forWritingTo: url)
                AVRemuxPipeline.lastAudioSpoolURL = url
                AVRemuxPipeline.lastAudioFrameSizes = []
            } else if let existing = AVRemuxPipeline.lastAudioSpoolURL {
                spoolURL = existing
                spoolSizes = AVRemuxPipeline.lastAudioFrameSizes
                spoolHandle = try? FileHandle(forWritingTo: existing)
                try? spoolHandle?.seekToEnd()
            }
        }
        keyframeLock.lock()
        lastKeyframeIndices = []
        lastVideoSizes = []
        lastCtts = []
        keyframeLock.unlock()
        let videoQueue = ItemQueue<VideoItem>(capacity: 300)
        let audioQueue = ItemQueue<Data>(capacity: 2000)
        let pumpQueue = DispatchQueue(label: "remux.pump", qos: .userInitiated)
        let doneGroup = DispatchGroup()
        let lock = NSLock()
        var failure: String?
        var videoFrames = 0
        var writerObservation: NSKeyValueObservation?
        var lastVideoPTS: Int64 = 0
        var lastVideoDTS: Int64 = 0
        var audioFrameIndex: Int64 = 0

        // 时间轴
        var frameStep: Int64 = 3750
        var deltaSamples: [Int64] = []
        var lastRawDTS: Int64 = -1
        struct GopFrame { let data: Data; let isKey: Bool; let poc: Int? }
        var gop: [GopFrame] = []
        var displayCursor: Int64 = 0
        var decodeCursor: Int64 = 0
        var pushedBeforeWriter = 0
        var pocMissing = 0
        var gopCount = 0

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

        /// 一个 GOP 结束：按 POC（码流权威显示顺序）重排后，仍以解码序写入
        func flushGop() {
            guard !gop.isEmpty else { return }
            gopCount += 1
            let count = gop.count
            var ptsByIndex = [Int64](repeating: 0, count: count)
            let pocs = gop.map { $0.poc }
            if pocs.allSatisfy({ $0 != nil }) {
                let order = (0..<count).sorted { (pocs[$0] ?? 0) < (pocs[$1] ?? 0) }
                for (rank, idx) in order.enumerated() {
                    ptsByIndex[idx] = displayCursor + Int64(rank)
                }
            } else {
                pocMissing += count
                for idx in 0..<count { ptsByIndex[idx] = displayCursor + Int64(idx) }
            }
            // 关键：必须在入队前创建 writer。队列容量有限，
            // 若先 push 再等"累计 N 帧才建 writer"，队列填满后 push 永久阻塞（表现为卡在 0%）
            if writer == nil, directMuxer == nil, currentFailure() == nil {
                do { try makeWriterIfNeeded(force: true) } catch { setFailure(error.localizedDescription) }
            }
            for index in 0..<count {
                let item = VideoItem(data: gop[index].data,
                                     pts: ptsByIndex[index] * frameStep,
                                     dts: decodeCursor * frameStep,
                                     isKey: gop[index].isKey)
                decodeCursor += 1
                if let muxer = directMuxer {
                    do {
                        try muxer.appendVideo(data: item.data, isKey: item.isKey, pts: item.pts, dts: item.dts)
                        lock.lock()
                        videoFrames += 1
                        lastVideoPTS = item.pts
                        lastVideoDTS = item.dts
                        lock.unlock()
                    } catch {
                        setFailure("自研封装写入失败：\(error.localizedDescription)")
                        return
                    }
                } else {
                    videoQueue.push(item)
                }
            }
            displayCursor += Int64(count)
            gop.removeAll()
            if currentFailure() != nil { videoQueue.finish() }
            if writer == nil, directMuxer == nil {
                pushedBeforeWriter += count
                if pushedBeforeWriter >= 32 {
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

            let videoWidth = info.width
            let videoHeight = info.height
            let videoSPS = info.sps
            let videoPPS = info.pps

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
                // 直接把完整 esds 通过扩展交给 CoreMedia，避免 AVAssetWriter 只写裸 cookie
                let atoms: [CFString: Any] = ["esds" as CFString: MP4AudioFixer.makeESDS(asc: asc)]
                let extensions: CFDictionary? = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
                let audioStatus = asc.withUnsafeBytes { buffer -> OSStatus in
                    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                   asbd: &asbd,
                                                   layoutSize: 0,
                                                   layout: nil,
                                                   magicCookieSize: asc.count,
                                                   magicCookie: buffer.baseAddress,
                                                   extensions: extensions,
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

            AVRemuxPipeline.lastFrameStep = frameStep
            writer = newWriter
            videoInput = vInput
            audioInput = aInput

            // P1：writer 状态一变失败就立刻记录真实原因（-11800 往往只是"失败状态下再 append"的返回值）
            writerObservation = newWriter.observe(\.status, options: [.new]) { observed, _ in
                guard observed.status == .failed else { return }
                let error = observed.error as NSError?
                lock.lock()
                let frames = videoFrames
                let lastPTS = lastVideoPTS
                let lastDTS = lastVideoDTS
                lock.unlock()
                DiagnosticsLog.write("[转MP4] writer 失败 @已写=\(frames) 域=\(error?.domain ?? "-") 码=\(error?.code ?? 0) 描述=\(error?.localizedDescription ?? "-") info=\(error?.userInfo ?? [:]) 最后样本 pts=\(lastPTS) dts=\(lastDTS)")
            }
            DiagnosticsLog.write("[转MP4] writer 创建完成 视频输入=1 音频输入=\(aInput == nil ? 0 : 1)")

            // 视频泵
            var videoPumpFinished = false
            var audioPumpFinished = false
            doneGroup.enter()
            // 计数器必须跨回调保持（requestMediaDataWhenReady 可能多次回调，放进闭包内会被反复重置）
            var pumpAppended = 0
            var pumpSkippedInvalid = 0
            var pumpSkippedToKeyframe = 0
            var pumpRetries = 0
            var pumpExpectKeyframe = false
            var pumpLoggedIssue = false
            var pumpLastDTS: Int64 = -1
            var pumpLastPTS: Int64 = -1
            var pumpParamStrippedLogged = false
            var pumpOffsetClampedLogged = false
            vInput.requestMediaDataWhenReady(on: pumpQueue) {
                var idleSince: Date?
                while vInput.isReadyForMoreMediaData {
                    guard let item = videoQueue.pop(waitSeconds: 0.2) else {
                        if videoQueue.isFinished {
                            if !videoPumpFinished {
                                videoPumpFinished = true
                                if pumpSkippedInvalid > 0 || pumpSkippedToKeyframe > 0 {
                                    DiagnosticsLog.write("[转MP4] 写入汇总 已写=\(pumpAppended) 跳过非法=\(pumpSkippedInvalid) 对齐跳过=\(pumpSkippedToKeyframe) 重试=\(pumpRetries)")
                                }
                                vInput.markAsFinished()
                                doneGroup.leave()
                            }
                            return
                        }
                        // 关键修复：队列暂时为空但尚未收到结束信号时必须继续等待。
                        // 旧实现直接 return，而 requestMediaDataWhenReady 不会再回调 → 永久死锁（进度停在 96%）
                        if idleSince == nil { idleSince = Date() }
                        if let idleSince, Date().timeIntervalSince(idleSince) > 60 {
                            setFailure("视频泵等待数据超时（队列已空但未收到结束信号）")
                            if !videoPumpFinished { videoPumpFinished = true; doneGroup.leave() }
                            vInput.markAsFinished()
                            return
                        }
                        continue
                    }
                    idleSince = nil

                    // A：起始必须对齐到关键帧，并跳过非法样本（零长/长度前缀不符）
                    if pumpAppended == 0 || pumpExpectKeyframe {
                        guard item.isKey else {
                            pumpSkippedToKeyframe += 1
                            continue
                        }
                        pumpExpectKeyframe = false
                    }
                    // P2：剥离带内 SPS/PPS（MP4 只认 avcC）
                    let sampleData = stripParameterSets(item.data,
                                                       expectedSPS: videoSPS,
                                                       expectedPPS: videoPPS,
                                                       logged: &pumpParamStrippedLogged)
                    guard isValidAVCC(sampleData) else {
                        pumpSkippedInvalid += 1
                        if !pumpLoggedIssue {
                            pumpLoggedIssue = true
                            DiagnosticsLog.write("[转MP4] 跳过非法样本 len=\(sampleData.count) key=\(item.isKey) dts=\(item.dts)")
                        }
                        continue
                    }

                    // P3：异常大的显示偏移（dts - pts 远超 1 帧）会破坏 writer 时序，钳制为 0
                    var samplePTS = item.pts
                    if item.dts > 0, item.dts - samplePTS > frameStep * 8 {
                        samplePTS = item.dts
                        if !pumpOffsetClampedLogged {
                            pumpOffsetClampedLogged = true
                            DiagnosticsLog.write("[转MP4] 显示偏移异常已钳制 dts=\(item.dts) pts=\(item.pts) 帧间隔=\(frameStep)")
                        }
                    }

                    guard let buffer = makeSampleBuffer(data: sampleData,
                                                        format: videoDesc,
                                                        pts: samplePTS,
                                                        dts: item.dts,
                                                        duration: frameStep,
                                                        timescale: 90000,
                                                        isKey: item.isKey) else {
                        setFailure("创建视频样本失败")
                        if !videoPumpFinished { videoPumpFinished = true; doneGroup.leave() }
                        vInput.markAsFinished()
                        return
                    }
                    let sampleIndex = videoFrames
                    if pumpAppended == 0 {
                        DiagnosticsLog.write("[转MP4] 起始样本 长度=\(sampleData.count)B 关键帧=\(item.isKey) dts=\(item.dts) 上一样本DTS=\(pumpLastDTS) 跳过非法=\(pumpSkippedInvalid) 对齐跳过=\(pumpSkippedToKeyframe)")
                    }
                    if !vInput.append(buffer) {
                        let error = newWriter.error as NSError?
                        // B：还没写成功过 → 判定为起始样本异常，跳到下一个关键帧重试（最多 3 次）
                        if pumpAppended == 0, pumpRetries < 3 {
                            pumpRetries += 1
                            pumpExpectKeyframe = true
                            DiagnosticsLog.write("[转MP4] 首样本被拒（\(error?.code ?? 0) \(error?.localizedDescription ?? "")），跳到下一个关键帧重试 第\(pumpRetries)次")
                            continue
                        }
                        DiagnosticsLog.write("[转MP4] 样本写入失败 已写=\(pumpAppended) 失败样本 len=\(item.data.count)B key=\(item.isKey) dts=\(item.dts) prevDTS=\(pumpLastDTS) pts=\(item.pts) status=\(newWriter.status.rawValue) 错误=\(error?.code ?? 0) \(error?.localizedDescription ?? "")")
                        setFailure("追加视频样本失败：\(error?.code ?? 0) \(error?.localizedDescription ?? "")")
                        if !videoPumpFinished { videoPumpFinished = true; doneGroup.leave() }
                        vInput.markAsFinished()
                        return
                    }
                    pumpAppended += 1
                    pumpLastDTS = item.dts
                    keyframeLock.lock()
                    if item.isKey { lastKeyframeIndices.append(Int32(sampleIndex)) }
                    lastVideoSizes.append(Int32(sampleData.count))
                    lastCtts.append(Int32(samplePTS - item.dts))
                    if lastVideoWidth == 0 {
                        lastVideoWidth = videoWidth
                        lastVideoHeight = videoHeight
                        lastVideoSPS = videoSPS
                        lastVideoPPS = videoPPS
                    }
                    keyframeLock.unlock()
                    lock.lock()
                    videoFrames += 1
                    lastVideoPTS = item.pts
                    lastVideoDTS = item.dts
                    lock.unlock()
                }
            }

            // 音频泵
            if let aInput, let aDesc {
                doneGroup.enter()
                aInput.requestMediaDataWhenReady(on: pumpQueue) {
                    var idleSince: Date?
                    while aInput.isReadyForMoreMediaData {
                        guard let data = audioQueue.pop(waitSeconds: 0.2) else {
                            if audioQueue.isFinished {
                                if !audioPumpFinished {
                                    audioPumpFinished = true
                                    aInput.markAsFinished()
                                    doneGroup.leave()
                                }
                                return
                            }
                            if idleSince == nil { idleSince = Date() }
                            if let idleSince, Date().timeIntervalSince(idleSince) > 60 {
                                setFailure("音频泵等待数据超时")
                                if !audioPumpFinished { audioPumpFinished = true; doneGroup.leave() }
                                aInput.markAsFinished()
                                return
                            }
                            continue
                        }
                        idleSince = nil
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

        demuxer.onVideoFrame = { data, pts, dts, isKey, isRef, poc in
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

            if isKey, !gop.isEmpty { flushGop() }
            gop.append(GopFrame(data: data, isKey: isKey, poc: poc))
            if gop.count > 600 { flushGop() }

            if writer == nil, directMuxer == nil {
                do { try makeWriterIfNeeded(force: false) } catch { setFailure(error.localizedDescription) }
            }
        }

        demuxer.onAudioFrame = { data, _ in
            guard currentFailure() == nil else { return }
            // 纯视频模式下也要记录音频参数（自建音轨需要采样率/声道/ASC）
            if let info = demuxer.audioInfo() {
                AVRemuxPipeline.lastAudioASC = info.audioSpecificConfig
                AVRemuxPipeline.lastAudioSampleRate = info.sampleRate
                AVRemuxPipeline.lastAudioChannels = info.channels
            }
            if videoOnly {
                if spooling {
                    spoolLock.lock()
                    try? spoolHandle?.write(contentsOf: data)
                    spoolSizes.append(data.count)
                    spoolLock.unlock()
                }
                return
            }
            audioQueue.push(data)
            if writer == nil, directMuxer == nil {
                do { try makeWriterIfNeeded(force: false) } catch { setFailure(error.localizedDescription) }
            }
        }

        var processedSegments = 0
        var paramChangeLogged = false
        let excludedIndices = Set(state.excluded ?? [])
        let total = max(1, state.segmentURLs.count - excludedIndices.count)
        // 心跳 + 停滞看门狗：卡住时能给出可诊断信息并自动中止
        let heartbeatQueue = DispatchQueue(label: "remux.heartbeat")
        var lastFrameSnapshot = -1
        var lastSegmentSnapshot = -1
        var stallTicks = 0
        let heartbeat = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        heartbeat.schedule(deadline: .now() + 5, repeating: 5)
        heartbeat.setEventHandler {
            lock.lock()
            let frames = videoFrames
            let pts = lastVideoPTS
            let dts = lastVideoDTS
            lock.unlock()

            // 只要帧数不增长就计入停滞（包含 writer 尚未创建的情况）
            if frames == lastFrameSnapshot, processedSegments == lastSegmentSnapshot {
                stallTicks += 1
            } else {
                stallTicks = 0
            }
            lastSegmentSnapshot = processedSegments
            lastFrameSnapshot = frames

            let ready = videoInput?.isReadyForMoreMediaData ?? false
            let status = writer?.status.rawValue ?? -1
            if directMuxer != nil {
                DiagnosticsLog.write("[转MP4] 心跳 段=\(processedSegments) 帧=\(frames) (直写) 停滞=\(stallTicks) \(demuxer.debugBufferSizes()) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
            } else {
                DiagnosticsLog.write("[转MP4] 心跳 段=\(processedSegments) 帧=\(frames) 队列=\(videoQueue.depth) ready=\(ready) status=\(status) 停滞=\(stallTicks) \(demuxer.debugBufferSizes()) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
            }

            // 30 秒无进展：打一次现场，但不中止（可能只是写得慢）
            if stallTicks == 6 {
                let error = (writer?.error as NSError?)?.localizedDescription ?? "-"
                let free = (Self.availableBytes() ?? 0) / (1024 * 1024)
                let memory = os_proc_available_memory() / (1024 * 1024)
                DiagnosticsLog.write("[转MP4] 写入变慢 30s 现场：ready=\(ready) status=\(status) 队列=\(videoQueue.depth) 最后PTS=\(pts) DTS=\(dts) writer错误=\(error) 可用磁盘=\(free)MB 可用内存=\(memory)MB")
            }

            // 5 分钟完全零进展：判定真停滞，安全中止（并解开队列，避免二次死锁）
            if stallTicks >= 60 {
                let error = (writer?.error as NSError?)?.localizedDescription ?? "-"
                DiagnosticsLog.write("[转MP4] 判定写入停滞 5 分钟：ready=\(ready) status=\(status) 队列=\(videoQueue.depth) 最后PTS=\(pts) DTS=\(dts) writer错误=\(error)")
                videoQueue.finish()
                audioQueue.finish()
                setFailure("写入停滞超过 5 分钟（设备 I/O 繁忙或文件过大）")
                writer?.cancelWriting()
            }
        }
        heartbeat.resume()
        defer { heartbeat.cancel() }

        for index in state.durations.indices {
            if currentFailure() != nil { break }
            guard !excludedIndices.contains(index) else { continue }
            if let segmentRange, !segmentRange.contains(index) { continue }
            let fileURL = dir.appendingPathComponent(LocalHLS.fileName(index: index))
            guard fm.fileExists(atPath: fileURL.path) else {
                throw RemuxError(message: "缺少分片 \(index + 1)")
            }
            // 每 100 个分片检查一次剩余空间与内存，告急时安全中止（分片保留）
            if index % 100 == 0, let free = Self.availableBytes(), free < 500 * 1024 * 1024 {
                throw RemuxError(message: "空间不足，已在第 \(index) 个分片处安全中止（原分片已保留）")
            }
            if index % 50 == 0 {
                let available = os_proc_available_memory()
                if Double(available) < (directMuxer != nil ? 150.0 : 300.0) * 1024 * 1024 {
                    // 内存吃紧：暂停喂数据，等系统回收（最多 90 秒），而不是直接放弃已完成的工作
                    let startWait = Date()
                    while Double(os_proc_available_memory()) < (directMuxer != nil ? 250.0 : 500.0) * 1024 * 1024,
                          Date().timeIntervalSince(startWait) < (directMuxer != nil ? 15.0 : 90.0) {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                    let after = os_proc_available_memory()
                    DiagnosticsLog.write("[转MP4] 内存吃紧，暂停喂数据 \(Int(Date().timeIntervalSince(startWait)))s 后恢复 内存=\(after / (1024 * 1024))MB")
                    if after < 80 * 1024 * 1024 {
                        throw RemuxError(message: "内存严重不足（\(after / (1024 * 1024))MB），已在第 \(index) 个分片处安全中止（原分片已保留）")
                    }
                }
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                autoreleasepool { demuxer.consume(chunk) }
            demuxer.updateDebugSnapshot()
                if currentFailure() != nil { break }
            }
            try? handle.close()

            // P2：参数集变化检测（不同码率变体常在片段边界更换 SPS/PPS，会导致写入被拒）
            if let info = demuxer.videoInfo(), AVRemuxPipeline.lastVideoWidth > 0 {
                let baseSPS = AVRemuxPipeline.lastVideoSPS
                let basePPS = AVRemuxPipeline.lastVideoPPS
                if !baseSPS.isEmpty, (info.sps != baseSPS || info.pps != basePPS) {
                    let changed = "[转MP4] 参数集变化 @段#\(index) 分辨率 \(AVRemuxPipeline.lastVideoWidth)x\(AVRemuxPipeline.lastVideoHeight) → \(info.width)x\(info.height) SPS=\(info.sps.count)B PPS=\(info.pps.count)B"
                    if !paramChangeLogged {
                        paramChangeLogged = true
                        DiagnosticsLog.write(changed)
                    }
                }
            }

            if index == 0, writer == nil, directMuxer == nil, currentFailure() == nil {
                do { try makeWriterIfNeeded(force: true) } catch { setFailure(error.localizedDescription) }
            }
            processedSegments = index + 1
            progress?(Double(index + 1) / Double(total))
        }
        demuxer.finish()
        flushGop()
        videoQueue.finish()
        audioQueue.finish()

        if let writer {
            let waited = doneGroup.wait(timeout: .now() + 120)
            if waited == .timedOut {
                DiagnosticsLog.write("[转MP4] 收尾等待超时 段=\(processedSegments)/\(total) 帧=\(videoFrames) 队列=\(videoQueue.depth) ready=\(videoInput?.isReadyForMoreMediaData ?? false) status=\(writer.status.rawValue)")
                writer.cancelWriting()
                throw RemuxError(message: "收尾超时（写入停滞），已安全中止，原分片已保留")
            }
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            let finished = semaphore.wait(timeout: .now() + 120)
            if finished == .timedOut {
                DiagnosticsLog.write("[转MP4] finishWriting 超时 帧=\(videoFrames) 队列=\(videoQueue.depth) status=\(writer.status.rawValue)")
                writer.cancelWriting()
                try? fm.removeItem(at: destination)
                throw RemuxError(message: "收尾超时（写入停滞），已安全中止，原分片已保留")
            }
            if let failure = currentFailure() {
                writer.cancelWriting()
                try? fm.removeItem(at: destination)
                throw RemuxError(message: "转封装失败：\(failure)")
            }
            guard writer.status == .completed else {
                try? fm.removeItem(at: destination)
                throw RemuxError(message: writer.error?.localizedDescription ?? "写出失败")
            }
        } else if directMuxer != nil {
            // 直写模式：writer 为 nil 属正常，收尾在下方由 DirectMuxer 完成
            if let failure = currentFailure() {
                throw RemuxError(message: "转封装失败：\(failure)")
            }
        } else if let failure = currentFailure() {
            throw RemuxError(message: "转封装失败：\(failure)")
        } else {
            throw RemuxError(message: "转封装失败：没有可写入的视频帧")
        }

        if let info = demuxer.audioInfo() {
            AVRemuxPipeline.lastAudioASC = info.audioSpecificConfig
            AVRemuxPipeline.lastAudioSampleRate = info.sampleRate
            AVRemuxPipeline.lastAudioChannels = info.channels
        }
        if spooling {
            try? spoolHandle?.close()
            spoolHandle = nil
            AVRemuxPipeline.collectedAudioFrames = []
            AVRemuxPipeline.lastAudioSpoolURL = spoolURL
            AVRemuxPipeline.lastAudioFrameSizes = spoolSizes
            let totalMB = spoolSizes.reduce(0, +) / (1024 * 1024)
            DiagnosticsLog.write("[转MP4] 音频帧已落盘 \(spoolSizes.count) 个 共 \(totalMB)MB（内存零驻留）")
        }
        let keyframeCount = directMuxer?.keyframeCount ?? lastKeyframeIndices.count
        DiagnosticsLog.write("[转MP4] 关键帧数=\(keyframeCount)/\(videoFrames) 用于补写 stss")
        DiagnosticsLog.write("[转MP4] 封装完成 视频帧=\(videoFrames) 音频帧=\(audioFrameIndex) GOP=\(gopCount) POC缺失=\(pocMissing) 帧间隔=\(frameStep)")

        // 自研封装：直接收尾（追加音频 + 写 moov），不经过 AVAssetWriter
        if let muxer = directMuxer {
            guard currentFailure() == nil else { return }
            guard let info = demuxer.videoInfo() else {
                throw RemuxError(message: "自研封装失败：缺少视频参数")
            }
            DiagnosticsLog.write("[转MP4] 自研封装：开始写 moov（追加音频 \(spoolSizes.count) 帧）")
            let log = try muxer.finish(width: info.width,
                                       height: info.height,
                                       sps: info.sps,
                                       pps: info.pps,
                                       frameStep: frameStep,
                                       sampleRate: max(8000, AVRemuxPipeline.lastAudioSampleRate),
                                       channels: max(1, AVRemuxPipeline.lastAudioChannels),
                                       asc: AVRemuxPipeline.lastAudioASC ?? Data(),
                                       audioSpoolURL: spoolURL,
                                       audioSizes: spoolSizes)
            DiagnosticsLog.write("[转MP4] \(log)")
            return
        }
    }

    private static func availableBytes() -> Int64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 自研封装直写：一次产出最终 MP4（视频 + 音频），不经 AVAssetWriter
    static func remuxDirect(state: SegmentJobState,
                            dir: URL,
                            destination: URL,
                            onProgress: ((Double) -> Void)? = nil) async throws {
        try await Task.detached(priority: .userInitiated) {
            try run(state: state, dir: dir, destination: destination,
                    progress: onProgress, videoOnly: true, audioFormatFlags: 2,
                    collectAudio: true, segmentRange: nil, resetAudioSpool: true,
                    useDirect: true)
        }.value
    }

    static func remux(state: SegmentJobState,
                      dir: URL,
                      destination: URL,
                      onProgress: ((Double) -> Void)? = nil,
                      videoOnly: Bool = false,
                      audioFormatFlags: UInt32 = 2,
                      collectAudio: Bool = false,
                      segmentRange: Range<Int>? = nil,
                      resetAudioSpool: Bool = true) async throws {
        try await Task.detached(priority: .userInitiated) {
            try run(state: state, dir: dir, destination: destination,
                    progress: onProgress, videoOnly: videoOnly, audioFormatFlags: audioFormatFlags,
                    collectAudio: collectAudio, segmentRange: segmentRange, resetAudioSpool: resetAudioSpool)
        }.value
    }

    // MARK: - 样本构造

    /// P2：剥离样本内嵌的 SPS/PPS（MP4 只认 avcC 里的参数集，带内重复会触发 -11800）
    private static func stripParameterSets(_ data: Data,
                                           expectedSPS: Data,
                                           expectedPPS: Data,
                                           logged: inout Bool) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 5 else { return data }
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var offset = 0
        var removed = false
        var mismatch = false
        while offset + 4 <= bytes.count {
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            let headerEnd = offset + 4
            guard length > 0, headerEnd + length <= bytes.count else {
                return data   // 结构异常交给后续校验处理
            }
            let nalType = bytes[headerEnd] & 0x1F
            let payload = Data(bytes[headerEnd..<(headerEnd + length)])
            if nalType == 7 {
                removed = true
                if !expectedSPS.isEmpty, payload != expectedSPS { mismatch = true }
            } else if nalType == 8 {
                removed = true
                if !expectedPPS.isEmpty, payload != expectedPPS { mismatch = true }
            } else {
                var lengthBE = UInt32(length).bigEndian
                withUnsafeBytes(of: &lengthBE) { output.append(contentsOf: $0) }
                output.append(contentsOf: bytes[headerEnd..<(headerEnd + length)])
            }
            offset = headerEnd + length
        }
        guard removed, !output.isEmpty else { return data }
        if !logged {
            logged = true
            DiagnosticsLog.write("[转MP4] 样本内嵌参数集已剥离（与 avcC 一致=\(!mismatch)）")
        }
        return Data(output)
    }

    /// 校验 AVCC 样本结构：4 字节长度前缀 + NAL，长度必须严格首尾闭合
    private static func isValidAVCC(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        let bytes = [UInt8](data)
        var offset = 0
        var units = 0
        while offset + 4 <= bytes.count {
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { return false }
            offset += length
            units += 1
        }
        return units > 0 && offset == bytes.count
    }

    private static func makeSampleBuffer(data: Data,
                                         format: CMFormatDescription,
                                         pts: Int64,
                                         dts: Int64,
                                         duration: Int64,
                                         timescale: Int32,
                                         isKey: Bool = true) -> CMSampleBuffer? {
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
        guard status == noErr, let sampleBuffer else { return nil }

        // 关键：非关键帧必须标记 NotSync，否则 AVAssetWriter 会认为所有样本都是同步样本，
        // 结果是不写 stss 表 → 之后任何 seek / 按时间抓帧都会失败
        if !isKey {
            CMSetAttachment(sampleBuffer,
                            key: kCMSampleAttachmentKey_NotSync,
                            value: kCFBooleanTrue,
                            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return sampleBuffer
    }
}
