import UIKit
import AVFoundation
import CoreImage

/// 通过播放链路抓帧：AVPlayerItemVideoOutput
/// 适用 AVAssetImageGenerator 拒绝解码的文件（mp4 / movpkg）
/// 注意：必须静音，否则抓帧瞬间会漏出视频声音
enum PlayerFrameGrabber {
    static func image(url: URL, at seconds: Double, timeout: TimeInterval = 5) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.isMuted = true          // 抓帧不能出声
        player.volume = 0
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            item.remove(output)
        }

        // 1) 等资产就绪
        let ready = await waitUntil(timeout: timeout) { item.status != .unknown }
        guard ready else {
            DiagnosticsLog.write("[抓帧] 超时未就绪 \(url.lastPathComponent)")
            return nil
        }
        guard item.status == .readyToPlay else {
            let error = (item.error as NSError?)?.localizedDescription ?? "-"
            DiagnosticsLog.write("[抓帧] 无法加载 \(url.lastPathComponent) 错误=\(error)")
            return nil
        }

        let target = max(0, seconds)

        // 2) 定位到目标时间（允许向后取最近可解帧）
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .positiveInfinity) { _ in
                continuation.resume()
            }
        }

        // 3) 等播放器真正停在目标位置附近（否则会抓到最后一次已解码的首帧）
        let tolerance = max(2.0, target * 0.02)
        let positioned = await waitUntil(timeout: 3.0) {
            let current = player.currentTime().seconds
            return current.isFinite && abs(current - target) <= tolerance
        }
        guard positioned else {
            let current = player.currentTime().seconds
            DiagnosticsLog.write("[抓帧] 定位失败 \(url.lastPathComponent) 目标=\(Int(target))s 实际=\(Int(current.isFinite ? current : -1))s")
            return nil
        }

        // 4) 让播放器解码出一帧
        player.play()
        let itemTime = CMTime(seconds: target, preferredTimescale: 600)
        let gotFrame = await waitUntil(timeout: 2.0) {
            output.hasNewPixelBuffer(forItemTime: itemTime)
        }
        player.pause()

        guard gotFrame,
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            DiagnosticsLog.write("[抓帧] 未取得像素 \(url.lastPathComponent) 目标=\(Int(target))s")
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        DiagnosticsLog.write("[抓帧] 成功 \(url.lastPathComponent) 目标=\(Int(target))s")
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
