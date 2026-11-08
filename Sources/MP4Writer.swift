import Foundation

/// 极简 MP4 写出：H.264(avc1) + AAC(mp4a)，每个样本单独成 chunk（简化 stsc/stco）
final class MP4Writer {
    enum WriteError: LocalizedError {
        case io(String)
        var errorDescription: String? {
            switch self {
            case .io(let message): return message
            }
        }
    }

    private struct SampleMeta {
        var offset: UInt64
        var size: UInt32
        var dts: Int64
        var ctts: Int32
        var isKey: Bool
    }

    private let url: URL
    private var handle: FileHandle
    private let video: TSDemuxer.VideoInfo
    private let audio: TSDemuxer.AudioInfo?

    private var videoSamples: [SampleMeta] = []
    private var audioSamples: [SampleMeta] = []

    private var mdatStart: UInt64 = 0
    private var mdatHeaderStart: UInt64 = 0
    private var writeOffset: UInt64 = 0

    private var audioCounter: Int64 = 0
    private var audioTickTimescale: Int32 = 0

    init(url: URL, video: TSDemuxer.VideoInfo, audio: TSDemuxer.AudioInfo?) throws {
        self.url = url
        self.video = video
        self.audio = audio
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        fm.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw WriteError.io("无法创建输出文件")
        }
        self.handle = handle
        try writeHeader()
    }

    // MARK: - 写入

    private func writeHeader() throws {
        var head = Data()
        head.append(box("ftyp", payload: {
            var p = Data()
            p.append(ascii("isom"))
            p.append(UInt32(512).be)
            p.append(ascii("isom"))
            p.append(ascii("iso2"))
            p.append(ascii("avc1"))
            p.append(ascii("mp41"))
            return p
        }()))

        mdatHeaderStart = UInt64(head.count)
        head.append(UInt32(1).be)              // size = 1 表示使用 64 位长度
        head.append(ascii("mdat"))
        head.append(UInt64(0).be)              // largesize 占位
        mdatStart = UInt64(head.count)

        try handle.write(contentsOf: head)
        writeOffset = mdatStart
    }

    func appendVideo(_ data: Data, pts: Int64, dts: Int64, isKey: Bool) throws {
        let offset = writeOffset
        try handle.write(contentsOf: data)
        writeOffset += UInt64(data.count)
        let ctts = Int32(clamping: Int(pts - dts))
        videoSamples.append(SampleMeta(offset: offset, size: UInt32(clamping: data.count),
                                       dts: dts, ctts: ctts, isKey: isKey))
    }

    func appendAudio(_ data: Data) throws {
        let offset = writeOffset
        try handle.write(contentsOf: data)
        writeOffset += UInt64(data.count)
        let dts = audioCounter * 1024
        audioCounter += 1
        audioSamples.append(SampleMeta(offset: offset, size: UInt32(clamping: data.count),
                                       dts: dts, ctts: 0, isKey: true))
    }

    // MARK: - 收尾

    func finish() throws {
        guard !videoSamples.isEmpty else {
            throw WriteError.io("没有采集到视频帧")
        }
        // 回填 mdat 长度
        let totalMdat = writeOffset - mdatHeaderStart + 8
        try handle.seek(toOffset: mdatHeaderStart + 8)
        try handle.write(contentsOf: UInt64(totalMdat).be)
        try handle.seekToEnd()

        let moov = buildMoov()
        try handle.write(contentsOf: moov)
        try? handle.close()
    }

    func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - moov

    private func buildMoov() -> Data {
        let videoTimescale: Int32 = 90000
        let videoDurations = durations(for: videoSamples, timescale: videoTimescale, defaultDelta: 3000)
        let videoDuration = videoDurations.reduce(0, +)

        var audioTimescale: Int32 = 0
        var audioDuration: Int64 = 0
        var audioDeltas: [Int32] = []
        if !audioSamples.isEmpty {
            audioTimescale = Int32(max(8000, audio?.sampleRate ?? 44100))
            audioDeltas = Array(repeating: 1024, count: audioSamples.count)
            audioDuration = Int64(audioDeltas.count) * 1024
        }

        let movieTimescale: Int32 = 1000
        let maxDuration = max(videoDuration, audioDuration * Int64(movieTimescale) / Int64(max(1, audioTimescale)))
        let movieDuration = Int32(clamping: Int(maxDuration))

        var traks = Data()
        traks.append(videoTrak(videoDurations: videoDurations,
                               timescale: videoTimescale,
                               duration: videoDuration))
        if !audioSamples.isEmpty {
            traks.append(audioTrak(deltas: audioDeltas,
                                   timescale: audioTimescale,
                                   duration: audioDuration))
        }

        var mvhdPayload = Data()
        mvhdPayload.append(UInt32(0).be)                 // creation
        mvhdPayload.append(UInt32(0).be)                 // modification
        mvhdPayload.append(UInt32(movieTimescale).be)
        mvhdPayload.append(UInt32(movieDuration).be)
        mvhdPayload.append(UInt32(0x00010000).be)        // rate
        mvhdPayload.append(UInt16(0x0100).be)            // volume
        mvhdPayload.append(Data(repeating: 0, count: 10))
        mvhdPayload.append(matrix())
        mvhdPayload.append(Data(repeating: 0, count: 24))
        mvhdPayload.append(UInt32(audioSamples.isEmpty ? 2 : 3).be) // next track id

        var moovPayload = Data()
        moovPayload.append(fullBox("mvhd", version: 0, flags: 0, payload: mvhdPayload))
        moovPayload.append(traks)
        return box("moov", payload: moovPayload)
    }

    private func videoTrak(videoDurations: [Int32], timescale: Int32, duration: Int64) -> Data {
        var tkhdPayload = Data()
        tkhdPayload.append(UInt32(0).be)
        tkhdPayload.append(UInt32(0).be)
        tkhdPayload.append(UInt32(1).be)                  // track id
        tkhdPayload.append(UInt32(0).be)
        tkhdPayload.append(UInt32(clamping: Int(duration * 1000 / Int64(timescale))).be)
        tkhdPayload.append(Data(repeating: 0, count: 8))
        tkhdPayload.append(UInt16(0).be)                  // layer
        tkhdPayload.append(UInt16(0).be)                  // alternate group
        tkhdPayload.append(UInt16(0).be)                  // volume (video=0)
        tkhdPayload.append(UInt16(0).be)
        tkhdPayload.append(matrix())
        tkhdPayload.append((UInt32(max(0, video.width)) << 16).be)
        tkhdPayload.append((UInt32(max(0, video.height)) << 16).be)

        var mdhdPayload = Data()
        mdhdPayload.append(UInt32(0).be)
        mdhdPayload.append(UInt32(0).be)
        mdhdPayload.append(UInt32(timescale).be)
        mdhdPayload.append(UInt32(clamping: Int(duration)).be)
        mdhdPayload.append(UInt16(0x55C4).be)
        mdhdPayload.append(UInt16(0).be)

        let stbl = videoStbl(durations: videoDurations, timescale: timescale)
        let minf = box("minf", payload: fullBox("vmhd", version: 0, flags: 1, payload: {
            var p = Data()
            p.append(UInt16(0).be)
            p.append(Data(repeating: 0, count: 6))
            return p
        }()) + dinf() + stbl)

        let mdia = box("mdia", payload: fullBox("mdhd", version: 0, flags: 0, payload: mdhdPayload)
            + fullBox("hdlr", version: 0, flags: 0, payload: handlerPayload(type: "vide", name: "VideoHandler"))
            + minf)

        return box("trak", payload: fullBox("tkhd", version: 0, flags: 7, payload: tkhdPayload) + mdia)
    }

    private func audioTrak(deltas: [Int32], timescale: Int32, duration: Int64) -> Data {
        var tkhdPayload = Data()
        tkhdPayload.append(UInt32(0).be)
        tkhdPayload.append(UInt32(0).be)
        tkhdPayload.append(UInt32(2).be)
        tkhdPayload.append(UInt32(0).be)
        tkhdPayload.append(UInt32(clamping: Int(duration * 1000 / Int64(timescale))).be)
        tkhdPayload.append(Data(repeating: 0, count: 8))
        tkhdPayload.append(UInt16(0).be)
        tkhdPayload.append(UInt16(0).be)
        tkhdPayload.append(UInt16(0x0100).be)
        tkhdPayload.append(UInt16(0).be)
        tkhdPayload.append(matrix())
        tkhdPayload.append(UInt32(0).be)
        tkhdPayload.append(UInt32(0).be)

        var mdhdPayload = Data()
        mdhdPayload.append(UInt32(0).be)
        mdhdPayload.append(UInt32(0).be)
        mdhdPayload.append(UInt32(timescale).be)
        mdhdPayload.append(UInt32(clamping: Int(duration)).be)
        mdhdPayload.append(UInt16(0x55C4).be)
        mdhdPayload.append(UInt16(0).be)

        var sttsRuns: [(Int32, Int32)] = []
        var count: Int32 = 0
        for delta in deltas {
            if let last = sttsRuns.last, last.1 == delta {
                sttsRuns[sttsRuns.count - 1].0 += 1
            } else {
                sttsRuns.append((1, delta))
            }
            count += 1
        }
        _ = count

        var sttsPayload = Data()
        sttsPayload.append(UInt32(sttsRuns.count).be)
        for run in sttsRuns {
            sttsPayload.append(UInt32(run.0).be)
            sttsPayload.append(UInt32(run.1).be)
        }

        var stszPayload = Data()
        stszPayload.append(UInt32(0).be)
        stszPayload.append(UInt32(audioSamples.count).be)
        for sample in audioSamples { stszPayload.append(UInt32(sample.size).be) }

        var offsets = Data()
        var use64 = false
        for sample in audioSamples where sample.offset > UInt64(UInt32.max) { use64 = true }

        var stcoPayload = Data()
        stcoPayload.append(UInt32(audioSamples.count).be)
        for sample in audioSamples {
            if use64 { offsets.append(sample.offset.be) } else { offsets.append(UInt32(sample.offset).be) }
        }

        let stbl = box("stbl", payload: stsdAudio() 
            + fullBox("stts", version: 0, flags: 0, payload: sttsPayload)
            + fullBox("stsc", version: 0, flags: 0, payload: {
                var p = Data()
                p.append(UInt32(1).be)
                p.append(UInt32(1).be)
                p.append(UInt32(1).be)
                p.append(UInt32(1).be)
                return p
            }())
            + fullBox("stsz", version: 0, flags: 0, payload: stszPayload)
            + fullBox(use64 ? "co64" : "stco", version: 0, flags: 0, payload: stcoPayload))

        let minf = box("minf", payload: fullBox("smhd", version: 0, flags: 0, payload: {
            var p = Data()
            p.append(UInt16(0).be)
            p.append(UInt16(0).be)
            return p
        }()) + dinf() + stbl)

        let mdia = box("mdia", payload: fullBox("mdhd", version: 0, flags: 0, payload: mdhdPayload)
            + fullBox("hdlr", version: 0, flags: 0, payload: handlerPayload(type: "soun", name: "SoundHandler"))
            + minf)

        return box("trak", payload: fullBox("tkhd", version: 0, flags: 7, payload: tkhdPayload) + mdia)
    }

    private func videoStbl(durations: [Int32], timescale: Int32) -> Data {
        _ = timescale
        var sttsRuns: [(Int32, Int32)] = []
        for delta in durations {
            if let last = sttsRuns.last, last.1 == delta {
                sttsRuns[sttsRuns.count - 1].0 += 1
            } else {
                sttsRuns.append((1, delta))
            }
        }
        var sttsPayload = Data()
        sttsPayload.append(UInt32(sttsRuns.count).be)
        for run in sttsRuns {
            sttsPayload.append(UInt32(run.0).be)
            sttsPayload.append(UInt32(run.1).be)
        }

        var cttsPayload = Data()
        cttsPayload.append(UInt32(videoSamples.count).be)
        for sample in videoSamples { cttsPayload.append(UInt32(bitPattern: sample.ctts).be) }

        var stssPayload = Data()
        let keys = videoSamples.enumerated().filter { $0.element.isKey }.map { UInt32($0.offset + 1) }
        stssPayload.append(UInt32(keys.count).be)
        for key in keys { stssPayload.append(key.be) }

        var stszPayload = Data()
        stszPayload.append(UInt32(0).be)
        stszPayload.append(UInt32(videoSamples.count).be)
        for sample in videoSamples { stszPayload.append(UInt32(sample.size).be) }

        var use64 = false
        for sample in videoSamples where sample.offset > UInt64(UInt32.max) { use64 = true }
        var stcoPayload = Data()
        stcoPayload.append(UInt32(videoSamples.count).be)
        for sample in videoSamples {
            if use64 { stcoPayload.append(sample.offset.be) } else { stcoPayload.append(UInt32(sample.offset).be) }
        }

        let stsc = fullBox("stsc", version: 0, flags: 0, payload: {
            var p = Data()
            p.append(UInt32(1).be)
            p.append(UInt32(1).be)
            p.append(UInt32(1).be)
            p.append(UInt32(1).be)
            return p
        }())

        return box("stbl", payload: stsdVideo()
            + fullBox("stts", version: 0, flags: 0, payload: sttsPayload)
            + fullBox("ctts", version: 0, flags: 0, payload: cttsPayload)
            + fullBox("stss", version: 0, flags: 0, payload: stssPayload)
            + stsc
            + fullBox("stsz", version: 0, flags: 0, payload: stszPayload)
            + fullBox(use64 ? "co64" : "stco", version: 0, flags: 0, payload: stcoPayload))
    }

    private func stsdVideo() -> Data {
        var avcCPayload = Data()
        avcCPayload.append(UInt8(1))
        avcCPayload.append(video.profileLevel.0)
        avcCPayload.append(UInt8(0))
        avcCPayload.append(video.profileLevel.1)
        avcCPayload.append(UInt8(0xFF))                   // lengthSizeMinusOne = 3
        avcCPayload.append(UInt8(0xE1))                   // 1 个 SPS
        avcCPayload.append(UInt16(video.sps.count).be)
        avcCPayload.append(video.sps)
        avcCPayload.append(UInt8(1))                      // 1 个 PPS
        avcCPayload.append(UInt16(video.pps.count).be)
        avcCPayload.append(video.pps)
        let avcC = box("avcC", payload: avcCPayload)

        var entry = Data()
        entry.append(Data(repeating: 0, count: 6))        // reserved
        entry.append(UInt16(1).be)                        // data ref index
        entry.append(UInt16(0).be)
        entry.append(UInt16(0).be)
        entry.append(Data(repeating: 0, count: 12))
        entry.append(UInt16(video.width).be)
        entry.append(UInt16(video.height).be)
        entry.append(UInt32(0x00480000).be)
        entry.append(UInt32(0x00480000).be)
        entry.append(UInt32(0).be)
        entry.append(UInt16(1).be)                        // frame count
        entry.append(Data(repeating: 0, count: 32))       // compressor name
        entry.append(UInt16(0x0018).be)                   // depth
        entry.append(UInt16(0xFFFF).be)
        entry.append(avcC)

        var stsd = Data()
        stsd.append(UInt32(1).be)
        stsd.append(box("avc1", payload: entry))
        return fullBox("stsd", version: 0, flags: 0, payload: stsd)
    }

    private func stsdAudio() -> Data {
        let rate = audio?.sampleRate ?? 44100
        let channels = audio?.channels ?? 2
        let asc = audio?.audioSpecificConfig ?? Data([0x12, 0x10])

        var esdsBody = Data()
        // ES_Descriptor
        var decoderConfig = Data()
        decoderConfig.append(UInt8(0x40))                 // AAC
        decoderConfig.append(UInt8(0x15))                 // AudioStream
        decoderConfig.append(Data(repeating: 0, count: 3))
        decoderConfig.append(UInt32(0).be)
        decoderConfig.append(UInt32(0).be)
        decoderConfig.append(descriptor(0x05, payload: asc))
        let dcd = descriptor(0x04, payload: decoderConfig)

        var esPayload = Data()
        esPayload.append(UInt16(1).be)                    // ES_ID
        esPayload.append(UInt8(0))                        // flags
        esPayload.append(dcd)
        esPayload.append(descriptor(0x06, payload: Data([0x02])))
        let es = descriptor(0x03, payload: esPayload)
        esdsBody.append(es)

        var entry = Data()
        entry.append(Data(repeating: 0, count: 6))
        entry.append(UInt16(1).be)
        entry.append(Data(repeating: 0, count: 8))
        entry.append(UInt16(channels).be)
        entry.append(UInt16(16).be)
        entry.append(UInt16(0).be)
        entry.append(UInt16(0).be)
        entry.append(UInt32(rate << 16).be)
        entry.append(fullBox("esds", version: 0, flags: 0, payload: esdsBody))

        var stsd = Data()
        stsd.append(UInt32(1).be)
        stsd.append(box("mp4a", payload: entry))
        return fullBox("stsd", version: 0, flags: 0, payload: stsd)
    }

    private func dinf() -> Data {
        var urlPayload = Data()
        urlPayload.append(UInt8(0))
        return box("dinf", payload: fullBox("dref", version: 0, flags: 0, payload: {
            var p = Data()
            p.append(UInt32(1).be)
            p.append(fullBox("url ", version: 0, flags: 1, payload: Data()))
            return p
        }()))
    }

    private func handlerPayload(type: String, name: String) -> Data {
        var p = Data()
        p.append(UInt32(0).be)
        p.append(ascii(type))
        p.append(Data(repeating: 0, count: 12))
        p.append(name.data(using: .utf8) ?? Data())
        p.append(UInt8(0))
        return p
    }

    private func durations(for samples: [SampleMeta], timescale: Int32, defaultDelta: Int32) -> [Int32] {
        _ = timescale
        var result: [Int32] = []
        for index in samples.indices {
            let delta: Int64
            if index + 1 < samples.count {
                delta = samples[index + 1].dts - samples[index].dts
            } else {
                delta = Int64(defaultDelta)
            }
            result.append(Int32(clamping: Int(max(1, min(delta, 90000)))))
        }
        return result
    }

    // MARK: - Box 工具

    private func matrix() -> Data {
        var p = Data()
        for value in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] {
            p.append(UInt32(value).be)
        }
        return p
    }

    private func descriptor(_ tag: UInt8, payload: Data) -> Data {
        var data = Data()
        data.append(tag)
        var length = payload.count
        // 简化写法：长度 < 128 时单字节
        if length >= 128 {
            data.append(UInt8(0x80 | ((length >> 7) & 0x7F)))
            data.append(UInt8(length & 0x7F))
        } else {
            data.append(UInt8(length))
        }
        length = 0
        data.append(payload)
        return data
    }

    private func ascii(_ text: String) -> Data {
        text.data(using: .ascii) ?? Data()
    }

    private func box(_ type: String, payload: Data) -> Data {
        var data = Data()
        data.append(UInt32(payload.count + 8).be)
        data.append(ascii(type))
        data.append(payload)
        return data
    }

    private func fullBox(_ type: String, version: UInt8, flags: UInt32, payload: Data) -> Data {
        var data = Data()
        data.append(UInt8(version))
        data.append(UInt8((flags >> 16) & 0xFF))
        data.append(UInt8((flags >> 8) & 0xFF))
        data.append(UInt8(flags & 0xFF))
        data.append(payload)
        return box(type, payload: data)
    }
}

extension UInt32 {
    var be: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 4)
    }
}

extension UInt16 {
    var be: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 2)
    }
}

extension UInt64 {
    var be: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 8)
    }
}
