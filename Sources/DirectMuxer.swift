import Foundation

/// 自研 MP4 封装器：不经 AVAssetWriter，直接按 ISO 结构写文件
/// 布局：ftyp | mdat(视频样本 + 音频样本) | moov
/// 优点：绕开 AVAssetWriter 的内部样本校验（-11800 / -16364），无大文件内存积压
final class DirectMuxer {
    struct MuxError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let handle: FileHandle
    private let destination: URL

    private var mdatContentStart: UInt64 = 0
    private var writeOffset: UInt64 = 0

    private var videoSizes: [Int32] = []
    private var videoCtts: [Int32] = []
    private var videoKeyframes: [Int32] = []
    private var videoChunkOffsets: [UInt64] = []
    private var videoChunkSamples = 0

    private let samplesPerChunk = 32

    init(destination: URL) throws {
        self.destination = destination
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw MuxError(message: "无法创建输出文件")
        }
        self.handle = handle

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
    }

    var videoSampleCount: Int { videoSizes.count }
    var keyframeCount: Int { videoKeyframes.count }

    func appendVideo(data: Data, isKey: Bool, pts: Int64, dts: Int64) throws {
        if videoChunkSamples == 0 {
            videoChunkOffsets.append(writeOffset)
        }
        try handle.write(contentsOf: data)
        writeOffset += UInt64(data.count)

        videoSizes.append(Int32(data.count))
        videoCtts.append(Int32(pts - dts))
        if isKey { videoKeyframes.append(Int32(videoSizes.count - 1)) }

        videoChunkSamples += 1
        if videoChunkSamples >= samplesPerChunk { videoChunkSamples = 0 }
    }

    // MARK: - 收尾

    func finish(width: Int,
                height: Int,
                sps: Data,
                pps: Data,
                frameStep: Int64,
                sampleRate: Int,
                channels: Int,
                asc: Data,
                audioSpoolURL: URL?,
                audioSizes: [Int]) throws -> String {
        var audioOffsets: [UInt64] = []
        if let audioSpoolURL, !audioSizes.isEmpty {
            let spool = try FileHandle(forReadingFrom: audioSpoolURL)
            defer { try? spool.close() }
            var index = 0
            while index < audioSizes.count {
                audioOffsets.append(writeOffset)
                let end = min(index + samplesPerChunk, audioSizes.count)
                for frameIndex in index..<end {
                    let size = audioSizes[frameIndex]
                    guard let chunk = try? spool.read(upToCount: size), chunk.count == size else {
                        throw MuxError(message: "音频临时文件读取不完整（帧 \(frameIndex)）")
                    }
                    try handle.write(contentsOf: chunk)
                    writeOffset += UInt64(size)
                }
                index = end
            }
        }

        var ctts = videoCtts
        var editShift: Int64 = 0
        if let minOffset = ctts.min(), minOffset < 0 {
            editShift = Int64(-minOffset)
            for index in ctts.indices { ctts[index] += Int32(editShift) }
        }

        let totalTicks = Int64(videoSizes.count) * frameStep
        let movieTimescale: UInt32 = 1000
        let movieDuration = UInt32(min(Double(UInt32.max),
                                       Double(totalTicks) / 90000.0 * Double(movieTimescale)))

        let videoTrak = MP4PartMerger.makeVideoTrak(sampleCount: videoSizes.count,
                                                    sizes: videoSizes,
                                                    ctts: ctts,
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
                                                        sizes: audioSizes,
                                                        offsets: audioOffsets.map { UInt32(min($0, UInt64(UInt32.max))) },
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
        try handle.write(contentsOf: moov)
        DiagnosticsLog.write("[转MP4] moov 已写入 \(moov.count)B 视频样本=\(videoSizes.count) 关键帧=\(videoKeyframes.count) 音频帧=\(audioSizes.count)")

        let totalMdat = 16 + (writeOffset - mdatContentStart)
        var sizeBytes = Data()
        sizeBytes.append(contentsOf: (0..<8).map { UInt8((totalMdat >> (56 - UInt64($0) * 8)) & 0xFF) })
        try handle.seek(toOffset: mdatContentStart - 8)
        try handle.write(contentsOf: sizeBytes)
        try handle.close()

        let finalSize = writeOffset + UInt64(moov.count)
        return "自研封装完成 视频样本=\(videoSizes.count) 关键帧=\(videoKeyframes.count) 音频帧=\(audioSizes.count) 总大小=\(finalSize)B"
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
