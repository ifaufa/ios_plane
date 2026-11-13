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

        let dirSize = directorySize(dir)
        if let available = availableCapacity(),
           available < Int64(Double(dirSize) * 2.3) + 200 * 1024 * 1024 {
            let need = Double(dirSize) * 2.3 / 1_073_741_824
            let left = Double(available) / 1_073_741_824
            throw ConversionError(message: String(format: "空间不足：转 MP4 约需 %.1f GB，当前仅剩 %.1f GB。原分片已保留。", need, left))
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
                let frames = AVRemuxPipeline.collectedAudioFrames
                let asc = AVRemuxPipeline.lastAudioASC ?? Data()
                let rate = max(8000, AVRemuxPipeline.lastAudioSampleRate)
                let channels = max(1, AVRemuxPipeline.lastAudioChannels)
                let videoOnlyURL = VideoLibrary.assetsDir.appendingPathComponent(UUID().uuidString + ".vonly.mp4")
                if fm2.fileExists(atPath: videoOnlyURL.path) { try? fm2.removeItem(at: videoOnlyURL) }
                try fm2.moveItem(at: outputURL, to: videoOnlyURL)
                let buildLog = try AudioTrackBuilder.build(videoURL: videoOnlyURL,
                                                           audioFrames: frames,
                                                           sampleRate: rate,
                                                           channels: channels,
                                                           asc: asc,
                                                           destination: outputURL,
                                                           keyframeIndices: AVRemuxPipeline.lastKeyframeIndices)
                DiagnosticsLog.write("[转MP4] stss 校验 \(MP4Inspector.describe(outputURL).contains("stss(") ? "通过" : "未写入")")
                try? fm2.removeItem(at: videoOnlyURL)
                DiagnosticsLog.write("[转MP4] \(buildLog)")
                let audioCount = ((try? await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)) ?? []).count
                let videoCount = ((try? await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video)) ?? []).count
                DiagnosticsLog.write(String(format: "[转MP4] S2 完成 耗时 %.1fs 产物轨道 视频=%d 音频=%d", Date().timeIntervalSince(start), videoCount, audioCount))
                if audioCount > 0, videoCount > 0 {
                    produced = true
                }
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
        if !produced {
            let report = try LocalHLS.merge(state: state, dir: dir, container: state.container)
            let mergedURL = report.url
            defer { try? fm.removeItem(at: mergedURL) }
            try await LocalHLS.exportMP4(from: mergedURL, to: outputURL)
            produced = true
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
