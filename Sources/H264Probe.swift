import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// 用 VideoToolbox 验证解复用出的样本：单帧探测 + 顺序解码（含参考帧链）
enum H264Probe {
    fileprivate static var sharedProbe: ProbeSink?
    fileprivate static var sharedCallback: VTDecompressionOutputCallback?

    static func decodeFirstFrame(avcc: Data, info: TSDemuxer.VideoInfo) -> String {
        decodeSequence(frames: [(avcc, 0, 0)], info: info)
    }

    /// 顺序解码：同一会话内逐帧解码，检测哪一帧损坏
    static func decodeSequence(frames: [(data: Data, pts: Int64, dts: Int64)],
                               info: TSDemuxer.VideoInfo) -> String {
        guard !frames.isEmpty else { return "无样本" }

        var format: CMFormatDescription?
        let formatStatus: OSStatus = info.sps.withUnsafeBytes { spsBuffer -> OSStatus in
            info.pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                guard let spsPtr = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(-1)
                }
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
        guard formatStatus == noErr, let format else {
            return "格式描述创建失败 status=\(formatStatus)"
        }

        let probe = ProbeSink()
        H264Probe.sharedProbe = probe
        let callback: VTDecompressionOutputCallback = { _, _, status, _, _, _, _ in
            H264Probe.sharedProbe?.statuses.append(status)
        }
        H264Probe.sharedCallback = callback

        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: nil
        )

        var session: VTDecompressionSession?
        let decoderParams = [kVTDecompressionPropertyKey_RealTime: false] as CFDictionary
        let sessionStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                         formatDescription: format,
                                                         decoderSpecification: decoderParams,
                                                         imageBufferAttributes: nil,
                                                         outputCallback: &record,
                                                         decompressionSessionOut: &session)
        guard sessionStatus == noErr, let session else {
            cleanup()
            return "VT 会话创建失败 status=\(sessionStatus)"
        }

        for (index, frame) in frames.enumerated() {
            var blockBuffer: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                                 memoryBlock: nil,
                                                                 blockLength: frame.data.count,
                                                                 blockAllocator: kCFAllocatorDefault,
                                                                 customBlockSource: nil,
                                                                 offsetToData: 0,
                                                                 dataLength: frame.data.count,
                                                                 flags: 0,
                                                                 blockBufferOut: &blockBuffer)
            guard blockStatus == noErr, let blockBuffer else {
                probe.texts.append("#\(index) 块创建失败")
                continue
            }
            _ = frame.data.withUnsafeBytes { buffer -> OSStatus in
                CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!,
                                              blockBuffer: blockBuffer,
                                              offsetIntoDestination: 0,
                                              dataLength: frame.data.count)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
                                            presentationTimeStamp: CMTime(value: frame.pts, timescale: 90000),
                                            decodeTimeStamp: CMTime(value: frame.dts, timescale: 90000))
            var sampleSize = frame.data.count
            var sampleBuffer: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                                    dataBuffer: blockBuffer,
                                                    dataReady: true,
                                                    makeDataReadyCallback: nil,
                                                    refcon: nil,
                                                    formatDescription: format,
                                                    sampleCount: 1,
                                                    sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing,
                                                    sampleSizeEntryCount: 1,
                                                    sampleSizeArray: &sampleSize,
                                                    sampleBufferOut: &sampleBuffer)
            guard sampleStatus == noErr, let sampleBuffer else {
                probe.texts.append("#\(index) 样本创建失败")
                continue
            }
            var infoFlags = VTDecodeInfoFlags(rawValue: 0)
            let decodeStatus = VTDecompressionSessionDecodeFrame(session,
                                                                 sampleBuffer: sampleBuffer,
                                                                 flags: VTDecodeFrameFlags(rawValue: 0),
                                                                 frameRefcon: nil,
                                                                 infoFlagsOut: &infoFlags)
            if decodeStatus != noErr {
                probe.texts.append("#\(index) 调用失败=\(decodeStatus)")
            }
        }

        // 等待全部回调
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if probe.statuses.count >= frames.count { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        VTDecompressionSessionInvalidate(session)
        cleanup()

        var lines: [String] = []
        for index in frames.indices {
            let status = index < probe.statuses.count ? probe.statuses[index] : OSStatus(-9999)
            let head = frames[index].data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            let verdict = status == noErr ? "OK" : "失败(\(status))"
            lines.append("#\(index)[\(frames[index].data.count)B \(head) \(verdict)]")
        }
        return "顺序解码：" + lines.joined(separator: " ")
    }

    fileprivate static func cleanup() {
        H264Probe.sharedProbe = nil
        H264Probe.sharedCallback = nil
    }
}

fileprivate final class ProbeSink {
    var statuses: [OSStatus] = []
    var texts: [String] = []
}
