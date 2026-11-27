import Foundation
import AVFoundation
import SwiftUI

/// 字幕朗读：把当前显示的字幕用系统 TTS 读出来
@MainActor
final class SubtitleSpeaker: NSObject, ObservableObject {
    static let shared = SubtitleSpeaker()

    // 设置键
    static let enabledKey = "tts.subtitle.enabled"
    static let trackKey = "tts.subtitle.track"       // 0 主字幕 1 次字幕 2 两者
    static let queueKey = "tts.subtitle.queue"       // true 排队 false 打断
    static let duckKey = "tts.subtitle.duck"         // 朗读时压低视频音量
    static let duckLevelKey = "tts.subtitle.duckLevel"
    static let rateKey = "tts.subtitle.rate"
    static let voiceKey = "tts.subtitle.voice"

    @Published private(set) var isSpeaking = false

    /// 朗读状态变化（用于压低/恢复视频音量）
    var onSpeakingChanged: ((Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenText = ""

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? false
    }

    static var duckEnabled: Bool {
        (UserDefaults.standard.object(forKey: duckKey) as? Bool) ?? true
    }

    static var duckLevel: Double {
        let value = UserDefaults.standard.object(forKey: duckLevelKey) as? Double
        return value ?? 0.6
    }

    static var isQueueMode: Bool {
        (UserDefaults.standard.object(forKey: queueKey) as? Bool) ?? true
    }

    static var trackIndex: Int {
        (UserDefaults.standard.object(forKey: trackKey) as? Int) ?? 0
    }

    // MARK: - 对外接口

    /// 每 0.2 秒由播放器调用；内部做去重与状态判断
    func handle(text: String?) {
        guard Self.isEnabled else { return }
        let cleaned = Self.clean(text ?? "")
        guard !cleaned.isEmpty else { return }
        guard cleaned != lastSpokenText else { return }
        lastSpokenText = cleaned
        speak(cleaned)
    }

    /// 播放器暂停 / 结束 / 关闭时调用
    func stopAll() {
        lastSpokenText = ""
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// 拖动进度后允许同一句重新朗读
    func resetDedup() {
        lastSpokenText = ""
    }

    // MARK: - 内部

    private func speak(_ text: String) {
        if !Self.isQueueMode {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // 队列模式：堆积过多时丢弃最旧的（避免无限滞后）
        if Self.isQueueMode, synthesizer.isSpeaking {
            // AVSpeechSynthesizer 自带队列，无需额外处理
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Self.rate
        utterance.volume = 0.95
        utterance.voice = Self.voice(for: text)
        synthesizer.speak(utterance)
    }

    private static var rate: Float {
        let stored = UserDefaults.standard.object(forKey: rateKey) as? Double
        return Float(stored ?? 0.52)
    }

    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let chinese = text.range(of: "\\p{Han}", options: .regularExpression) != nil
        let language = chinese ? "zh-CN" : "en-US"
        if let identifier = UserDefaults.standard.string(forKey: voiceKey),
           let voice = AVSpeechSynthesisVoice(identifier: identifier),
           voice.language.hasPrefix(chinese ? "zh" : "en") {
            return voice
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    /// 去掉音效标注与多余空白
    static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "♪", with: "")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 200 {
            text = String(text.prefix(200))
        }
        return text
    }

    /// 可选音色（只计算一次并缓存，避免每次刷新重建列表导致选择页跳动）
    static let cachedVoices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("en") }
        .sorted { lhs, rhs in
            if lhs.language == rhs.language { return lhs.name < rhs.name }
            return lhs.language < rhs.language
        }

    static func displayName(for identifier: String) -> String {
        guard !identifier.isEmpty else { return "自动（跟随语言）" }
        return cachedVoices.first { $0.identifier == identifier }?.name ?? "已失效（自动）"
    }

    /// 试听某个音色
    func preview(voiceID: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let text = "这是一段试听，用来感受音色与语速。"
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Self.rate
        utterance.volume = 0.95
        if !voiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        synthesizer.speak(utterance)
    }
}

extension SubtitleSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            self.onSpeakingChanged?(true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !synthesizer.isSpeaking else { return }
            self.isSpeaking = false
            self.onSpeakingChanged?(false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !synthesizer.isSpeaking else { return }
            self.isSpeaking = false
            self.onSpeakingChanged?(false)
        }
    }
}
