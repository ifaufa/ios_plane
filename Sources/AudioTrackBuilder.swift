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
                      destination: URL,
                      keyframeIndices: [Int32] = []) throws -> String {
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
        guard var videoTrak = videoTrackBox(in: moovData) else {
            throw BuildError(message: "视频 moov 缺少视频 trak")
        }

        // 补写同步样本表：现有产物全部缺 stss，导致 seek 可能落在非 IDR 帧
        let writeStss = UserDefaults.standard.object(forKey: "mp4WriteStss") as? Bool ?? true
        if writeStss, !keyframeIndices.isEmpty {
            let patched = try addSyncSampleTable(to: videoTrak, indices: keyframeIndices)
            if patched.count > videoTrak.count {
                videoTrak = patched
                DiagnosticsLog.write("[转MP4] 已补写 stss 条目=\(keyframeIndices.count)")
            }
        } else if !writeStss {
            DiagnosticsLog.write("[转MP4] 已关闭 stss 补写（设置项）")
        }

        // 3) 计算音频参数
        let ascData = asc.isEmpty ? Data([0x11, 0x90]) : asc
        let esds = MP4AudioFixer.makeESDS(asc: ascData)
        let framesPerSecond = Double(sampleRate) / 1024.0
        let audioSeconds = Double(audioFrames.count) / max(1.0, framesPerSecond)

        // 4) 写目标文件
        let dest = try FileHandle(forWritingTo: createFile(at: destination))
        defer { try? dest.close() }

        // 4.1 mdat 之前的全部内容（ftyp/free 等）原样搬运，保证视频绝对偏移不变
        try source.seek(toOffset: 0)
        var prefixRemaining = mdatRange.offset
        while prefixRemaining > 0 {
            let chunkSize = Int(min(prefixRemaining, 4 << 20))
            guard let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try dest.write(contentsOf: chunk)
            prefixRemaining -= UInt64(chunk.count)
        }

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

        // mdat 头（总负载，沿用原头长度以保证负载起点一致）
        let totalPayload = videoPayloadSize + audioPayloadSize
        if videoHeaderLength == 16 {
            var header = Data()
            header.append(contentsOf: [0, 0, 0, 1])
            header.append("mdat".data(using: .ascii)!)
            let value = totalPayload + 16
            header.append(contentsOf: (0..<8).map { UInt8((value >> (56 - $0 * 8)) & 0xFF) })
            try dest.write(contentsOf: header)
        } else {
            guard totalPayload + 8 <= UInt64(UInt32.max) else {
                throw BuildError(message: "单 mdat 超过 4GB，暂不支持")
            }
            try dest.write(contentsOf: boxHeader(type: "mdat", payloadSize: totalPayload))
        }

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
        var running = mdatRange.offset + videoHeaderLength + videoPayloadSize
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

        let finalSize = mdatRange.offset + videoHeaderLength + videoPayloadSize + audioPayloadSize + UInt64(moov.count)
        return "音频轨已自建并合并 帧=\(audioFrames.count) 采样率=\(sampleRate) 总大小=\(finalSize)B"
    }

    // MARK: - 原地合并（P1：不产生第三份副本）

    /// 直接把 AVAssetWriter 产出的纯视频文件「就地」升级为含音频的最终 MP4：
    /// 截掉旧 moov → 改写 mdat 尺寸 → 追加音频负载 → 追加新 moov
    /// 峰值磁盘 = 分片 + 这一个文件（≈2S），不再产生第二份完整副本
    static func mergeInPlace(videoURL: URL,
                             audioFrames: [Data],
                             sampleRate: Int,
                             channels: Int,
                             asc: Data,
                             keyframeIndices: [Int32] = []) throws -> String {
        guard !audioFrames.isEmpty else {
            throw BuildError(message: "没有音频帧")
        }

        let handle = try FileHandle(forUpdating: videoURL)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        // 1) 扫描顶层 box
        var mdatRange: (offset: UInt64, size: UInt64)?
        var moovRange: (offset: UInt64, size: UInt64)?
        var cursor: UInt64 = 0
        while cursor + 8 <= fileSize {
            try handle.seek(toOffset: cursor)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(header.u32(at: 0))
            let type = header.ascii(at: 4, length: 4)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 { size = header.u64(at: 8); headerLength = 16 }
            else if size == 0 { size = fileSize - cursor }
            guard size >= headerLength else { break }
            if type == "mdat" { mdatRange = (cursor, size) }
            if type == "moov" { moovRange = (cursor, size) }
            cursor += size
        }
        guard let mdatRange, let moovRange else {
            throw BuildError(message: "原地合并失败：缺少 mdat/moov")
        }
        guard moovRange.offset > mdatRange.offset else {
            throw BuildError(message: "原地合并失败：moov 不在 mdat 之后")
        }

        // 2) 读旧 moov，取 mvhd 与视频 trak
        try handle.seek(toOffset: moovRange.offset)
        guard let moovData = try handle.read(upToCount: Int(moovRange.size)) else {
            throw BuildError(message: "读取 moov 失败")
        }
        guard let mvhd = childBox(in: moovData, from: 8, to: moovData.count, type: "mvhd") else {
            throw BuildError(message: "moov 缺少 mvhd")
        }
        guard var videoTrak = videoTrackBox(in: moovData) else {
            throw BuildError(message: "moov 缺少视频 trak")
        }

        let writeStss = UserDefaults.standard.object(forKey: "mp4WriteStss") as? Bool ?? true
        if writeStss, !keyframeIndices.isEmpty {
            let patched = try addSyncSampleTable(to: videoTrak, indices: keyframeIndices)
            if patched.count > videoTrak.count { videoTrak = patched }
        }

        // 3) 计算音频参数与负载尺寸
        let ascData = asc.isEmpty ? Data([0x11, 0x90]) : asc
        let esds = MP4AudioFixer.makeESDS(asc: ascData)
        let timescale = mvhd.u32(at: 20)
        let audioSeconds = Double(audioFrames.count) * 1024.0 / Double(max(1, sampleRate))

        try handle.seek(toOffset: mdatRange.offset)
        guard let mdatHeader = try handle.read(upToCount: 16), mdatHeader.count >= 8 else {
            throw BuildError(message: "读取 mdat 头失败")
        }
        let headerLength: UInt64 = mdatHeader.u32(at: 0) == 1 ? 16 : 8
        let videoPayloadSize = mdatRange.size - headerLength
        var audioPayloadSize: UInt64 = 0
        for frame in audioFrames { audioPayloadSize += UInt64(frame.count) }
        let totalPayload = videoPayloadSize + audioPayloadSize

        // 4) 截掉旧 moov
        try handle.truncate(atOffset: moovRange.offset)

        // 5) 改写 mdat 尺寸（原地，只动头部的 size 字段）
        var newHeader = Data()
        if headerLength == 16 {
            newHeader.append(contentsOf: [0, 0, 0, 1])
            newHeader.append("mdat".data(using: .ascii)!)
            let value = totalPayload + 16
            newHeader.append(contentsOf: (0..<8).map { UInt8((value >> (56 - UInt64($0) * 8)) & 0xFF) })
        } else {
            guard totalPayload + 8 <= UInt64(UInt32.max) else {
                throw BuildError(message: "单 mdat 超过 4GB，暂不支持原地合并")
            }
            newHeader.append(contentsOf: be32(UInt32(totalPayload + 8)))
            newHeader.append("mdat".data(using: .ascii)!)
        }
        try handle.seek(toOffset: mdatRange.offset)
        try handle.write(contentsOf: newHeader)

        // 6) 追加音频负载（chunk 偏移 = 绝对位置）
        let samplesPerChunk = 32
        var audioOffsets: [UInt32] = []
        var running = mdatRange.offset + headerLength + videoPayloadSize
        var index = 0
        try handle.seek(toOffset: running)
        while index < audioFrames.count {
            audioOffsets.append(UInt32(min(running, UInt64(UInt32.max))))
            let end = min(index + samplesPerChunk, audioFrames.count)
            for frameIndex in index..<end {
                let frame = audioFrames[frameIndex]
                try handle.write(contentsOf: frame)
                running += UInt64(frame.count)
            }
            index = end
        }

        // 7) 组装并追加新 moov
        var mvhdPatched = mvhd
        if timescale > 0, 28 <= mvhdPatched.count {
            var audioDuration = UInt32(min(Double(UInt32.max), audioSeconds * Double(timescale)))
            let current = mvhdPatched.u32(at: 24)
            if audioDuration < current { audioDuration = current }
            mvhdPatched.replaceSubrange(24..<28,
                                        with: withUnsafeBytes(of: audioDuration.bigEndian) { Data($0) })
        }

        let audioTrak = makeAudioTrak(frameCount: audioFrames.count,
                                      sizes: audioFrames.map { $0.count },
                                      offsets: audioOffsets,
                                      samplesPerChunk: samplesPerChunk,
                                      sampleRate: sampleRate,
                                      channels: channels,
                                      esds: esds,
                                      timescale: timescale,
                                      duration: audioSeconds,
                                      trackID: 2)

        var moovBody = Data()
        moovBody.append(mvhdPatched)
        moovBody.append(videoTrak)
        moovBody.append(audioTrak)
        var moov = boxHeader(type: "moov", payloadSize: UInt64(moovBody.count))
        moov.append(moovBody)
        try handle.seek(toOffset: running)
        try handle.write(contentsOf: moov)

        let finalSize = running + UInt64(moov.count)
        return "原地合并完成 帧=\(audioFrames.count) 采样率=\(sampleRate) 总大小=\(finalSize)B"
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

    // MARK: - stss 补写

    /// 在视频 trak 的 stbl 末尾插入 stss，并逐级修正父 box 尺寸
    private static func addSyncSampleTable(to trak: Data, indices: [Int32]) throws -> Data {
        guard let mdia = childRange(trak, in: 8..<trak.count, type: "mdia"),
              let minf = childRange(trak, in: (mdia.lowerBound + 8)..<mdia.upperBound, type: "minf"),
              let stbl = childRange(trak, in: (minf.lowerBound + 8)..<minf.upperBound, type: "stbl") else {
            DiagnosticsLog.write("[转MP4] stss 补写失败：找不到 stbl")
            return trak
        }
        if childRange(trak, in: (stbl.lowerBound + 8)..<stbl.upperBound, type: "stss") != nil {
            return trak
        }

        // 样本总数（stsz 的 sample_count 位于 box 起始 +16）
        guard let stsz = childRange(trak, in: (stbl.lowerBound + 8)..<stbl.upperBound, type: "stsz") else {
            throw BuildError(message: "stss 写入失败：缺少 stsz，无法校验样本范围")
        }
        let sampleCount = Int(trak.u32(at: stsz.lowerBound + 16))
        guard sampleCount > 0 else {
            throw BuildError(message: "stss 写入失败：stsz 样本数为 0")
        }

        // ISO BMFF：sample_number 从 1 开始，且必须严格递增、不超过样本总数
        var entries: [UInt32] = []
        entries.reserveCapacity(indices.count)
        var lastEntry: UInt32 = 0
        for index in indices {
            let number = UInt32(index) + 1
            guard number >= 1, number > lastEntry, number <= UInt32(sampleCount) else {
                throw BuildError(message: "stss 写入失败：样本号 \(number) 非法（范围 1…\(sampleCount)）")
            }
            lastEntry = number
            entries.append(number)
        }
        guard !entries.isEmpty else {
            throw BuildError(message: "stss 写入失败：关键帧序号为空")
        }

        var payload = Data()
        payload.append(contentsOf: [0, 0, 0, 0])                 // version/flags
        payload.append(contentsOf: be32(UInt32(entries.count)))  // entry_count
        for number in entries { payload.append(contentsOf: be32(number)) }

        var stss = Data()
        stss.append(contentsOf: be32(UInt32(payload.count + 8)))
        stss.append("stss".data(using: .ascii)!)
        stss.append(payload)

        var result = trak
        result.insert(contentsOf: stss, at: stbl.upperBound)

        let delta = UInt32(stss.count)
        // 从内到外修正尺寸：stbl → minf → mdia → trak
        for range in [stbl, minf, mdia] {
            let current = result.u32(at: range.lowerBound)
            result.replaceSubrange(range.lowerBound..<(range.lowerBound + 4),
                                   with: withUnsafeBytes(of: (current + delta).bigEndian) { Data($0) })
        }
        let trakSize = result.u32(at: 0)
        result.replaceSubrange(0..<4, with: withUnsafeBytes(of: (trakSize + delta).bigEndian) { Data($0) })

        // 自检：子 box 之和必须等于 trak 长度
        var cursor = 8
        var sum = 8
        while cursor + 8 <= result.count {
            let size = Int(result.u32(at: cursor))
            guard size >= 8, cursor + size <= result.count else { break }
            cursor += size
            sum += size
        }
        guard sum == result.count else {
            throw BuildError(message: "stss 写入失败：尺寸链不自洽（\(sum) ≠ \(result.count)）")
        }
        DiagnosticsLog.write("[转MP4] stss 写入自检通过 条目=\(entries.count) 首个=\(entries.first ?? 0) 末个=\(entries.last ?? 0) 样本总数=\(sampleCount)")
        return result
    }

    private static func childRange(_ data: Data, in range: Range<Int>, type: String) -> Range<Int>? {
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size = Int(data.u32(at: cursor))
            let boxType = data.ascii(at: cursor + 4, length: 4)
            guard size >= 8, cursor + size <= range.upperBound else { return nil }
            if boxType == type { return cursor..<(cursor + size) }
            cursor += size
        }
        return nil
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
