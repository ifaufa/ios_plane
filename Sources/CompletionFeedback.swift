import Foundation
import AVFoundation
import UserNotifications
import UIKit

/// 下载完成的反馈：低音量提示音 + 后台本地通知
enum CompletionFeedback {
    static let soundKey = "downloads.completionSound"
    static let noticeKey = "downloads.completionNotice"

    static var soundEnabled: Bool {
        (UserDefaults.standard.object(forKey: soundKey) as? Bool) ?? true
    }

    static var noticeEnabled: Bool {
        (UserDefaults.standard.object(forKey: noticeKey) as? Bool) ?? true
    }

    // MARK: - 提示音

    private static var player: AVAudioPlayer?
    private static var lastPlayed = Date.distantPast
    private static let lock = NSLock()

    /// 低音量提示音，2 秒节流；与视频播放共存（不改变音频会话类别）
    static func playCompletionSound() {
        guard soundEnabled else { return }
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastPlayed) > 2 else {
            lock.unlock()
            return
        }
        lastPlayed = now
        if player == nil { player = makePlayer() }
        let instance = player
        lock.unlock()

        instance?.currentTime = 0
        instance?.play()
    }

    private static func makePlayer() -> AVAudioPlayer? {
        let sampleRate = 44100.0
        let duration = 0.18
        let total = Int(sampleRate * duration)
        var pcm = [Int16]()
        pcm.reserveCapacity(total)
        for index in 0..<total {
            let t = Double(index) / sampleRate
            let frequency = t < 0.09 ? 880.0 : 1320.0
            let envelope = exp(-t * 14)
            let value = sin(2 * Double.pi * frequency * t) * envelope * 0.35
            pcm.append(Int16(max(-1, min(1, value)) * 16000))
        }

        var data = Data()
        let byteRate = UInt32(sampleRate) * 2
        let dataSize = UInt32(pcm.count * 2)
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: le32(36 + dataSize))
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(contentsOf: le32(16))
        data.append(contentsOf: le16(1))
        data.append(contentsOf: le16(1))
        data.append(contentsOf: le32(UInt32(sampleRate)))
        data.append(contentsOf: le32(byteRate))
        data.append(contentsOf: le16(2))
        data.append(contentsOf: le16(16))
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: le32(dataSize))
        for sample in pcm {
            let value = UInt16(bitPattern: sample)
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }

        let audio = try? AVAudioPlayer(data: data)
        audio?.volume = 0.5
        audio?.prepareToPlay()
        return audio
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    // MARK: - 本地通知

    static var authorizationDenied = false

    static func requestAuthorizationIfNeeded() {
        guard noticeEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                authorizationDenied = (settings.authorizationStatus == .denied)
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                authorizationDenied = !granted
                DiagnosticsLog.write("[通知] 权限申请 granted=\(granted)")
            }
        }
    }

    static func notifyCompleted(title: String, sizeText: String?) {
        post(title: "下载完成", body: sizeText.map { "\(title) · \($0)" } ?? title)
    }

    static func notifyFailed(title: String, reason: String) {
        post(title: "下载失败", body: "\(title)：\(reason)")
    }

    private static func post(title: String, body: String) {
        guard noticeEnabled else { return }
        // 前台不弹横幅，避免与 Toast 重复
        guard UIApplication.shared.applicationState != .active else {
            DiagnosticsLog.write("[通知] 前台跳过横幅 \(title)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DiagnosticsLog.write("[通知] 投递失败 \(error.localizedDescription)")
            }
        }
    }
}
