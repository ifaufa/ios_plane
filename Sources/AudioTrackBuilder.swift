import Foundation

/// 用 AVAssetWriter 已产出的视频文件 + 我们自己写的音频轨，合成最终的 MP4
/// 输出布局：ftyp(视频) + mdat(视频，原样搬移) + mdat(音频，新建) + moov{mvhd + 视频 trak + 音频 trak}
/// 视频 trak 的 chunk 偏移保持不变（ftyp/mdat 位置一致），无需重算
enum AudioTrackBuilder {
    struct BuildError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func build(videoURL: URL,
                      audioFrames: [Data],
                      sampleRate: Int,
                      channels: Int,
                      asc: Data,
                      destination: URL) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: videoURL.path) else {
            throw BuildError(message: "视频文件不存在")
        }
        guard !audioFrames.isEmpty else {
            throw BuildError(message: "没有音频帧")
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        let source = try FileHandle(forReadingFrom: videoURL)
        defer { try? source.close() }
        let sourceSize = try source.seekToEnd()

        // 1) 扫描视频文件顶层 box
        var ftypRange: (offset: UInt64, size: UInt64)?
        var mdatRange: (offset: UInt64, size: UInt64)?
        var moovRange: (offset: UInt64, size: UInt64)?
        var cursor: UInt64 = 0
        while cursor + 8 <= sourceSize {
            try source.seek(toOffset: cursor)
            guard let header = try source.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(header.u32(at: 0))
            let type = header.ascii(at: 4, length: 4)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 { size = header.u64(at: 8); headerLength = 16 }
            else if size == 0 { size = sourceSize - cursor }
            guard size >= headerLength else { break }
            switch type {
            case "ftyp": ftypRange = (cursor, size)
            case "mdat": mdatRange = (cursor, size)
            case "moov": moovRange = (cursor, size)
            default: break
            }
            cursor += size
        }
        guard let ftypRange, let mdatRange, let moovRange else {
            throw BuildError(message: "视频文件缺少 ftyp/mdat/moov")
        }

        // 2) 读视频 moov，取出 mvhd 与视频 trak
        try source.seek(toOffset: moovRange.offset)
        guard let moovData = try source.read(upToCount: Int(moovRange.size)) else {
            throw BuildError(message: "读取视频 moov 失败")
        }
        guard let mvhd = childBox(in: moovData, from: 8, to: moovData.count, type: "mvhd") else {
            throw BuildError(message: "视频 moov 缺少 mvhd")
        }
        guard let videoTrak = videoTrackBox(in: moovData) else {
            throw BuildError(message: "视频 moov 缺少视频 trak")
        }

        // 3) 计算音频参数
        let ascData = asc.isEmpty ? Data([0x11, 0x90]) : asc
        let esds = MP4AudioFixer.makeESDS(asc: ascData)
        let framesPerSecond = Double(sampleRate) / 1024.0
        let audioSeconds = Double(audioFrames.count) / max(1.0, framesPerSecond)

        // 4) 写目标文件
        let dest = try FileHandle(forWritingTo: createFile(at: destination))
        defer { try? dest.close() }

        // 4.1 ftyp（原样）
        try source.seek(toOffset: ftypRange.offset)
        if let ftyp = try source.read(upToCount: Int(ftypRange.size)) {
            try dest.write(contentsOf: ftyp)
        }
        let ftypSize = ftypRange.size

        // 4.2 单个 mdat：视频负载（原样）+ 音频负载
        // 视频 mdat 头长度（8 或 16）
        try source.seek(toOffset: mdatRange.offset)
        guard let mdatHeader = try source.read(upToCount: 16), mdatHeader.count >= 8 else {
            throw BuildError(message: "读取视频 mdat 头失败")
        }
        let videoHeaderLength: UInt64 = mdatHeader.u32(at: 0) == 1 ? 16 : 8
        let videoPayloadSize = mdatRange.size - videoHeaderLength
        var audioPayloadSize: UInt64 = 0
        for frame in audioFrames { audioPayloadSize += UInt64(frame.count) }

        // mdat 头（总负载）
        try dest.write(contentsOf: boxHeader(type: "mdat", payloadSize: videoPayloadSize + audioPayloadSize))

        // 视频负载（跳过原 mdat 头）
        try source.seek(toOffset: mdatRange.offset + videoHeaderLength)
        var remaining = videoPayloadSize
        while remaining > 0 {
            let chunkSize = Int(min(remaining, 4 << 20))
            guard let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try dest.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }

        // 音频负载 + chunk 偏移（每 32 个样本一个 chunk）
        let samplesPerChunk = 32
        var audioOffsets: [UInt32] = []
        var running = ftypSize + 8 + videoPayloadSize
        var index = 0
        while index < audioFrames.count {
            audioOffsets.append(UInt32(min(running, UInt64(UInt32.max))))
            let end = min(index + samplesPerChunk, audioFrames.count)
            for frameIndex in index..<end {
                let frame = audioFrames[frameIndex]
                try dest.write(contentsOf: frame)
                running += UInt64(frame.count)
            }
            index = end
        }

        // 4.4 moov
        var mvhdPatched = mvhd
        let timescale = mvhd.u32(at: 20)
        let durationOffset = 24
        if timescale > 0, durationOffset + 4 <= mvhdPatched.count {
            var audioDur = UInt32(min(Double(UInt32.max), audioSeconds * Double(timescale)))
            let current = mvhdPatched.u32(at: durationOffset)
            if audioDur < current { audioDur = current }
            mvhdPatched.replaceSubrange(durationOffset..<(durationOffset + 4),
                                        with: withUnsafeBytes(of: audioDur.bigEndian) { Data($0) })
        }

        let trackID = UInt32(2)
        let trak = makeAudioTrak(frameCount: audioFrames.count,
                                 sizes: audioFrames.map { $0.count },
                                 offsets: audioOffsets,
                                 samplesPerChunk: samplesPerChunk,
                                 sampleRate: sampleRate,
                                 channels: channels,
                                 esds: esds,
                                 timescale: timescale,
                                 duration: Double(audioFrames.count) * 1024.0 / Double(max(1, sampleRate)),
                                 trackID: trackID)

        var moovBody = Data()
        moovBody.append(mvhdPatched)
        moovBody.append(videoTrak)
        moovBody.append(trak)
        var moov = boxHeader(type: "moov", payloadSize: UInt64(moovBody.count))
        moov.append(moovBody)
        try dest.write(contentsOf: moov)

        let finalSize = ftypSize + 8 + videoPayloadSize + audioPayloadSize + UInt64(moov.count)
        return "音频轨已自建并合并 帧=\(audioFrames.count) 采样率=\(sampleRate) 总大小=\(finalSize)B"
    }

    // MARK: - 音频 trak

    private static func makeAudioTrak(frameCount: Int,
                                      sizes: [Int],
                                      offsets: [UInt32],
                                      samplesPerChunk: Int,
                                      sampleRate: Int,
                                      channels: Int,
                                      esds: Data,
                                      timescale: UInt32,
                                      duration: Double,
                                      trackID: UInt32) -> Data {
        let mediaDuration = UInt32(min(Double(UInt32.max), Double(frameCount) * 1024.0))
        let movieDuration = UInt32(min(Double(UInt32.max), duration * Double(max(1, timescale))))

        // tkhd
        var tkhdBody = Data()
        tkhdBody.append(contentsOf: [0x00, 0x00, 0x00, 0x03])       // version 0, flags 3（enabled+inMovie）
        tkhdBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])       // creation/modification
        tkhdBody.append(contentsOf: be32(trackID))
        tkhdBody.append(contentsOf: [0, 0, 0, 0])                   // reserved
        tkhdBody.append(contentsOf: be32(movieDuration))
        tkhdBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])       // reserved
        tkhdBody.append(contentsOf: [0, 0])                         // layer
        tkhdBody.append(contentsOf: [0, 0])                         // alternate group
        tkhdBody.append(contentsOf: [0x01, 0x00])                   // volume 1.0
        tkhdBody.append(contentsOf: [0, 0])                         // reserved
        tkhdBody.append(contentsOf: identityMatrix())
        tkhdBody.append(contentsOf: [0, 0, 0, 0])                   // width
        tkhdBody.append(contentsOf: [0, 0, 0, 0])                   // height
        let tkhd = box(type: "tkhd", body: tkhdBody)

        // mdhd
        var mdhdBody = Data()
        mdhdBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        mdhdBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        mdhdBody.append(contentsOf: be32(UInt32(max(8000, sampleRate))))
        mdhdBody.append(contentsOf: be32(mediaDuration))
        mdhdBody.append(contentsOf: [0x55, 0xC4, 0x00, 0x00])       // language 'und' + pre_defined
        let mdhd = box(type: "mdhd", body: mdhdBody)

        // hdlr
        var hdlrBody = Data()
        hdlrBody.append(contentsOf: [0, 0, 0, 0])
        hdlrBody.append(contentsOf: [0, 0, 0, 0])
        hdlrBody.append("soun".data(using: .ascii)!)
        hdlrBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        hdlrBody.append("SoundHandler".data(using: .ascii)!)
        hdlrBody.append(0)
        let hdlr = box(type: "hdlr", body: hdlrBody)

        // smhd
        var smhdBody = Data()
        smhdBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        let smhd = box(type: "smhd", body: smhdBody)

        // dinf/dref
        var urlBody = Data()
        urlBody.append(contentsOf: [0x00, 0x00, 0x00, 0x01])       // flags = self-contained
        let url = box(type: "url ", body: urlBody)
        var drefBody = Data()
        drefBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        drefBody.append(contentsOf: be32(1))
        drefBody.append(url)
        let dref = box(type: "dref", body: drefBody)
        let dinf = box(type: "dinf", body: dref)

        // stsd / mp4a + esds
        var mp4aBody = Data()
        mp4aBody.append(contentsOf: [0, 0, 0, 0, 0, 0])             // reserved
        mp4aBody.append(contentsOf: [0x00, 0x01])                   // data ref index
        mp4aBody.append(contentsOf: [0, 0])                         // version
        mp4aBody.append(contentsOf: [0, 0])                         // revision
        mp4aBody.append(contentsOf: [0, 0, 0, 0])                   // vendor
        mp4aBody.append(contentsOf: be16(UInt16(max(1, channels))))
        mp4aBody.append(contentsOf: be16(16))                       // sample size
        mp4aBody.append(contentsOf: [0, 0])                         // pre_defined
        mp4aBody.append(contentsOf: [0, 0])                         // reserved
        mp4aBody.append(contentsOf: be32(UInt32(max(8000, sampleRate)) << 16))
        mp4aBody.append(esds)
        let mp4a = box(type: "mp4a", body: mp4aBody)

        var stsdBody = Data()
        stsdBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stsdBody.append(contentsOf: be32(1))
        stsdBody.append(mp4a)
        let stsd = box(type: "stsd", body: stsdBody)

        // stts：单条记录（每帧 1024 采样）
        var sttsBody = Data()
        sttsBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        sttsBody.append(contentsOf: be32(1))
        sttsBody.append(contentsOf: be32(UInt32(frameCount)))
        sttsBody.append(contentsOf: be32(1024))
        let stts = box(type: "stts", body: sttsBody)

        // stsc：每 chunk 固定样本数，尾块单独一条
        let chunkCount = max(1, offsets.count)
        let remainder = frameCount % samplesPerChunk
        var stscEntries: [(UInt32, UInt32)] = []
        if remainder == 0 || chunkCount <= 1 {
            stscEntries = [(1, UInt32(max(1, remainder == 0 ? samplesPerChunk : frameCount)))]
        } else {
            stscEntries = [(1, UInt32(samplesPerChunk)), (UInt32(chunkCount), UInt32(remainder))]
        }
        var stscBody = Data()
        stscBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stscBody.append(contentsOf: be32(UInt32(stscEntries.count)))
        for (firstChunk, samples) in stscEntries {
            stscBody.append(contentsOf: be32(firstChunk))
            stscBody.append(contentsOf: be32(samples))
            stscBody.append(contentsOf: be32(1))
        }
        let stsc = box(type: "stsc", body: stscBody)

        // stsz
        var stszBody = Data()
        stszBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stszBody.append(contentsOf: be32(0))
        stszBody.append(contentsOf: be32(UInt32(frameCount)))
        for size in sizes { stszBody.append(contentsOf: be32(UInt32(size))) }
        let stsz = box(type: "stsz", body: stszBody)

        // stco
        var stcoBody = Data()
        stcoBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stcoBody.append(contentsOf: be32(UInt32(offsets.count)))
        for offset in offsets { stcoBody.append(contentsOf: be32(offset)) }
        let stco = box(type: "stco", body: stcoBody)

        var stblBody = Data()
        stblBody.append(stsd)
        stblBody.append(stts)
        stblBody.append(stsc)
        stblBody.append(stsz)
        stblBody.append(stco)
        let stbl = box(type: "stbl", body: stblBody)

        var minfBody = Data()
        minfBody.append(smhd)
        minfBody.append(dinf)
        minfBody.append(stbl)
        let minf = box(type: "minf", body: minfBody)

        var mdiaBody = Data()
        mdiaBody.append(mdhd)
        mdiaBody.append(hdlr)
        mdiaBody.append(minf)
        let mdia = box(type: "mdia", body: mdiaBody)

        var trakBody = Data()
        trakBody.append(tkhd)
        trakBody.append(mdia)
        return box(type: "trak", body: trakBody)
    }

    // MARK: - box 工具

    private static func identityMatrix() -> [UInt8] {
        let values: [Int32] = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]
        var bytes: [UInt8] = []
        for value in values { bytes.append(contentsOf: be32(UInt32(bitPattern: value))) }
        return bytes
    }

    private static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func box(type: String, body: Data) -> Data {
        var data = boxHeader(type: type, payloadSize: UInt64(body.count))
        data.append(body)
        return data
    }

    private static func boxHeader(type: String, payloadSize: UInt64) -> Data {
        var header = Data()
        if payloadSize + 8 > UInt64(UInt32.max) {
            header.append(contentsOf: be32(1))
            header.append(type.data(using: .ascii)!)
            header.append(contentsOf: [
                UInt8((payloadSize + 16) >> 56), UInt8(((payloadSize + 16) >> 48) & 0xFF),
                UInt8(((payloadSize + 16) >> 40) & 0xFF), UInt8(((payloadSize + 16) >> 32) & 0xFF),
                UInt8(((payloadSize + 16) >> 24) & 0xFF), UInt8(((payloadSize + 16) >> 16) & 0xFF),
                UInt8(((payloadSize + 16) >> 8) & 0xFF), UInt8((payloadSize + 16) & 0xFF)
            ])
        } else {
            header.append(contentsOf: be32(UInt32(payloadSize + 8)))
            header.append(type.data(using: .ascii)!)
        }
        return header
    }

    private static func createFile(at url: URL) throws -> URL {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw BuildError(message: "无法创建输出文件")
        }
        return url
    }

    private static func childBox(in data: Data, from: Int, to: Int, type: String) -> Data? {
        var cursor = from
        while cursor + 8 <= to {
            let size = Int(data.u32(at: cursor))
            let boxType = data.ascii(at: cursor + 4, length: 4)
            guard size >= 8, cursor + size <= to else { return nil }
            if boxType == type { return data.subdata(in: cursor..<(cursor + size)) }
            cursor += size
        }
        return nil
    }

    private static func videoTrackBox(in moov: Data) -> Data? {
        var cursor = 8
        while cursor + 8 <= moov.count {
            let size = Int(moov.u32(at: cursor))
            let type = moov.ascii(at: cursor + 4, length: 4)
            guard size >= 8, cursor + size <= moov.count else { return nil }
            if type == "trak" {
                let trak = moov.subdata(in: cursor..<(cursor + size))
                if trak.range(of: Data("vmhd".utf8)) != nil { return trak }
            }
            cursor += size
        }
        return nil
    }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(self[startIndex + offset + index]) }
        return value
    }

    func u64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(self[startIndex + offset + index]) }
        return value
    }

    func ascii(at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "????" }
        return String(decoding: self[(startIndex + offset)..<(startIndex + offset + length)], as: UTF8.self)
    }
}
