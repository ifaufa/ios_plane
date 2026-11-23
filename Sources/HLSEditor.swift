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
        var mixedParams: Bool
    }

    /// 一个待输出的片段（可来自不同源）
    struct ExportClip {
        let indexURL: URL
        let start: Double
        let end: Double
        /// 编码参数指纹（用于判断是否需要 DISCONTINUITY）
        let signatureKey: String
    }

    /// 源参数指纹（分辨率 / profile / 音频采样率与声道）
    struct StreamSignature: Equatable {
        let width: Int
        let height: Int
        let profile: Int
        let sampleRate: Int
        let channels: Int

        var key: String { "\(width)x\(height)-p\(profile)-\(sampleRate)hz-\(channels)ch" }

        var label: String {
            var parts: [String] = []
            if width > 0, height > 0 { parts.append("\(width)×\(height)") }
            if sampleRate > 0 { parts.append("\(sampleRate)Hz") }
            if channels > 0 { parts.append("\(channels)声道") }
            return parts.isEmpty ? "未知参数" : parts.joined(separator: " ")
        }
    }

    /// 读取首个分片，得到该源的编码参数
    static func probeSignature(playlistURL: URL) -> StreamSignature? {
        guard let entries = parsePlaylist(playlistURL), let first = entries.first else { return nil }
        let url = playlistURL.deletingLastPathComponent().appendingPathComponent(first.uri)
        guard let data = try? Data(contentsOf: url), data.count > 1024 else { return nil }
        let demuxer = TSDemuxer()
        demuxer.quiet = true
        demuxer.consume(data)
        demuxer.finish()
        let video = demuxer.videoInfo()
        let audio = demuxer.audioInfo()
        guard video != nil || audio != nil else { return nil }
        return StreamSignature(width: video?.width ?? 0,
                               height: video?.height ?? 0,
                               profile: Int(video?.profileLevel.0 ?? 0),
                               sampleRate: audio?.sampleRate ?? 0,
                               channels: audio?.channels ?? 0)
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

    /// 脏时间戳修正：取 PTS 上相邻的"正常帧"的相对时间作为替代
    /// （valid 必须按 pts 升序；找不到前一个就用第一个）
    private static func nearestRelative(_ pts: Int64,
                                        among valid: [(pts: Int64, rel: Int64, offset: Int)]) -> Int64? {
        guard !valid.isEmpty else { return nil }
        var previous: Int64?
        for item in valid {
            if item.pts <= pts { previous = item.rel } else { break }
        }
        return previous ?? valid.first?.rel
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

    static func export(clips: [ExportClip],
                       title: String,
                       outputRoot: URL,
                       progress: ((Double) -> Void)? = nil) throws -> ExportResult {
        guard !clips.isEmpty else { throw EditorError.emptyResult }

        let uuid = UUID().uuidString
        let outputDir = outputRoot.appendingPathComponent(uuid, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var writtenURI: [String] = []
        var writtenDurations: [Double] = []
        var discontinuityFlags: [Bool] = []
        var sourceCache: [String: Data] = [:]
        var outputCursorTicks: Int64 = 0
        var lastWrittenPTS: Int64 = -1
        var firstWrittenPTS: Int64 = -1
        var lastSignatureKey: String?
        var signatureSet: Set<String> = []
        var baseDir = outputRoot
        var entries: [Entry] = []
        var cumulative: [Double] = []

        func loadSegment(_ uri: String) throws -> Data {
            if let cached = sourceCache[uri] { return cached }
            let url = baseDir.appendingPathComponent(uri)
            let data = try Data(contentsOf: url)
            sourceCache[uri] = data
            return data
        }

        do {
            for (clipIndex, clip) in clips.enumerated() {
                guard let parsed = parsePlaylist(clip.indexURL) else { throw EditorError.playlistUnreadable }
                entries = parsed
                baseDir = clip.indexURL.deletingLastPathComponent()
                sourceCache.removeAll(keepingCapacity: true)
                cumulative = []
                var total = 0.0
                for entry in entries {
                    cumulative.append(total)
                    total += entry.duration
                }
                guard total > 0.5 else { continue }

                // 参数变化 → 在该片段之前插入 DISCONTINUITY（RFC 8216 要求）
                var needsDiscontinuity = false
                if let last = lastSignatureKey, last != clip.signatureKey {
                    needsDiscontinuity = true
                    DiagnosticsLog.write("[剪辑] 参数变化 段#" + String(clipIndex + 1)
                                         + "：" + last + " → " + clip.signatureKey + "，插入 DISCONTINUITY")
                }
                lastSignatureKey = clip.signatureKey
                signatureSet.insert(clip.signatureKey)

                let range = (max(0, min(clip.start, total)), max(0, min(clip.end, total)))
                guard range.1 - range.0 >= 0.2 else { continue }

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
                        // v3：**保留源 PTS 的相对间距**（平滑度来源），只做整体平移 + 统一缩放；
                        // 个别脏时间戳用相邻正常帧插值修正，不做边界钳制。
                        var bytes = [UInt8](piece)
                        let videoPID = scanResult.videoPID
                        var videoList = stamps.filter { $0.pid == videoPID }
                        if videoList.isEmpty { videoList = stamps }
                        let audioList = stamps.filter { $0.pid != videoPID }

                        func estimateSpan(_ list: [PESStamp]) -> Int64 {
                            guard list.count > 1 else { return 0 }
                            let sorted = list.sorted { $0.pts < $1.pts }
                            var deltas: [Int64] = []
                            deltas.reserveCapacity(sorted.count)
                            for i in 1..<sorted.count {
                                let delta = sorted[i].pts - sorted[i - 1].pts
                                if delta > 0, delta < 90000 { deltas.append(delta) }
                            }
                            guard !deltas.isEmpty else { return 0 }
                            deltas.sort()
                            let median = deltas[deltas.count / 2]
                            return median * Int64(max(1, sorted.count - 1))
                        }

                        let videoSpan = estimateSpan(videoList)
                        let audioSpan = estimateSpan(audioList)
                        let referenceSpan = videoSpan > 0 ? videoSpan : audioSpan
                        let scale: Double = referenceSpan > 0
                            ? Double(targetTicks) / Double(referenceSpan)
                            : 1.0
                        let firstPTS = videoList.min(by: { $0.pts < $1.pts })?.pts
                            ?? stamps.min(by: { $0.pts < $1.pts })?.pts ?? 0
                        let spanLimit = referenceSpan > 0 ? referenceSpan : targetTicks

                        // 建立"正常帧"索引（按 PTS 升序），用于脏值插值
                        var validVideo: [(pts: Int64, rel: Int64, offset: Int)] = []
                        for stamp in videoList.sorted(by: { $0.pts < $1.pts }) {
                            let rel = stamp.pts - firstPTS
                            if rel >= -180000, rel <= spanLimit + spanLimit {   // -2s ~ 2 倍跨度 视为有效
                                validVideo.append((stamp.pts, rel, stamp.packetOffset))
                            }
                        }
                        var validAudio: [Int: Int64] = [:]
                        var validAudioList: [(pts: Int64, rel: Int64, offset: Int)] = []
                        for stamp in audioList.sorted(by: { $0.pts < $1.pts }) {
                            let rel = stamp.pts - firstPTS
                            if rel >= -180000, rel <= spanLimit + spanLimit {
                                validAudio[stamp.packetOffset] = rel
                                validAudioList.append((stamp.pts, rel, stamp.packetOffset))
                            }
                        }
                        let videoValidMap = Dictionary(uniqueKeysWithValues: validVideo.map { ($0.offset, $0.rel) })

                        var interpolated = 0
                        for stamp in stamps {
                            let ptsLocal = stamp.ptsOffset - startOffset + headerBytes
                            guard ptsLocal + 5 <= bytes.count else { continue }
                            let isVideo = (stamp.pid == videoPID)
                            var relative: Int64
                            if isVideo {
                                if let rel = videoValidMap[stamp.packetOffset] {
                                    relative = rel
                                } else {
                                    // 脏值：取 PTS 上相邻的正常帧作为替代，避免出现 26 小时跳变
                                    relative = Self.nearestRelative(stamp.pts, among: validVideo) ?? 0
                                    interpolated += 1
                                }
                            } else {
                                if let rel = validAudio[stamp.packetOffset] {
                                    relative = rel
                                } else {
                                    relative = Self.nearestRelative(stamp.pts, among: validAudioList) ?? 0
                                    interpolated += 1
                                }
                            }
                            let newPTS = outputCursorTicks + Int64((Double(relative) * scale).rounded())
                            writeTimestamp(&bytes, ptsLocal, newPTS)
                            if stamp.dtsOffset >= 0 {
                                let dtsLocal = stamp.dtsOffset - startOffset + headerBytes
                                if dtsLocal + 5 <= bytes.count {
                                    // 保持原有 PTS−DTS 差值（B 帧重排结构不变）
                                    let reorder = max(0, stamp.pts - stamp.dts)
                                    let newDTS = max(0, newPTS - reorder)
                                    writeTimestamp(&bytes, dtsLocal, newDTS)
                                }
                            }
                            if firstWrittenPTS < 0 { firstWrittenPTS = newPTS }
                            if newPTS > lastWrittenPTS { lastWrittenPTS = newPTS }
                        }
                        if writtenURI.count < 3 || interpolated > 0 {
                            DiagnosticsLog.write("[剪辑] 片段#" + String(writtenURI.count + 1)
                                                 + " 帧=" + String(videoList.count)
                                                 + " 跨度=" + String(format: "%.2f", Double(referenceSpan) / 90000) + "s"
                                                 + " 目标=" + String(format: "%.2f", pieceDuration) + "s"
                                                 + " 缩放=" + String(format: "%.3f", scale)
                                                 + (interpolated > 0 ? " 插值修正 " + String(interpolated) + " 帧" : ""))
                        }
                        piece = Data(bytes)
                    }

                    let uri = LocalHLS.fileName(index: writtenURI.count)
                    try piece.write(to: outputDir.appendingPathComponent(uri), options: .atomic)
                    writtenURI.append(uri)
                    writtenDurations.append(pieceDuration)
                    discontinuityFlags.append(needsDiscontinuity)
                    needsDiscontinuity = false
                    outputCursorTicks += targetTicks
                    progress?(Double(writtenURI.count) / Double(max(1, clips.count * 4)))
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
            if offset < discontinuityFlags.count, discontinuityFlags[offset] {
                playlist += "#EXT-X-DISCONTINUITY\n"
            }
            playlist += "#EXTINF:" + String(format: "%.3f", writtenDurations[offset]) + ",\n"
            playlist += uri + "\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        try playlist.write(to: outputDir.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)

        let sumDuration = writtenDurations.reduce(0, +)
        // 写入状态文件，保证后续"转 MP4"可用
        let isMixed = signatureSet.count > 1
        let state = SegmentJobState(id: uuid,
                                    title: title,
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
                                    pendingParse: false,
                                    mixedParams: isMixed)
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
        DiagnosticsLog.write("[剪辑] 导出完成 源=" + title
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
