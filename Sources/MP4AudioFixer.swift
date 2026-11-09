import Foundation

/// 修补 AVAssetWriter 产出的音频轨：mp4a 样本描述缺少 esds 时手工补写
/// 前置条件：moov 位于文件末尾（AVAssetWriter 的顺序：ftyp → mdat → moov），
/// 因此增长 moov 不会影响 stco/co64 指向的 mdat 偏移
enum MP4AudioFixer {
    static func fix(url: URL, asc: Data, sampleRate: Int = 0, audioChannels: Int = 2, handlerType: String = "soun") -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无法打开" }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return "无法读取大小" }

        // 1) 定位 moov
        var offset: UInt64 = 0
        var moovOffset: UInt64?
        var moovSize: UInt64 = 0
        var moovHeaderLength: UInt64 = 8
        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(header.u32(at: 0))
            let type = header.ascii(at: 4, length: 4)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 {
                size = header.u64(at: 8)
                headerLength = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerLength else { break }
            if type == "moov" {
                moovOffset = offset
                moovSize = size
                moovHeaderLength = headerLength
                break
            }
            offset += size
        }
        guard let moovOffset, moovSize > 16 else { return "未找到 moov" }
        guard moovOffset + moovSize == fileSize else {
            return "moov 不在文件末尾（offset=\(moovOffset) size=\(moovSize) total=\(fileSize)），跳过修补"
        }

        try? handle.seek(toOffset: moovOffset)
        guard var moov = try? handle.read(upToCount: Int(moovSize)) else { return "读取 moov 失败" }

        // 2) 找音频 trak
        let bodyStart = Int(moovHeaderLength)
        guard let trakRange = findTrak(in: moov, bodyStart: bodyStart, handlerType: handlerType) else {
            return "未找到 \(handlerType) 轨"
        }
        guard let stsdRange = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["mdia", "minf", "stbl", "stsd"]),
              let entryRange = firstSampleEntry(in: moov, stsdRange: stsdRange) else {
            return "未找到音频样本描述"
        }

        let entryType = moov.ascii(at: entryRange.lowerBound + 4, length: 4)
        let entrySize = entryRange.count
        let hexHead = moov.subdata(in: entryRange).prefix(96).map { String(format: "%02x", $0) }.joined(separator: " ")
        guard entryType == "mp4a" else {
            return "音频样本描述类型=\(entryType)（非 mp4a）hex=\(hexHead)"
        }

        // 3) 轨头字段规范化（就地改 4 字节，不影响尺寸）
        var notes: [String] = []
        // 3.0) mp4a 样本描述固定字段（声道/位宽/采样率）规范化
        let entryHex = moov.subdata(in: entryRange).prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        notes.append("mp4a hex=\(entryHex)")
        if entryRange.count >= 36, sampleRate > 0 {
            let base = entryRange.lowerBound
            let channels = UInt16(min(8, max(1, audioChannels)))
            let rate16 = UInt32(min(96000, max(8000, sampleRate))) << 16
            moov.replaceSubrange((base + 24)..<(base + 26), with: withUnsafeBytes(of: channels.bigEndian) { Data($0) })
            moov.replaceSubrange((base + 26)..<(base + 28), with: withUnsafeBytes(of: UInt16(16).bigEndian) { Data($0) })
            moov.replaceSubrange((base + 32)..<(base + 36), with: withUnsafeBytes(of: rate16.bigEndian) { Data($0) })
        }
        if let tkhd = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["tkhd"]) {
            let flagsField = moov.u32(at: tkhd.lowerBound + 8)
            let flags = flagsField & 0xFFFFFF
            if flags & 0x1 == 0 {
                let newFlags = (flagsField & 0xFF000000) | (flags | 0x1)
                moov.replaceSubrange((tkhd.lowerBound + 8)..<(tkhd.lowerBound + 12),
                                     with: withUnsafeBytes(of: newFlags.bigEndian) { Data($0) })
                notes.append("启用音轨(tkhd flags 0x\(String(format: "%06x", flags))→0x\(String(format: "%06x", flags | 1)))")
            }
        }
        if let mdhd = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["mdia", "mdhd"]) {
            let version = moov.u32(at: mdhd.lowerBound + 8) >> 24
            let tsOffset = mdhd.lowerBound + 8 + 4 + (version == 1 ? 16 : 8)
            let timescale = moov.u32(at: tsOffset)
            if timescale == 0 || timescale > 1_000_000 {
                let fixed = UInt32(max(8000, sampleRate))
                moov.replaceSubrange(tsOffset..<(tsOffset + 4), with: withUnsafeBytes(of: fixed.bigEndian) { Data($0) })
                notes.append("修正 mdhd timescale \(timescale)→\(fixed)")
            }
        }
        if !notes.isEmpty {
            DiagnosticsLog.write("[转MP4] 音轨头修正：\(notes.joined(separator: "；"))")
        }

        // 4) 已有 esds？AVAssetWriter 可能写入"裸 ASC"（无描述符层级），必须替换
        let childrenStart = entryRange.lowerBound + 36
        var replaceRange: Range<Int>?
        let newESDS = buildESDS(asc: asc)
        if let existing = findChild(moov, from: childrenStart, to: entryRange.upperBound, type: "esds") {
            let hex = moov.subdata(in: existing).prefix(48).map { String(format: "%02x", $0) }.joined(separator: " ")
            let payloadTag = existing.lowerBound + 12 < existing.upperBound ? moov[moov.startIndex + existing.lowerBound + 12] : 0
            if payloadTag == 0x03 {
                return "esds 结构正常 size=\(existing.count) hex=\(hex)"
            }
            replaceRange = existing
            DiagnosticsLog.write("[转MP4] esds 结构非法（裸 ASC），替换为合规描述符：原 hex=\(hex)")
        }

        // 4) 写入 esds（替换非法的 / 插入缺失的）
        let delta: Int
        if let replaceRange {
            delta = newESDS.count - replaceRange.count
            moov.replaceSubrange(replaceRange, with: newESDS)
        } else {
            delta = newESDS.count
            moov.insert(contentsOf: newESDS, at: entryRange.upperBound)
        }
        let esds = Data(repeating: 0, count: delta)   // 仅用于尺寸换算

        // 5) 逐级修正父 box 尺寸（样本描述、stsd、stbl、minf、mdia、trak、moov）
        var containers: [Range<Int>] = [entryRange, stsdRange, trakRange]
        if let stbl = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["mdia", "minf", "stbl"]) { containers.append(stbl) }
        if let minf = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["mdia", "minf"]) { containers.append(minf) }
        if let mdia = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["mdia"]) { containers.append(mdia) }
        // 从内到外（先小范围后大范围）修正尺寸，避免范围失效
        let ordered = containers.sorted { $0.count < $1.count }
        for range in ordered {
            let newSize = UInt32(range.count + delta)
            moov.replaceSubrange(range.lowerBound..<(range.lowerBound + 4), with: withUnsafeBytes(of: newSize.bigEndian) { Data($0) })
        }
        let newMoovSize = UInt32(moov.count)
        moov.replaceSubrange(0..<4, with: withUnsafeBytes(of: newMoovSize.bigEndian) { Data($0) })

        // 6) 写回（moov 在末尾，直接覆盖 + 截断）
        try? handle.seek(toOffset: moovOffset)
        try? handle.write(contentsOf: moov)
        try? handle.truncate(atOffset: moovOffset + UInt64(moov.count))

        return "esds 已写入（新增 \(delta)B，ASC=\(asc.map { String(format: "%02x", $0) }.joined())）"
    }

    /// 打印音频轨关键参数（tkhd/mdhd/stts/stsz），用于定位被系统丢弃的原因
    static func inspectAudioTrack(url: URL, handlerType: String = "soun") -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无法打开" }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return "无法读取大小" }

        var offset: UInt64 = 0
        var moovOffset: UInt64?
        var moovSize: UInt64 = 0
        var moovHeaderLength: UInt64 = 8
        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(header.u32(at: 0))
            let type = header.ascii(at: 4, length: 4)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 { size = header.u64(at: 8); headerLength = 16 }
            else if size == 0 { size = fileSize - offset }
            guard size >= headerLength else { break }
            if type == "moov" { moovOffset = offset; moovSize = size; moovHeaderLength = headerLength; break }
            offset += size
        }
        guard let moovOffset else { return "无 moov" }
        try? handle.seek(toOffset: moovOffset)
        guard let moov = try? handle.read(upToCount: Int(moovSize)) else { return "读 moov 失败" }

        guard let trakRange = findTrak(in: moov, bodyStart: Int(moovHeaderLength), handlerType: handlerType) else {
            return "无 \(handlerType) 轨"
        }
        var parts: [String] = []
        if let tkhd = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["tkhd"]) {
            let flags = moov.u32(at: tkhd.lowerBound + 8) & 0xFFFFFF
            let duration = moov.u32(at: tkhd.lowerBound + 8 + 4 + 8 + 8)
            parts.append("tkhd flags=0x\(String(format: "%06x", flags)) dur=\(duration)")
        }
        if let mdhd = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["mdia", "mdhd"]) {
            let version = moov.u32(at: mdhd.lowerBound + 8) >> 24
            let timescale: UInt32 = version == 1 ? moov.u32(at: mdhd.lowerBound + 8 + 4 + 16) : moov.u32(at: mdhd.lowerBound + 8 + 4 + 8)
            let duration: UInt64 = version == 1 ? moov.u64(at: mdhd.lowerBound + 8 + 4 + 20) : UInt64(moov.u32(at: mdhd.lowerBound + 8 + 4 + 12))
            parts.append("mdhd v=\(version) timescale=\(timescale) dur=\(duration)")
        }
        if let edts = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["edts", "elst"]) {
            let count = moov.u32(at: edts.lowerBound + 12)
            parts.append("elst v=\(moov.u32(at: edts.lowerBound + 8) >> 24) count=\(count)")
            if count > 0 {
                let entry = edts.lowerBound + 16
                parts.append("elst0 segDur=\(moov.u32(at: entry)) mediaTime=\(Int32(bitPattern: moov.u32(at: entry + 4)))")
            }
        } else {
            parts.append("无 edts")
        }
        if let stts = descend(moov, from: trakRange.lowerBound + 8, upper: trakRange.upperBound, path: ["mdia", "minf", "stbl", "stts"]) {
            parts.append("stts entries=\(moov.u32(at: stts.lowerBound + 12))")
        }
        return parts.joined(separator: " ")
    }
    // MARK: - esds 构造

    private static func buildESDS(asc: Data) -> Data {
        // DecoderSpecificInfo (0x05)
        var dsi = Data([0x05])
        dsi.append(contentsOf: descriptorLength(asc.count))
        dsi.append(asc)

        // DecoderConfigDescriptor (0x04)
        var dcd = Data([0x04])
        var dcdBody = Data([0x40])                       // objectTypeIndication: MPEG-4 Audio
        dcdBody.append(0x15)                             // streamType=5(audio)<<2 | upStream=0 | reserved=1
        dcdBody.append(contentsOf: [0x00, 0x18, 0x00])   // bufferSizeDB
        dcdBody.append(contentsOf: [0x00, 0x03, 0x00, 0x00]) // maxBitrate
        dcdBody.append(contentsOf: [0x00, 0x02, 0x00, 0x00]) // avgBitrate
        dcdBody.append(dsi)
        dcd.append(contentsOf: descriptorLength(dcdBody.count))
        dcd.append(dcdBody)

        // SLConfigDescriptor (0x06)
        let slc = Data([0x06, 0x01, 0x02])

        // ES_Descriptor (0x03)
        var esBody = Data([0x00, 0x01, 0x00])            // ES_ID=1, flags=0
        esBody.append(dcd)
        esBody.append(slc)
        var es = Data([0x03])
        es.append(contentsOf: descriptorLength(esBody.count))
        es.append(esBody)

        var payload = Data([0x00, 0x00, 0x00, 0x00])     // version/flags
        payload.append(es)
        var box = Data()
        let size = UInt32(8 + payload.count)
        box.append(withUnsafeBytes(of: size.bigEndian) { Data($0) })
        box.append("esds".data(using: .ascii)!)
        box.append(payload)
        return box
    }

    /// MPEG-4 描述符长度编码（每字节 7 位）
    private static func descriptorLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F), at: 0)
            value >>= 7
        }
        for index in 0..<(bytes.count - 1) { bytes[index] |= 0x80 }
        return bytes
    }

    // MARK: - box 导航

    private static func findTrak(in data: Data, bodyStart: Int, handlerType: String) -> Range<Int>? {
        var cursor = bodyStart
        while cursor + 8 <= data.count {
            let size = Int(data.u32(at: cursor))
            let type = data.ascii(at: cursor + 4, length: 4)
            guard size >= 8, cursor + size <= data.count else { return nil }
            if type == "trak" {
                let range = cursor..<(cursor + size)
                if let hdlr = descend(data, from: cursor + 8, upper: cursor + size, path: ["mdia", "hdlr"]),
                   data.ascii(at: hdlr.lowerBound + 16, length: 4) == handlerType {
                    return range
                }
            }
            cursor += size
        }
        return nil
    }

    private static func descend(_ data: Data, from: Int, upper: Int, path: [String]) -> Range<Int>? {
        var cursor = from
        var currentUpper = upper
        for (index, type) in path.enumerated() {
            var found: Range<Int>?
            var scan = cursor
            while scan + 8 <= currentUpper {
                let size = Int(data.u32(at: scan))
                let boxType = data.ascii(at: scan + 4, length: 4)
                guard size >= 8, scan + size <= currentUpper else { break }
                if boxType == type {
                    found = scan..<(scan + size)
                    break
                }
                scan += size
            }
            guard let range = found else { return nil }
            if index == path.count - 1 { return range }
            cursor = range.lowerBound + 8
            currentUpper = range.upperBound
        }
        return nil
    }

    private static func firstSampleEntry(in data: Data, stsdRange: Range<Int>) -> Range<Int>? {
        let entryStart = stsdRange.lowerBound + 16   // 8(box) + 4(version/flags) + 4(count)
        guard entryStart + 8 <= stsdRange.upperBound else { return nil }
        let size = Int(data.u32(at: entryStart))
        guard size >= 16, entryStart + size <= stsdRange.upperBound else { return nil }
        return entryStart..<(entryStart + size)
    }

    private static func findChild(_ data: Data, from: Int, to: Int, type: String) -> Range<Int>? {
        var cursor = from
        while cursor + 8 <= to {
            let size = Int(data.u32(at: cursor))
            let boxType = data.ascii(at: cursor + 4, length: 4)
            guard size >= 8, cursor + size <= to else { return nil }
            if boxType == type { return cursor..<(cursor + size) }
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
