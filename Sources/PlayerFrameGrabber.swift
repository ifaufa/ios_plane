import UIKit
import AVFoundation
import CoreImage

/// 通过播放链路抓帧：AVPlayerItemVideoOutput
/// 适用 AVAssetImageGenerator 拒绝解码的文件（mp4 / movpkg）
enum PlayerFrameGrabber {
    static func image(url: URL, at seconds: Double, timeout: TimeInterval = 4) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            item.remove(output)
        }

        // 1) 等资产就绪
        let ready = await waitUntil(timeout: timeout) {
            item.status != .unknown
        }
        guard ready else {
            DiagnosticsLog.write("[抓帧] 超时未就绪 \(url.lastPathComponent)")
            return nil
        }
        guard item.status == .readyToPlay else {
            let error = (item.error as NSError?)?.localizedDescription ?? "-"
            DiagnosticsLog.write("[抓帧] 无法加载 \(url.lastPathComponent) 错误=\(error)")
            return nil
        }

        // 2) 定位到目标时间（允许向后取最近可解帧）
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { _ in
                continuation.resume()
            }
        }

        // 3) 让播放器真正出手一帧
        player.play()
        let gotFrame = await waitUntil(timeout: 2.0) {
            output.hasNewPixelBuffer(forItemTime: target)
        }
        player.pause()

        guard gotFrame, let buffer = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) else {
            DiagnosticsLog.write("[抓帧] 未取得像素 \(url.lastPathComponent) 目标=\(Int(seconds))s")
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        DiagnosticsLog.write("[抓帧] 成功 \(url.lastPathComponent) 目标=\(Int(seconds))s")
        return UIImage(cgImage: cgImage)
    }

    private static func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}
