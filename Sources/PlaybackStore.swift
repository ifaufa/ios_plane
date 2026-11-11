import SwiftUI
import AVKit
import UIKit
import Combine

/// 共享播放器：悬浮窗与全屏共用同一 AVPlayer；自带会话隔离与自愈
@MainActor
final class PlaybackStore: ObservableObject {
    static let shared = PlaybackStore()

    @Published private(set) var videoID: UUID?
    @Published private(set) var title: String = ""
    @Published var isFullscreen = false
    @Published var isPlaying = false

    let player = AVPlayer()

    var onProgress: ((UUID, Double) -> Void)?
    var onClose: (() -> Void)?

    private var timeObserver: Any?
    private var lastSaved: Double = 0
    private var session: LocalHLS.Session?
    private var sourceURL: URL?
    private var isHLS = false
    private var userPaused = false
    private var waitingTicks = 0
    private var recoveryAttempts = 0
    private var interruptionObserver: NSObjectProtocol?

    var isActive: Bool { videoID != nil }

    init() {
        configureAudioSession()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                Task { @MainActor in self.ensurePlaying() }
            }
        }
    }

    // MARK: - 打开 / 关闭

    func open(video: VideoItem, url: URL) {
        if videoID == video.id {
            ensurePlaying()
            return
        }
        close(notify: false)

        videoID = video.id
        title = video.title
        sourceURL = url
        isHLS = url.pathExtension.lowercased() == "m3u8"
        lastSaved = video.lastPosition ?? 0
        userPaused = false
        recoveryAttempts = 0
        waitingTicks = 0

        configureAudioSession()
        let start = video.lastPosition ?? 0
        loadItem(startAt: start)
        player.play()
        isPlaying = true
        attachObserver()
    }

    /// 重建播放项（首次打开或自愈时使用）
    private func loadItem(startAt seconds: Double) {
        guard let sourceURL else { return }
        session?.stop()
        session = nil

        let item: AVPlayerItem
        if isHLS {
            if let opened = try? LocalHLS.open(playlistURL: sourceURL) {
                session = opened
                item = AVPlayerItem(url: opened.url)
            } else {
                item = AVPlayerItem(url: sourceURL)
            }
        } else {
            item = AVPlayerItem(url: sourceURL)
        }
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        if seconds > 3 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func close(notify: Bool = true) {
        detachObserver()
        let seconds = player.currentTime().seconds
        if seconds.isFinite, let id = videoID, abs(seconds - lastSaved) >= 1 {
            onProgress?(id, seconds)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        session?.stop()
        session = nil
        sourceURL = nil

        videoID = nil
        title = ""
        isPlaying = false
        isFullscreen = false
        userPaused = false
        if notify { onClose?() }
    }

    // MARK: - 控制

    func togglePlay() {
        if player.rate > 0 {
            userPaused = true
            player.pause()
            isPlaying = false
        } else {
            userPaused = false
            recoverIfNeeded(force: false)
            player.play()
            isPlaying = true
        }
    }

    func enterFullscreen() { isFullscreen = true }

    func exitFullscreen() {
        isFullscreen = false
        ensurePlaying()
    }

    func reportProgress(_ seconds: Double) {
        guard let id = videoID else { return }
        onProgress?(id, seconds)
    }

    /// 确保音频会话可用并继续播放（浏览器关闭、来电结束后调用）
    func ensurePlaying() {
        configureAudioSession()
        guard isActive, !userPaused else { return }
        if player.currentItem?.status == .failed {
            recoverIfNeeded(force: true)
            return
        }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        }
    }

    // MARK: - 内部

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    private func attachObserver() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite, abs(seconds - self.lastSaved) >= 5 {
                self.lastSaved = seconds
                if let id = self.videoID { self.onProgress?(id, seconds) }
            }
            self.isPlaying = self.player.rate > 0
            self.checkHealth()
        }
    }

    private func detachObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    /// 卡顿/失败检测：本地服务被抢占或网络中断时自动重建播放项
    private func checkHealth() {
        guard isActive, !userPaused else {
            waitingTicks = 0
            return
        }
        let failed = player.currentItem?.status == .failed
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if failed || waiting {
            waitingTicks += 1
            if failed || waitingTicks >= 8 {   // 约 4 秒无进展
                recoverIfNeeded(force: failed)
            }
        } else {
            waitingTicks = 0
            if player.rate > 0 { recoveryAttempts = 0 }
        }
    }

    private func recoverIfNeeded(force: Bool) {
        guard isActive, !userPaused else { return }
        guard recoveryAttempts < 3 else { return }
        let failed = player.currentItem?.status == .failed
        guard force || failed else { return }
        recoveryAttempts += 1
        waitingTicks = 0

        let seconds = player.currentTime().seconds
        let position = seconds.isFinite && seconds > 0 ? seconds : lastSaved
        DiagnosticsLog.write("[播放] 自愈第 \(recoveryAttempts) 次，位置=\(Int(position))s 失败=\(failed)")
        loadItem(startAt: position)
        player.play()
        isPlaying = true
    }
}
