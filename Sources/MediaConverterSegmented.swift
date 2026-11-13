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
        let per = max(1, indices.count / partCount)
        DiagnosticsLog.write("[转MP4] 分段转换 \(indices.count) 个分片 → \(partCount) 段（每段约 \(per) 片）")

        var partURLs: [URL] = []
        var allSizes: [Int32] = []
        var allCtts: [Int32] = []
        var allKeys: [Int32] = []
        var sampleBase = 0
        let fm = FileManager.default
        defer { for url in partURLs { try? fm.removeItem(at: url) } }

        for part in 0..<partCount {
            let lower = part * per
            let upper = (part == partCount - 1) ? indices.count : (part + 1) * per
            guard lower < upper else { continue }
            let range = indices[lower]..<(indices[upper - 1] + 1)
            let partURL = VideoLibrary.assetsDir.appendingPathComponent(UUID().uuidString + ".part\(part).mp4")

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
                                            resetAudioSpool: part == 0)

            let partSizes = AVRemuxPipeline.lastVideoSizes
            let partKeys = AVRemuxPipeline.lastKeyframeIndices
            let partCtts = AVRemuxPipeline.lastCtts
            guard !partSizes.isEmpty else {
                throw PlaylistError.network("第 \(part + 1) 段没有产出样本")
            }
            allSizes.append(contentsOf: partSizes)
            allCtts.append(contentsOf: partCtts)
            allKeys.append(contentsOf: partKeys.map { $0 + Int32(sampleBase) })
            sampleBase += partSizes.count
            partURLs.append(partURL)
            DiagnosticsLog.write("[转MP4] 第 \(part + 1)/\(partCount) 段完成 样本=\(partSizes.count) 累计=\(sampleBase)")
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

        // 产物校验
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
}
