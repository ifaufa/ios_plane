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
                            collectAudio: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
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
        if collectAudio {
            if let previous = AVRemuxPipeline.lastAudioSpoolURL { try? FileManager.default.removeItem(at: previous) }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("audio-spool-" + UUID().uuidString + ".aac")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            spoolURL = url
            spoolHandle = try? FileHandle(forWritingTo: url)
            AVRemuxPipeline.lastAudioSpoolURL = url
            AVRemuxPipeline.lastAudioFrameSizes = []
        }
        keyframeLock.lock()
        lastKeyframeIndices = []
        keyframeLock.unlock()
        let videoQueue = ItemQueue<VideoItem>(capacity: 32)
        let audioQueue = ItemQueue<Data>(capacity: 2000)
        let pumpQueue = DispatchQueue(label: "remux.pump", qos: .userInitiated)
        let doneGroup = DispatchGroup()
        let lock = NSLock()
        var failure: String?
        var videoFrames = 0
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
            if writer == nil, currentFailure() == nil {
                do { try makeWriterIfNeeded(force: true) } catch { setFailure(error.localizedDescription) }
            }
            for index in 0..<count {
                let item = VideoItem(data: gop[index].data,
                                     pts: ptsByIndex[index] * frameStep,
                                     dts: decodeCursor * frameStep,
                                     isKey: gop[index].isKey)
                decodeCursor += 1
                videoQueue.push(item)
            }
            displayCursor += Int64(count)
            gop.removeAll()
            if currentFailure() != nil { videoQueue.finish() }
            if writer == nil {
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

            writer = newWriter
            videoInput = vInput
            audioInput = aInput
            DiagnosticsLog.write("[转MP4] writer 创建完成 视频输入=1 音频输入=\(aInput == nil ? 0 : 1)")

            // 视频泵
            var videoPumpFinished = false
            var audioPumpFinished = false
            doneGroup.enter()
            vInput.requestMediaDataWhenReady(on: pumpQueue) {
                var idleSince: Date?
                while vInput.isReadyForMoreMediaData {
                    guard let item = videoQueue.pop(waitSeconds: 0.2) else {
                        if videoQueue.isFinished {
                            if !videoPumpFinished {
                                videoPumpFinished = true
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
                    guard let buffer = makeSampleBuffer(data: item.data,
                                                        format: videoDesc,
                                                        pts: item.pts,
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
                    if !vInput.append(buffer) {
                        let error = newWriter.error as NSError?
                        setFailure("追加视频样本失败：\(error?.code ?? 0) \(error?.localizedDescription ?? "")")
                        if !videoPumpFinished { videoPumpFinished = true; doneGroup.leave() }
                        vInput.markAsFinished()
                        return
                    }
                    if item.isKey {
                        keyframeLock.lock()
                        lastKeyframeIndices.append(Int32(sampleIndex))
                        keyframeLock.unlock()
                    }
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

            if writer == nil {
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
                if collectAudio {
                    spoolLock.lock()
                    try? spoolHandle?.write(contentsOf: data)
                    spoolSizes.append(data.count)
                    spoolLock.unlock()
                }
                return
            }
            audioQueue.push(data)
            if writer == nil {
                do { try makeWriterIfNeeded(force: false) } catch { setFailure(error.localizedDescription) }
            }
        }

        var processedSegments = 0
        let excludedIndices = Set(state.excluded ?? [])
        let total = max(1, state.segmentURLs.count - excludedIndices.count)
        // 心跳 + 停滞看门狗：卡住时能给出可诊断信息并自动中止
        let heartbeatQueue = DispatchQueue(label: "remux.heartbeat")
        var lastFrameSnapshot = -1
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
            if frames == lastFrameSnapshot {
                stallTicks += 1
            } else {
                stallTicks = 0
            }
            lastFrameSnapshot = frames

            let ready = videoInput?.isReadyForMoreMediaData ?? false
            let status = writer?.status.rawValue ?? -1
            DiagnosticsLog.write("[转MP4] 心跳 段=\(processedSegments) 帧=\(frames) 队列=\(videoQueue.depth) ready=\(ready) status=\(status) 停滞=\(stallTicks) \(demuxer.debugBufferSizes()) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")

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
            let fileURL = dir.appendingPathComponent(LocalHLS.fileName(index: index))
            guard fm.fileExists(atPath: fileURL.path) else {
                throw RemuxError(message: "缺少分片 \(index + 1)")
            }
            // 每 100 个分片检查一次剩余空间与内存，告急时安全中止（分片保留）
            if index % 100 == 0, let free = Self.availableBytes(), free < 500 * 1024 * 1024 {
                throw RemuxError(message: "空间不足，已在第 \(index) 个分片处安全中止（原分片已保留）")
            }
            if index % 100 == 0, os_proc_available_memory() < 200 * 1024 * 1024 {
                throw RemuxError(message: "内存不足，已在第 \(index) 个分片处安全中止（原分片已保留）。请关闭其它 App 后重试")
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                autoreleasepool { demuxer.consume(chunk) }
                if currentFailure() != nil { break }
            }
            try? handle.close()
            if index == 0, writer == nil, currentFailure() == nil {
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
        if collectAudio {
            try? spoolHandle?.close()
            spoolHandle = nil
            AVRemuxPipeline.collectedAudioFrames = []
            AVRemuxPipeline.lastAudioSpoolURL = spoolURL
            AVRemuxPipeline.lastAudioFrameSizes = spoolSizes
            let totalMB = spoolSizes.reduce(0, +) / (1024 * 1024)
            DiagnosticsLog.write("[转MP4] 音频帧已落盘 \(spoolSizes.count) 个 共 \(totalMB)MB（内存零驻留）")
        }
                DiagnosticsLog.write("[转MP4] 关键帧数=\(lastKeyframeIndices.count)/\(videoFrames) 用于补写 stss")
        DiagnosticsLog.write("[转MP4] 封装完成 视频帧=\(videoFrames) 音频帧=\(audioFrameIndex) GOP=\(gopCount) POC缺失=\(pocMissing) 帧间隔=\(frameStep)")
    }

    private static func availableBytes() -> Int64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func remux(state: SegmentJobState,
                      dir: URL,
                      destination: URL,
                      onProgress: ((Double) -> Void)? = nil,
                      videoOnly: Bool = false,
                      audioFormatFlags: UInt32 = 2,
                      collectAudio: Bool = false) async throws {
        try await Task.detached(priority: .userInitiated) {
            try run(state: state, dir: dir, destination: destination,
                    progress: onProgress, videoOnly: videoOnly, audioFormatFlags: audioFormatFlags, collectAudio: collectAudio)
        }.value
    }

    // MARK: - 样本构造

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
