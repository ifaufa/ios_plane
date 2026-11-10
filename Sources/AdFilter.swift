import Foundation

/// 断点（DISCONTINUITY）插入内容识别与剔除
/// S1（默认）：编码参数与主段不一致的区间判为插入内容
/// S2（可选开关）：断点处更换密钥的区间也判为插入内容
enum AdFilter {
    static let dropKeyChangedKey = "segments.dropKeyChanged"

    struct Result {
        var excluded: [Int]
        var descriptions: [String]
    }

    /// 分析并返回应剔除的分片索引（不修改 state）
    static func analyze(state: SegmentJobState, dir: URL, dropKeyChanged: Bool) -> Result {
        guard let discontinuities = state.discontinuities, !discontinuities.isEmpty else {
            return Result(excluded: [], descriptions: [])
        }
        let total = state.segmentURLs.count
        let keyChanges = Set(state.keyChanges ?? [])
        let boundaries = discontinuities.filter { $0 > 0 && $0 < total }.sorted()
        guard !boundaries.isEmpty else { return Result(excluded: [], descriptions: []) }

        let main = probeParams(dir: dir, index: 0, cache: [:])

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

            var cache: [Int: (Int, Int)] = [:]
            var rangeParams: (Int, Int)?
            var sampleIndex = start
            while sampleIndex < end, rangeParams == nil {
                rangeParams = probeParams(dir: dir, index: sampleIndex, cache: cache)
                sampleIndex += 1
            }
            guard let candidate = rangeParams, let base = main else { continue }
            if candidate != base {
                excluded.append(contentsOf: start..<end)
                descriptions.append("#\(start+1)–#\(end)（分辨率 \(candidate.0)x\(candidate.1) ≠ 主段 \(base.0)x\(base.1)）")
            }
        }

        return Result(excluded: excluded.sorted(), descriptions: descriptions)
    }

    /// 读取分片首部的视频分辨率（失败返回 nil）
    private static func probeParams(dir: URL, index: Int, cache: [Int: (Int, Int)]) -> (Int, Int)? {
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
                return (info.width, info.height)
            }
        }
        return nil
    }
}
