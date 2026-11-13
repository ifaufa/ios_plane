import Foundation

/// 分段输出的合并器：把多段纯视频 MP4 拼成一个完整 MP4（视频轨重建 + 音频轨追加）
/// 目的：避免单个 AVAssetWriter 处理 2GB+ 产物导致内存积压/停滞
enum MP4PartMerger {
    struct MergeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func merge(partURLs: [URL],
                      sizes: [Int32],
                      ctts: [Int32],
                      keyframeIndices: [Int32],
                      frameStep: Int64,
                      width: Int,
                      height: Int,
                      sps: Data,
                      pps: Data,
                      audioSpoolURL: URL?,
                      audioSizes: [Int],
                      sampleRate: Int,
                      channels: Int,
                      asc: Data,
                      destination: URL) throws -> String {
        guard !partURLs.isEmpty else { throw MergeError(message: "没有分段产物") }
        guard sizes.count == ctts.count, !sizes.isEmpty else {
            throw MergeError(message: "样本表不一致（sizes=\(sizes.count) ctts=\(ctts.count)）")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)

        // 1) 扫描各段 mdat 负载
        var payloads: [(url: URL, offset: UInt64, size: UInt64)] = []
        var ftypData: Data?
        for url in partURLs {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            var cursor: UInt64 = 0
            var mdat: (UInt64, UInt64)?
            while cursor + 8 <= fileSize {
                try handle.seek(toOffset: cursor)
                guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
                var size = UInt64(header.u32(at: 0))
                let type = header.ascii(at: 4, length: 4)
                var headerLength: UInt64 = 8
                if size == 1, header.count >= 16 { size = header.u64(at: 8); headerLength = 16 }
                else if size == 0 { size = fileSize - cursor }
                guard size >= headerLength else { break }
                if type == "mdat" { mdat = (cursor + headerLength, size - headerLength) }
                if type == "ftyp", ftypData == nil {
                    try handle.seek(toOffset: cursor)
                    ftypData = try handle.read(upToCount: Int(min(size, 256)))
                }
                cursor += size
            }
            guard let mdat else { throw MergeError(message: "分段缺少 mdat：\(url.lastPathComponent)") }
            payloads.append((url, mdat.0, mdat.1))
        }

        let videoPayloadTotal = payloads.reduce(UInt64(0)) { $0 + $1.size }
        let expectedVideo = sizes.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard videoPayloadTotal >= expectedVideo else {
            throw MergeError(message: "分段负载小于样本总和（\(videoPayloadTotal) < \(expectedVideo)）")
        }

        let dest = try FileHandle(forWritingTo: destination)
        defer { try? dest.close() }

        // 2) ftyp
        var ftyp = ftypData ?? Data()
        if ftyp.isEmpty {
            var body = Data()
            body.append("isom".data(using: .ascii)!)
            body.append(contentsOf: be32(512))
            body.append("isom".data(using: .ascii)!)
            body.append("iso2".data(using: .ascii)!)
            body.append("avc1".data(using: .ascii)!)
            body.append("mp41".data(using: .ascii)!)
            ftyp = box(type: "ftyp", body: body)
        }
        try dest.write(contentsOf: ftyp)

        // 3) mdat 头（16 字节，末尾回填）
        var mdatHeader = Data()
        mdatHeader.append(contentsOf: [0, 0, 0, 1])
        mdatHeader.append("mdat".data(using: .ascii)!)
        mdatHeader.append(contentsOf: [UInt8](repeating: 0, count: 8))
        try dest.write(contentsOf: mdatHeader)

        let mdatStart = UInt64(ftyp.count + 16)
        var running = mdatStart

        // 4) 视频负载
        for payload in payloads {
            let handle = try FileHandle(forReadingFrom: payload.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: payload.offset)
            var remaining = payload.size
            while remaining > 0 {
                let chunkSize = Int(min(remaining, 4 << 20))
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                try dest.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
            running += payload.size
        }

        // 5) 音频负载
        let samplesPerChunk = 32
        var audioOffsets: [UInt32] = []
        if let audioSpoolURL, !audioSizes.isEmpty {
            let spool = try FileHandle(forReadingFrom: audioSpoolURL)
            defer { try? spool.close() }
            var index = 0
            while index < audioSizes.count {
                audioOffsets.append(UInt32(min(running, UInt64(UInt32.max))))
                let end = min(index + samplesPerChunk, audioSizes.count)
                for frameIndex in index..<end {
                    let size = audioSizes[frameIndex]
                    guard let chunk = try? spool.read(upToCount: size), chunk.count == size else {
                        throw MergeError(message: "音频临时文件读取不完整（帧 \(frameIndex)）")
                    }
                    try dest.write(contentsOf: chunk)
                    running += UInt64(size)
                }
                index = end
            }
        }

        // 6) 视频 chunk 偏移（每 32 样本一块）
        var chunkOffsets: [UInt64] = []
        var offsetCursor = mdatStart
        var cursorSample = 0
        while cursorSample < sizes.count {
            chunkOffsets.append(offsetCursor)
            let end = min(cursorSample + samplesPerChunk, sizes.count)
            for i in cursorSample..<end { offsetCursor += UInt64(sizes[i]) }
            cursorSample = end
        }

        // 7) ctts 归一化（避免负值）
        var cttsValues = ctts
        let minOffset = cttsValues.min() ?? 0
        var editShift: Int64 = 0
        if minOffset < 0 {
            editShift = Int64(-minOffset)
            for i in 0..<cttsValues.count { cttsValues[i] += Int32(editShift) }
        }

        let totalTicks = Int64(sizes.count) * frameStep
        let movieTimescale: UInt32 = 1000
        let movieDuration = UInt32(min(Double(UInt32.max),
                                       Double(totalTicks) / 90000.0 * Double(movieTimescale)))

        let videoTrak = makeVideoTrak(sampleCount: sizes.count,
                                      sizes: sizes,
                                      ctts: cttsValues,
                                      keyframes: keyframeIndices,
                                      frameStep: frameStep,
                                      chunkOffsets: chunkOffsets,
                                      samplesPerChunk: samplesPerChunk,
                                      width: width,
                                      height: height,
                                      sps: sps,
                                      pps: pps,
                                      movieDuration: movieDuration,
                                      editShift: editShift)

        let audioSeconds = Double(audioSizes.count) * 1024.0 / Double(max(1, sampleRate))
        let audioTrak = audioSizes.isEmpty ? Data() : AudioTrackBuilder.makeAudioTrak(
            frameCount: audioSizes.count,
            sizes: audioSizes,
            offsets: audioOffsets,
            samplesPerChunk: samplesPerChunk,
            sampleRate: sampleRate,
            channels: channels,
            esds: MP4AudioFixer.makeESDS(asc: asc.isEmpty ? Data([0x11, 0x90]) : asc),
            timescale: movieTimescale,
            duration: audioSeconds,
            trackID: 2)

        var moovBody = Data()
        moovBody.append(makeMVHD(timescale: movieTimescale, duration: movieDuration, nextTrackID: 3))
        moovBody.append(videoTrak)
        if !audioTrak.isEmpty { moovBody.append(audioTrak) }
        var moov = boxHeader(type: "moov", payloadSize: UInt64(moovBody.count))
        moov.append(moovBody)
        try dest.write(contentsOf: moov)

        // 8) 回填 mdat 尺寸
        let totalMdat = 16 + (running - mdatStart)
        var sizeBytes = Data()
        sizeBytes.append(contentsOf: (0..<8).map { UInt8((totalMdat >> (56 - UInt64($0) * 8)) & 0xFF) })
        try dest.seek(toOffset: UInt64(ftyp.count + 8))
        try dest.write(contentsOf: sizeBytes)

        let finalSize = running + UInt64(moov.count)
        return "分段合并完成 段数=\(partURLs.count) 视频样本=\(sizes.count) 总大小=\(finalSize)B"
    }

    // MARK: - box 构建

    private static func makeVideoTrak(sampleCount: Int,
                                      sizes: [Int32],
                                      ctts: [Int32],
                                      keyframes: [Int32],
                                      frameStep: Int64,
                                      chunkOffsets: [UInt64],
                                      samplesPerChunk: Int,
                                      width: Int,
                                      height: Int,
                                      sps: Data,
                                      pps: Data,
                                      movieDuration: UInt32,
                                      editShift: Int64) -> Data {
        let mediaDuration = UInt32(min(Double(UInt32.max), Double(sampleCount) * Double(frameStep)))

        var tkhdBody = Data()
        tkhdBody.append(contentsOf: [0x00, 0x00, 0x00, 0x03])
        tkhdBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        tkhdBody.append(contentsOf: be32(1))
        tkhdBody.append(contentsOf: [0, 0, 0, 0])
        tkhdBody.append(contentsOf: be32(movieDuration))
        tkhdBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        tkhdBody.append(contentsOf: [0, 0, 0, 0])
        tkhdBody.append(contentsOf: [0, 0, 0, 0])
        tkhdBody.append(contentsOf: identity())
        tkhdBody.append(contentsOf: be32(UInt32(width) << 16))
        tkhdBody.append(contentsOf: be32(UInt32(height) << 16))
        let tkhd = box(type: "tkhd", body: tkhdBody)

        var edts = Data()
        if editShift > 0 {
            var elstBody = Data()
            elstBody.append(contentsOf: [0, 0, 0, 0])
            elstBody.append(contentsOf: be32(1))
            elstBody.append(contentsOf: be32(movieDuration))
            elstBody.append(contentsOf: be32(UInt32(editShift)))
            elstBody.append(contentsOf: be16(1))
            elstBody.append(contentsOf: be16(0))
            edts = box(type: "edts", body: box(type: "elst", body: elstBody))
        }

        var mdhdBody = Data()
        mdhdBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        mdhdBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        mdhdBody.append(contentsOf: be32(90000))
        mdhdBody.append(contentsOf: be32(mediaDuration))
        mdhdBody.append(contentsOf: [0x55, 0xC4, 0x00, 0x00])
        let mdhd = box(type: "mdhd", body: mdhdBody)

        var hdlrBody = Data()
        hdlrBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        hdlrBody.append(contentsOf: [0, 0, 0, 0])
        hdlrBody.append("vide".data(using: .ascii)!)
        hdlrBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        hdlrBody.append("VideoHandler".data(using: .ascii)!)
        hdlrBody.append(0)
        let hdlr = box(type: "hdlr", body: hdlrBody)

        var vmhdBody = Data()
        vmhdBody.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        vmhdBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        let vmhd = box(type: "vmhd", body: vmhdBody)

        var drefBody = Data()
        drefBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        drefBody.append(contentsOf: be32(1))
        drefBody.append(box(type: "url ", body: Data([0x00, 0x00, 0x00, 0x01])))
        let dinf = box(type: "dinf", body: box(type: "dref", body: drefBody))

        var avcCBody = Data()
        avcCBody.append(contentsOf: [1,
                                     sps.count > 0 ? sps[sps.startIndex] : 0x64,
                                     sps.count > 1 ? sps[sps.startIndex + 1] : 0x00,
                                     sps.count > 2 ? sps[sps.startIndex + 2] : 0x1F,
                                     0xFF, 0xE1])
        avcCBody.append(contentsOf: be16(UInt16(sps.count)))
        avcCBody.append(sps)
        avcCBody.append(contentsOf: [0x01])
        avcCBody.append(contentsOf: be16(UInt16(pps.count)))
        avcCBody.append(pps)
        let avcC = box(type: "avcC", body: avcCBody)

        var avc1Body = Data()
        avc1Body.append(contentsOf: [0, 0, 0, 0, 0, 0])
        avc1Body.append(contentsOf: [0x00, 0x01])
        avc1Body.append(contentsOf: [UInt8](repeating: 0, count: 16))
        avc1Body.append(contentsOf: be16(UInt16(width)))
        avc1Body.append(contentsOf: be16(UInt16(height)))
        avc1Body.append(contentsOf: be32(0x00480000))
        avc1Body.append(contentsOf: be32(0x00480000))
        avc1Body.append(contentsOf: [0, 0, 0, 0])
        avc1Body.append(contentsOf: be16(1))
        avc1Body.append(contentsOf: [UInt8](repeating: 0, count: 32))
        avc1Body.append(contentsOf: be16(0x0018))
        avc1Body.append(contentsOf: be16(0xFFFF))
        avc1Body.append(avcC)
        let avc1 = box(type: "avc1", body: avc1Body)

        var stsdBody = Data()
        stsdBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stsdBody.append(contentsOf: be32(1))
        stsdBody.append(avc1)
        let stsd = box(type: "stsd", body: stsdBody)

        var sttsBody = Data()
        sttsBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        sttsBody.append(contentsOf: be32(1))
        sttsBody.append(contentsOf: be32(UInt32(sampleCount)))
        sttsBody.append(contentsOf: be32(UInt32(frameStep)))
        let stts = box(type: "stts", body: sttsBody)

        var cttsEntries: [(count: UInt32, offset: Int32)] = []
        for value in ctts {
            if let last = cttsEntries.last, last.offset == value {
                cttsEntries[cttsEntries.count - 1].count += 1
            } else {
                cttsEntries.append((1, value))
            }
        }
        var cttsBody = Data()
        cttsBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        cttsBody.append(contentsOf: be32(UInt32(cttsEntries.count)))
        for entry in cttsEntries {
            cttsBody.append(contentsOf: be32(entry.count))
            cttsBody.append(contentsOf: be32(UInt32(bitPattern: entry.offset)))
        }
        let cttsBox = box(type: "ctts", body: cttsBody)

        let chunkCount = max(1, chunkOffsets.count)
        let remainder = sampleCount % samplesPerChunk
        var stscEntries: [(UInt32, UInt32)] = []
        if remainder == 0 || chunkCount <= 1 {
            stscEntries = [(1, UInt32(max(1, remainder == 0 ? samplesPerChunk : sampleCount)))]
        } else {
            stscEntries = [(1, UInt32(samplesPerChunk)), (UInt32(chunkCount), UInt32(remainder))]
        }
        var stscBody = Data()
        stscBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stscBody.append(contentsOf: be32(UInt32(stscEntries.count)))
        for entry in stscEntries {
            stscBody.append(contentsOf: be32(entry.0))
            stscBody.append(contentsOf: be32(entry.1))
            stscBody.append(contentsOf: be32(1))
        }
        let stsc = box(type: "stsc", body: stscBody)

        var stszBody = Data()
        stszBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stszBody.append(contentsOf: be32(0))
        stszBody.append(contentsOf: be32(UInt32(sampleCount)))
        for size in sizes { stszBody.append(contentsOf: be32(UInt32(size))) }
        let stsz = box(type: "stsz", body: stszBody)

        let needs64 = chunkOffsets.contains { $0 > UInt64(UInt32.max) }
        var offsetBody = Data()
        offsetBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        offsetBody.append(contentsOf: be32(UInt32(chunkOffsets.count)))
        if needs64 {
            for offset in chunkOffsets { offsetBody.append(contentsOf: be64(offset)) }
        } else {
            for offset in chunkOffsets { offsetBody.append(contentsOf: be32(UInt32(offset))) }
        }
        let offsets = box(type: needs64 ? "co64" : "stco", body: offsetBody)

        var stssBody = Data()
        stssBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        stssBody.append(contentsOf: be32(UInt32(keyframes.count)))
        for index in keyframes { stssBody.append(contentsOf: be32(UInt32(index) + 1)) }
        let stss = box(type: "stss", body: stssBody)

        var stblBody = Data()
        stblBody.append(stsd)
        stblBody.append(stts)
        stblBody.append(cttsBox)
        stblBody.append(stsc)
        stblBody.append(stsz)
        stblBody.append(offsets)
        if !keyframes.isEmpty { stblBody.append(stss) }
        var stbl = boxHeader(type: "stbl", payloadSize: UInt64(stblBody.count))
        stbl.append(stblBody)

        var minfBody = Data()
        minfBody.append(vmhd)
        minfBody.append(dinf)
        minfBody.append(stbl)
        var minf = boxHeader(type: "minf", payloadSize: UInt64(minfBody.count))
        minf.append(minfBody)

        var mdiaBody = Data()
        mdiaBody.append(mdhd)
        mdiaBody.append(hdlr)
        mdiaBody.append(minf)
        var mdia = boxHeader(type: "mdia", payloadSize: UInt64(mdiaBody.count))
        mdia.append(mdiaBody)

        var trakBody = Data()
        trakBody.append(tkhd)
        if !edts.isEmpty { trakBody.append(edts) }
        trakBody.append(mdia)
        var trak = boxHeader(type: "trak", payloadSize: UInt64(trakBody.count))
        trak.append(trakBody)
        return trak
    }

    private static func makeMVHD(timescale: UInt32, duration: UInt32, nextTrackID: UInt32) -> Data {
        var body = Data()
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        body.append(contentsOf: be32(timescale))
        body.append(contentsOf: be32(duration))
        body.append(contentsOf: be32(0x00010000))
        body.append(contentsOf: be16(0x0100))
        body.append(contentsOf: [0, 0])
        body.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        body.append(contentsOf: identity())
        body.append(contentsOf: [UInt8](repeating: 0, count: 24))
        body.append(contentsOf: be32(nextTrackID))
        return box(type: "mvhd", body: body)
    }

    private static func identity() -> [UInt8] {
        [0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x00, 0x00, 0x00]
    }

    private static func box(type: String, body: Data) -> Data {
        var data = boxHeader(type: type, payloadSize: UInt64(body.count))
        data.append(body)
        return data
    }

    private static func boxHeader(type: String, payloadSize: UInt64) -> Data {
        var data = Data()
        data.append(contentsOf: be32(UInt32(payloadSize + 8)))
        data.append(type.data(using: .ascii)!)
        return data
    }

    private static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func be64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (56 - UInt64($0) * 8)) & 0xFF) }
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