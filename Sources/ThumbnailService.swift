import UIKit
import AVFoundation
import VideoToolbox
import CoreMedia

/// 视频库预览图：取「总时长 30%」处的一帧
/// MP4/movpkg 走 AVAssetImageGenerator；分片（HLS）走自研解复用 + VideoToolbox
enum ThumbnailService {
    /// 缓存版本号：改动取帧策略时递增，旧图自动失效
    private static let cacheVersion = "v2"
    private static let fraction = 0.3

    private static var root: URL {
        let dir = VideoLibrary.assetsDir.appendingPathComponent(".thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString)-\(cacheVersion).jpg")
    }

    static func cached(for id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return UIImage(data: data)
    }

    static func ensureThumbnail(for item: VideoItem, localURL: URL) async -> UIImage? {
        if let cached = cached(for: item.id) { return cached }
        let isHLS = localURL.pathExtension.lowercased() == "m3u8"
        guard let image = await generate(localURL: localURL, isHLS: isHLS, knownDuration: item.duration) else {
            return nil
        }
        if let data = image.jpegData(compressionQuality: 0.82) {
            try? data.write(to: fileURL(for: item.id), options: .atomic)
        }
        return image
    }

    // MARK: - 生成

    private static func generate(localURL: URL, isHLS: Bool, knownDuration: Double) async -> UIImage? {
        if isHLS {
            return await frameAtFractionFromSegments(dir: localURL.deletingLastPathComponent())
        }
        return await imageFromAsset(localURL, knownDuration: knownDuration)
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
        generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)

        if let result = try? await generator.image(at: CMTime(seconds: target, preferredTimescale: 600)) {
            return UIImage(cgImage: result.image)
        }
        for fallback in [1.0, 0.0] {
            if let result = try? await generator.image(at: CMTime(seconds: fallback, preferredTimescale: 600)) {
                return UIImage(cgImage: result.image)
            }
        }
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

        // 优先取目标分片，失败则回退到第 1 个分片
        for index in [targetIndex, 0] {
            if let image = firstKeyframeImage(dir: dir, index: index) { return image }
        }
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
enum FirstFrameDecoder {
    fileprivate final class Sink {
        var image: CGImage?
    }

    private static var sink: Sink?

    private static let callback: VTDecompressionOutputCallback = { _, _, status, _, imageBuffer, _, _ in
        guard status == noErr, let imageBuffer, let sink else { return }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
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

        let newSink = Sink()
        sink = newSink
        defer { sink = nil }

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
                                                frameRefcon: nil,
                                                infoFlagsOut: nil) == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return newSink.image.map { UIImage(cgImage: $0) }
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
