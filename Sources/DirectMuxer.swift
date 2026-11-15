import Foundation

/// 自研 MP4 封装器：不经 AVAssetWriter，直接按 ISO 结构写文件
/// 布局：ftyp | mdat(视频样本与音频样本交错写入) | moov
/// 设计要点：
/// 1) 音频不再等收尾时才一次性追写（那是 307MB 的突发写，会把内存/IO 压爆），改为**边转边写**
/// 2) 收尾只剩"构造 moov"，各阶段有日志与 fsync（便于定位被系统中断的环节）
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
    private var videoChunkSamples = 0

    // 音频样本表（边写边记录）
    private var audioSizes: [Int32] = []
    private var audioChunkOffsets: [UInt64] = []
    private var audioChunkSamples = 0
    private var audioWriteBuffer = Data()

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

        // 预留容量，避免 25 万级 append 反复扩容拷贝
        videoSizes.reserveCapacity(400_000)
        videoCtts.reserveCapacity(400_000)
        videoChunkOffsets.reserveCapacity(16_384)
        audioSizes.reserveCapacity(600_000)
        audioChunkOffsets.reserveCapacity(32_768)
        audioWriteBuffer.reserveCapacity(1 << 20)
    }

    var videoSampleCount: Int { videoSizes.count }
    var keyframeCount: Int { videoKeyframes.count }

    func flushSync() {
        _ = fsync(handle.fileDescriptor)
        bytesSinceSync = 0
    }

    // MARK: - 写入样本

    func appendVideo(data: Data, isKey: Bool, pts: Int64, dts: Int64) throws {
        if videoChunkSamples == 0 { videoChunkOffsets.append(writeOffset) }
        try handle.write(contentsOf: data)
        writeOffset += UInt64(data.count)
        bytesSinceSync += UInt64(data.count)

        videoSizes.append(Int32(data.count))
        videoCtts.append(Int32(pts - dts))
        if isKey { videoKeyframes.append(Int32(videoSizes.count - 1)) }

        videoChunkSamples += 1
        if videoChunkSamples >= samplesPerChunk { videoChunkSamples = 0 }

        if bytesSinceSync >= 256 * 1024 * 1024 {
            _ = fsync(handle.fileDescriptor)
            bytesSinceSync = 0
        }
    }

    /// 音频边转边写：内部聚成 1MB 再落盘，避免碎片小写
    func appendAudio(_ frame: Data) {
        if audioChunkSamples == 0 {
            audioChunkOffsets.append(writeOffset + UInt64(audioWriteBuffer.count))
        }
        audioWriteBuffer.append(frame)
        audioSizes.append(Int32(frame.count))

        audioChunkSamples += 1
        if audioChunkSamples >= samplesPerChunk { audioChunkSamples = 0 }

        if audioWriteBuffer.count >= 1 << 20 {
            flushAudioBuffer()
        }
    }

    private func flushAudioBuffer() {
        guard !audioWriteBuffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: audioWriteBuffer)
            writeOffset += UInt64(audioWriteBuffer.count)
            bytesSinceSync += UInt64(audioWriteBuffer.count)
            audioWriteBuffer.removeAll(keepingCapacity: true)
            if bytesSinceSync >= 128 * 1024 * 1024 {
                _ = fsync(handle.fileDescriptor)
                bytesSinceSync = 0
            }
        } catch {
            DiagnosticsLog.write("[转MP4] 音频写入失败：\(error.localizedDescription)")
        }
    }

    func audioFrameCount() -> Int { audioSizes.count }

    // MARK: - 收尾

    func finish(width: Int,
                height: Int,
                sps: Data,
                pps: Data,
                frameStep: Int64,
                sampleRate: Int,
                channels: Int,
                asc: Data) throws -> String {
        // 阶段 1：把残留音频写入 mdat
        DiagnosticsLog.write("[转MP4] 收尾①写入剩余音频 缓冲=\(audioWriteBuffer.count)B 音频帧=\(audioSizes.count) 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
        flushAudioBuffer()
        flushSync()

        // 阶段 2：规范化 ctts（负偏移 → 平移 + elst 补偿）
        DiagnosticsLog.write("[转MP4] 收尾②构造样本表 内存=\(os_proc_available_memory() / (1024 * 1024))MB")
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

        // 阶段 3：组装并写入 moov
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

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
