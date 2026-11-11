import UIKit
import AVFoundation
import VideoToolbox
import CoreMedia

/// 视频库预览图：取「总时长 30%」处的一帧
/// MP4/movpkg 走 AVAssetImageGenerator；分片（HLS）走自研解复用 + VideoToolbox
extension Notification.Name {
    static let thumbnailReady = Notification.Name("thumbnail.ready")
}

enum ThumbnailService {
    /// 缓存版本号：改动取帧策略时递增，旧图自动失效
    private static let cacheVersion = "v6"
    private static var didPurge = false
    private static var inFlight: Set<UUID> = []
    private static let inFlightLock = NSLock()
    private static let fraction = 0.3

    private static var root: URL {
        let dir = VideoLibrary.assetsDir.appendingPathComponent(".thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString)-\(cacheVersion).jpg")
    }

    /// 启动后后台串行补齐所有缺失缩略图（含 movpkg），保证日志完整可诊断
    static func pregenerate(items: [VideoItem], urlFor: @escaping (VideoItem) -> URL) async {
        purgeOldCachesIfNeeded()
        removeOrphans(validIDs: Set(items.map { $0.id }))
        var generated = 0
        var cachedCount = 0
        var missingCount = 0
        for item in items {
            if cached(for: item.id) != nil { cachedCount += 1; continue }
            let url = urlFor(item)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !exists {
                missingCount += 1
                DiagnosticsLog.write("[缩略图] 跳过（文件不存在）\(item.fileName)")
                continue
            }
            if url.pathExtension.lowercased() == "movpkg" {
                DiagnosticsLog.write("[缩略图] movpkg 开始处理 \(url.lastPathComponent) 是目录=\(isDirectory.boolValue)")
            }
            if await ensureThumbnail(for: item, localURL: url) != nil { generated += 1 }
        }
        DiagnosticsLog.write("[缩略图] 预生成检查 \(items.count) 个，命中缓存 \(cachedCount)，新生成 \(generated)，缺文件 \(missingCount)")
    }

    /// 删除库里已不存在的条目对应缩略图
    private static func removeOrphans(validIDs: Set<UUID>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for url in entries where url.lastPathComponent.hasSuffix("-\(cacheVersion).jpg") {
            let name = url.lastPathComponent
            let idPart = name.replacingOccurrences(of: "-\(cacheVersion).jpg", with: "")
            if let id = UUID(uuidString: idPart), !validIDs.contains(id) {
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        if removed > 0 { DiagnosticsLog.write("[缩略图] 清理孤儿缩略图 \(removed) 个") }
    }

    static func cached(for id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return UIImage(data: data)
    }

    static func ensureThumbnail(for item: VideoItem, localURL: URL) async -> UIImage? {
        purgeOldCachesIfNeeded()
        if let cached = cached(for: item.id) { return cached }

        inFlightLock.lock()
        if inFlight.contains(item.id) {
            inFlightLock.unlock()
            return nil
        }
        inFlight.insert(item.id)
        inFlightLock.unlock()
        defer {
            inFlightLock.lock()
            inFlight.remove(item.id)
            inFlightLock.unlock()
        }

        let isHLS = localURL.pathExtension.lowercased() == "m3u8"
        guard let image = await generate(localURL: localURL, isHLS: isHLS, knownDuration: item.duration) else {
            return nil
        }
        if let data = image.jpegData(compressionQuality: 0.82) {
            try? data.write(to: fileURL(for: item.id), options: .atomic)
            NotificationCenter.default.post(name: .thumbnailReady, object: item.id)
        }
        return image
    }

    /// 缓存版本升级时清掉旧图，避免继续显示历史（错误的）缩略图
    private static func purgeOldCachesIfNeeded() {
        guard !didPurge else { return }
        didPurge = true
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for url in entries where !url.lastPathComponent.hasSuffix("-\(cacheVersion).jpg") {
            try? fm.removeItem(at: url)
            removed += 1
        }
        if removed > 0 { DiagnosticsLog.write("[缩略图] 清理旧缓存 \(removed) 个") }
    }

    // MARK: - 生成

    private static func generate(localURL: URL, isHLS: Bool, knownDuration: Double) async -> UIImage? {
        if isHLS {
            return await frameAtFractionFromSegments(dir: localURL.deletingLastPathComponent())
        }

        // 非分片：先算目标时间，再用播放链路抓帧（imageGenerator 对这批文件会 Cannot Decode）
        var duration = knownDuration
        if duration <= 0 {
            let asset = AVURLAsset(url: localURL)
            duration = (try? await asset.load(.duration))?.seconds ?? 0
        }
        let target = duration > 0 ? min(max(duration * fraction, 1), max(duration - 1, 1)) : 3

        if let image = await PlayerFrameGrabber.image(url: localURL, at: target) {
            DiagnosticsLog.write("[缩略图] 播放链路抓帧成功 \(localURL.lastPathComponent) 目标=\(Int(target))s 时长=\(Int(duration))s")
            return image
        }

        // 回退 2：AVAssetReader 确定性解码（与播放器状态无关）
        if let image = await AssetReaderFrameGrabber.image(url: localURL, at: target) {
            DiagnosticsLog.write("[缩略图] 解码器抓帧成功 \(localURL.lastPathComponent) 目标=\(Int(target))s")
            return image
        }

        // 回退 3：旧产物缺少 stss 表、无法 seek，只能从开头解码（取 1s 附近）
        for fallback in [1.0, 0.5] {
            if let image = await AssetReaderFrameGrabber.image(url: localURL, at: fallback) {
                DiagnosticsLog.write("[缩略图] 旧文件回退取帧 \(localURL.lastPathComponent) 位置=\(fallback)s")
                return image
            }
        }

        // 回退：AVAssetImageGenerator（可能仍失败）
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return await imageFromBundle(localURL)
        }
        return await imageFromAsset(localURL, knownDuration: duration)
    }

    /// movpkg 等目录型资产：先直接对包取帧，失败再找内部最大的媒体文件
    private static func imageFromBundle(_ dir: URL) async -> UIImage? {
        DiagnosticsLog.write("[缩略图] movpkg 尝试直接取帧 \(dir.lastPathComponent)")
        if let image = await imageFromAsset(dir, knownDuration: 0) {
            DiagnosticsLog.write("[缩略图] movpkg 直接取帧成功 \(dir.lastPathComponent)")
            return image
        }
        DiagnosticsLog.write("[缩略图] movpkg 直接取帧失败，改为扫描内部文件")

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        var candidates: [(url: URL, size: Int)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            if size > 64 * 1024 { candidates.append((url, size)) }
        }
        candidates.sort { $0.size > $1.size }
        DiagnosticsLog.write("[缩略图] movpkg 内文件数=\(candidates.count) 最大三个=\(candidates.prefix(3).map { "\($0.url.lastPathComponent)(\($0.size / 1024)KB)" }.joined(separator: ","))")

        for candidate in candidates.prefix(3) {
            if let image = await imageFromAsset(candidate.url, knownDuration: 0) {
                DiagnosticsLog.write("[缩略图] 使用内部文件 \(candidate.url.lastPathComponent) 成功")
                return image
            }
        }
        DiagnosticsLog.write("[缩略图] movpkg 内所有候选均取帧失败 \(dir.lastPathComponent)")
        return nil
    }

    private static func imageFromAsset(_ url: URL, knownDuration: Double) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        var duration = knownDuration
        if duration <= 0, let loaded = try? await asset.load(.duration) {
            duration = loaded.seconds
        }
        let target = duration > 0 ? min(max(duration * fraction, 1), max(duration - 1, 1)) : 3

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        // 只允许"向后"放宽：允许取目标之后的最近关键帧，但不允许退回到更早的帧（避免变成首帧）
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity

        var best: (image: CGImage, actual: Double)?
        var lastError: String?

        for attempt in [target, max(target * 0.6, 1), 1.0] {
            do {
                let result = try await generator.image(at: CMTime(seconds: attempt, preferredTimescale: 600))
                let actual = result.actualTime.seconds
                if best == nil || abs(actual - target) < abs((best?.actual ?? 0) - target) {
                    best = (result.image, actual.isFinite ? actual : 0)
                }
                if attempt == target {
                    DiagnosticsLog.write("[缩略图] 生成成功 \(url.lastPathComponent) 目标=\(Int(target))s 实得=\(Int(actual))s")
                }
                break
            } catch {
                lastError = error.localizedDescription
            }
        }

        if let best {
            if best.actual < target * 0.5 {
                DiagnosticsLog.write("[缩略图] 取偏 \(url.lastPathComponent) 目标=\(Int(target))s 实得=\(Int(best.actual))s")
            }
            return UIImage(cgImage: best.image)
        }

        let tracks = (try? await asset.load(.tracks)) ?? []
        let videoTracks = tracks.filter { $0.mediaType == .video }
        var sizeText = "-"
        if let first = videoTracks.first, let natural = try? await first.load(.naturalSize) {
            sizeText = "\(Int(natural.width))x\(Int(natural.height))"
        }
        DiagnosticsLog.write("[缩略图] 取帧失败 \(url.lastPathComponent) 目标=\(Int(target))s 时长=\(Int(duration))s 轨道=\(tracks.count)(视频\(videoTracks.count)) 尺寸=\(sizeText) 错误=\(lastError ?? "-")")
        return nil
    }

    // MARK: - 分片（HLS）

    private static func frameAtFractionFromSegments(dir: URL) async -> UIImage? {
        let playlistURL = dir.appendingPathComponent("index.m3u8")
        let durations = parseDurations(playlistURL)
        let total = durations.reduce(0, +)

        var targetIndex = 0
        if total > 0, !durations.isEmpty {
            let target = total * fraction
            var accumulated: Double = 0
            for (index, duration) in durations.enumerated() {
                if accumulated + duration > target { targetIndex = index; break }
                accumulated += duration
                targetIndex = index
            }
        }

        DiagnosticsLog.write("[缩略图] 分片目录 \(dir.lastPathComponent) 段数=\(durations.count) 总时长=\(Int(total))s 目标分片=#\(targetIndex)")
        // 优先取目标分片，失败则回退到第 1 个分片
        for index in [targetIndex, 0] {
            if let image = firstKeyframeImage(dir: dir, index: index) {
                DiagnosticsLog.write("[缩略图] 分片生成成功 段#\(index) 目录=\(dir.lastPathComponent)")
                return image
            }
        }
        DiagnosticsLog.write("[缩略图] 分片生成失败 目录=\(dir.lastPathComponent)")
        return nil
    }

    private static func parseDurations(_ playlistURL: URL) -> [Double] {
        guard let text = try? String(contentsOf: playlistURL, encoding: .utf8) else { return [] }
        var durations: [Double] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                if let duration = Double(value.trimmingCharacters(in: .whitespaces)) {
                    durations.append(duration)
                }
            }
        }
        return durations
    }

    private static func firstKeyframeImage(dir: URL, index: Int) -> UIImage? {
        let file = dir.appendingPathComponent(LocalHLS.fileName(index: index))
        guard FileManager.default.fileExists(atPath: file.path),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var captured: Data?
        let demuxer = TSDemuxer()
        demuxer.onVideoFrame = { data, _, _, isKey, _, _ in
            if isKey, captured == nil { captured = data }
        }

        var consumed = 0
        while consumed < 4 << 20 {
            guard let chunk = try? handle.read(upToCount: 256 << 10), !chunk.isEmpty else { break }
            demuxer.consume(chunk)
            consumed += chunk.count
            if captured != nil, demuxer.videoInfo() != nil { break }
        }
        guard let frame = captured, let info = demuxer.videoInfo() else { return nil }
        return FirstFrameDecoder.image(avcc: frame, info: info)
    }
}

/// 单帧 H.264 解码（AVCC 样本 + SPS/PPS）
/// 并发安全：解码结果通过 sourceFrameRefCon 绑定到每次调用独立的上下文，
/// 不使用全局变量（否则并发生成缩略图会串图）
enum FirstFrameDecoder {
    fileprivate final class Sink {
        var image: CGImage?
    }

    private static let callback: VTDecompressionOutputCallback = { _, sourceRefCon, status, _, imageBuffer, _, _ in
        guard status == noErr, let imageBuffer, let sourceRefCon else { return }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
        let sink = Unmanaged<Sink>.fromOpaque(sourceRefCon).takeUnretainedValue()
        sink.image = cgImage
    }

    static func image(avcc: Data, info: TSDemuxer.VideoInfo) -> UIImage? {
        var format: CMFormatDescription?
        let status: OSStatus = info.sps.withUnsafeBytes { spsBuffer -> OSStatus in
            info.pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                guard let spsPtr = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [info.sps.count, info.pps.count]
                return pointers.withUnsafeBufferPointer { ptrBuffer -> OSStatus in
                    sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        guard status == noErr, let format else { return nil }

        let result = Sink()
        let resultPointer = Unmanaged.passUnretained(result).toOpaque()

        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: nil
        )
        var session: VTDecompressionSession?
        let decoderParams = [kVTDecompressionPropertyKey_RealTime: false] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                           formatDescription: format,
                                           decoderSpecification: decoderParams,
                                           imageBufferAttributes: nil,
                                           outputCallback: &record,
                                           decompressionSessionOut: &session) == noErr,
              let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        guard let sample = makeSampleBuffer(avcc: avcc, format: format) else { return nil }
        guard VTDecompressionSessionDecodeFrame(session,
                                                sampleBuffer: sample,
                                                flags: [VTDecodeFrameFlags._EnableAsynchronousDecompression],
                                                frameRefcon: resultPointer,
                                                infoFlagsOut: nil) == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return result.image.map { UIImage(cgImage: $0) }
    }

    private static func makeSampleBuffer(avcc: Data, format: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                memoryBlock: nil,
                                                blockLength: avcc.count,
                                                blockAllocator: kCFAllocatorDefault,
                                                customBlockSource: nil,
                                                offsetToData: 0,
                                                dataLength: avcc.count,
                                                flags: 0,
                                                blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return nil }
        let copied = avcc.withUnsafeBytes { buffer -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                          dataBuffer: blockBuffer,
                                          dataReady: true,
                                          makeDataReadyCallback: nil,
                                          refcon: nil,
                                          formatDescription: format,
                                          sampleCount: 1,
                                          sampleTimingEntryCount: 1,
                                          sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 1,
                                          sampleSizeArray: &size,
                                          sampleBufferOut: &sampleBuffer)
        return status == noErr ? sampleBuffer : nil
    }
}
