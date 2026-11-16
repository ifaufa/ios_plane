import Foundation

/// D1：严格结构校验（模拟外部解析器的严格程度）
/// 目的：找出 AVFoundation 宽容但外部播放器不接受的地方
enum MP4StrictValidator {

    struct Issue {
        let fatal: Bool
        let text: String
    }

    struct Report {
        var issues: [Issue] = []
        var hasFatal: Bool { issues.contains { $0.fatal } }
        var summary: String {
            if issues.isEmpty { return "全部通过" }
            return issues.map { ($0.fatal ? "致命：" : "警告：") + $0.text }.joined(separator: " | ")
        }
    }

    // MARK: - 入口

    static func validate(_ url: URL) -> Report {
        var report = Report()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            report.issues.append(Issue(fatal: true, text: "无法打开文件"))
            return report
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else {
            report.issues.append(Issue(fatal: true, text: "文件为空"))
            return report
        }

        var topBoxes: [(type: String, start: UInt64, size: UInt64)] = []
        var offset: UInt64 = 0
        while offset + 8 <= size {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var boxSize = UInt64(header.be32(0))
            let type = header.ascii(4, 4)
            var headerLength: UInt64 = 8
            if boxSize == 1, header.count >= 16 {
                boxSize = header.be64(8)
                headerLength = 16
            } else if boxSize == 0 {
                boxSize = size - offset
            }
            guard boxSize >= headerLength, offset + boxSize <= size else {
                report.issues.append(Issue(fatal: true, text: "顶层 box \(type) 尺寸非法（\(boxSize)B @\(offset)）"))
                break
            }
            topBoxes.append((type, offset, boxSize))
            offset += boxSize
        }
        if offset != size {
            report.issues.append(Issue(fatal: true, text: "顶层 box 未严格闭合（剩余 \(size - offset)B）"))
        }
        guard let moovBox = topBoxes.first(where: { $0.type == "moov" }) else {
            report.issues.append(Issue(fatal: true, text: "缺少 moov"))
            return report
        }
        guard let mdatBox = topBoxes.first(where: { $0.type == "mdat" }) else {
            report.issues.append(Issue(fatal: true, text: "缺少 mdat"))
            return report
        }
        let mdatContentStart = mdatBox.start + (mdatBox.size == 1 ? 16 : 8)
        let mdatEnd = mdatBox.start + mdatBox.size
        let moovBeforeMdat = moovBox.start < mdatBox.start

        guard let moov = readBox(handle, at: moovBox.start, size: moovBox.size) else {
            report.issues.append(Issue(fatal: true, text: "moov 读取失败"))
            return report
        }

        var trackIndex = 0
        for child in boxes(in: moov, from: 8) where child.type == "trak" {
            trackIndex += 1
            validateTrack(child.data, index: trackIndex, handle: handle,
                          mdatStart: mdatContentStart, mdatEnd: mdatEnd, report: &report)
        }
        if trackIndex == 0 {
            report.issues.append(Issue(fatal: true, text: "moov 内没有 trak"))
        }

        DiagnosticsLog.write("[严格校验] moov在mdat之后=\(!moovBeforeMdat) trak=\(trackIndex) 问题=\(report.issues.count)")
        for issue in report.issues {
            DiagnosticsLog.write("[严格校验] \(issue.fatal ? "致命" : "警告")：\(issue.text)")
        }
        if report.issues.isEmpty {
            DiagnosticsLog.write("[严格校验] 通过：box 闭合、chunk/样本表自洽、ctts 非负、stss 起始为同步样本")
        }
        return report
    }

    // MARK: - 编码参数 dump（与系统引擎产物做对照）

    static func dumpCodecInfo(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }

        // 顶层扫描：ftyp 品牌 + 定位 moov（不整体拷贝 mdat）
        var moovData: Data?
        var offset: UInt64 = 0
        while offset + 8 <= size {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var boxSize = UInt64(header.be32(0))
            let type = header.ascii(4, 4)
            var headerLength: UInt64 = 8
            if boxSize == 1, header.count >= 16 {
                boxSize = header.be64(8); headerLength = 16
            } else if boxSize == 0 {
                boxSize = size - offset
            }
            guard boxSize >= headerLength, offset + boxSize <= size else { break }

            if type == "ftyp" {
                var brands = header.ascii(8, 4)
                var pos = offset + 16
                while pos + 4 <= min(offset + boxSize, size) {
                    try? handle.seek(toOffset: pos)
                    if let b = try? handle.read(upToCount: 4), b.count == 4 { brands += "/" + b.ascii(0, 4) }
                    pos += 4
                }
                DiagnosticsLog.write("[编码参数] ftyp=" + brands)
            }
            if type == "moov" {
                try? handle.seek(toOffset: offset)
                moovData = try? handle.read(upToCount: Int(boxSize))
            }
            offset += boxSize
        }

        guard let moov = moovData else { return }
        for trak in boxes(in: moov, from: 8) where trak.type == "trak" {
            guard let mdia = firstBox(trak.data, type: "mdia"),
                  let minf = firstBox(mdia, type: "minf"),
                  let stbl = firstBox(minf, type: "stbl"),
                  let stsd = firstBox(stbl, type: "stsd") else { continue }
            for entry in boxes(in: stsd, from: 16) {
                if entry.type == "avc1" {
                    let avc1 = entry.data
                    let w = avc1.be16(32)
                    let h = avc1.be16(34)
                    let avcCStart = 86
                    if avc1.count > avcCStart + 8, avc1.ascii(avcCStart + 4, 4) == "avcC" {
                        let profile = avc1[avc1.startIndex + avcCStart + 8 + 1]
                        let level = avc1[avc1.startIndex + avcCStart + 8 + 3]
                        let lenSize = Int(avc1[avc1.startIndex + avcCStart + 8 + 4] & 0x03) + 1
                        let numSPS = Int(avc1[avc1.startIndex + avcCStart + 8 + 5] & 0x1F)
                        var pos = avcCStart + 8 + 6
                        var spsLen = 0; var spsHex = "-"
                        if numSPS > 0, pos + 2 <= avc1.count {
                            spsLen = Int(avc1.be16(pos)); pos += 2
                            spsHex = avc1.hex(pos, min(spsLen, 24)); pos += spsLen
                        }
                        var ppsLen = 0; var ppsHex = "-"
                        if pos < avc1.count {
                            let numPPS = Int(avc1[avc1.startIndex + pos]); pos += 1
                            if numPPS > 0, pos + 2 <= avc1.count {
                                ppsLen = Int(avc1.be16(pos)); pos += 2
                                ppsHex = avc1.hex(pos, min(ppsLen, 24))
                            }
                        }
                        DiagnosticsLog.write("[编码参数] avc1 " + String(w) + "x" + String(h) + " profile=0x" + String(profile, radix: 16) + " level=0x" + String(level, radix: 16) + " lenSize=" + String(lenSize) + " SPS=" + String(spsLen) + "B " + spsHex + " PPS=" + String(ppsLen) + "B " + ppsHex)
                    }
                } else if entry.type == "mp4a" {
                    let mp4a = entry.data
                    let channels = mp4a.be16(24)
                    let sr = mp4a.be32(32) >> 16
                    DiagnosticsLog.write("[编码参数] mp4a channels=" + String(channels) + " samplerate=" + String(sr))
                }
            }
        }
    }


    // MARK: - trak 校验

    private static func validateTrack(_ trak: Data, index: Int, handle: FileHandle,
                                      mdatStart: UInt64, mdatEnd: UInt64,
                                      report: inout Report) {
        let label = "trak#\(index)"
        guard let mdia = firstBox(trak, type: "mdia") else {
            report.issues.append(Issue(fatal: true, text: "\(label) 缺少 mdia"))
            return
        }
        guard let mdhd = firstBox(mdia, type: "mdhd") else {
            report.issues.append(Issue(fatal: true, text: "\(label) 缺少 mdhd"))
            return
        }
        var mediaDuration: UInt64 = 0
        if mdhd.count >= 24 {
            let version = mdhd[mdhd.startIndex]
            mediaDuration = version == 0 ? UInt64(mdhd.be32(24)) : mdhd.be64(28)
        }
        guard let minf = firstBox(mdia, type: "minf"),
              let stbl = firstBox(minf, type: "stbl") else {
            report.issues.append(Issue(fatal: true, text: "\(label) 缺少 stbl"))
            return
        }

        if firstBox(stbl, type: "stsd") == nil {
            report.issues.append(Issue(fatal: true, text: "\(label) 缺少 stsd"))
        }

        guard let stsz = firstBox(stbl, type: "stsz"), stsz.count >= 20 else {
            report.issues.append(Issue(fatal: true, text: "\(label) 缺少 stsz"))
            return
        }
        let sampleSizeConst = stsz.be32(12)
        let sampleCount = Int(stsz.be32(16))
        var sizes: [UInt64] = []
        sizes.reserveCapacity(sampleCount)
        if sampleSizeConst != 0 {
            sizes = Array(repeating: UInt64(sampleSizeConst), count: sampleCount)
        } else {
            guard stsz.count >= 20 + sampleCount * 4 else {
                report.issues.append(Issue(fatal: true, text: "\(label) stsz 条目不足（声明 \(sampleCount)）"))
                return
            }
            for i in 0..<sampleCount { sizes.append(UInt64(stsz.be32(20 + i * 4))) }
        }
        let totalBytes = sizes.reduce(UInt64(0), +)

        guard let stsc = firstBox(stbl, type: "stsc"), stsc.count >= 16 else {
            report.issues.append(Issue(fatal: true, text: "\(label) 缺少 stsc"))
            return
        }
        let stscCount = Int(stsc.be32(12))
        guard stsc.count >= 16 + stscCount * 12 else {
            report.issues.append(Issue(fatal: true, text: "\(label) stsc 条目不足"))
            return
        }
        var runs: [(firstChunk: Int, perChunk: Int)] = []
        for i in 0..<stscCount {
            let base = 16 + i * 12
            runs.append((Int(stsc.be32(base)), Int(stsc.be32(base + 4))))
        }

        var chunkOffsets: [UInt64] = []
        if let stco = firstBox(stbl, type: "stco") {
            let n = Int(stco.be32(12))
            guard stco.count >= 16 + n * 4 else {
                report.issues.append(Issue(fatal: true, text: "\(label) stco 条目不足"))
                return
            }
            for i in 0..<n { chunkOffsets.append(UInt64(stco.be32(16 + i * 4))) }
        } else if let co64 = firstBox(stbl, type: "co64") {
            let n = Int(co64.be32(12))
            guard co64.count >= 16 + n * 8 else {
                report.issues.append(Issue(fatal: true, text: "\(label) co64 条目不足"))
                return
            }
            for i in 0..<n { chunkOffsets.append(co64.be64(16 + i * 8)) }
        } else {
            report.issues.append(Issue(fatal: true, text: "\(label) 缺少 stco/co64"))
            return
        }

        var chunkSampleCounts: [Int] = []
        var sampleIndex = 0
        var runIndex = 0
        for chunk in 1...max(1, chunkOffsets.count) {
            while runIndex + 1 < runs.count, chunk >= runs[runIndex + 1].firstChunk { runIndex += 1 }
            let per = runs.isEmpty ? 0 : runs[runIndex].perChunk
            let remaining = sampleCount - sampleIndex
            let take = min(per, max(0, remaining))
            chunkSampleCounts.append(take)
            sampleIndex += take
        }
        if sampleIndex != sampleCount {
            report.issues.append(Issue(fatal: true, text: "\(label) stsc 展开样本数 \(sampleIndex) ≠ stsz \(sampleCount)"))
        }

        var cursor = 0
        var payloadSum: UInt64 = 0
        for (chunkIndex, take) in chunkSampleCounts.enumerated() where take > 0 {
            let start = chunkOffsets[chunkIndex]
            var span: UInt64 = 0
            for i in cursor..<(cursor + take) { span += sizes[i] }
            payloadSum += span
            if start < mdatStart || start + span > mdatEnd {
                report.issues.append(Issue(fatal: true, text: "\(label) chunk#\(chunkIndex + 1) 越界（\(start)+\(span) 不在 mdat 内）"))
                break
            }
            if chunkIndex + 1 < chunkOffsets.count, chunkOffsets[chunkIndex + 1] < start + span {
                report.issues.append(Issue(fatal: true, text: "\(label) chunk#\(chunkIndex + 1) 与前一块重叠"))
                break
            }
            cursor += take
        }
        if payloadSum != totalBytes {
            report.issues.append(Issue(fatal: true, text: "\(label) 样本字节合计 \(payloadSum) ≠ stsz 合计 \(totalBytes)"))
        }

        if let stts = firstBox(stbl, type: "stts") {
            let n = Int(stts.be32(12))
            var sum: UInt64 = 0
            for i in 0..<n where stts.count >= 16 + i * 8 {
                let count = UInt64(stts.be32(16 + i * 8))
                let delta = UInt64(stts.be32(20 + i * 8))
                sum += count * delta
            }
            if mediaDuration > 0, sum != mediaDuration {
                let diff = abs(Double(sum) - Double(mediaDuration))
                let ratio = diff / Double(mediaDuration)
                if ratio > 0.005 {
                    report.issues.append(Issue(fatal: false, text: "\(label) stts 合计 \(sum) 与 mdhd \(mediaDuration) 偏差 \(String(format: "%.2f", ratio * 100))%"))
                }
            }
        }

        if let ctts = firstBox(stbl, type: "ctts") {
            let version = ctts[ctts.startIndex]
            let n = Int(ctts.be32(12))
            var negative = 0
            var maxOffset: Int64 = 0
            for i in 0..<n where ctts.count >= 16 + i * 8 {
                let raw = ctts.be32(20 + i * 8)
                let value = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
                if value < 0 { negative += 1 }
                maxOffset = max(maxOffset, value)
            }
            if negative > 0 {
                report.issues.append(Issue(fatal: true, text: "\(label) ctts 有 \(negative) 条负偏移（version=\(version)）"))
            }
            DiagnosticsLog.write("[严格校验] \(label) ctts=\(n)条 最大偏移=\(maxOffset)ticks")
        }

        if let stss = firstBox(stbl, type: "stss") {
            let n = Int(stss.be32(12))
            if n > 0, stss.count >= 20 {
                let first = stss.be32(16)
                if first != 1 {
                    report.issues.append(Issue(fatal: true, text: "\(label) stss 首个样本号=\(first)（应为 1）"))
                }
            }
        }

        if trackIsVideo(trak, mdia: mdia),
           let firstOffset = chunkOffsets.first,
           let size = sizes.first, size > 0, size < 4_000_000 {
            try? handle.seek(toOffset: firstOffset)
            if let data = try? handle.read(upToCount: Int(size)), data.count == Int(size) {
                var types: [Int] = []
                var cur = 0
                while cur + 4 <= data.count, types.count < 32 {
                    let length = Int(data.be32(cur))
                    cur += 4
                    guard length > 0, cur + length <= data.count else { break }
                    types.append(Int(data[data.startIndex + cur] & 0x1F))
                    cur += length
                }
                let typeList = types.map { String($0) }.joined(separator: ",")
                DiagnosticsLog.write("[严格校验] \(label) 首样本 NAL=[\(typeList)]")
                if !types.contains(5) {
                    report.issues.append(Issue(fatal: true, text: "\(label) 首样本不含 IDR（NAL=[\(typeList)]），外部解码器会黑屏"))
                }
            }
        }
    }

    private static func trackIsVideo(_ trak: Data, mdia: Data) -> Bool {
        if let hdlr = firstBox(mdia, type: "hdlr"), hdlr.count >= 16 {
            return hdlr.ascii(16, 4) == "vide"
        }
        return firstBox(trak, type: "vmhd") != nil
    }

    // MARK: - box 工具

    private struct Box { let type: String; let data: Data }

    private static func readBox(_ handle: FileHandle, at offset: UInt64, size: UInt64) -> Data? {
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(size)), data.count == Int(size) else { return nil }
        return data
    }

    private static func boxes(in container: Data, from start: Int) -> [Box] {
        var result: [Box] = []
        var offset = start
        while offset + 8 <= container.count {
            let size = Int(container.be32(offset))
            let type = container.ascii(offset + 4, 4)
            guard size >= 8, offset + size <= container.count else { break }
            let body = container.subdata(in: (container.startIndex + offset + 8)..<(container.startIndex + offset + size))
            result.append(Box(type: type, data: withHeader(type: type, size: size, body: body)))
            offset += size
        }
        return result
    }

    private static func withHeader(type: String, size: Int, body: Data) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
                                 UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
        data.append(type.data(using: .ascii) ?? Data("????".utf8))
        data.append(body)
        return data
    }

    private static func firstBox(_ container: Data, type: String) -> Data? {
        boxes(in: container, from: 8).first { $0.type == type }?.data
    }
}

private extension Data {
    func be16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        var value: UInt16 = 0
        for i in 0..<2 { value = (value << 8) | UInt16(self[startIndex + offset + i]) }
        return value
    }

    func be32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(self[startIndex + offset + i]) }
        return value
    }

    func be64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(self[startIndex + offset + i]) }
        return value
    }

    func ascii(_ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "????" }
        return String(decoding: self[(startIndex + offset)..<(startIndex + offset + length)], as: UTF8.self)
    }

    func hex(_ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "-" }
        var out = ""
        for i in 0..<length { out += String(format: "%02x", self[startIndex + offset + i]) }
        return out
    }
}
