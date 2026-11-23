import Foundation

/// 分片视频剪辑引擎（v1.5）
/// 关键帧对齐 + 纯字节拷贝 + **PES 时间戳重写**（视频与音频一起），
/// 输出从 0 开始、段间连续的时间轴，因此不再需要逐段 DISCONTINUITY。
enum HLSEditor {

    struct Entry {
        var duration: Double
        var uri: String
    }

    struct UnitPointer {
        let offset: Int
        let isIDR: Bool
    }

    struct PESStamp {
        let packetOffset: Int   // TS 包起始
        let pid: Int
        let ptsOffset: Int      // PTS 字段（5 字节）绝对偏移
        let dtsOffset: Int      // DTS 字段绝对偏移（-1 表示没有）
        let pts: Int64
        let dts: Int64
    }

    struct ScanResult {
        var videoPID: Int?
        var audioPID: Int?
        var psHeaders: [Data] = []
        var units: [UnitPointer] = []
        var stamps: [PESStamp] = []
    }

    struct ExportResult {
        var fileName: String
        var dirName: String
        var duration: Double
        var fileSize: Int64
        var segmentCount: Int
    }

    enum EditorError: LocalizedError {
        case playlistUnreadable
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .playlistUnreadable: return "无法读取播放列表（index.m3u8）"
            case .emptyResult: return "选中的区间没有可用内容"
            }
        }
    }

    // MARK: - 播放列表

    static func parsePlaylist(_ url: URL) -> [Entry]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var entries: [Entry] = []
        var pending: Double?
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count)
                let number = value.split(separator: ",").first.map(String.init) ?? ""
                pending = Double(number.trimmingCharacters(in: .whitespaces))
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if let duration = pending {
                    entries.append(Entry(duration: duration, uri: line))
                }
                pending = nil
            }
        }
        return entries.isEmpty ? nil : entries
    }

    // MARK: - TS 扫描

    static func scan(_ data: Data) -> ScanResult {
        var result = ScanResult()
        let bytes = [UInt8](data)
        var videoPID: Int?
        var audioPID: Int?
        var pmtPID: Int?
        var patPacket: Data?
        var pmtPacket: Data?

        let packetCount = bytes.count / 188
        var index = 0
        while index < packetCount {
            let base = index * 188
            defer { index += 1 }
            guard bytes[base] == 0x47 else { continue }

            let pid = (Int(bytes[base + 1] & 0x1F) << 8) | Int(bytes[base + 2])
            let hasPayloadStart = (bytes[base + 1] & 0x40) != 0
            guard let payload = payloadStart(bytes, base: base) else { continue }

            if pid == 0, hasPayloadStart, patPacket == nil {
                let sectionStart = payload + 1 + Int(bytes[payload])
                if sectionStart + 12 <= base + 188, bytes[sectionStart] == 0x00 {
                    let programCount = (Int(bytes[sectionStart + 10]) << 8 | Int(bytes[sectionStart + 11]))
                    let offset = sectionStart + 8
                    if programCount > 0, offset + 4 <= base + 188 {
                        pmtPID = (Int(bytes[offset + 2] & 0x1F) << 8) | Int(bytes[offset + 3])
                        patPacket = data.subdata(in: base..<(base + 188))
                    }
                }
                continue
            }

            if let pmt = pmtPID, pid == pmt, hasPayloadStart, pmtPacket == nil {
                let sectionStart = payload + 1 + Int(bytes[payload])
                if sectionStart + 12 <= base + 188, bytes[sectionStart] == 0x02 {
                    let sectionLength = (Int(bytes[sectionStart + 1] & 0x0F) << 8) | Int(bytes[sectionStart + 2])
                    let programInfoLength = (Int(bytes[sectionStart + 10] & 0x0F) << 8) | Int(bytes[sectionStart + 11])
                    var streamOffset = sectionStart + 12 + programInfoLength
                    let limit = min(base + 188, sectionStart + 3 + sectionLength)
                    while streamOffset + 5 <= limit {
                        let streamType = bytes[streamOffset]
                        let elementaryPID = (Int(bytes[streamOffset + 1] & 0x1F) << 8) | Int(bytes[streamOffset + 2])
                        let esInfoLength = (Int(bytes[streamOffset + 3] & 0x0F) << 8) | Int(bytes[streamOffset + 4])
                        if streamType == 0x1B, videoPID == nil {
                            videoPID = elementaryPID
                        } else if (streamType == 0x0F || streamType == 0x11 || streamType == 0x03), audioPID == nil {
                            audioPID = elementaryPID
                        }
                        streamOffset += 5 + esInfoLength
                    }
                    pmtPacket = data.subdata(in: base..<(base + 188))
                }
                continue
            }

            let isVideo = (videoPID != nil && pid == videoPID)
            let isAudio = (audioPID != nil && pid == audioPID)
            guard isVideo || isAudio else { continue }
            guard payload + 9 <= base + 188,
                  bytes[payload] == 0x00, bytes[payload + 1] == 0x00, bytes[payload + 2] == 0x01 else { continue }

            // PTS/DTS 字段位置
            let flags = bytes[payload + 7]
            let stampFlags = (flags >> 6) & 0x03
            var ptsOffset = -1
            var dtsOffset = -1
            if stampFlags == 0x02 || stampFlags == 0x03 {
                ptsOffset = payload + 9
                if stampFlags == 0x03 { dtsOffset = payload + 14 }
                if ptsOffset + 5 <= base + 188 {
                    let pts = readTimestamp(bytes, ptsOffset)
                    let dts = dtsOffset >= 0 && dtsOffset + 5 <= base + 188 ? readTimestamp(bytes, dtsOffset) : pts
                    result.stamps.append(PESStamp(packetOffset: base,
                                                  pid: pid,
                                                  ptsOffset: ptsOffset,
                                                  dtsOffset: dtsOffset,
                                                  pts: pts,
                                                  dts: dts))
                }
            }

            guard isVideo, hasPayloadStart else { continue }
            let headerDataLength = Int(bytes[payload + 8])
            let esStart = payload + 9 + headerDataLength
            guard esStart + 4 <= base + 188 else { continue }
            var isIDR = false
            if bytes[esStart] == 0x00, bytes[esStart + 1] == 0x00, bytes[esStart + 2] == 0x01 {
                isIDR = (bytes[esStart + 3] & 0x1F) == 5
            } else if bytes[esStart] == 0x00, bytes[esStart + 1] == 0x00, bytes[esStart + 2] == 0x00,
                      esStart + 4 <= base + 188, bytes[esStart + 3] == 0x01 {
                isIDR = (bytes[esStart + 4] & 0x1F) == 5
            }
            result.units.append(UnitPointer(offset: base, isIDR: isIDR))
        }

        result.videoPID = videoPID
        result.audioPID = audioPID
        if let pat = patPacket { result.psHeaders.append(pat) }
        if let pmt = pmtPacket { result.psHeaders.append(pmt) }
        return result
    }

    private static func payloadStart(_ bytes: [UInt8], base: Int) -> Int? {
        guard base + 4 < bytes.count else { return nil }
        let adaptation = Int((bytes[base + 3] >> 4) & 0x03)
        if adaptation == 1 { return base + 4 }
        if adaptation == 3 {
            guard base + 5 < bytes.count else { return nil }
            let length = Int(bytes[base + 4])
            let start = base + 5 + length
            guard start < base + 188 else { return nil }
            return start
        }
        return nil
    }

    private static func readTimestamp(_ bytes: [UInt8], _ offset: Int) -> Int64 {
        let b0 = Int64(bytes[offset] & 0x0E)
        let b1 = Int64(bytes[offset + 1])
        let b2 = Int64(bytes[offset + 2] & 0xFE)
        let b3 = Int64(bytes[offset + 3])
        let b4 = Int64(bytes[offset + 4] & 0xFE)
        return (b0 << 29) | (b1 << 22) | (b2 << 14) | (b3 << 7) | (b4 >> 1)
    }

    private static func writeTimestamp(_ bytes: inout [UInt8], _ offset: Int, _ value: Int64) {
        let prefix = bytes[offset] & 0xF0
        bytes[offset] = prefix | UInt8(((value >> 30) & 0x07) << 1) | 0x01
        bytes[offset + 1] = UInt8((value >> 22) & 0xFF)
        bytes[offset + 2] = UInt8((((value >> 15) & 0x7F) << 1) | 0x01)
        bytes[offset + 3] = UInt8((value >> 7) & 0xFF)
        bytes[offset + 4] = UInt8(((value & 0x7F) << 1) | 0x01)
    }

    // MARK: - 导出

    static func export(sourceTitle: String,
                       indexURL: URL,
                       outputRoot: URL,
                       ranges: [(start: Double, end: Double)],
                       progress: ((Double) -> Void)? = nil) throws -> ExportResult {
        guard let entries = parsePlaylist(indexURL) else { throw EditorError.playlistUnreadable }
        let baseDir = indexURL.deletingLastPathComponent()

        var cumulative: [Double] = []
        var total = 0.0
        for entry in entries {
            cumulative.append(total)
            total += entry.duration
        }
        guard total > 0.5 else { throw EditorError.emptyResult }

        let cleaned = ranges
            .map { (max(0, min($0.start, total)), max(0, min($0.end, total))) }
            .filter { $0.1 - $0.0 >= 0.2 }
            .sorted { $0.0 < $1.0 }
        guard !cleaned.isEmpty else { throw EditorError.emptyResult }

        let uuid = UUID().uuidString
        let outputDir = outputRoot.appendingPathComponent(uuid, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var writtenURI: [String] = []
        var writtenDurations: [Double] = []
        var sourceCache: [String: Data] = [:]
        var outputCursorTicks: Int64 = 0
        var lastWrittenPTS: Int64 = -1
        var firstWrittenPTS: Int64 = -1

        func loadSegment(_ uri: String) throws -> Data {
            if let cached = sourceCache[uri] { return cached }
            let url = baseDir.appendingPathComponent(uri)
            let data = try Data(contentsOf: url)
            sourceCache[uri] = data
            return data
        }

        do {
            for range in cleaned {
                var index = 0
                while index < entries.count {
                    let segStart = cumulative[index]
                    let segEnd = segStart + entries[index].duration
                    defer { index += 1 }
                    guard segEnd > range.0 + 0.01, segStart < range.1 - 0.01 else { continue }

                    let pieceStart = max(range.0, segStart)
                    let pieceEnd = min(range.1, segEnd)
                    guard pieceEnd - pieceStart >= 0.1 else { continue }

                    let data = try loadSegment(entries[index].uri)
                    let scanResult = scan(data)
                    let unitCount = max(1, scanResult.units.count)
                    let segDuration = max(0.01, entries[index].duration)

                    // 起始单元（必须落在 IDR 上）
                    var startUnit = 0
                    if pieceStart > segStart + 0.02 {
                        let fraction = (pieceStart - segStart) / segDuration
                        let target = Int((fraction * Double(unitCount)).rounded(.down))
                        let from = max(0, min(target, unitCount - 1))
                        guard let keyIndex = scanResult.units[from...].firstIndex(where: { $0.isIDR }) else { continue }
                        startUnit = keyIndex
                    }
                    // 结束单元（不含）
                    var endUnit = unitCount
                    if pieceEnd < segEnd - 0.02 {
                        let fraction = (pieceEnd - segStart) / segDuration
                        let target = Int((fraction * Double(unitCount)).rounded(.up))
                        endUnit = max(startUnit + 1, min(unitCount, target))
                    }
                    guard endUnit > startUnit else { continue }

                    let startOffset = startUnit > 0 ? scanResult.units[startUnit].offset : 0
                    let endOffset = endUnit < unitCount ? scanResult.units[endUnit].offset : data.count
                    guard endOffset > startOffset else { continue }

                    let unitsInPiece = endUnit - startUnit
                    let pieceDuration = segDuration * Double(unitsInPiece) / Double(unitCount)
                    let targetTicks = Int64((pieceDuration * 90000).rounded())

                    // 组装字节：必要时补 PAT/PMT
                    var piece = Data()
                    var headerBytes = 0
                    if startOffset > 0 {
                        for header in scanResult.psHeaders {
                            piece.append(header)
                            headerBytes += header.count
                        }
                    }
                    piece.append(data.subdata(in: startOffset..<endOffset))

                    // 重写 PES 时间戳（视频 + 音频）
                    let stamps = scanResult.stamps.filter { $0.packetOffset >= startOffset && $0.packetOffset < endOffset }
                    let videoStamps: [PESStamp]
                    if let videoPID = scanResult.videoPID {
                        videoStamps = stamps.filter { $0.pid == videoPID }
                    } else {
                        videoStamps = stamps
                    }
                    if !stamps.isEmpty {
                        // 不再依赖源 PTS 的数值，改为「按帧序重建时间轴」：
                        //   视频 PTS = 显示顺序 × 每帧时长（用 PTS 排序得到显示顺序，抗脏值）
                        //   视频 DTS = 解码顺序 × 每帧时长（单调、保证 ≤ PTS）
                        //   音频 PTS = 包顺序 × 每包时长
                        // 这样片段的 PTS 跨度精确等于目标时长，个别异常时间戳不再影响整体。
                        var bytes = [UInt8](piece)
                        let videoByPTS = videoStamps.sorted { $0.pts < $1.pts }
                        var displayRank: [Int: Int] = [:]
                        for (rank, stamp) in videoByPTS.enumerated() {
                            displayRank[stamp.packetOffset] = rank
                        }
                        let videoByPacket = videoStamps.sorted { $0.packetOffset < $1.packetOffset }
                        var decodeRank: [Int: Int] = [:]
                        for (rank, stamp) in videoByPacket.enumerated() {
                            decodeRank[stamp.packetOffset] = rank
                        }
                        let audioStamps = stamps.filter { $0.pid != scanResult.videoPID }
                            .sorted { $0.packetOffset < $1.packetOffset }
                        var audioRank: [Int: Int] = [:]
                        for (rank, stamp) in audioStamps.enumerated() {
                            audioRank[stamp.packetOffset] = rank
                        }

                        let videoStep = videoStamps.count > 1
                            ? Double(targetTicks) / Double(videoStamps.count - 1)
                            : Double(targetTicks)
                        let audioStep = audioStamps.count > 1
                            ? Double(targetTicks) / Double(audioStamps.count - 1)
                            : 0

                        for stamp in stamps {
                            let ptsLocal = stamp.ptsOffset - startOffset + headerBytes
                            guard ptsLocal + 5 <= bytes.count else { continue }
                            var offsetTicks: Int64
                            if let rank = displayRank[stamp.packetOffset] {
                                offsetTicks = Int64((Double(rank) * videoStep).rounded())
                            } else if let rank = audioRank[stamp.packetOffset] {
                                offsetTicks = Int64((Double(rank) * audioStep).rounded())
                            } else {
                                continue
                            }
                            let newPTS = outputCursorTicks + offsetTicks
                            writeTimestamp(&bytes, ptsLocal, newPTS)
                            if stamp.dtsOffset >= 0 {
                                let dtsLocal = stamp.dtsOffset - startOffset + headerBytes
                                if dtsLocal + 5 <= bytes.count {
                                    let dtsTicks: Int64
                                    if let rank = decodeRank[stamp.packetOffset] {
                                        dtsTicks = Int64((Double(rank) * videoStep).rounded())
                                    } else {
                                        dtsTicks = offsetTicks
                                    }
                                    writeTimestamp(&bytes, dtsLocal, outputCursorTicks + min(dtsTicks, offsetTicks + 0))
                                }
                            }
                            if firstWrittenPTS < 0 { firstWrittenPTS = newPTS }
                            if newPTS > lastWrittenPTS { lastWrittenPTS = newPTS }
                        }
                        piece = Data(bytes)
                    }

                    let uri = LocalHLS.fileName(index: writtenURI.count)
                    try piece.write(to: outputDir.appendingPathComponent(uri), options: .atomic)
                    writtenURI.append(uri)
                    writtenDurations.append(pieceDuration)
                    outputCursorTicks += targetTicks
                    progress?(Double(writtenURI.count) / Double(max(1, cleaned.count * 4)))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputDir)
            throw error
        }

        guard !writtenURI.isEmpty else {
            try? FileManager.default.removeItem(at: outputDir)
            throw EditorError.emptyResult
        }

        let targetDuration = max(1, Int(ceil(writtenDurations.max() ?? 1)))
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for (offset, uri) in writtenURI.enumerated() {
            playlist += "#EXTINF:" + String(format: "%.3f", writtenDurations[offset]) + ",\n"
            playlist += uri + "\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        try playlist.write(to: outputDir.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)

        let sumDuration = writtenDurations.reduce(0, +)
        // 写入状态文件，保证后续"转 MP4"可用
        let state = SegmentJobState(id: uuid,
                                    title: sourceTitle,
                                    sourceURL: "edit://" + uuid,
                                    container: "ts",
                                    segmentURLs: writtenURI,
                                    durations: writtenDurations,
                                    completed: Array(0..<writtenURI.count),
                                    mediaSequence: 0,
                                    totalDuration: sumDuration,
                                    createdAt: Date(),
                                    updatedAt: Date(),
                                    initURL: nil,
                                    keyURI: nil,
                                    keyIV: nil,
                                    paused: true,
                                    failure: nil,
                                    discontinuities: nil,
                                    keyChanges: nil,
                                    excluded: nil,
                                    pendingParse: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: outputDir.appendingPathComponent("state.json"), options: .atomic)
        }

        // 自检：时间轴连续性（首尾 PTS 跨度 vs 播放列表总时长）
        if firstWrittenPTS >= 0, lastWrittenPTS > firstWrittenPTS {
            let actual = Double(lastWrittenPTS - firstWrittenPTS) / 90000.0
            let deviation = sumDuration > 0 ? abs(actual - sumDuration) / sumDuration : 0
            DiagnosticsLog.write("[剪辑] 时间轴校验 列表=" + String(format: "%.1f", sumDuration)
                                 + "s 实际=" + String(format: "%.1f", actual)
                                 + "s 偏差=" + String(format: "%.1f", deviation * 100) + "%")
        }

        let size = directorySize(outputDir)
        progress?(1.0)
        DiagnosticsLog.write("[剪辑] 导出完成 源=" + sourceTitle
                             + " 段=" + String(writtenURI.count)
                             + " 时长=" + String(format: "%.1f", sumDuration) + "s"
                             + " 大小=" + ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        return ExportResult(fileName: uuid + "/index.m3u8",
                            dirName: uuid,
                            duration: sumDuration,
                            fileSize: size,
                            segmentCount: writtenURI.count)
    }

    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
