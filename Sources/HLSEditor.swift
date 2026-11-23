import Foundation

/// 分片视频剪辑引擎（v1：关键帧对齐、纯字节拷贝、不重编码）
/// 思路：按 EXTINF 时间轴把"保留区间"映射到分片；边界分片内按 TS 包扫描
/// 找到 IDR（关键帧）/ 下一帧的字节偏移，从那里截取，最后重新生成 index.m3u8。
enum HLSEditor {

    struct Entry {
        var duration: Double
        var uri: String
    }

    struct UnitPointer {
        /// 该帧（PES 起始）在文件中的字节偏移
        let offset: Int
        /// 是否关键帧（IDR）
        let isIDR: Bool
    }

    struct ExportResult {
        var fileName: String        // "<UUID>/index.m3u8"
        var dirName: String         // "<UUID>"
        var duration: Double
        var fileSize: Int64
        var segmentCount: Int
    }

    enum EditorError: LocalizedError {
        case playlistUnreadable
        case noFrames
        case emptyResult
        case noIDR

        var errorDescription: String? {
            switch self {
            case .playlistUnreadable:
                return "无法读取播放列表（index.m3u8）"
            case .noFrames:
                return "分片里找不到视频帧"
            case .emptyResult:
                return "选中的区间没有可用内容"
            case .noIDR:
                return "边界分片内找不到关键帧，无法精确切割"
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

    // MARK: - TS 扫描（找每帧的字节偏移 + 关键帧）

    static func scanUnits(_ data: Data) -> (units: [UnitPointer], psHeaders: [Data]) {
        let bytes = [UInt8](data)
        var videoPID: Int?
        var pmtPID: Int?
        var patPacket: Data?
        var pmtPacket: Data?
        var units: [UnitPointer] = []

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
                // PAT
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
                    let programInfoLength = (Int(bytes[sectionStart + 10] & 0x0F) << 8) | Int(bytes[sectionStart + 11])
                    var streamOffset = sectionStart + 12 + programInfoLength
                    let limit = min(base + 188, sectionStart + 3 + ((Int(bytes[sectionStart + 1] & 0x0F) << 8) | Int(bytes[sectionStart + 2])))
                    while streamOffset + 5 <= limit {
                        let streamType = bytes[streamOffset]
                        let elementaryPID = (Int(bytes[streamOffset + 1] & 0x1F) << 8) | Int(bytes[streamOffset + 2])
                        let esInfoLength = (Int(bytes[streamOffset + 3] & 0x0F) << 8) | Int(bytes[streamOffset + 4])
                        if streamType == 0x1B, videoPID == nil {
                            videoPID = elementaryPID
                            pmtPacket = data.subdata(in: base..<(base + 188))
                        }
                        streamOffset += 5 + esInfoLength
                    }
                }
                continue
            }

            guard let video = videoPID, pid == video, hasPayloadStart else { continue }
            // PES 头
            guard payload + 9 <= base + 188, bytes[payload] == 0x00, bytes[payload + 1] == 0x00, bytes[payload + 2] == 0x01 else { continue }
            let headerDataLength = Int(bytes[payload + 8])
            let esStart = payload + 9 + headerDataLength
            guard esStart + 4 <= base + 188 else { continue }
            var isIDR = false
            if bytes[esStart] == 0x00, bytes[esStart + 1] == 0x00, bytes[esStart + 2] == 0x01 {
                let nalType = bytes[esStart + 3] & 0x1F
                isIDR = (nalType == 5)
            } else if bytes[esStart] == 0x00, bytes[esStart + 1] == 0x00, bytes[esStart + 2] == 0x00, esStart + 4 <= base + 188, bytes[esStart + 3] == 0x01 {
                isIDR = (bytes[esStart + 4] & 0x1F) == 5
            }
            units.append(UnitPointer(offset: base, isIDR: isIDR))
        }

        var headers: [Data] = []
        if let pat = patPacket { headers.append(pat) }
        if let pmt = pmtPacket { headers.append(pmt) }
        return (units, headers)
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

        let uuid = UUID().uuidString
        let outputDir = outputRoot.appendingPathComponent(uuid, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var writtenURI: [String] = []
        var writtenDurations: [Double] = []
        var sourceCache: [String: Data] = [:]

        func loadSegment(_ uri: String) throws -> Data {
            if let cached = sourceCache[uri] { return cached }
            let url = baseDir.appendingPathComponent(uri)
            let data = try Data(contentsOf: url)
            sourceCache[uri] = data
            return data
        }

        let cleaned = ranges
            .map { (max(0, min($0.start, total)), max(0, min($0.end, total))) }
            .filter { $0.1 - $0.0 >= 0.2 }
            .sorted { $0.0 < $1.0 }
        guard !cleaned.isEmpty else {
            try? FileManager.default.removeItem(at: outputDir)
            throw EditorError.emptyResult
        }

        var emitted = 0
        var didCut = false
        for range in cleaned {
            var index = 0
            while index < entries.count {
                let segStart = cumulative[index]
                let segEnd = segStart + entries[index].duration
                defer { index += 1 }
                guard segEnd > range.0 + 0.01, segStart < range.1 - 0.01 else { continue }

                let pieceStart = max(range.0, segStart)
                let pieceEnd = min(range.1, segEnd)
                let pieceDuration = pieceEnd - pieceStart
                guard pieceDuration >= 0.1 else { continue }

                let isWhole = (pieceStart <= segStart + 0.02) && (pieceEnd >= segEnd - 0.02)
                let destination = outputDir.appendingPathComponent(LocalHLS.fileName(index: emitted))
                let uri = LocalHLS.fileName(index: emitted)

                if isWhole {
                    let data = try loadSegment(entries[index].uri)
                    try data.write(to: destination, options: .atomic)
                } else {
                    let data = try loadSegment(entries[index].uri)
                    let scan = scanUnits(data)
                    guard !scan.units.isEmpty else { continue }

                    var startOffset = 0
                    if pieceStart > segStart + 0.02 {
                        let fraction = (pieceStart - segStart) / max(0.001, entries[index].duration)
                        let target = Int((fraction * Double(scan.units.count)).rounded(.down))
                        let candidates = scan.units.dropFirst(max(0, min(target, scan.units.count - 1)))
                        guard let keyframe = candidates.first(where: { $0.isIDR }) else { continue }
                        startOffset = keyframe.offset
                        didCut = true
                    }

                    var endOffset = data.count
                    if pieceEnd < segEnd - 0.02 {
                        let fraction = (pieceEnd - segStart) / max(0.001, entries[index].duration)
                        let target = Int((fraction * Double(scan.units.count)).rounded(.up)) - 1
                        let nextIndex = max(0, min(target + 1, scan.units.count - 1))
                        endOffset = scan.units[nextIndex].offset
                        didCut = true
                    }

                    guard endOffset > startOffset else { continue }
                    var piece = Data()
                    if startOffset > 0 {
                        for header in scan.psHeaders { piece.append(header) }
                    }
                    piece.append(data.subdata(in: startOffset..<endOffset))
                    try piece.write(to: destination, options: .atomic)
                }

                writtenURI.append(uri)
                writtenDurations.append(pieceDuration)
                emitted += 1
                progress?(Double(emitted) / Double(max(1, cleaned.count * 4)))
            }
        }

        guard !writtenURI.isEmpty else {
            try? FileManager.default.removeItem(at: outputDir)
            throw EditorError.emptyResult
        }

        // 写播放列表（PTS 不连续处标记 DISCONTINUITY）
        let targetDuration = max(1, Int(ceil(writtenDurations.max() ?? 1)))
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for (offset, uri) in writtenURI.enumerated() {
            if didCut, offset > 0 {
                playlist += "#EXT-X-DISCONTINUITY\n"
            }
            playlist += "#EXTINF:" + String(format: "%.3f", writtenDurations[offset]) + ",\n"
            playlist += uri + "\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        let playlistURL = outputDir.appendingPathComponent("index.m3u8")
        try playlist.write(to: playlistURL, atomically: true, encoding: .utf8)

        let size = directorySize(outputDir)
        progress?(1.0)
        DiagnosticsLog.write("[剪辑] 导出完成 源=" + sourceTitle
                             + " 段=" + String(writtenURI.count)
                             + " 时长=" + String(format: "%.1f", writtenDurations.reduce(0, +)) + "s"
                             + " 大小=" + ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        return ExportResult(fileName: uuid + "/index.m3u8",
                            dirName: uuid,
                            duration: writtenDurations.reduce(0, +),
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
