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

    var onVideoFrame: ((_ avcc: Data, _ pts: Int64, _ dts: Int64, _ isKey: Bool, _ isRef: Bool, _ poc: Int?) -> Void)?
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

    private var pocParams: POCParams?
    private var prevPocLsb = 0
    private var prevPoc = 0
    private var pocMissingCount = 0
    private var multiAUCount = 0
    /// 已学习到的帧间隔（90kHz ticks），用于同 PES 多帧的 DTS 递推
    private var frameStep: Int64 = 3750
    private var lastPESDTS: Int64 = -1
    private var lastPESUnits = 0
    private var sps: Data?
    private var pps: Data?
    private var storedVideoInfo: VideoInfo?
    private var storedAudioInfo: AudioInfo?
    private var videoInfoEmitted = false
    private var audioInfoEmitted = false
    private var audioConfig: Data?
    private var audioRate = 0
    private var audioChannels = 0

    // MARK: - 输入

    func videoInfo() -> VideoInfo? { storedVideoInfo }
    func audioInfo() -> AudioInfo? { storedAudioInfo }

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
                // 用相邻 PES 的 DTS 差与上一 PES 的帧数，学习帧间隔
                if lastPESDTS >= 0, parsed.dts > lastPESDTS, lastPESUnits > 0 {
                    frameStep = max(1, (parsed.dts - lastPESDTS) / Int64(lastPESUnits))
                }
                lastPESDTS = parsed.dts
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

        // 按 VCL NAL 切分访问单元：一个 VCL = 一帧
        // （编码器可能把多个帧打包进同一个 PES，合并成一个样本会导致 AVAssetWriter 判非法）
        var units: [[Data]] = []
        var unitKeys: [Bool] = []
        var unitRefs: [Bool] = []
        var current: [Data] = []
        var currentHasVCL = false
        var currentIsKey = false
        var currentIsRef = true

        for nal in nals {
            guard let first = nal.first else { continue }
            let type = first & 0x1F
            if type == 7 {
                sps = nal
                if let parsed = Self.parsePOCParams(nal) {
                    pocParams = parsed
                    prevPocLsb = 0
                    prevPoc = 0
                }
                continue
            }
            if type == 8 {
                pps = nal
                if let flag = Self.parsePPSBottomFieldFlag(nal), var current = pocParams {
                    current.bottomFieldPocPresent = flag
                    pocParams = current
                }
                continue
            }
            if type == 9 { continue } // AUD 丢弃
            if type == 5 || type == 1 {
                if currentHasVCL {
                    units.append(current)
                    unitKeys.append(currentIsKey)
                    unitRefs.append(currentIsRef)
                    current = []
                    currentHasVCL = false
                    currentIsKey = false
                    currentIsRef = true
                }
                if type == 5 {
                    currentIsKey = true
                    currentIsRef = true
                } else {
                    // type 1：按 slice_type 判断 P(参考) / B(非参考)
                    let st = Self.sliceType(nal)
                    currentIsRef = (st == nil) || (st! % 5 == 0) || (st! % 5 == 3) || (st! % 5 == 2)
                }
                currentHasVCL = true
            }
            current.append(nal)
        }
        if currentHasVCL {
            units.append(current)
            unitKeys.append(currentIsKey)
            unitRefs.append(currentIsRef)
        }

        emitVideoInfoIfNeeded()
        guard !units.isEmpty else { return }

        if units.count > 1 {
            multiAUCount += units.count - 1
            DiagnosticsLog.write("[转MP4] PES 含多帧（\(units.count) 帧，累计拆分 \(multiAUCount)）")
        }
        lastPESUnits = units.count

        // 同一 PES 拆出的多帧：DTS/PTS 按已学习到的帧间隔递推
        for (index, unit) in units.enumerated() {
            var avcc = Data()
            for nal in unit {
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
                avcc.append(nal)
            }
            let auDTS = (dts >= 0 ? dts : max(0, pts)) + Int64(index) * frameStep
            let auPTS = max((pts >= 0 ? pts : auDTS), auDTS) + Int64(index) * frameStep
            let poc = pocForUnit(unit)
            if poc == nil { pocMissingCount += 1 }
            onVideoFrame?(avcc, auPTS, auDTS,
                          unitKeys[index],
                          index < unitRefs.count ? unitRefs[index] : true,
                          poc)
        }
    }

    /// 由 slice 头计算 POC（显示顺序）；失败返回 nil（调用方回退到启发式排序）
    private func pocForUnit(_ unit: [Data]) -> Int? {
        guard let params = pocParams, params.pocType == 0 else { return nil }
        guard let vcl = unit.first(where: {
            let type = ($0.first ?? 0) & 0x1F
            return type == 1 || type == 5
        }) else { return nil }
        guard let (isIDR, lsb) = Self.slicePocLsb(vcl, params: params) else { return nil }
        if isIDR {
            prevPocLsb = lsb
            prevPoc = 0
            return 0
        }
        let maxLsb = 1 << params.log2MaxPocLsb
        var delta = lsb - prevPocLsb
        if delta < -(maxLsb / 2) { delta += maxLsb } else if delta > maxLsb / 2 { delta -= maxLsb }
        prevPoc += delta
        prevPocLsb = lsb
        return prevPoc
    }
    private func emitVideoInfoIfNeeded() {
        guard !videoInfoEmitted, let sps, let pps, sps.count > 3 else { return }
        videoInfoEmitted = true
        let profile = sps[sps.startIndex + 1]
        let level = sps[sps.startIndex + 3]
        let (w, h) = Self.parseSPSDimensions(sps)
        let info = VideoInfo(width: w, height: h, sps: sps, pps: pps, profileLevel: (profile, level))
        storedVideoInfo = info
        onInfo?(info, nil)
    }

    // MARK: - POC（显示顺序，来自码流本身，不依赖时间戳）

    struct POCParams {
        var log2MaxFrameNum = 4
        var pocType = 0
        var log2MaxPocLsb = 4
        var frameMbsOnly = true
        var bottomFieldPocPresent = false
    }

    static func parsePOCParams(_ sps: Data) -> POCParams? {
        let bytes = [UInt8](sps)
        guard bytes.count > 4 else { return nil }
        let profile = bytes[1]
        var reader = BitReader(bytes: Array(bytes[4...]))
        var params = POCParams()
        _ = reader.readUE()                              // sps_id

        let highProfiles: Set<UInt8> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        if highProfiles.contains(profile) {
            let chromaFormat = reader.readUE()
            if chromaFormat == 3 { _ = reader.readBits(1) }
            _ = reader.readUE()
            _ = reader.readUE()
            _ = reader.readBits(1)
            if reader.readBits(1) == 1 {
                let count = chromaFormat == 3 ? 12 : 8
                for _ in 0..<count {
                    if reader.readBits(1) == 1 {
                        reader.skipScalingList(size: 16)
                        reader.skipScalingList(size: 64)
                    }
                }
            }
        }

        params.log2MaxFrameNum = reader.readUE() + 4
        params.pocType = reader.readUE()
        if params.pocType == 0 {
            params.log2MaxPocLsb = reader.readUE() + 4
        } else if params.pocType == 1 {
            _ = reader.readBits(1)
            _ = reader.readSE()
            _ = reader.readSE()
            let count = reader.readUE()
            for _ in 0..<count { _ = reader.readSE() }
        } else if params.pocType != 2 {
            return nil
        }
        _ = reader.readUE()                              // max_num_ref_frames
        _ = reader.readBits(1)                           // gaps_in_frame_num_value_allowed
        _ = reader.readUE()                              // width
        _ = reader.readUE()                              // height
        params.frameMbsOnly = reader.readBits(1) == 1
        return params
    }

    static func parsePPSBottomFieldFlag(_ pps: Data) -> Bool? {
        let bytes = [UInt8](pps)
        guard bytes.count > 2 else { return nil }
        var reader = BitReader(bytes: Array(bytes[1...]))
        _ = reader.readUE()                              // pps_id
        _ = reader.readUE()                              // sps_id
        _ = reader.readBits(1)                           // entropy_coding_mode_flag
        return reader.readBits(1) == 1
    }

    /// 读取 slice 的 POC lsb（poc_type == 0）
    static func slicePocLsb(_ nal: Data, params: POCParams) -> (isIDR: Bool, lsb: Int)? {
        guard params.pocType == 0 else { return nil }
        let bytes = [UInt8](nal)
        guard bytes.count > 1 else { return nil }
        let nalType = bytes[0] & 0x1F
        var reader = BitReader(bytes: Array(bytes[1...]))
        _ = reader.readUE()                              // first_mb_in_slice
        _ = reader.readUE()                              // slice_type
        _ = reader.readUE()                              // pps_id
        _ = reader.readBits(params.log2MaxFrameNum)      // frame_num
        if !params.frameMbsOnly {
            let fieldPic = reader.readBits(1)
            if fieldPic == 1 { _ = reader.readBits(1) }
        }
        if nalType == 5 { _ = reader.readUE() }          // idr_pic_id
        if params.bottomFieldPocPresent, !params.frameMbsOnly { _ = reader.readSE() }
        let lsb = reader.readBits(params.log2MaxPocLsb)
        return (nalType == 5, lsb)
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
                    let info = AudioInfo(sampleRate: audioRate, channels: max(1, channelConfig), audioSpecificConfig: config)
                    storedAudioInfo = info
                    onInfo?(nil, info)
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
        var codeStarts: [Int] = []   // 起始码第一个 0x00 的位置
        var nalStarts: [Int] = []    // NAL 头的实际起点

        var i = 0
        while i + 3 <= bytes.count {
            if i + 4 <= bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                codeStarts.append(i)
                nalStarts.append(i + 4)
                i += 4
            } else if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                codeStarts.append(i)
                nalStarts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }

        for index in nalStarts.indices {
            let start = nalStarts[index]
            // 结束位置 = 下一个起始码的起点（不能减 3/4，否则会残留 0x00）
            let end = index + 1 < codeStarts.count ? codeStarts[index + 1] : bytes.count
            guard start < end else { continue }
            // 原样保留 NAL 字节（含尾部 cabac_zero_words），不做任何修剪以免损坏切片
            result.append(Data(bytes[start..<end]))
        }
        return result
    }

    /// 解析 slice_type（0=P 1=B 2=I 3=SP 4=SI），用于区分参考帧/B 帧
    static func sliceType(_ nal: Data) -> Int? {
        guard nal.count > 2 else { return nil }
        var reader = BitReader(bytes: Array(nal.dropFirst()))
        _ = reader.readUE()   // first_mb_in_slice
        return reader.readUE()
    }
    /// 从 SPS 里解析分辨率（严格按 H.264 语法，含 high profile 的 chroma 字段）
    static func parseSPSDimensions(_ sps: Data) -> (Int, Int) {
        let bytes = [UInt8](sps)
        guard bytes.count > 4 else { return (0, 0) }
        let profile = bytes[1]
        var reader = BitReader(bytes: Array(bytes[4...]))   // 跳过 NAL 头/profile/constraint/level

        _ = reader.readUE()                                 // seq_parameter_set_id

        let highProfiles: Set<UInt8> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        if highProfiles.contains(profile) {
            let chromaFormat = reader.readUE()
            if chromaFormat == 3 { _ = reader.readBits(1) }
            _ = reader.readUE()                             // bit_depth_luma_minus8
            _ = reader.readUE()                             // bit_depth_chroma_minus8
            _ = reader.readBits(1)                          // qpprime_y_zero_transform_bypass
            if reader.readBits(1) == 1 {                    // seq_scaling_matrix_present
                let count = chromaFormat == 3 ? 12 : 8
                for _ in 0..<count {
                    if reader.readBits(1) == 1 {
                        reader.skipScalingList(size: 16)
                        reader.skipScalingList(size: 64)
                    }
                }
            }
        }

        _ = reader.readUE()                                 // log2_max_frame_num_minus4
        let pocType = reader.readUE()
        if pocType == 0 {
            _ = reader.readUE()                             // log2_max_pic_order_cnt_lsb_minus4
        } else if pocType == 1 {
            _ = reader.readBits(1)
            _ = reader.readSE()
            _ = reader.readSE()
            let count = reader.readUE()
            for _ in 0..<count { _ = reader.readSE() }
        }
        _ = reader.readUE()                                 // max_num_ref_frames
        _ = reader.readBits(1)                              // gaps_in_frame_num_value_allowed
        let widthMbs = reader.readUE() + 1
        let heightMapUnits = reader.readUE() + 1
        let frameMbsOnly = reader.readBits(1)
        if frameMbsOnly == 0 { _ = reader.readBits(1) }
        _ = reader.readBits(1)                              // direct_8x8_inference

        var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
        if reader.readBits(1) == 1 {
            cropLeft = reader.readUE()
            cropRight = reader.readUE()
            cropTop = reader.readUE()
            cropBottom = reader.readUE()
        }

        let heightMultiplier = 2 - frameMbsOnly
        var width = widthMbs * 16
        var height = heightMapUnits * 16 * heightMultiplier

        // 裁剪单位：4:2:0 = 2, 4:2:2 = 2(垂直 1), 4:4:4 = 1
        let chromaArrayType = 1
        let subWidthC = chromaArrayType == 3 ? 1 : 2
        let subHeightC = chromaArrayType == 1 ? 2 : 1
        let cropUnitX = chromaArrayType == 0 ? 1 : subWidthC
        let cropUnitY = (chromaArrayType == 0 ? 1 : subHeightC) * heightMultiplier

        width -= (cropLeft + cropRight) * cropUnitX
        height -= (cropTop + cropBottom) * cropUnitY
        return (max(0, width), max(0, height))
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

    /// 跳过 scaling list（SPS 里存在时长度不固定，必须按语法跳过）
    mutating func skipScalingList(size: Int) {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                let delta = readSE()
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
    }
}
