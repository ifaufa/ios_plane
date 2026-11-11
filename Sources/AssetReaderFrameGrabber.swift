import UIKit
import AVFoundation
import CoreImage

/// 用 AVAssetReader 做确定性解码抓帧（本地产物，非 HLS）
/// 与播放器状态无关：从目标时间前的同步样本开始解码，取最接近目标时间的帧
enum AssetReaderFrameGrabber {
    static func image(url: URL, at seconds: Double) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let track = tracks.first else {
            DiagnosticsLog.write("[解码抓帧] 无视频轨 \(url.lastPathComponent)")
            return nil
        }

        guard let reader = try? AVAssetReader(asset: asset) else {
            DiagnosticsLog.write("[解码抓帧] 无法创建 reader \(url.lastPathComponent)")
            return nil
        }

        let start = max(0, seconds - 6)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: 20, preferredTimescale: 600))

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            DiagnosticsLog.write("[解码抓帧] 无法添加输出 \(url.lastPathComponent)")
            return nil
        }
        reader.add(output)

        guard reader.startReading() else {
            let error = reader.error?.localizedDescription ?? "-"
            DiagnosticsLog.write("[解码抓帧] 启动失败 \(url.lastPathComponent) 错误=\(error)")
            return nil
        }
        defer { reader.cancelReading() }

        let context = CIContext(options: nil)
        var best: (image: UIImage, time: Double)?
        var lastTime: Double = -1

        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts.isFinite { lastTime = pts }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { continue }
            let image = UIImage(cgImage: cgImage)

            if pts.isFinite, pts >= seconds - 0.5 {
                DiagnosticsLog.write("[解码抓帧] 成功 \(url.lastPathComponent) 目标=\(Int(seconds))s 实得=\(Int(pts))s")
                return image
            }
            if best == nil || abs(lastTime - seconds) < abs((best?.time ?? 0) - seconds) {
                best = (image, lastTime)
            }
            if pts.isFinite, pts > seconds + 8 { break }
            if reader.status == .failed { break }
        }

        if let best {
            DiagnosticsLog.write("[解码抓帧] 取最近帧 \(url.lastPathComponent) 目标=\(Int(seconds))s 实得=\(Int(best.time))s")
            return best.image
        }

        DiagnosticsLog.write("[解码抓帧] 无可用样本 \(url.lastPathComponent) 目标=\(Int(seconds))s 最后时间=\(Int(lastTime))s 状态=\(reader.status.rawValue)")
        return nil
    }
}
