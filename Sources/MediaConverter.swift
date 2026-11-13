import Foundation
import AVFoundation

/// 分片态视频转 MP4：TS 走自研无损转封装；失败再降级系统导出
enum MediaConverter {
    struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func convertToMP4(item: VideoItem,
                             onProgress: ((Double) -> Void)? = nil) async throws -> (fileName: String, duration: Double, fileSize: Int64) {
        guard item.fileName.lowercased().hasSuffix(".m3u8") else {
            throw ConversionError(message: "该视频已经是单体文件，无需转换")
        }
        let fm = FileManager.default
        let dir = VideoLibrary.assetsDir.appendingPathComponent((item.fileName as NSString).deletingLastPathComponent)
        guard let state = loadState(dir: dir) else {
            throw ConversionError(message: "缺少分片状态文件，无法转换")
        }

        cleanStaleTemps(in: dir)

        // 编码预检：10-bit H.264 无法在 App 内解码/封装，提前明确失败
        let verdict = CodecProbe.probeLocal(dir: dir)
        DiagnosticsLog.write("[转MP4] 编码预检 \(verdict.detail)")
        if !verdict.supported {
            throw ConversionError(message: "该视频为 \(verdict.detail)，iOS 不支持解码，无法在 App 内转为 MP4。建议用外部播放器或电脑处理。")
        }

        let dirSize = directorySize(dir)
        let estimatedFinal = Int64(Double(dirSize) * 0.75)
        let audioSpool = Int64(Double(dirSize) * 0.12)
        let safetyMargin: Int64 = 1024 * 1024 * 1024
        let required = dirSize + estimatedFinal + audioSpool + safetyMargin
        if let available = availableCapacity() {
            DiagnosticsLog.write(String(format: "[转MP4] 空间预检 分片=%.2fGB 库内记录=%.2fGB 预估成品=%.2fGB 音频临时=%.2fGB 余量=1.00GB 可用=%.2fGB 需求=%.2fGB",
                                        Double(dirSize) / 1_073_741_824,
                                        Double(item.fileSize) / 1_073_741_824,
                                        Double(estimatedFinal) / 1_073_741_824,
                                        Double(audioSpool) / 1_073_741_824,
                                        Double(available) / 1_073_741_824,
                                        Double(required) / 1_073_741_824))
            if available < required {
                throw ConversionError(message: String(format: "空间不足：分片 %.1f GB + 预估成品 %.1f GB（余量 0.3 GB），共需约 %.1f GB，当前仅剩 %.1f GB。原分片已保留。",
                                                     Double(dirSize) / 1_073_741_824,
                                                     Double(estimatedFinal) / 1_073_741_824,
                                                     Double(required) / 1_073_741_824,
                                                     Double(available) / 1_073_741_824))
            }
        }

        let outputName = UUID().uuidString + ".mp4"
        let outputURL = VideoLibrary.assetsDir.appendingPathComponent(outputName)
        if fm.fileExists(atPath: outputURL.path) {
            try? fm.removeItem(at: outputURL)
        }

        var produced = false

        // 1) 自研解复用 + AVAssetWriter（视频轨已验证正确）
        //    S1：通过格式描述扩展提供完整 esds；S2：视频-only + 自建音频轨合并；S3：保留画面版本
        let fm2 = FileManager.default
        let tryS1 = UserDefaults.standard.bool(forKey: "mp4TryS1")
        if tryS1 {
        do {
            let start = Date()
            try await AVRemuxPipeline.remux(state: state, dir: dir, destination: outputURL,
                                            onProgress: onProgress, videoOnly: false, audioFormatFlags: 2)
            let sizeAfter = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let asc = AVRemuxPipeline.lastAudioASC, !asc.isEmpty {
                let fixLog = MP4AudioFixer.fix(url: outputURL, asc: asc,
                                               sampleRate: AVRemuxPipeline.lastAudioSampleRate,
                                               audioChannels: AVRemuxPipeline.lastAudioChannels)
                let sizePatched = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                DiagnosticsLog.write("[转MP4] esds 修补：\(fixLog)（文件 \(sizeAfter)B → \(sizePatched)B）")
            }
            DiagnosticsLog.write("[转MP4] 音频轨诊断 \(MP4AudioFixer.inspectAudioTrack(url: outputURL))")
            let audioCount = ((try? await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)) ?? []).count
            DiagnosticsLog.write(String(format: "[转MP4] S1 完成 耗时 %.1fs 产物轨道 音频=%d", Date().timeIntervalSince(start), audioCount))
            if audioCount > 0 {
                produced = true
            } else {
                DiagnosticsLog.write("[转MP4] S1 无音轨，改用 S2（自建音频轨）")
            }
        } catch {
            DiagnosticsLog.write("[转MP4] S1 失败：\(error.localizedDescription)")
        }
        }

        // S2：视频-only 转换 + 收集音频帧 + 自建音频轨合并
        if !produced {
            do {
                let start = Date()
                AVRemuxPipeline.collectedAudioFrames = []
                try await AVRemuxPipeline.remux(state: state, dir: dir, destination: outputURL,
                                                onProgress: onProgress, videoOnly: true, collectAudio: true)
                let asc = AVRemuxPipeline.lastAudioASC ?? Data()
                let rate = max(8000, AVRemuxPipeline.lastAudioSampleRate)
                let channels = max(1, AVRemuxPipeline.lastAudioChannels)
                guard let spoolURL = AVRemuxPipeline.lastAudioSpoolURL else {
                    throw PlaylistError.network("转换失败：音频临时文件缺失")
                }
                defer { try? FileManager.default.removeItem(at: spoolURL) }
                // 原地合并：直接在 AVAssetWriter 产出的文件上追加音频 + 重写 moov，
                // 音频帧流式从临时文件读取，不产生第三份副本、内存零驻留
                let buildLog = try AudioTrackBuilder.mergeInPlace(videoURL: outputURL,
                                                                  audioSpoolURL: spoolURL,
                                                                  audioFrameSizes: AVRemuxPipeline.lastAudioFrameSizes,
                                                                  sampleRate: rate,
                                                                  channels: channels,
                                                                  asc: asc,
                                                                  keyframeIndices: AVRemuxPipeline.lastKeyframeIndices)
                DiagnosticsLog.write("[转MP4] \(buildLog)")

                // 产物级校验：视频 1 条 + 音频 1 条 + stss 已写入，任一不满足即明确失败（不静默降级）
                let builtAsset = AVURLAsset(url: outputURL)
                let audioCount = ((try? await builtAsset.loadTracks(withMediaType: .audio)) ?? []).count
                let videoCount = ((try? await builtAsset.loadTracks(withMediaType: .video)) ?? []).count
                let wroteStss = MP4Inspector.describe(outputURL).contains("stss(")
                DiagnosticsLog.write(String(format: "[转MP4] S2 完成 耗时 %.1fs 产物轨道 视频=%d 音频=%d stss=%@",
                                            Date().timeIntervalSince(start), videoCount, audioCount,
                                            wroteStss ? "已写入" : "未写入"))

                if videoCount != 1 || audioCount < 1 || !wroteStss {
                    var reasons: [String] = []
                    if videoCount != 1 { reasons.append("产物视频轨=\(videoCount)") }
                    if audioCount < 1 { reasons.append("产物无音频轨") }
                    if !wroteStss { reasons.append("stss 未写入") }
                    throw PlaylistError.network("转换失败：\(reasons.joined(separator: "，"))。可在设置中关闭“转换时写入同步样本表(stss)”后重试，或反馈该日志")
                }
                produced = true
            } catch {
                DiagnosticsLog.write("[转MP4] S2 失败：\(error.localizedDescription)")
            }
        }

        // S3：兜底——只要有画面就保留（不再整体失败）
        if !produced, fm2.fileExists(atPath: outputURL.path) {
            let videoCount = ((try? await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video)) ?? []).count
            if videoCount > 0 {
                produced = true
                DiagnosticsLog.write("[转MP4] S3：保留画面版本（无音轨）")
            }
        }
        // 2) fMP4 或自研失败：走 AVFoundation（HLS 资产）
        if !produced {
            do {
                let playlist = dir.appendingPathComponent("index.m3u8")
                let session = try LocalHLS.open(playlistURL: playlist)
                defer { session.stop() }
                let httpURL = session.url
                try await TSRemuxer.remux(source: httpURL, destination: outputURL)
                produced = true
                DiagnosticsLog.write("[转MP4] AVFoundation 转封装成功")
            } catch {
                DiagnosticsLog.write("[转MP4] AVFoundation 转封装失败：\(error.localizedDescription)")
            }
        }

        // 3) 最后兜底：合并后用系统导出（可能重编码）
        //    大文件（>1.5G）跳过：历史上该路径在导出 3G+ 文件时会内存暴涨被系统杀掉
        if !produced {
            if dirSize > 1_500_000_000 {
                DiagnosticsLog.write("[转MP4] 跳过系统导出兜底（源 \(dirSize / (1024 * 1024))MB 过大，避免内存崩溃）")
            } else {
                let report = try LocalHLS.merge(state: state, dir: dir, container: state.container)
                let mergedURL = report.url
                defer { try? fm.removeItem(at: mergedURL) }
                try await LocalHLS.exportMP4(from: mergedURL, to: outputURL)
                produced = true
            }
        }

        DiagnosticsLog.write("[转MP4] 结构自检 \(MP4Inspector.describe(outputURL))")

        let verify = await LocalHLS.verifyByPlayer(outputURL)
        let trackInfo = await describeTracks(outputURL)
        DiagnosticsLog.write("[转MP4] 轨道信息 \(trackInfo)")

        guard verify.playable, verify.duration > 1 else {
            // 保留产物，便于导出到电脑上比对（不删除，也不入库）
            DiagnosticsLog.write("[转MP4] 校验未通过，产物已保留：\(outputURL.lastPathComponent)")
            throw ConversionError(message: "转换后校验失败（\(verify.detail)；\(trackInfo)）。原分片已保留，产物 \(outputName) 也在「文件」App 里，可导出到电脑用 VLC 验证。")
        }

        try? fm.removeItem(at: dir)
        let attrs = try? fm.attributesOfItem(atPath: outputURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        DiagnosticsLog.write("[转MP4] 完成 时长=\(String(format: "%.1f", verify.duration))s 大小=\(size)B 已删除分片")
        return (outputName, verify.duration, size)
    }

    // MARK: - 工具

    private static func describeTracks(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else {
            return "无轨道"
        }
        var parts: [String] = []
        for track in tracks {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let range = (try? await track.load(.timeRange))?.duration.seconds ?? 0
            if track.mediaType == .audio {
                var description = "soun"
                if let formats = try? await track.load(.formatDescriptions), let first = formats.first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
                    description += " \(Int(asbd.mChannelsPerFrame))ch/\(Int(asbd.mSampleRate))Hz"
                }
                parts.append("\(description) \(String(format: "%.1f", range))s")
            } else {
                parts.append("\(track.mediaType.rawValue) \(Int(size.width))x\(Int(size.height)) \(String(format: "%.1f", range))s")
            }
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        return "总时长=\(String(format: "%.1f", duration))s | " + parts.joined(separator: " | ")
    }

    /// 导出合并 TS（电脑端可用 ffmpeg -i merged.ts -c copy out.mp4 无损转换）
    static func exportMergedTS(dir: URL, title: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let state = loadState(dir: dir) else {
                throw ConversionError(message: "缺少任务状态（state.json）")
            }
            let report = try LocalHLS.merge(state: state, dir: dir, container: state.container)
            let ext = report.url.pathExtension.isEmpty ? "ts" : report.url.pathExtension
            let base = title.isEmpty ? UUID().uuidString : title.replacingOccurrences(of: "/", with: "_")
            let dest = VideoLibrary.assetsDir.appendingPathComponent("\(base)-合并.\(ext)")
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: report.url, to: dest)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            DiagnosticsLog.write("[导出TS] 完成 \(dest.lastPathComponent) \(size)B")
            return dest
        }.value
    }
    private static func loadState(dir: URL) -> SegmentJobState? {
        let stateURL = dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SegmentJobState.self, from: data)
    }

    /// 清理下载中断/历史转换遗留的临时文件，避免虚增分片目录大小
    private static func cleanStaleTemps(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        var freed: Int64 = 0
        for url in items {
            let name = url.lastPathComponent.lowercased()
            let isTemp = name.hasSuffix(".part") || name.hasSuffix(".tmp")
                || name.hasSuffix(".download") || name.hasSuffix(".vonly.mp4")
                || name == "merged.ts" || name == "merged.mp4"
            guard isTemp else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
                freed += Int64(size)
            }
        }
        if removed > 0 {
            DiagnosticsLog.write("[转MP4] 清理残留临时文件 \(removed) 个，释放 \(freed / (1024 * 1024))MB")
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        for case let sub as String in enumerator {
            let fileURL = url.appendingPathComponent(sub)
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func availableCapacity() -> Int64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
