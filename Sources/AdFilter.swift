import Foundation

/// 断点（DISCONTINUITY）插入内容识别与剔除
/// S1（默认）：编码参数与主段不一致的区间判为插入内容
/// S2（可选开关）：断点处更换密钥的区间也判为插入内容
enum AdFilter {
    static let dropKeyChangedKey = "segments.dropKeyChanged"
    /// S1 判定模式：false=分辨率（默认），true=编码参数指纹
    static let fingerprintKey = "segments.adDetectFingerprint"

    struct Result {
        var excluded: [Int]
        var descriptions: [String]
    }

    /// 分析并返回应剔除的分片索引（不修改 state）
    static func analyze(state: SegmentJobState, dir: URL, dropKeyChanged: Bool, useFingerprint: Bool = false) -> Result {
        guard let discontinuities = state.discontinuities, !discontinuities.isEmpty else {
            return Result(excluded: [], descriptions: [])
        }
        let total = state.segmentURLs.count
        let keyChanges = Set(state.keyChanges ?? [])
        let boundaries = discontinuities.filter { $0 > 0 && $0 < total }.sorted()
        guard !boundaries.isEmpty else { return Result(excluded: [], descriptions: []) }

        let main = probeParams(dir: dir, index: 0)
        let modeText = useFingerprint ? "指纹" : "分辨率"

        var excluded: [Int] = []
        var descriptions: [String] = []

        for (position, start) in boundaries.enumerated() {
            let end = position + 1 < boundaries.count ? boundaries[position + 1] : total
            guard start < end else { continue }

            if dropKeyChanged, keyChanges.contains(start) {
                excluded.append(contentsOf: start..<end)
                descriptions.append("#\(start+1)–#\(end)（断点处更换密钥）")
                continue
            }

            var rangeParams: VideoParams?
            var sampleIndex = start
            while sampleIndex < end, rangeParams == nil {
                rangeParams = probeParams(dir: dir, index: sampleIndex)
                sampleIndex += 1
            }
            guard let candidate = rangeParams, let base = main else { continue }

            let candidateKey = useFingerprint ? (candidate.fingerprint ?? "\(candidate.width)x\(candidate.height)")
                                              : "\(candidate.width)x\(candidate.height)"
            let baseKey = useFingerprint ? (base.fingerprint ?? "\(base.width)x\(base.height)")
                                         : "\(base.width)x\(base.height)"

            if candidateKey != baseKey {
                excluded.append(contentsOf: start..<end)
                descriptions.append("#\(start+1)–#\(end)（\(modeText) \(candidate.summary) ≠ 主段 \(base.summary)）")
            }
        }

        return Result(excluded: excluded.sorted(), descriptions: descriptions)
    }

    struct VideoParams {
        var width: Int
        var height: Int
        var fingerprint: String?
        var summary: String
    }

    /// 读取分片首部的视频参数（分辨率 + SPS/PPS 指纹）
    private static func probeParams(dir: URL, index: Int) -> VideoParams? {
        let url = dir.appendingPathComponent(LocalHLS.fileName(index: index))
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let demuxer = TSDemuxer()
        var consumed = 0
        while consumed < 3 << 20 {
            guard let chunk = try? handle.read(upToCount: 256 << 10), !chunk.isEmpty else { break }
            demuxer.consume(chunk)
            consumed += chunk.count
            if let info = demuxer.videoInfo() {
                let hash = MediaCrypto.sha256Hex(info.sps + info.pps).prefix(8)
                let summary = "\(info.width)x\(info.height) SPS=\(info.sps.count)B PPS=\(info.pps.count)B p\(info.profileLevel.0) fp=\(hash)"
                return VideoParams(width: info.width,
                                   height: info.height,
                                   fingerprint: "\(info.width)x\(info.height)-\(info.profileLevel.0)-\(hash)",
                                   summary: summary)
            }
        }
        return nil
    }
}
