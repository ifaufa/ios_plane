import Foundation
import AVFoundation

extension MediaConverter {
    /// 大文件分段转换：把分片按顺序切成 N 段，每段单独写一个纯视频 MP4，
    /// 最后用 MP4PartMerger 合并为一个完整 MP4（含音频、stss）。
    static func convertSegmented(state: SegmentJobState,
                                 dir: URL,
                                 outputURL: URL,
                                 dirSize: Int64,
                                 onProgress: ((Double) -> Void)?) async throws {
        let excluded = Set(state.excluded ?? [])
        let indices = state.durations.indices.filter { !excluded.contains($0) }
        guard !indices.isEmpty else { throw PlaylistError.network("没有可用分片") }

        // 每段目标 ~700MB，最多 8 段
        let partCount = max(2, min(8, Int(ceil(Double(dirSize) / 700_000_000))))
        let budget = max(1, indices.count / partCount)

        // P3：按参数集（SPS/PPS）变化点切段，避免同一 writer 内混合不同编码参数
        let ranges = try planRanges(dir: dir, indices: indices, budget: budget)
        DiagnosticsLog.write("[转MP4] 分段转换 \(indices.count) 个分片 → \(ranges.count) 段（参数集扫描完成）")

        var partURLs: [URL] = []
        var allSizes: [Int32] = []
        var allCtts: [Int32] = []
        var allKeys: [Int32] = []
        var sampleBase = 0
        let fm = FileManager.default
        defer { for url in partURLs { try? fm.removeItem(at: url) } }

        for (offset, range) in ranges.enumerated() {
            let lower = indices.firstIndex(of: range.lowerBound) ?? 0
            let upper = (indices.firstIndex(of: range.upperBound - 1) ?? lower) + 1
            let partURL = VideoLibrary.assetsDir.appendingPathComponent(UUID().uuidString + ".part\(offset).mp4")

            try await AVRemuxPipeline.remux(state: state,
                                            dir: dir,
                                            destination: partURL,
                                            onProgress: { value in
                                                let base = Double(lower) / Double(indices.count)
                                                let span = Double(upper - lower) / Double(indices.count)
                                                onProgress?(base + value * span)
                                            },
                                            videoOnly: true,
                                            collectAudio: true,
                                            segmentRange: range,
                                            resetAudioSpool: offset == 0)

            let partSizes = AVRemuxPipeline.lastVideoSizes
            let partKeys = AVRemuxPipeline.lastKeyframeIndices
            let partCtts = AVRemuxPipeline.lastCtts
            guard !partSizes.isEmpty else {
                throw PlaylistError.network("第 \(offset + 1) 段没有产出样本")
            }
            allSizes.append(contentsOf: partSizes)
            allCtts.append(contentsOf: partCtts)
            allKeys.append(contentsOf: partKeys.map { $0 + Int32(sampleBase) })
            sampleBase += partSizes.count
            partURLs.append(partURL)
            DiagnosticsLog.write("[转MP4] 第 \(offset + 1)/\(ranges.count) 段完成 段范围=#\(range.lowerBound)–#\(range.upperBound - 1) 样本=\(partSizes.count) 累计=\(sampleBase)")
        }

        guard let spoolURL = AVRemuxPipeline.lastAudioSpoolURL else {
            throw PlaylistError.network("音频临时文件缺失")
        }
        defer { try? fm.removeItem(at: spoolURL) }

        let log = try MP4PartMerger.merge(partURLs: partURLs,
                                          sizes: allSizes,
                                          ctts: allCtts,
                                          keyframeIndices: allKeys,
                                          frameStep: AVRemuxPipeline.lastFrameStep,
                                          width: AVRemuxPipeline.lastVideoWidth,
                                          height: AVRemuxPipeline.lastVideoHeight,
                                          sps: AVRemuxPipeline.lastVideoSPS,
                                          pps: AVRemuxPipeline.lastVideoPPS,
                                          audioSpoolURL: spoolURL,
                                          audioSizes: AVRemuxPipeline.lastAudioFrameSizes,
                                          sampleRate: max(8000, AVRemuxPipeline.lastAudioSampleRate),
                                          channels: max(1, AVRemuxPipeline.lastAudioChannels),
                                          asc: AVRemuxPipeline.lastAudioASC ?? Data(),
                                          destination: outputURL)
        DiagnosticsLog.write("[转MP4] \(log)")

        let asset = AVURLAsset(url: outputURL)
        let videoCount = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).count
        let audioCount = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).count
        let stssOK = MP4Inspector.describe(outputURL).contains("stss(")
        DiagnosticsLog.write("[转MP4] 分段产物校验 视频轨=\(videoCount) 音频轨=\(audioCount) stss=\(stssOK ? "已写入" : "未写入")")
        guard videoCount == 1 else {
            throw PlaylistError.network("分段合并后视频轨数量异常（\(videoCount)）")
        }
        guard audioCount >= 1 else {
            throw PlaylistError.network("分段合并后无音频轨")
        }
        guard stssOK else {
            throw PlaylistError.network("分段合并后缺少 stss")
        }
    }

    // MARK: - 分段规划

    /// 扫描各分片首个 SPS/PPS：
    /// - 参数集变化处强制切段（避免同一 writer 混合不同编码参数）
    /// - 若分辨率也变化 → 明确报错（无损合并单文件在技术上不可行）
    private static func planRanges(dir: URL,
                                   indices: [Int],
                                   budget: Int) throws -> [Range<Int>] {
        guard indices.count > 32 else {
            return [indices.first!..<(indices.last! + 1)]
        }

        var baseSPS: Data?
        var basePPS: Data?
        var baseSize: (Int, Int)?
        var forcedStarts = Set<Int>()
        var scanned = 0
        let scanDeadline = Date().addingTimeInterval(20)

        for index in indices {
            if Date() > scanDeadline { break }
            guard let info = probeParams(dir: dir, index: index) else { continue }
            scanned += 1
            if baseSPS == nil {
                baseSPS = info.sps
                basePPS = info.pps
                baseSize = (info.width, info.height)
                continue
            }
            let changed = info.sps != baseSPS || info.pps != basePPS
            if changed {
                if let baseSize, baseSize != (info.width, info.height) {
                    throw PlaylistError.network("该源包含多种分辨率（\(baseSize.0)x\(baseSize.1) 与 \(info.width)x\(info.height)），无法无损合并为单个 MP4。建议改用『系统引擎』下载，或分集下载。")
                }
                if index != indices.first { forcedStarts.insert(index) }
            }
        }

        DiagnosticsLog.write("[转MP4] 参数集扫描 已扫描=\(scanned) 变化点=\(forcedStarts.count)")

        var ranges: [Range<Int>] = []
        var start = indices[0]
        var count = 0
        var previous = indices[0]
        for index in indices {
            let needBreak = (forcedStarts.contains(index) || count >= budget) && count > 0
            if needBreak {
                ranges.append(start..<(previous + 1))
                start = index
                count = 0
            }
            previous = index
            count += 1
        }
        ranges.append(start..<(indices.last! + 1))
        return ranges
    }

    /// 读取单个分片头部的视频参数（最多 192KB，拿到即停）
    private static func probeParams(dir: URL, index: Int) -> (width: Int, height: Int, sps: Data, pps: Data)? {
        let url = dir.appendingPathComponent(LocalHLS.fileName(index: index))
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let demuxer = TSDemuxer()
        var consumed = 0
        while consumed < 192 * 1024 {
            guard let chunk = try? handle.read(upToCount: 32 * 1024), !chunk.isEmpty else { break }
            demuxer.consume(chunk)
            consumed += chunk.count
            if let info = demuxer.videoInfo() {
                return (info.width, info.height, info.sps, info.pps)
            }
        }
        return nil
    }
}
