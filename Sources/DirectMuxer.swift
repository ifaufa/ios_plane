import Foundation

/// 自研 MP4 封装器：不经 AVAssetWriter，直接按 ISO 结构写文件
/// 布局：ftyp | mdat(视频 chunk 与音频 chunk 交替写入) | moov
///
/// 关键纪律（决定能否正常播放）：
/// 1) 每个 chunk 固定 32 个样本，且**整块一次性写入** → chunk 内绝不会被其它数据插入
/// 2) 音频与视频以「整 chunk」为单位交替写入 → 既省内存（不再收尾时突发写 300MB），又保证 chunk 连续
/// 3) 收尾只剩「固定 32 规则的样本表 + moov」，可被 chunk 数公式校验
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
    private var videoDurations: [UInt32] = []
    private var videoKeyframes: [Int32] = []
    private var videoChunkOffsets: [UInt64] = []

    // 音频样本表
    private var audioSizes: [Int32] = []
    private var audioChunkOffsets: [UInt64] = []

    // 待写入的整块（各 32 个样本）
    private var pendingVideo = Data()
    private var pendingVideoSizes: [Int32] = []
    private var pendingVideoCtts: [Int32] = []
    private var pendingVideoDurations: [UInt32] = []
    private var pendingVideoKeys: [Int32] = []
    private var pendingAudio = Data()
    private var pendingAudioSizes: [Int32] = []

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
        pendingAudio.reserveCapacity(1 << 16)
        pendingVideoSizes.reserveCapacity(samplesPerChunk)
        pendingVideoCtts.reserveCapacity(samplesPerChunk)
        pendingVideoDurations.reserveCapacity(samplesPerChunk)
        videoDurations.reserveCapacity(400_000)
        pendingVideoKeys.reserveCapacity(4)
        pendingAudioSizes.reserveCapacity(samplesPerChunk)
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
        pendingVideoDurations.append(duration)
        if isKey { pendingVideoKeys.append(Int32(pendingVideoSizes.count - 1)) }

        if pendingVideoSizes.count >= samplesPerChunk {
            try flushVideoChunk()
        }
    }

    func appendAudio(_ frame: Data) {
        pendingAudio.append(frame)
        pendingAudioSizes.append(Int32(frame.count))
        if pendingAudioSizes.count >= samplesPerChunk {
            flushAudioChunk()
        }
    }

    func audioFrameCount() -> Int { audioSizes.count + pendingAudioSizes.count }

    /// 整块写入：chunk 内样本必然连续
    private func flushVideoChunk() throws {
        guard !pendingVideoSizes.isEmpty else { return }
        videoChunkOffsets.append(writeOffset)
        try handle.write(contentsOf: pendingVideo)
        writeOffset += UInt64(pendingVideo.count)
        bytesSinceSync += UInt64(pendingVideo.count)

        let base = videoSizes.count
        videoSizes.append(contentsOf: pendingVideoSizes)
        videoCtts.append(contentsOf: pendingVideoCtts)
        videoDurations.append(contentsOf: pendingVideoDurations)
        for key in pendingVideoKeys { videoKeyframes.append(Int32(base) + key) }

        pendingVideo.removeAll(keepingCapacity: true)
        pendingVideoSizes.removeAll(keepingCapacity: true)
        pendingVideoCtts.removeAll(keepingCapacity: true)
        pendingVideoDurations.removeAll(keepingCapacity: true)
        pendingVideoKeys.removeAll(keepingCapacity: true)

        if bytesSinceSync >= 256 * 1024 * 1024 {
            _ = fsync(handle.fileDescriptor)
            bytesSinceSync = 0
        }
    }

    private func flushAudioChunk() {
        guard !pendingAudioSizes.isEmpty else { return }
        audioChunkOffsets.append(writeOffset)
        do {
            try handle.write(contentsOf: pendingAudio)
            writeOffset += UInt64(pendingAudio.count)
            bytesSinceSync += UInt64(pendingAudio.count)
            audioSizes.append(contentsOf: pendingAudioSizes)
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
        DiagnosticsLog.write("[转MP4] 收尾①写入剩余 chunk 视频待写=\(pendingVideoSizes.count) 音频待写=\(pendingAudioSizes.count) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
        try flushVideoChunk()
        flushAudioChunk()
        flushSync()

        DiagnosticsLog.write("[转MP4] 收尾②构造样本表 视频样本=\(videoSizes.count) 音频帧=\(audioSizes.count) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")

        // chunk 数必须严格等于 ceil(样本数/32)（整块写入保证）
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
        DiagnosticsLog.write("[转MP4] chunk 连续性校验通过 视频chunk=\(videoChunkOffsets.count) 音频chunk=\(audioChunkOffsets.count)")

        var editShift: Int64 = 0
        if let minOffset = videoCtts.min(), minOffset < 0 {
            editShift = Int64(-minOffset)
            for index in videoCtts.indices { videoCtts[index] += Int32(editShift) }
        }

        // 真实时间轴：按逐帧时长求和；缺失时退回均匀网格
        var totalTicks = Int64(videoSizes.count) * frameStep
        if videoDurations.count == videoSizes.count, !videoDurations.isEmpty {
            totalTicks = videoDurations.reduce(Int64(0)) { $0 + Int64($1) }
            let avg = Double(totalTicks) / Double(videoDurations.count)
            let uniform = Double(frameStep)
            DiagnosticsLog.write(String(format: "[转MP4] 时间轴 逐帧时长 平均=%.1f 中位=%lld 合计=%.1fs（均匀网格=%.1fs）",
                                        avg, frameStep, Double(totalTicks) / 90000.0,
                                        Double(Int64(videoSizes.count) * frameStep) / 90000.0))
            let durationMin = videoDurations.min() ?? 0
            let durationMax = videoDurations.max() ?? 0
            guard durationMin > 0, Int(durationMax) <= 45000 else {
                throw MuxError(message: "帧时长异常（min=\(durationMin) max=\(durationMax)），已中止以免产出抖动视频")
            }
            DiagnosticsLog.write("[转MP4] 时长校验通过 min=\(durationMin) max=\(durationMax) 总时长=\(String(format: "%.1f", Double(totalTicks) / 90000.0))s")
        }
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
                                                    editShift: editShift,
                                                    durations: videoDurations.count == videoSizes.count ? videoDurations : nil)

        var audioTrak = Data()
        if !audioSizes.isEmpty {
            let audioSeconds = Double(audioSizes.count) * 1024.0 / Double(max(1, sampleRate))
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

        DiagnosticsLog.write("[转MP4] 收尾③写 moov \(moov.count)B 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
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

    /// 每个 chunk 内的样本必须在文件里连续（允许 chunk 之间插入其它数据）
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
