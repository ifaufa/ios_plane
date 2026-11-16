import Foundation

/// 自研 MP4 封装器：不经 AVAssetWriter，直接按 ISO 结构写文件
/// 布局：ftyp | mdat(视频 chunk … 然后音频 chunk) | moov
///
/// 布局纪律（与已验证正常播放的旧路径保持一致）：
/// 1) 视频按 32 样本整块写入，chunk 内绝不被打断
/// 2) 音频**不打散在视频中间**，而是先落临时文件，收尾时整段追加到 mdat 尾部
///    （穿插布局会让播放器频繁跨段读取，表现为周期性抖动/卡顿）
/// 3) 音频追加按 4MB 批量 + fsync，配合收尾前的内存预检，避免大文件被系统杀掉
final class DirectMuxer {
    struct MuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let handle: FileHandle
    private let destination: URL

    private var mdatContentStart: UInt64 = 0
    private var writeOffset: UInt64 = 0

    // 视频样本表
    private var videoSizes: [Int32] = []
    private var videoCtts: [Int32] = []
    private var videoKeyframes: [Int32] = []
    private var videoChunkOffsets: [UInt64] = []

    // 音频（落临时文件，收尾时追加到 mdat 尾部）
    private var audioSizes: [Int32] = []
    private var audioChunkOffsets: [UInt64] = []
    private var audioSpoolURL: URL?
    private var audioSpool: FileHandle?

    // 待写入的整块（各 32 个样本）
    private var pendingVideo = Data()
    private var pendingVideoSizes: [Int32] = []
    private var pendingVideoCtts: [Int32] = []
    private var pendingVideoKeys: [Int32] = []

    private let samplesPerChunk = 32
    private var bytesSinceSync: UInt64 = 0

    init(destination: URL) throws {
        self.destination = destination
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw MuxError(message: "无法创建输出文件")
        }
        self.handle = handle
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)

        // 音频临时文件（与分片目录分开，避免污染空间统计）
        let spoolURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mux-audio-" + UUID().uuidString + ".aac")
        fm.createFile(atPath: spoolURL.path, contents: nil)
        audioSpoolURL = spoolURL
        audioSpool = try? FileHandle(forWritingTo: spoolURL)

        var ftypBody = Data()
        ftypBody.append("isom".data(using: .ascii)!)
        ftypBody.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        ftypBody.append("isom".data(using: .ascii)!)
        ftypBody.append("iso2".data(using: .ascii)!)
        ftypBody.append("avc1".data(using: .ascii)!)
        ftypBody.append("mp41".data(using: .ascii)!)

        var ftyp = Data()
        ftyp.append(contentsOf: be32(UInt32(ftypBody.count + 8)))
        ftyp.append("ftyp".data(using: .ascii)!)
        ftyp.append(ftypBody)
        try handle.write(contentsOf: ftyp)

        var mdatHeader = Data()
        mdatHeader.append(contentsOf: [0, 0, 0, 1])
        mdatHeader.append("mdat".data(using: .ascii)!)
        mdatHeader.append(contentsOf: [UInt8](repeating: 0, count: 8))
        try handle.write(contentsOf: mdatHeader)

        mdatContentStart = UInt64(ftyp.count + 16)
        writeOffset = mdatContentStart

        videoSizes.reserveCapacity(400_000)
        videoCtts.reserveCapacity(400_000)
        videoChunkOffsets.reserveCapacity(16_384)
        audioSizes.reserveCapacity(600_000)
        audioChunkOffsets.reserveCapacity(32_768)
        pendingVideo.reserveCapacity(1 << 19)
        pendingVideoSizes.reserveCapacity(samplesPerChunk)
        pendingVideoCtts.reserveCapacity(samplesPerChunk)
        pendingVideoKeys.reserveCapacity(4)
    }

    deinit {
        try? audioSpool?.close()
        if let audioSpoolURL { try? FileManager.default.removeItem(at: audioSpoolURL) }
    }

    var videoSampleCount: Int { videoSizes.count + pendingVideoSizes.count }
    var keyframeCount: Int { videoKeyframes.count + pendingVideoKeys.count }
    var audioFrameCount: Int { audioSizes.count }

    func flushSync() {
        _ = fsync(handle.fileDescriptor)
        bytesSinceSync = 0
    }

    // MARK: - 样本写入

    func appendVideo(data: Data, isKey: Bool, pts: Int64, dts: Int64, duration: UInt32 = 0) throws {
        pendingVideo.append(data)
        pendingVideoSizes.append(Int32(data.count))
        pendingVideoCtts.append(Int32(pts - dts))
        if isKey { pendingVideoKeys.append(Int32(pendingVideoSizes.count - 1)) }

        if pendingVideoSizes.count >= samplesPerChunk {
            try flushVideoChunk()
        }
    }

    /// 音频先落临时文件，收尾时整段追加（不穿插进视频区）
    func appendAudio(_ frame: Data) {
        try? audioSpool?.write(contentsOf: frame)
        audioSizes.append(Int32(frame.count))
    }

    private func flushVideoChunk() throws {
        guard !pendingVideoSizes.isEmpty else { return }
        videoChunkOffsets.append(writeOffset)
        try handle.write(contentsOf: pendingVideo)
        writeOffset += UInt64(pendingVideo.count)
        bytesSinceSync += UInt64(pendingVideo.count)

        let base = videoSizes.count
        videoSizes.append(contentsOf: pendingVideoSizes)
        videoCtts.append(contentsOf: pendingVideoCtts)
        for key in pendingVideoKeys { videoKeyframes.append(Int32(base) + key) }

        pendingVideo.removeAll(keepingCapacity: true)
        pendingVideoSizes.removeAll(keepingCapacity: true)
        pendingVideoCtts.removeAll(keepingCapacity: true)
        pendingVideoKeys.removeAll(keepingCapacity: true)

        if bytesSinceSync >= 256 * 1024 * 1024 {
            _ = fsync(handle.fileDescriptor)
            bytesSinceSync = 0
        }
    }

    // MARK: - 收尾

    func finish(width: Int,
                height: Int,
                sps: Data,
                pps: Data,
                frameStep: Int64,
                sampleRate: Int,
                channels: Int,
                asc: Data) throws -> String {
        DiagnosticsLog.write("[转MP4] 收尾①写入剩余视频 chunk 视频待写=\(pendingVideoSizes.count) 音频帧=\(audioSizes.count) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
        try flushVideoChunk()
        flushSync()

        // 收尾②：音频整段追加到 mdat 尾部（4MB 批量）
        DiagnosticsLog.write("[转MP4] 收尾②追加音频 帧数=\(audioSizes.count) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
        try appendAudioToTail()

        DiagnosticsLog.write("[转MP4] 收尾③构造样本表 视频样本=\(videoSizes.count) 音频帧=\(audioSizes.count) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")

        let expectedVideoChunks = (videoSizes.count + samplesPerChunk - 1) / samplesPerChunk
        let expectedAudioChunks = audioSizes.isEmpty ? 0 : (audioSizes.count + samplesPerChunk - 1) / samplesPerChunk
        guard videoChunkOffsets.count == expectedVideoChunks else {
            throw MuxError(message: "视频 chunk 数不符（\(videoChunkOffsets.count) ≠ \(expectedVideoChunks)）")
        }
        guard audioChunkOffsets.count == expectedAudioChunks else {
            throw MuxError(message: "音频 chunk 数不符（\(audioChunkOffsets.count) ≠ \(expectedAudioChunks)）")
        }
        DiagnosticsLog.write("[转MP4] chunk 连续性校验通过 视频chunk=\(videoChunkOffsets.count) 音频chunk=\(audioChunkOffsets.count)")

        // P3：显示偏移诊断
        let maxCtts = videoCtts.map { abs($0) }.max() ?? 0
        let uniqueCtts = Set(videoCtts).count
        let uniqueRatio = videoCtts.isEmpty ? 0 : Double(uniqueCtts) / Double(videoCtts.count)
        DiagnosticsLog.write(String(format: "[转MP4] 显示偏移 max=%dticks（%.1f 帧）偏移种类=%d 唯一率=%.1f%%",
                                    maxCtts, Double(maxCtts) / Double(max(1, frameStep)), uniqueCtts, uniqueRatio * 100))

        var editShift: Int64 = 0
        if let minOffset = videoCtts.min(), minOffset < 0 {
            editShift = Int64(-minOffset)
            for index in videoCtts.indices { videoCtts[index] += Int32(editShift) }
        }

        let totalTicks = Int64(videoSizes.count) * frameStep
        let movieTimescale: UInt32 = 1000
        let movieDuration = UInt32(min(Double(UInt32.max),
                                       Double(totalTicks) / 90000.0 * Double(movieTimescale)))

        let videoTrak = MP4PartMerger.makeVideoTrak(sampleCount: videoSizes.count,
                                                    sizes: videoSizes,
                                                    ctts: videoCtts,
                                                    keyframes: videoKeyframes,
                                                    frameStep: frameStep,
                                                    chunkOffsets: videoChunkOffsets,
                                                    samplesPerChunk: samplesPerChunk,
                                                    width: width,
                                                    height: height,
                                                    sps: sps,
                                                    pps: pps,
                                                    movieDuration: movieDuration,
                                                    editShift: editShift)

        var audioTrak = Data()
        if !audioSizes.isEmpty {
            let audioSeconds = Double(audioSizes.count) * 1024.0 / Double(max(1, sampleRate))
            let videoSeconds = Double(totalTicks) / 90000.0
            let deviation = abs(videoSeconds - audioSeconds) / max(1.0, audioSeconds)
            if deviation > 0.01 {
                DiagnosticsLog.write(String(format: "[转MP4] 警告：音画时长偏差 %.1f%%（视频=%.1fs 音频=%.1fs）",
                                            deviation * 100, videoSeconds, audioSeconds))
            } else {
                DiagnosticsLog.write(String(format: "[转MP4] 音画时长一致 视频=%.1fs 音频=%.1fs 偏差=%.2f%%",
                                            videoSeconds, audioSeconds, deviation * 100))
            }
            audioTrak = AudioTrackBuilder.makeAudioTrak(frameCount: audioSizes.count,
                                                        sizes: audioSizes.map { Int($0) },
                                                        offsets: audioChunkOffsets.map { UInt32(min($0, UInt64(UInt32.max))) },
                                                        samplesPerChunk: samplesPerChunk,
                                                        sampleRate: sampleRate,
                                                        channels: channels,
                                                        esds: MP4AudioFixer.makeESDS(asc: asc.isEmpty ? Data([0x11, 0x90]) : asc),
                                                        timescale: movieTimescale,
                                                        duration: audioSeconds,
                                                        trackID: 2)
        }

        var moovBody = Data()
        moovBody.append(MP4PartMerger.makeMVHD(timescale: movieTimescale,
                                               duration: movieDuration,
                                               nextTrackID: audioTrak.isEmpty ? 2 : 3))
        moovBody.append(videoTrak)
        if !audioTrak.isEmpty { moovBody.append(audioTrak) }
        var moov = Data()
        moov.append(contentsOf: be32(UInt32(moovBody.count + 8)))
        moov.append("moov".data(using: .ascii)!)
        moov.append(moovBody)

        DiagnosticsLog.write("[转MP4] 收尾④写 moov \(moov.count)B 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
        try handle.write(contentsOf: moov)
        flushSync()

        let totalMdat = 16 + (writeOffset - mdatContentStart)
        var sizeBytes = Data()
        sizeBytes.append(contentsOf: (0..<8).map { UInt8((totalMdat >> (56 - UInt64($0) * 8)) & 0xFF) })
        try handle.seek(toOffset: mdatContentStart - 8)
        try handle.write(contentsOf: sizeBytes)
        try handle.close()

        try? audioSpool?.close()
        audioSpool = nil
        if let audioSpoolURL { try? FileManager.default.removeItem(at: audioSpoolURL) }

        let finalSize = writeOffset + UInt64(moov.count)
        return "自研封装完成 视频样本=\(videoSizes.count) 关键帧=\(videoKeyframes.count) 音频帧=\(audioSizes.count) moov=\(moov.count)B 总大小=\(finalSize)B"
    }

    /// 音频整段追加到 mdat 尾部，并记录每 32 帧的 chunk 偏移
    private func appendAudioToTail() throws {
        guard !audioSizes.isEmpty else { return }
        guard let spoolURL = audioSpoolURL, let spool = try? FileHandle(forReadingFrom: spoolURL) else {
            throw MuxError(message: "音频临时文件缺失")
        }
        defer { try? spool.close() }

        // P4：小块（64KB）写入 + 每次 fsync，内存占用恒定，不依赖大缓冲
        var buffer = Data()
        buffer.reserveCapacity(96 * 1024)
        var frameIndex = 0
        var chunkStartOffset = writeOffset
        var writtenSinceLog = 0
        var totalWritten = 0
        var lastLogPercent = 0

        while frameIndex < audioSizes.count {
            if frameIndex % samplesPerChunk == 0 {
                chunkStartOffset = writeOffset + UInt64(buffer.count)
                audioChunkOffsets.append(chunkStartOffset)
            }
            let size = Int(audioSizes[frameIndex])
            guard let chunk = try? spool.read(upToCount: size), chunk.count == size else {
                throw MuxError(message: "音频临时文件读取不完整（帧 \(frameIndex)）")
            }
            buffer.append(chunk)
            writtenSinceLog += size
            frameIndex += 1

            if buffer.count >= 64 * 1024 || frameIndex >= audioSizes.count {
                try writeAudioBuffer(&buffer)
                totalWritten += writtenSinceLog
                writtenSinceLog = 0

                // P1：内存感知限速（脏页堆积会把进程顶死）
                let available = Double(os_proc_available_memory())
                if available < 150.0 * 1024 * 1024 {
                    let waitStart = Date()
                    while Double(os_proc_available_memory()) < 150.0 * 1024 * 1024,
                          Date().timeIntervalSince(waitStart) < 30 {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }

                let percent = Int(Double(totalWritten) / Double(max(1, audioSizeTotal)) * 100)
                if percent >= lastLogPercent + 20 {
                    lastLogPercent = percent
                    DiagnosticsLog.write("[转MP4] 音频追加 \(percent)% 已写=\(totalWritten / (1024 * 1024))MB 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
                }
            }
        }

        if !buffer.isEmpty { try writeAudioBuffer(&buffer) }
        flushSync()
    }

    private var audioSizeTotal: Int { audioSizes.reduce(0) { $0 + Int($1) } }

    private func writeAudioBuffer(_ buffer: inout Data) throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        writeOffset += UInt64(buffer.count)
        bytesSinceSync += UInt64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        // P4：每次写后刷盘，脏页不累积
        _ = fsync(handle.fileDescriptor)
        bytesSinceSync = 0
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
