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
    private var pauseTicks = 0
    private var pauseRecoveries = 0
    private var lastRecoveryTime = Date.distantPast
    private var healthTimer: Timer?
    private var tickCount = 0
    private var loadStartedAt: Date?
    private var loadReported = false
    @Published var errorNotice: String?
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
            let needsReload = player.currentItem == nil || player.currentItem?.status == .failed
            if needsReload {
                DiagnosticsLog.write("[播放] 同一条目重新加载（状态=\(player.currentItem?.status.rawValue ?? -1)）")
                recoveryAttempts = 0
                configureAudioSession()
                loadItem(startAt: player.currentTime().seconds)
                player.play()
                isPlaying = true
            } else {
                ensurePlaying()
            }
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
        startHealthTimer()
        Task { await reportAssetInfo() }
        DiagnosticsLog.write("[播放] 打开 \(video.title) 源=\(url.lastPathComponent)")
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
        loadStartedAt = Date()
        loadReported = false
        player.replaceCurrentItem(with: item)
        if seconds > 3 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func close(notify: Bool = true) {
        stopHealthTimer()
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

    /// 打开浏览器前切到混音模式：与 WebView 音频共存，避免被中断（不能 setActive(false)，那会直接暂停播放）
    func prepareForExternalAudio() {
        configureAudioSession(mixing: true)
    }

    /// 确保音频会话可用并继续播放（浏览器关闭、来电结束后调用）
    func ensurePlaying() {
        guard isActive, !userPaused else { return }

        var sessionError = "ok"
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback,
                                                            options: [.allowAirPlay, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            sessionError = error.localizedDescription
        }

        if player.currentItem?.status == .failed {
            DiagnosticsLog.write("[播放] 会话=\(sessionError) item 已失败，强制重建")
            recoveryAttempts = 0
            recoverIfNeeded(force: true)
            return
        }

        if player.rate == 0 { player.play() }
        isPlaying = player.rate > 0
        DiagnosticsLog.write("[播放] 恢复尝试 会话=\(sessionError) rate=\(String(format: "%.1f", player.rate)) status=\(player.currentItem?.status.rawValue ?? -1)")
    }

    // MARK: - 内部

    private func configureAudioSession(mixing: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = mixing
            ? [.mixWithOthers, .allowAirPlay, .allowBluetoothA2DP]
            : [.allowAirPlay, .allowBluetoothA2DP]
        try? session.setCategory(.playback, mode: .moviePlayback, options: options)
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
        }
    }

    /// 独立 0.5s 监督：不依赖播放时间轴推进（加载卡死时 periodic observer 不会回调）
    private func startHealthTimer() {
        stopHealthTimer()
        tickCount = 0
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
    }

    private func stopHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func detachObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    /// 卡顿/失败/意外暂停检测：本地服务被抢占、网络中断、浏览器抢音频会话时自愈
    private func checkHealth() {
        guard isActive, !userPaused else {
            waitingTicks = 0
            pauseTicks = 0
            return
        }
        tickCount += 1
        let statusValue = player.currentItem?.status.rawValue ?? -1
        let abnormal = player.currentItem?.status == .failed || player.rate == 0
        if abnormal || tickCount % 20 == 0 {
            DiagnosticsLog.write("[播放] 监督 status=\(statusValue) rate=\(String(format: "%.1f", player.rate)) ctl=\(player.timeControlStatus.rawValue) tick=\(tickCount)")
        }
        // 加载超时：item 长时间停留在 .unknown，界面会一直黑屏且无任何日志
        if let item = player.currentItem, item.status == .unknown,
           let started = loadStartedAt, Date().timeIntervalSince(started) > 5, !loadReported {
            loadReported = true
            Task { await self.reportAssetInfo() }
            if recoveryAttempts < 1 {
                recoveryAttempts += 1
                DiagnosticsLog.write("[播放] 加载超时，重建播放项")
                loadItem(startAt: lastSaved)
                player.play()
            } else {
                errorNotice = "该文件无法被系统解析，建议重新转换"
                DiagnosticsLog.write("[播放] 加载超时且重建无效，判定文件异常")
            }
            return
        }

        let failed = player.currentItem?.status == .failed
        if failed, let error = player.currentItem?.error as NSError? {
            DiagnosticsLog.write("[播放] item 失败 \(error.domain) \(error.code) \(error.localizedDescription)")
        }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let silentlyPaused = player.rate == 0
            && player.timeControlStatus == .paused
            && player.currentItem?.status == .readyToPlay

        if failed || waiting {
            waitingTicks += 1
            pauseTicks = 0
            if failed || waitingTicks >= 8 {   // 约 4 秒无进展
                recoverIfNeeded(force: failed)
            }
        } else if silentlyPaused {
            // 典型场景：关闭浏览器后 WKWebView 让音频会话失活，播放器被静默暂停
            pauseTicks += 1
            waitingTicks = 0
            if pauseTicks >= 4 {               // 约 2 秒
                pauseTicks = 0
                if Date().timeIntervalSince(lastRecoveryTime) > 2, pauseRecoveries < 6 {
                    lastRecoveryTime = Date()
                    pauseRecoveries += 1
                    DiagnosticsLog.write("[播放] 检测到意外暂停，自动恢复（第 \(pauseRecoveries) 次）")
                    ensurePlaying()
                }
            }
        } else {
            waitingTicks = 0
            pauseTicks = 0
            if player.rate > 0 {
                recoveryAttempts = 0
                pauseRecoveries = 0
            }
        }
    }

    private func reportAssetInfo() async {
        guard let url = sourceURL else { return }
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.load(.tracks)) ?? []
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        var detail = ""
        if let video = tracks.first(where: { $0.mediaType == .video }),
           let natural = try? await video.load(.naturalSize) {
            detail = "尺寸=\(Int(natural.width))x\(Int(natural.height))"
        }
        DiagnosticsLog.write("[播放] 资产自检 \(url.lastPathComponent) 轨道=\(tracks.count) 类型=\(tracks.map { $0.mediaType.rawValue }.joined(separator: ",")) 时长=\(Int(duration))s \(detail)")
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
