import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// 用 VideoToolbox 试解第一帧，判定"解复用出的样本是否合法"
enum H264Probe {
    static func decodeFirstFrame(avcc: Data, info: TSDemuxer.VideoInfo) -> String {
        let head = avcc.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")

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

        var session: VTDecompressionSession?
        let callback: VTDecompressionOutputCallback = { _, _, status, _, _, _ in
            NotificationCenter.default.post(name: .h264ProbeFrame, object: status)
        }
        var decoderParams = [kVTDecompressionPropertyKey_RealTime: false] as CFDictionary
        var sessionStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                         formatDescription: format,
                                                         decoderSpecifications: decoderParams as CFDictionary,
                                                         destinationImageBufferAttributes: nil,
                                                         outputCallback: callback,
                                                         decompressionSessionOut: &session)
        guard sessionStatus == noErr, let session else {
            return "VT 会话创建失败 status=\(sessionStatus)"
        }

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
              let blockBuffer else {
            return "CMBlockBuffer 创建失败"
        }
        let copied = avcc.withUnsafeBytes { buffer -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard copied == noErr else {
            return "样本数据写入失败"
        }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
                                        presentationTimeStamp: CMTime(value: 0, timescale: 90000),
                                        decodeTimeStamp: CMTime(value: 0, timescale: 90000))
        var sampleSize = avcc.count
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
            return "CMSampleBuffer 创建失败 status=\(sampleStatus)"
        }

        let probe = ProbeSink()
        let ref = Unmanaged.passRetained(probe).toOpaque()
        let callback: VTDecompressionOutputCallback = { refCon, _, status, _, _, _, _ in
            guard let refCon else { return }
            Unmanaged<ProbeSink>.fromOpaque(refCon).takeUnretainedValue().receivedStatus = status
        }
        var sessionStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                         formatDescription: format,
                                                         decoderSpecifications: decoderParams as CFDictionary,
                                                         outputCallback: callback,
                                                         decompressionSessionOut: &session)
        guard sessionStatus == noErr, let session else {
            Unmanaged.passUnretained(probe).release()
            return "VT 会话创建失败 status=\(sessionStatus)"
        }

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
              let blockBuffer else {
            Unmanaged.passUnretained(probe).release()
            return "CMBlockBuffer 创建失败"
        }
        let copied = avcc.withUnsafeBytes { buffer -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard copied == noErr else {
            Unmanaged.passUnretained(probe).release()
            return "样本数据写入失败"
        }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
                                        presentationTimeStamp: CMTime(value: 0, timescale: 90000),
                                        decodeTimeStamp: CMTime(value: 0, timescale: 90000))
        var sampleSize = avcc.count
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
            Unmanaged.passUnretained(probe).release()
            return "CMSampleBuffer 创建失败 status=\(sampleStatus)"
        }

        var infoFlags = VTDecodeFrameFlags(rawValue: 0)
        let decodeStatus = VTDecompressionSessionDecodeFrame(session,
                                                             sampleBuffer: sampleBuffer,
                                                             decodeFlags: infoFlags,
                                                             sourceFrameRefCon: ref,
                                                             infoFlagsOut: &infoFlags)
        if decodeStatus != noErr {
            VTDecompressionSessionInvalidate(session)
            Unmanaged.passUnretained(probe).release()
            return "解码调用失败 status=\(decodeStatus)（首帧头=\(head)）"
        }

        let deadline = Date().addingTimeInterval(2)
        var result = "解码无回调（2s 超时）"
        while Date() < deadline {
            if let status = probe.receivedStatus {
                result = status == noErr ? "解码成功（样本合法）" : "解码失败 status=\(status)"
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        VTDecompressionSessionInvalidate(session)
        Unmanaged.passUnretained(probe).release()
        return result + "（首帧头=\(head)）"
    }
}

private final class ProbeSink {
    var receivedStatus: OSStatus?
}
