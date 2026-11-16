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

        // stsd
        if firstBox(stbl, type: "stsd") == nil {
            report.issues.append(Issue(fatal: true, text: "\(label) 缺少 stsd"))
        }

        // stsz
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

        // stsc
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

        // stco / co64
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

        // 按 stsc 展开每个 chunk 的样本数，校验样本总数与总量
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
            report.issues.append(Issue(fatal: true,
                                       text: "\(label) stsc 展开样本数 \(sampleIndex) ≠ stsz \(sampleCount)"))
        }

        // 校验每个 chunk 落在 mdat 内、且 chunk 内样本连续
        var cursor = 0
        var payloadSum: UInt64 = 0
        for (chunkIndex, take) in chunkSampleCounts.enumerated() where take > 0 {
            let start = chunkOffsets[chunkIndex]
            var span: UInt64 = 0
            for i in cursor..<(cursor + take) { span += sizes[i] }
            payloadSum += span
            if start < mdatStart || start + span > mdatEnd {
                report.issues.append(Issue(fatal: true,
                                           text: "\(label) chunk#\(chunkIndex + 1) 越界（\(start)+\(span) 不在 mdat 内）"))
                break
            }
            if chunkIndex + 1 < chunkOffsets.count, chunkOffsets[chunkIndex + 1] < start + span {
                report.issues.append(Issue(fatal: true,
                                           text: "\(label) chunk#\(chunkIndex + 1) 与前一块重叠"))
                break
            }
            cursor += take
        }
        if payloadSum != totalBytes {
            report.issues.append(Issue(fatal: true, text: "\(label) 样本字节合计 \(payloadSum) ≠ stsz 合计 \(totalBytes)"))
        }

        // stts 总时长 vs mdhd
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
                    report.issues.append(Issue(fatal: false,
                                               text: "\(label) stts 合计 \(sum) 与 mdhd \(mediaDuration) 偏差 \(String(format: "%.2f", ratio * 100))%"))
                }
            }
        }

        // ctts 非负
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

        // stss 首个样本必须是 1（1-based）
        if let stss = firstBox(stbl, type: "stss") {
            let n = Int(stss.be32(12))
            if n > 0, stss.count >= 20 {
                let first = stss.be32(16)
                if first != 1 {
                    report.issues.append(Issue(fatal: true, text: "\(label) stss 首个样本号=\(first)（应为 1）"))
                }
            }
        }

        // 首个样本的 NAL 类型（视频轨应含 IDR，类型 5）
        if let stsd = firstBox(stbl, type: "stsd"),
           let firstOffset = chunkOffsets.first,
           trackIsVideo(trak, mdia: mdia) {
            let handlerIsVideo = true
            _ = stsd
            if handlerIsVideo, let size = sizes.first, size > 0, size < 4_000_000 {
                try? handle.seek(toOffset: firstOffset)
                if let data = try? handle.read(upToCount: Int(size)), data.count == Int(size) {
                    // 扫描该 AU 内所有 NAL：必须包含 IDR（类型 5）；SEI(6) 在前属正常
                    var types: [Int] = []
                    var cursor = 0
                    while cursor + 4 <= data.count, types.count < 32 {
                        let length = Int(data.be32(cursor))
                        cursor += 4
                        guard length > 0, cursor + length <= data.count else { break }
                        types.append(Int(data[data.startIndex + cursor] & 0x1F))
                        cursor += length
                    }
                    let typeList = types.map { String($0) }.joined(separator: ",")
                    DiagnosticsLog.write("[严格校验] \(label) 首样本 NAL=[\(typeList)]")
                    if !types.contains(5) {
                        report.issues.append(Issue(fatal: true,
                                                   text: "\(label) 首样本不含 IDR（NAL=[\(typeList)]），外部解码器会黑屏"))
                    }
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

    /// 列出容器内容（data 从容器 body 起点开始）
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

    /// 让孩子 box 自带 8 字节头（便于统一用 be32(12)/be32(16) 偏移读取）
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
}
