import Foundation

/// 极简 MPEG-TS 解复用：只支持 H.264 视频 + AAC(ADTS) 音频
final class TSDemuxer {
    struct VideoInfo {
        var width: Int
        var height: Int
        var sps: Data
        var pps: Data
        var profileLevel: (UInt8, UInt8)
    }
    struct AudioInfo {
        var sampleRate: Int
        var channels: Int
        var audioSpecificConfig: Data
    }

    var onVideoFrame: ((_ avcc: Data, _ pts: Int64, _ dts: Int64, _ isKey: Bool) -> Void)?
    var onAudioFrame: ((_ raw: Data, _ pts: Int64) -> Void)?
    var onInfo: ((VideoInfo?, AudioInfo?) -> Void)?
    var onError: ((String) -> Void)?

    private var buffer = Data()
    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var videoStreamType: UInt8?
    private var audioStreamType: UInt8?

    private var videoPES = Data()
    private var audioPES = Data()
    private var pendingPTS: Int64 = -1
    private var pendingDTS: Int64 = -1

    private var sps: Data?
    private var pps: Data?
    private var videoInfoEmitted = false
    private var audioInfoEmitted = false
    private var audioConfig: Data?
    private var audioRate = 0
    private var audioChannels = 0

    // MARK: - 输入

    func consume(_ data: Data) {
        buffer.append(data)
        process()
    }

    func finish() {
        if !videoPES.isEmpty {
            handleVideoPES(videoPES, pts: pendingPTS, dts: pendingDTS)
            videoPES.removeAll()
        }
        if !audioPES.isEmpty {
            handleAudioPES(audioPES, pts: pendingPTS)
            audioPES.removeAll()
        }
    }

    private func process() {
        var offset = 0
        while offset + 188 <= buffer.count {
            // 同步
            if buffer[buffer.startIndex + offset] != 0x47 {
                offset += 1
                continue
            }
            let packet = buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + 188))
            parsePacket(packet)
            offset += 188
        }
        if offset > 0 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
        }
    }

    private func parsePacket(_ packet: Data) {
        let bytes = [UInt8](packet)
        let pid = (Int(bytes[1] & 0x1F) << 8) | Int(bytes[2])
        let pusi = (bytes[1] & 0x40) != 0
        let afc = (bytes[3] >> 4) & 0x3

        var payloadStart = 4
        if afc & 0x2 != 0 {
            let afLength = Int(bytes[4])
            payloadStart = 5 + afLength
        }
        guard afc & 0x1 != 0, payloadStart < 188 else { return }
        let payload = Data(bytes[payloadStart..<188])

        if pid == 0 {
            parsePAT(payload)
        } else if pid == pmtPID {
            parsePMT(payload)
        } else if pid == videoPID {
            appendPES(payload, pusi: pusi, isVideo: true)
        } else if pid == audioPID {
            appendPES(payload, pusi: pusi, isVideo: false)
        }
    }

    private func parsePAT(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count > 8 else { return }
        var i = 1 + Int(bytes[0]) // pointer_field
        guard i + 8 <= bytes.count, bytes[i] == 0x00 else { return }
        let sectionLength = (Int(bytes[i + 1] & 0x0F) << 8) | Int(bytes[i + 2])
        var cursor = i + 8
        let end = min(bytes.count, i + 3 + sectionLength - 4)
        while cursor + 4 <= end {
            let program = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
            let pid = ((Int(bytes[cursor + 2]) & 0x1F) << 8) | Int(bytes[cursor + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            cursor += 4
        }
    }

    private func parsePMT(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count > 12 else { return }
        var i = 1 + Int(bytes[0])
        guard i + 12 <= bytes.count, bytes[i] == 0x02 else { return }
        let sectionLength = (Int(bytes[i + 1] & 0x0F) << 8) | Int(bytes[i + 2])
        let programInfoLength = (Int(bytes[i + 10] & 0x0F) << 8) | Int(bytes[i + 11])
        var cursor = i + 12 + programInfoLength
        let end = min(bytes.count, i + 3 + sectionLength - 4)
        while cursor + 5 <= end {
            let streamType = bytes[cursor]
            let pid = ((Int(bytes[cursor + 1]) & 0x1F) << 8) | Int(bytes[cursor + 2])
            let esInfoLength = (Int(bytes[cursor + 3] & 0x0F) << 8) | Int(bytes[cursor + 4])
            if streamType == 0x1B, videoPID == nil {
                videoPID = pid
                videoStreamType = streamType
            } else if streamType == 0x0F, audioPID == nil {
                audioPID = pid
                audioStreamType = streamType
            }
            cursor += 5 + esInfoLength
        }
    }

    private func appendPES(_ payload: Data, pusi: Bool, isVideo: Bool) {
        if isVideo {
            if pusi {
                if !videoPES.isEmpty {
                    handleVideoPES(videoPES, pts: pendingPTS, dts: pendingDTS)
                    videoPES.removeAll()
                }
                let parsed = parsePESHeader(payload)
                pendingPTS = parsed.pts
                pendingDTS = parsed.dts
                videoPES.append(parsed.payload)
            } else {
                videoPES.append(payload)
            }
        } else {
            if pusi {
                if !audioPES.isEmpty {
                    handleAudioPES(audioPES, pts: pendingPTS)
                    audioPES.removeAll()
                }
                let parsed = parsePESHeader(payload)
                pendingPTS = parsed.pts
                pendingDTS = parsed.dts
                audioPES.append(parsed.payload)
            } else {
                audioPES.append(payload)
            }
        }
    }

    private func parsePESHeader(_ payload: Data) -> (pts: Int64, dts: Int64, payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count > 9, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 else {
            return (-1, -1, payload)
        }
        let flags = bytes[7]
        let ptsDtsFlags = (flags >> 6) & 0x3
        let headerLength = Int(bytes[8])
        var pts: Int64 = -1
        var dts: Int64 = -1

        func readTimestamp(_ start: Int) -> Int64 {
            guard start + 5 <= bytes.count else { return -1 }
            let b0 = Int64(bytes[start] & 0x0E) << 29
            let b1 = Int64(bytes[start + 1]) << 22
            let b2 = Int64(bytes[start + 2] & 0xFE) << 14
            let b3 = Int64(bytes[start + 3]) << 7
            let b4 = Int64(bytes[start + 4] & 0xFE) >> 1
            return b0 | b1 | b2 | b3 | b4
        }

        if ptsDtsFlags == 2 || ptsDtsFlags == 3 {
            pts = readTimestamp(9)
        }
        if ptsDtsFlags == 3 {
            dts = readTimestamp(14)
        } else {
            dts = pts
        }

        let dataStart = 9 + headerLength
        let body = dataStart <= bytes.count ? Data(bytes[dataStart...]) : Data()
        return (pts, dts, body)
    }

    // MARK: - 视频

    private func handleVideoPES(_ pes: Data, pts: Int64, dts: Int64) {
        guard !pes.isEmpty else { return }
        let nals = Self.splitNALUnits(pes)
        guard !nals.isEmpty else { return }

        var hasVCL = false
        var isKey = false
        var avcc = Data()

        for nal in nals {
            guard let first = nal.first else { continue }
            let type = first & 0x1F
            if type == 7 {
                sps = nal
                continue
            }
            if type == 8 {
                pps = nal
                continue
            }
            if type == 9 { continue } // AUD 丢弃
            if type == 5 { isKey = true }
            if type == 1 || type == 5 { hasVCL = true }

            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        emitVideoInfoIfNeeded()

        guard hasVCL, !avcc.isEmpty else { return }
        onVideoFrame?(avcc, pts, dts, isKey)
    }

    private func emitVideoInfoIfNeeded() {
        guard !videoInfoEmitted, let sps, let pps, sps.count > 3 else { return }
        videoInfoEmitted = true
        let profile = sps[sps.startIndex + 1]
        let level = sps[sps.startIndex + 3]
        let (w, h) = Self.parseSPSDimensions(sps)
        onInfo?(VideoInfo(width: w, height: h, sps: sps, pps: pps, profileLevel: (profile, level)), nil)
    }

    // MARK: - 音频

    private func handleAudioPES(_ pes: Data, pts: Int64) {
        let bytes = [UInt8](pes)
        var index = 0
        var frameIndex = 0

        while index + 7 <= bytes.count {
            guard bytes[index] == 0xFF, (bytes[index + 1] & 0xF0) == 0xF0 else {
                index += 1
                continue
            }
            let protectionAbsent = (bytes[index + 1] & 0x01) == 1
            let profile = Int((bytes[index + 2] & 0xC0) >> 6)
            let freqIndex = Int((bytes[index + 2] & 0x3C) >> 2)
            let channelConfig = Int(((bytes[index + 2] & 0x01) << 2) | ((bytes[index + 3] & 0xC0) >> 6))
            let frameLength = (Int(bytes[index + 3] & 0x03) << 11)
                | (Int(bytes[index + 4]) << 3)
                | (Int(bytes[index + 5] & 0xE0) >> 5)
            let headerSize = protectionAbsent ? 7 : 9
            guard frameLength > headerSize, index + frameLength <= bytes.count else { break }

            if audioConfig == nil {
                let objectType = profile + 1
                audioRate = Self.sampleRates[min(freqIndex, Self.sampleRates.count - 1)]
                audioChannels = channelConfig
                var config = Data()
                config.append(UInt8((objectType << 3) | ((freqIndex >> 1) & 0x07)))
                config.append(UInt8(((freqIndex & 0x01) << 7) | ((channelConfig & 0x0F) << 3)))
                audioConfig = config
                if !audioInfoEmitted {
                    audioInfoEmitted = true
                    onInfo?(nil, AudioInfo(sampleRate: audioRate, channels: max(1, channelConfig), audioSpecificConfig: config))
                }
            }

            let raw = Data(bytes[(index + headerSize)..<(index + frameLength)])
            let framePTS = pts >= 0 ? pts + Int64(frameIndex) * 1024 * 90000 / Int64(max(1, audioRate)) : -1
            onAudioFrame?(raw, framePTS)
            frameIndex += 1
            index += frameLength
        }
    }

    // MARK: - 工具

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    static func splitNALUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var result: [Data] = []
        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append(i + 4)
                i += 4
            } else {
                i += 1
            }
        }
        for (idx, start) in starts.enumerated() {
            let end = idx + 1 < starts.count ? starts[idx + 1] - 3 : bytes.count
            if start < end {
                result.append(Data(bytes[start..<end]))
            }
        }
        return result
    }

    /// 从 SPS 里解析分辨率（Exp-Golomb）
    static func parseSPSDimensions(_ sps: Data) -> (Int, Int) {
        let bytes = [UInt8](sps)
        guard bytes.count > 4 else { return (0, 0) }
        var reader = BitReader(bytes: Array(bytes[3...]))
        _ = reader.readUE() // profile_idc 之后依次解析
        _ = reader.readUE()
        _ = reader.readUE()
        _ = reader.readUE()
        _ = reader.readUE()
        let pocType = reader.readUE()
        if pocType == 0 {
            _ = reader.readUE()
        } else if pocType == 1 {
            _ = reader.readBits(1)
            _ = reader.readSE()
            _ = reader.readSE()
            let count = Int(reader.readUE())
            for _ in 0..<count { _ = reader.readSE() }
        }
        _ = reader.readUE()
        _ = reader.readBits(1)
        let widthMbs = Int(reader.readUE()) + 1
        let heightMap = Int(reader.readUE()) + 1
        _ = reader.readBits(1)
        var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
        if reader.readBits(1) == 1 {
            cropLeft = Int(reader.readUE())
            cropRight = Int(reader.readUE())
            cropTop = Int(reader.readUE())
            cropBottom = Int(reader.readUE())
        }
        let width = widthMbs * 16 - (cropLeft + cropRight) * 2
        let height = heightMap * 16 - (cropTop + cropBottom) * 2
        return (width, height)
    }
}

/// 简易 Exp-Golomb 位读取
struct BitReader {
    private let bytes: [UInt8]
    private var bitIndex = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func readBits(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byteIndex = bitIndex / 8
            guard byteIndex < bytes.count else { return value }
            let bit = (bytes[byteIndex] >> (7 - UInt8(bitIndex % 8))) & 1
            value = (value << 1) | Int(bit)
            bitIndex += 1
        }
        return value
    }

    mutating func readUE() -> Int {
        var zeros = 0
        while readBits(1) == 0, zeros < 32 { zeros += 1 }
        guard zeros > 0 else { return 0 }
        return (1 << zeros) - 1 + readBits(zeros)
    }

    mutating func readSE() -> Int {
        let value = readUE()
        return value % 2 == 1 ? (value + 1) / 2 : -(value / 2)
    }
}
