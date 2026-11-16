import Foundation

/// 自研 MP4 封装器：不经 AVAssetWriter，直接按 ISO 结构写文件
/// 布局：ftyp | mdat(视频 chunk 与音频 chunk 交替写入) | moov
///
/// 写入纪律：
/// 1) 视频：32 个样本为一个 chunk，**整块原子写入**（chunk 内绝不被打断）
/// 2) 音频：先在内存里攒到约 1 秒（≈32KB），**只在视频 chunk 边界**写入一段连续区
///    → 既避免收尾一次性写 300MB（内存被顶爆），又保证每个 chunk 内部连续
/// 3) 收尾只剩「不足 1 秒的尾巴 + moov」，秒级完成
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

    // 音频样本表
    private var audioSizes: [Int32] = []
    private var audioChunkOffsets: [UInt64] = []
    private var audioFramesInChunk = 0

    // 待写入缓冲
    private var pendingVideo = Data()
    private var pendingVideoSizes: [Int32] = []
    private var pendingVideoCtts: [Int32] = []
    private var pendingVideoKeys: [Int32] = []
    private var pendingAudio = Data()
    private var pendingAudioSizes: [Int32] = []

    private let samplesPerChunk = 32
    /// 音频攒到约 1 秒再写（48k 立体声 AAC ≈ 24–32KB/秒）
    private let audioBatchBytes = 32 * 1024
    private var bytesSinceSync: UInt64 = 0

    /// 收尾进度（-1 = 未进入收尾），供心跳日志
    private(set) var appendProgressPercent: Int = -1

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
        pendingAudio.reserveCapacity(audioBatchBytes * 2)
        pendingAudioSizes.reserveCapacity(64)
    }

    var videoSampleCount: Int { videoSizes.count + pendingVideoSizes.count }
    var keyframeCount: Int { videoKeyframes.count + pendingVideoKeys.count }

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

    /// 音频先在内存攒 ~1 秒，再在视频 chunk 边界整段写入
    func appendAudio(_ frame: Data) {
        pendingAudio.append(frame)
        pendingAudioSizes.append(Int32(frame.count))
        if pendingAudio.count >= audioBatchBytes {
            flushAudioChunk()
        }
    }

    func audioFrameCount() -> Int { audioSizes.count + pendingAudioSizes.count }

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

    /// 只在视频 chunk 完整（pendingVideoSizes 为空）时调用，保证视频 chunk 不被音频劈开
    private func flushAudioChunk() {
        guard !pendingAudioSizes.isEmpty else { return }
        do {
            if !pendingVideoSizes.isEmpty { try flushVideoChunk() }
            let base = writeOffset
            var offsetInBuffer: UInt64 = 0
            for size in pendingAudioSizes {
                if audioFramesInChunk == 0 {
                    audioChunkOffsets.append(base + offsetInBuffer)
                }
                audioSizes.append(size)
                offsetInBuffer += UInt64(size)
                audioFramesInChunk += 1
                if audioFramesInChunk >= samplesPerChunk { audioFramesInChunk = 0 }
            }
            try handle.write(contentsOf: pendingAudio)
            writeOffset += UInt64(pendingAudio.count)
            bytesSinceSync += UInt64(pendingAudio.count)
        } catch {
            DiagnosticsLog.write("[转MP4] 音频写入失败：\(error.localizedDescription)")
        }
        pendingAudio.removeAll(keepingCapacity: true)
        pendingAudioSizes.removeAll(keepingCapacity: true)
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
        appendProgressPercent = 0
        DiagnosticsLog.write("[转MP4] 收尾①写入剩余数据 视频待写=\(pendingVideoSizes.count) 音频待写=\(pendingAudioSizes.count) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
        try flushVideoChunk()
        flushAudioChunk()
        flushSync()
        appendProgressPercent = 100

        DiagnosticsLog.write("[转MP4] 收尾②构造样本表 视频样本=\(videoSizes.count) 音频帧=\(audioSizes.count) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")

        // D1：结构自检（写 moov 之前先把明显不合法的情况挡住）
        let expectedVideoChunks = (videoSizes.count + samplesPerChunk - 1) / samplesPerChunk
        let expectedAudioChunks = audioSizes.isEmpty ? 0 : (audioSizes.count + samplesPerChunk - 1) / samplesPerChunk
        guard videoChunkOffsets.count == expectedVideoChunks else {
            throw MuxError(message: "视频 chunk 数不符（\(videoChunkOffsets.count) ≠ \(expectedVideoChunks)）")
        }
        guard audioChunkOffsets.count == expectedAudioChunks else {
            throw MuxError(message: "音频 chunk 数不符（\(audioChunkOffsets.count) ≠ \(expectedAudioChunks)）")
        }
        try validateChunks(offsets: videoChunkOffsets, sizes: videoSizes, label: "视频")
        try validateChunks(offsets: audioChunkOffsets, sizes: audioSizes, label: "音频")

        // 关键帧序号（1-based）范围校验
        if let firstKey = videoKeyframes.first, let lastKey = videoKeyframes.last {
            guard firstKey >= 0, lastKey < Int32(videoSizes.count) else {
                throw MuxError(message: "关键帧序号越界（首个=\(firstKey + 1) 末个=\(lastKey + 1) 样本数=\(videoSizes.count)）")
            }
            DiagnosticsLog.write("[转MP4] stss 自检 首个=\(firstKey + 1) 末个=\(lastKey + 1) 条目=\(videoKeyframes.count) 样本总数=\(videoSizes.count)")
        }

        // 样本字节总和必须等于 mdat 负载
        let videoBytes = videoSizes.reduce(Int64(0)) { $0 + Int64($1) }
        let audioBytes = audioSizes.reduce(Int64(0)) { $0 + Int64($1) }
        let payload = Int64(writeOffset - mdatContentStart)
        guard videoBytes + audioBytes == payload else {
            throw MuxError(message: "样本字节与 mdat 不符（视频+音频=\(videoBytes + audioBytes) mdat负载=\(payload)）")
        }
        DiagnosticsLog.write("[转MP4] chunk 连续性校验通过 视频chunk=\(videoChunkOffsets.count) 音频chunk=\(audioChunkOffsets.count) 负载=\(payload / (1024 * 1024))MB")

        // 显示偏移诊断
        let maxCtts = videoCtts.map { abs($0) }.max() ?? 0
        let uniqueCtts = Set(videoCtts).count
        DiagnosticsLog.write("[转MP4] 显示偏移 max=\(maxCtts)ticks（\(String(format: "%.1f", Double(maxCtts) / Double(max(1, frameStep)))) 帧）种类=\(uniqueCtts)")

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

        DiagnosticsLog.write("[转MP4] 收尾③写 moov \(moov.count)B editShift=\(editShift)ticks 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
        try handle.write(contentsOf: moov)
        flushSync()

        let totalMdat = 16 + (writeOffset - mdatContentStart)
        var sizeBytes = Data()
        sizeBytes.append(contentsOf: (0..<8).map { UInt8((totalMdat >> (56 - UInt64($0) * 8)) & 0xFF) })
        try handle.seek(toOffset: mdatContentStart - 8)
        try handle.write(contentsOf: sizeBytes)
        try handle.close()

        let finalSize = writeOffset + UInt64(moov.count)
        return "自研封装完成 视频样本=\(videoSizes.count) 关键帧=\(videoKeyframes.count) 音频帧=\(audioSizes.count) moov=\(moov.count)B 总大小=\(finalSize)B"
    }

    private func validateChunks(offsets: [UInt64], sizes: [Int32], label: String) throws {
        guard !offsets.isEmpty, !sizes.isEmpty else { return }
        var index = 0
        for chunkIndex in 0..<offsets.count {
            let start = offsets[chunkIndex]
            let end = min(index + samplesPerChunk, sizes.count)
            var span: UInt64 = 0
            for sample in index..<end { span += UInt64(sizes[sample]) }
            guard start + span <= writeOffset else {
                throw MuxError(message: "\(label) chunk#\(chunkIndex) 越界")
            }
            if chunkIndex + 1 < offsets.count, offsets[chunkIndex + 1] < start + span {
                throw MuxError(message: "\(label) chunk#\(chunkIndex) 被其它数据插入（\(offsets[chunkIndex + 1]) < \(start + span)）")
            }
            index = end
        }
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
