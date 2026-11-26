import SwiftUI
import AVKit
import UIKit
import Combine

/// 共享播放器：悬浮窗与全屏共用同一 AVPlayer；自带会话隔离与自愈
/// 「播放意图」expectsPlaying 是唯一真相：只有用户希望播放时才自动恢复，
/// 用户主动暂停永远不会被自愈逻辑打断
@MainActor
final class PlaybackStore: ObservableObject {
    static let shared = PlaybackStore()

    @Published private(set) var videoID: UUID?
    @Published private(set) var title: String = ""
    @Published var isFullscreen = false
    @Published var isPlaying = false
    @Published var expectsPlaying = false
    /// 常驻倍速（按视频记忆）
    @Published var playbackRate: Float = 1.0
    /// 画面比例（全局默认 + 按视频记忆）
    @Published private(set) var gravityMode: VideoGravityMode = .fit

    enum VideoGravityMode: Int, CaseIterable {
        case fit, fill, stretch

        var title: String {
            switch self {
            case .fit: return "适应"
            case .fill: return "填充"
            case .stretch: return "拉伸"
            }
        }

        var detail: String {
            switch self {
            case .fit: return "完整画面 + 黑边"
            case .fill: return "铺满屏幕，裁切边缘"
            case .stretch: return "铺满屏幕，画面变形"
            }
        }

        var icon: String {
            switch self {
            case .fit: return "rectangle.arrowtriangle.2.inward"
            case .fill: return "rectangle.arrowtriangle.2.outward"
            case .stretch: return "arrow.up.left.and.arrow.down.right"
            }
        }
    }

    static let gravityKey = "playback.gravity"

    func cycleGravity() {
        let all = VideoGravityMode.allCases
        let current = all.firstIndex(of: gravityMode) ?? 0
        setGravity(all[(current + 1) % all.count])
    }

    func setGravity(_ mode: VideoGravityMode) {
        gravityMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.gravityKey)
        if let id = videoID {
            UserDefaults.standard.set(mode.rawValue, forKey: "playback.gravity.\(id.uuidString)")
        }
        DiagnosticsLog.write("[播放] 画面比例 " + mode.title)
    }

    private func restoreGravity(for id: UUID) {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: "playback.gravity.\(id.uuidString)") as? Int,
           let mode = VideoGravityMode(rawValue: raw) {
            gravityMode = mode
            return
        }
        let globalRaw = defaults.object(forKey: Self.gravityKey) as? Int ?? 0
        gravityMode = VideoGravityMode(rawValue: globalRaw) ?? .fit
    }
    /// 已播放到结尾且没有下一集（用于显示"已播放完"、并阻止自愈逻辑反复恢复）
    @Published private(set) var isFinished = false
    /// 是否正在 AirPlay 投屏
    @Published var isAirPlaying = false
    @Published var errorNotice: String?

    let player = AVPlayer()

    var onProgress: ((UUID, Double) -> Void)?
    var onClose: (() -> Void)?

    // MARK: - 连播

    /// 由外部注入：取同系列下一集 / 打开指定条目
    var nextEpisodeProvider: ((VideoItem) -> VideoItem?)?
    var openEpisodeHandler: ((VideoItem) -> Void)?

    @Published private(set) var currentVideo: VideoItem?
    @Published private(set) var countdownNext: VideoItem?
    @Published private(set) var countdownRemaining = 0
    @Published private(set) var seriesTiming: PlaybackPrefs.SeriesTiming?
    let countdownTotal = 7

    // MARK: - A-B 循环

    @Published private(set) var loopStart: Double?
    @Published private(set) var loopEnd: Double?
    @Published private(set) var isLooping = false
    @Published var loopNotice: String?

    private var loopObserver: Any?
    private var isLoopSeeking = false

    private var endObserver: NSObjectProtocol?
    private var countdownTimer: Timer?
    private var pendingAutoNext = false
    /// 本集是否已触发过片尾倒计时（防重复）
    private var outroTriggered = false
    /// 本集不再跳片尾（取消 / 本集不跳过 / 从头播放）
    private var outroSuppressed = false
    /// 拖动/暂停后的冷却截止时间
    private var outroCooldownUntil = Date.distantPast

    private var timeObserver: Any?
    private var healthTimer: Timer?
    private var tickCount = 0
    private var lastSaved: Double = 0
    private var session: LocalHLS.Session?
    private var sourceURL: URL?
    private var isHLS = false
    private var waitingTicks = 0
    private var pauseTicks = 0
    private var pauseRecoveries = 0
    private var lastRecoveryTime = Date.distantPast
    private var recoveryAttempts = 0
    /// 等待（waitingToPlay）自愈次数与上次时间
    private var waitingRecoveries = 0
    private var lastWaitingRecovery = Date.distantPast
    /// 上次详细状态日志时间 / 上次记录的 ctl
    private var lastStatusLogAt = Date.distantPast
    private var lastLoggedCtl = -1
    private var loadStartedAt: Date?
    private var loadReported = false
    private var didMuteProbe = false
    private var didFallbackToZero = false
    private var intendedStart: Double = 0
    private var scrubbing = false
    private var expectsPlayingBeforeScrub = false
    private var interruptionObserver: NSObjectProtocol?

    var isActive: Bool { videoID != nil }

    private var externalObserver: NSKeyValueObservation?

    init() {
        configureAudioSession()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        externalObserver = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, change in
            let active = change.newValue ?? false
            Task { @MainActor in
                self?.isAirPlaying = active
                DiagnosticsLog.write("[播放] AirPlay 状态 \(active ? "已连接" : "已断开")")
            }
        }
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

    func open(video: VideoItem, url: URL, fromBeginning: Bool = false) {
        if videoID == video.id {
            if fromBeginning {
                // 从头播放：同一条目也强制重载到 0
                recoveryAttempts = 0
                configureAudioSession()
                resetEpisodeSkipState(fromBeginning: true)
                loadItem(startAt: 0)
                play()
                DiagnosticsLog.write("[播放] 从头播放：本集不跳片头/片尾")
                return
            }
            let needsReload = player.currentItem == nil || player.currentItem?.status == .failed
            if needsReload {
                DiagnosticsLog.write("[播放] 同一条目重新加载（状态=\(player.currentItem?.status.rawValue ?? -1)）")
                recoveryAttempts = 0
                configureAudioSession()
                loadItem(startAt: player.currentTime().seconds)
                play()
            } else {
                ensurePlaying()
            }
            return
        }
        // 连播切集时保持全屏，不要退回悬浮窗
        close(notify: false, keepFullscreen: true)

        videoID = video.id
        title = video.title
        currentVideo = video
        seriesTiming = PlaybackPrefs.shared.timing(forTitle: video.title)
        restorePlaybackRate(for: video.id)
        restoreGravity(for: video.id)
        sourceURL = url
        isHLS = url.pathExtension.lowercased() == "m3u8"
        lastSaved = video.lastPosition ?? 0
        recoveryAttempts = 0
        errorNotice = nil
        waitingTicks = 0
        pauseTicks = 0
        pauseRecoveries = 0
        isFinished = false
        cancelCountdown()
        resetEpisodeSkipState(fromBeginning: fromBeginning)
        // 循环区间不跨集
        stopLooping()
        loopStart = nil
        loopEnd = nil

        configureAudioSession()

        // 起始定位：续播优先；否则按「片头时长」跳过片头（手动打开与连播一致）
        let resumePosition = fromBeginning ? 0 : (video.lastPosition ?? 0)
        let introLength = seriesTiming?.introLength ?? 0
        var startAt = resumePosition > 3 ? resumePosition : 0
        var introSkipped = false
        if fromBeginning {
            startAt = 0
        } else if PlaybackPrefs.shared.skipIntro,
                  introLength > 3,
                  startAt < introLength - 0.5 {
            startAt = introLength
            introSkipped = true
        }
        if introSkipped {
            DiagnosticsLog.write("[播放] 跳过片头 " + Self.timeText(introLength) + "（来源=" + (pendingAutoNext ? "连播" : "手动") + "）")
        }
        pendingAutoNext = false
        if fromBeginning {
            DiagnosticsLog.write("[播放] 从头播放：本集不跳片头/片尾")
        }
        intendedStart = startAt
        didMuteProbe = false
        didFallbackToZero = false

        let syncInfo = isHLS ? "HLS" : Self.syncSampleInfo(url)
        if !isHLS {
            DiagnosticsLog.write("[播放] 同步样本表探测 \(url.lastPathComponent)：\(syncInfo)")
        }

        loadItem(startAt: startAt)
        play()
        attachObserver()
        startHealthTimer()
        Task { await reportAssetInfo() }
        DiagnosticsLog.write("[播放] 打开 \(video.title) 源=\(url.lastPathComponent) 续播=\(Int(startAt))s")
    }

    private func loadItem(startAt seconds: Double) {
        guard let sourceURL else { return }
        session?.stop()
        session = nil

        let item: AVPlayerItem
        if isHLS {
            if let opened = try? LocalHLS.open(playlistURL: sourceURL) {
                session = opened
                // 优先用局域网地址：本机同样可访问，且 AirPlay 时电视能拉到流
                let preferred = opened.lanURL ?? opened.url
                item = AVPlayerItem(url: preferred)
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
                        toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
    }

    func close(notify: Bool = true, keepFullscreen: Bool = false) {
        cancelCountdown()
        removeLoopObserver()
        isLooping = false
        loopStart = nil
        loopEnd = nil
        loopNotice = nil
        currentVideo = nil
        seriesTiming = nil
        // 单例状态收口：关闭播放器时字幕一并清空，避免串到下一个视频
        SubtitleCenter.shared.clear()
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
        if !keepFullscreen { isFullscreen = false }
        expectsPlaying = false
        if notify { onClose?() }
    }

    // MARK: - 播放控制（用户意图入口，全屏与悬浮窗共用）

    func play() {
        isFinished = false
        expectsPlaying = true
        if player.rate == 0 { player.playImmediately(atRate: max(0.5, playbackRate)) }
        isPlaying = player.rate > 0
    }

    /// 设置常驻倍速（0.5–2.0），按视频记忆
    func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.5, min(2.0, rate))
        if let id = videoID {
            UserDefaults.standard.set(Double(playbackRate), forKey: "playbackRate.\(id.uuidString)")
        }
        if player.rate > 0 {
            player.playImmediately(atRate: playbackRate)
        }
        DiagnosticsLog.write("[播放] 倍速 " + String(format: "%.2f", playbackRate) + "×")
    }

    /// 打开视频时恢复该视频上次的倍速
    private func restorePlaybackRate(for id: UUID) {
        let saved = UserDefaults.standard.object(forKey: "playbackRate.\(id.uuidString)") as? Double
        let value = Float(saved ?? 1.0)
        playbackRate = (value >= 0.5 && value <= 2.0) ? value : 1.0
    }

    /// 播放到结尾且没有下一集：明确进入"已播放完"状态，
    /// 关闭 expectsPlaying 以免"意外暂停自愈"反复恢复一个已经结束的视频
    private func finishPlayback() {
        isFinished = true
        expectsPlaying = false
        pauseTicks = 0
        waitingTicks = 0
        player.pause()
        isPlaying = false
        DiagnosticsLog.write("[播放] 已播放完，进入结束状态（不再自动恢复）")
    }

    func pause() {
        expectsPlaying = false
        pauseTicks = 0
        player.pause()
        isPlaying = false
        dismissCountdownTemporarily("暂停")
    }

    func togglePlay() {
        if expectsPlaying || player.rate > 0 { pause() } else { play() }
    }

    /// 拖动进度条：先暂停并记住原意图（幂等，避免重复进入覆盖原意图）
    func beginScrub() {
        guard !scrubbing else { return }
        expectsPlayingBeforeScrub = expectsPlaying
        DiagnosticsLog.write("[播放] 开始拖动 原意图=\(expectsPlaying)")
        dismissCountdownTemporarily("拖动")
        expectPauseTemporarily()
    }

    /// 拖动结束：按原意图决定是否继续
    func endScrub(resume: Bool? = nil) {
        // 若 beginScrub 未被调用（极端情况），回退到当前意图，避免"松手后一直暂停"
        let wasScrubbing = scrubbing
        let shouldPlay = resume ?? (wasScrubbing ? expectsPlayingBeforeScrub : expectsPlaying)
        scrubbing = false
        DiagnosticsLog.write("[播放] 结束拖动 续播=\(shouldPlay)")
        if shouldPlay {
            play()
        } else {
            pause()
        }
    }

    /// 手势快进/后退预览期间的临时暂停（不改变用户意图）
    func pauseForPreview() {
        player.pause()
        isPlaying = false
    }

    /// 预览结束：仅在用户原本希望播放时恢复
    func resumeAfterPreview() {
        guard expectsPlaying else { return }
        player.playImmediately(atRate: max(0.5, playbackRate))
        isPlaying = player.rate > 0
    }

    private func expectPauseTemporarily() {
        scrubbing = true
        player.pause()
        isPlaying = false
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

    /// 打开浏览器前切到混音模式：与 WebView 音频共存，避免被中断
    func prepareForExternalAudio() {
        configureAudioSession(mixing: true)
    }

    /// 仅在"用户希望播放"时恢复；用户主动暂停时调用无副作用
    func ensurePlaying() {
        guard isActive, expectsPlaying else { return }

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

        if player.rate == 0 { player.playImmediately(atRate: max(0.5, playbackRate)) }
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
        if endObserver == nil {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    guard let ended = note.object as? AVPlayerItem,
                          ended === self.player.currentItem else { return }
                    guard !self.isLooping else { return }
                    self.beginCountdown(reason: "播放结束", ignoreOutroSuppressed: true)
                }
            }
        }
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
            if seconds.isFinite { self.checkOutro(at: seconds) }
        }
    }

    private func detachObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    // MARK: - 连播 / 片头片尾

    /// 每集重置跳过状态（打开新一集时调用）
    private func resetEpisodeSkipState(fromBeginning: Bool) {
        outroTriggered = false
        outroSuppressed = fromBeginning
        outroCooldownUntil = .distantPast
    }

    /// 片尾检测：按「剩余时长 ≤ 片尾时长」判定（片尾贴着结尾，能适配正片长短不一）
    private func checkOutro(at seconds: Double) {
        // 循环播放期间暂停片尾跳过与连播，结束循环后自动恢复
        guard !isLooping else { return }
        guard PlaybackPrefs.shared.skipOutro, !outroSuppressed, !outroTriggered else { return }
        guard Date() >= outroCooldownUntil else { return }
        guard countdownNext == nil, expectsPlaying, !scrubbing else { return }
        guard let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 30 else { return }
        guard let timing = seriesTiming else { return }
        let introLength = timing.introLength
        let outroLength = timing.outroLength
        guard outroLength > 0 else { return }

        // 保护 1：配置吃掉了全部时长 → 不跳
        guard introLength + outroLength < duration - 5 else {
            return
        }
        // 保护 2：本集比参考总时长短出一个片尾及以上 → 判定「本集没有片尾」
        if PlaybackPrefs.shared.protectNoOutro, timing.refDuration > 0,
           timing.refDuration - duration >= outroLength {
            if !outroTriggered {
                outroSuppressed = true
                let short = Self.timeText(timing.refDuration - duration)
                DiagnosticsLog.write("[播放] 本集比参考短 " + short + "（≥ 片尾 " + Self.timeText(outroLength) + "），判定无片尾，不自动跳")
            }
            return
        }
        // 保护 3：还没走出片头就不判定
        guard seconds > introLength + 1 else { return }

        let remaining = duration - seconds
        guard remaining <= outroLength else { return }
        beginCountdown(reason: "剩余 " + Self.timeText(max(0, remaining)) + " ≤ 片尾 " + Self.timeText(outroLength))
    }

    static func timeText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// 进入倒计时（可取消）
    /// - Parameter ignoreOutroSuppressed: 播完自然结束时仍要切下一集，不受"取消跳片尾"影响
    private func beginCountdown(reason: String, ignoreOutroSuppressed: Bool = false) {
        guard countdownNext == nil else { return }
        guard ignoreOutroSuppressed || !outroSuppressed else { return }
        guard PlaybackPrefs.shared.autoNext, let current = currentVideo else { return }
        guard let next = nextEpisodeProvider?(current) else {
            DiagnosticsLog.write("[播放] 无下一集（\(reason)）→ 进入结束状态")
            finishPlayback()
            return
        }
        outroTriggered = true
        countdownNext = next
        countdownRemaining = countdownTotal
        DiagnosticsLog.write("[播放] \(reason) → \(countdownTotal) 秒后播放 \(next.title)")
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.countdownRemaining -= 1
                if self.countdownRemaining <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    self.performNextEpisode()
                }
            }
        }
    }

    private func performNextEpisode() {
        guard let next = countdownNext else { return }
        countdownNext = nil
        countdownRemaining = 0
        pendingAutoNext = true
        DiagnosticsLog.write("[播放] 连播 → \(next.title)")
        openEpisodeHandler?(next)
    }

    /// 用户点「取消」：本集不再跳片尾（仍然会在播完后自动切下一集）
    func cancelCountdown() {
        guard countdownNext != nil || countdownTimer != nil else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownNext = nil
        countdownRemaining = 0
        outroSuppressed = true
        DiagnosticsLog.write("[播放] 已取消跳片尾（仅本集），播完后仍会自动切下一集")
    }

    /// 拖动 / 暂停导致的关闭：只关本次 + 10 秒冷却，稍后仍可再次触发
    private func dismissCountdownTemporarily(_ reason: String) {
        guard countdownNext != nil || countdownTimer != nil else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownNext = nil
        countdownRemaining = 0
        outroTriggered = false
        outroCooldownUntil = Date().addingTimeInterval(10)
        DiagnosticsLog.write("[播放] " + reason + " → 关闭倒计时，10 秒冷却")
    }

    /// 本集不跳过（一次性，只影响本集）
    func skipForThisEpisode() {
        outroSuppressed = true
        outroTriggered = true
        if countdownNext != nil || countdownTimer != nil {
            countdownTimer?.invalidate()
            countdownTimer = nil
            countdownNext = nil
            countdownRemaining = 0
        }
        DiagnosticsLog.write("[播放] 本集不跳过片尾（播完仍会自动切下一集）")
    }

    /// 标记片头：记录「片头时长」= 当前播放位置
    func markIntroHere() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0, !title.isEmpty else { return }
        PlaybackPrefs.shared.setIntroLength(seconds, forTitle: title)
        seriesTiming = PlaybackPrefs.shared.timing(forTitle: title)
        DiagnosticsLog.write("[播放] 标记片头时长 " + Self.timeText(seconds))
    }

    /// 标记片尾：记录「片尾时长」= 本集总时长 − 当前播放位置，并记录参考总时长
    func markOutroHere() {
        let duration = player.currentItem?.duration.seconds ?? 0
        let seconds = player.currentTime().seconds
        guard duration.isFinite, duration > 0, seconds.isFinite, !title.isEmpty else { return }
        let outroLength = max(0, duration - seconds)
        guard outroLength >= 3 else {
            DiagnosticsLog.write("[播放] 片尾过短（<3s），未记录")
            return
        }
        PlaybackPrefs.shared.setOutroLength(outroLength, forTitle: title, refDuration: duration)
        seriesTiming = PlaybackPrefs.shared.timing(forTitle: title)
        DiagnosticsLog.write("[播放] 标记片尾时长 " + Self.timeText(outroLength) + "（参考总长 " + Self.timeText(duration) + "）")
    }

    // MARK: - A-B 循环

    private var currentDuration: Double {
        let value = player.currentItem?.duration.seconds ?? 0
        return value.isFinite && value > 0 ? value : 0
    }

    private func notifyLoop(_ text: String) {
        loopNotice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.loopNotice == text { self.loopNotice = nil }
        }
    }

    /// 打点：第 1 次设 A；第 2 次设 B；A/B 都设好后再次点击 = 重新设 A（清空 B）
    func markLoopPoint() {
        let position = player.currentTime().seconds
        guard position.isFinite, position >= 0 else { return }
        let total = currentDuration

        if loopStart == nil || loopEnd != nil {
            if total > 1, total - position < 1 {
                notifyLoop("太靠结尾，请往前一点再设 A")
                return
            }
            stopLooping()
            loopStart = position
            loopEnd = nil
            DiagnosticsLog.write("[播放] 循环起点 A=" + Self.timeText(position))
        } else if let start = loopStart {
            guard position - start >= 1 else {
                notifyLoop("区间不足 1 秒，请往后一点再设 B")
                return
            }
            loopEnd = position
            DiagnosticsLog.write("[播放] 循环终点 B=" + Self.timeText(position)
                                 + " 区间=" + String(format: "%.1f", position - start) + "s")
        }
    }

    /// 清空 A/B 并结束循环
    func clearLoopPoints() {
        stopLooping()
        loopStart = nil
        loopEnd = nil
        notifyLoop("已清空循环区间")
        DiagnosticsLog.write("[播放] 已清空循环区间")
    }

    /// 手势设点模式（上半屏设 A / 下半屏设 B）
    @Published var isMarkingPoints = false
    /// 打开播放器后是否自动弹出剪辑面板（视频库「分片剪辑」入口用）
    var pendingOpenEditor = false

    /// 直接设置起点（时间框提交时用）
    func updateLoopStart(_ seconds: Double) {
        let total = currentDuration
        var value = max(0, seconds)
        if total > 1 { value = min(value, total - 1) }
        if let end = loopEnd { value = min(value, max(0, end - 1)) }
        loopStart = value
        rebuildLoopObserverIfNeeded()
    }

    /// 直接设置终点
    func updateLoopEnd(_ seconds: Double) {
        guard let start = loopStart else { return }
        let total = currentDuration
        var value = max(0, seconds)
        if total > 0 { value = min(value, total - 0.05) }
        value = max(value, start + 1)
        loopEnd = value
        rebuildLoopObserverIfNeeded()
    }

    /// 手势：设 A（当前播放位置）
    func markA() {
        setLoopStartToCurrent()
    }

    /// 手势：设 B（当前播放位置）
    func markB() {
        setLoopEndToCurrent()
    }

    /// 设点模式下的 ±秒 微调（左右边缘单击）
    func stepSeek(_ delta: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let total = currentDuration
        var target = current + delta
        if total > 0 { target = min(target, total - 0.05) }
        target = max(0, target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
        notifyLoop((delta > 0 ? "＋" : "－") + String(format: "%.0f", abs(delta))
                   + " 秒 → " + Self.timeText(target))
    }

    func setLoopStartToCurrent() {
        let position = player.currentTime().seconds
        guard position.isFinite, position >= 0 else { return }
        let total = currentDuration
        if total > 1, total - position < 1 {
            notifyLoop("太靠结尾，无法设为起点")
            return
        }
        var value = position
        if let end = loopEnd { value = min(value, end - 1) }
        loopStart = max(0, value)
        rebuildLoopObserverIfNeeded()
        notifyLoop("已设 A " + Self.timeText(loopStart ?? 0))
    }

    func setLoopEndToCurrent() {
        guard let start = loopStart else {
            notifyLoop("请先设置起点 A")
            return
        }
        let position = player.currentTime().seconds
        guard position.isFinite, position - start >= 1 else {
            notifyLoop("终点需比起点晚 1 秒以上")
            return
        }
        var value = position
        let total = currentDuration
        if total > 0 { value = min(value, total - 0.05) }
        loopEnd = value
        rebuildLoopObserverIfNeeded()
        notifyLoop("已设 B " + Self.timeText(value))
    }

    func adjustLoopStart(by delta: Double) {
        guard let current = loopStart else { return }
        var value = max(0, current + delta)
        if let end = loopEnd { value = min(value, end - 1) }
        let total = currentDuration
        if total > 1 { value = min(value, total - 1) }
        loopStart = value
        rebuildLoopObserverIfNeeded()
    }

    func adjustLoopEnd(by delta: Double) {
        guard let current = loopEnd else { return }
        var value = current + delta
        if let start = loopStart { value = max(value, start + 1) }
        let total = currentDuration
        if total > 0 { value = min(value, total - 0.05) }
        loopEnd = max(0, value)
        rebuildLoopObserverIfNeeded()
    }

    /// 开启 / 结束循环
    func toggleLooping() {
        guard let start = loopStart, let end = loopEnd, end - start >= 1 else {
            notifyLoop("请先设置起点 A 与终点 B")
            return
        }
        if isLooping {
            stopLooping()
            return
        }
        isLooping = true
        DiagnosticsLog.write("[播放] 开始循环 " + Self.timeText(start) + " ↔ " + Self.timeText(end)
                             + "（循环期间暂停片尾跳过与连播）")
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        attachLoopObserver()
    }

    func stopLooping() {
        guard isLooping || loopObserver != nil else { return }
        isLooping = false
        removeLoopObserver()
        DiagnosticsLog.write("[播放] 循环已结束")
    }

    /// 用户拖动到循环区间之外 → 结束循环（保留 A/B）
    func handleSeek(to seconds: Double) {
        guard isLooping, let start = loopStart, let end = loopEnd else { return }
        guard seconds.isFinite else { return }
        if seconds < start - 0.5 || seconds > end + 0.5 {
            stopLooping()
            notifyLoop("已离开循环区间，循环结束")
        }
    }

    private func rebuildLoopObserverIfNeeded() {
        guard isLooping else { return }
        attachLoopObserver()
    }

    private func attachLoopObserver() {
        removeLoopObserver()
        guard isLooping, let end = loopEnd else { return }
        let time = CMTime(seconds: end, preferredTimescale: 600)
        loopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isLooping, !self.isLoopSeeking, let start = self.loopStart else { return }
                self.isLoopSeeking = true
                self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in
                        self.isLoopSeeking = false
                        if self.expectsPlaying { self.player.playImmediately(atRate: max(0.5, self.playbackRate)) }
                    }
                }
            }
        }
    }

    private func removeLoopObserver() {
        if let observer = loopObserver {
            player.removeTimeObserver(observer)
            loopObserver = nil
        }
        isLoopSeeking = false
    }



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

    private func checkHealth() {
        // 用户主动暂停 / 拖动中：只统计不干预
        guard isActive, expectsPlaying, !scrubbing else {
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

        // D1：状态变化或每 30 秒记录一次详细状态（用于定位卡滞原因）
        if player.timeControlStatus.rawValue != lastLoggedCtl || tickCount % 60 == 0 {
            logDetailedStatus("状态")
        }

        if let item = player.currentItem, item.status == .unknown,
           let started = loadStartedAt, Date().timeIntervalSince(started) > 5, !loadReported {
            loadReported = true
            Task { await self.reportAssetInfo() }
            if recoveryAttempts < 1 {
                recoveryAttempts += 1
                DiagnosticsLog.write("[播放] 加载超时，重建播放项")
                loadItem(startAt: lastSaved)
                play()
            } else {
                errorNotice = "该文件无法被系统解析，建议重新转换"
                DiagnosticsLog.write("[播放] 加载超时且重建无效，判定文件异常")
            }
            return
        }

        let failed = player.currentItem?.status == .failed
        if failed, let error = player.currentItem?.error as NSError? {
            DiagnosticsLog.write("[播放] item 失败 \(error.domain) \(error.code) \(error.localizedDescription)")
            // 本地服务鉴权/权限类错误：重启服务也修不好，明确提示并停止无谓重试
            if error.domain == NSURLErrorDomain, error.code == -1102 || error.code == -1011 || error.code == -1008 {
                errorNotice = "本地播放服务鉴权失败，请重新点击该视频播放"
                waitingTicks = 0
                pauseTicks = 0
                return
            }
        }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let silentlyPaused = player.rate == 0
            && player.timeControlStatus == .paused
            && player.currentItem?.status == .readyToPlay

        if failed || waiting {
            waitingTicks += 1
            pauseTicks = 0
            if failed {
                recoverIfNeeded(force: true)
            } else if waitingTicks >= 8 {
                recoverFromWaiting()
            }
        } else if silentlyPaused {
            pauseTicks += 1
            waitingTicks = 0
            if pauseTicks >= 4 {
                pauseTicks = 0
                if Date().timeIntervalSince(lastRecoveryTime) > 2, pauseRecoveries < 6 {
                    lastRecoveryTime = Date()
                    pauseRecoveries += 1
                    let current = player.currentTime().seconds
                    let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
                    let keepUp = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
                    DiagnosticsLog.write("[播放] 检测到意外暂停（第 \(pauseRecoveries) 次）位置=\(Int(current.isFinite ? current : -1))s 期望=\(Int(intendedStart))s 原因=\(reason) 可播=\(keepUp)")

                    // 续播失败：seek 卡在非 IDR / 位置没到位 → 回退从头，且只做一次
                    if !didFallbackToZero, intendedStart > 3, player.rate == 0,
                       abs(current - intendedStart) > 3 {
                        didFallbackToZero = true
                        DiagnosticsLog.write("[播放] 续播起播失败（位置=\(Int(current))s 目标=\(Int(intendedStart))s），回退从头播放")
                        intendedStart = 0
                        loadItem(startAt: 0)
                        play()
                        return
                    }

                    // 位置明显没到位：退回从头播放
                    if abs(current - intendedStart) > max(3, intendedStart * 0.1), current < intendedStart - 1 {
                        DiagnosticsLog.write("[播放] seek 未到位，回退从头播放")
                        intendedStart = 0
                        loadItem(startAt: 0)
                        play()
                        return
                    }

                    ensurePlaying()

                    // 第 2 次仍失败：静音探针，判断是否为音频轨问题
                    if pauseRecoveries >= 2, !didMuteProbe {
                        didMuteProbe = true
                        player.isMuted = true
                        player.play()
                        let probeRate = player.rate
                        DiagnosticsLog.write("[播放] 静音探针 rate=\(String(format: "%.1f", probeRate))（>0 说明音频轨解码异常）")
                        if probeRate == 0 {
                            player.isMuted = false
                        }
                    }
                }
            }
        } else {
            waitingTicks = 0
            pauseTicks = 0
            if player.rate > 0 {
                recoveryAttempts = 0
                pauseRecoveries = 0
                waitingRecoveries = 0
            }
        }
    }

    /// 结构化探测同步样本表：moov → trak(视频) → mdia → minf → stbl → stss
    private static func syncSampleInfo(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无法打开" }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return "无法读取大小" }

        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var boxSize = UInt64(header.u32(at: 0))
            let type = header.ascii(at: 4, length: 4)
            var headerLength: UInt64 = 8
            if boxSize == 1, header.count >= 16 {
                boxSize = header.u64(at: 8)
                headerLength = 16
            } else if boxSize == 0 {
                boxSize = fileSize - offset
            }
            guard boxSize >= headerLength else { break }

            if type == "moov" {
                try? handle.seek(toOffset: offset)
                guard let moov = try? handle.read(upToCount: Int(min(boxSize, 32 << 20))) else {
                    return "读取 moov 失败"
                }
                let body = Int(headerLength)..<moov.count
                var cursor = body.lowerBound
                while cursor + 8 <= body.upperBound {
                    let size = Int(moov.u32(at: cursor))
                    let boxType = moov.ascii(at: cursor + 4, length: 4)
                    guard size >= 8, cursor + size <= body.upperBound else { break }
                    if boxType == "trak" {
                        let trakRange = cursor..<(cursor + size)
                        let isVideo = moov.range(of: Data("vmhd".utf8), in: trakRange) != nil
                        if isVideo {
                            if let stbl = descendant(moov, in: trakRange, path: ["mdia", "minf", "stbl"]) {
                                if let stss = child(moov, in: stbl, type: "stss") {
                                    let entries = moov.u32(at: stss.lowerBound + 12)
                                    return "moov=\(boxSize / 1024)KB stss(entries=\(entries))"
                                }
                                return "moov=\(boxSize / 1024)KB 视频轨无 stss"
                            }
                        }
                    }
                    cursor += size
                }
                return "moov=\(boxSize / 1024)KB 未找到视频 trak"
            }
            offset += boxSize
        }
        return "未找到 moov"
    }

    private static func child(_ data: Data, in range: Range<Int>, type: String) -> Range<Int>? {
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size = Int(data.u32(at: cursor))
            let boxType = data.ascii(at: cursor + 4, length: 4)
            guard size >= 8, cursor + size <= range.upperBound else { return nil }
            if boxType == type { return cursor..<(cursor + size) }
            cursor += size
        }
        return nil
    }

    private static func descendant(_ data: Data, in range: Range<Int>, path: [String]) -> Range<Int>? {
        var current = range
        for type in path {
            guard let found = child(data, in: (current.lowerBound + 8)..<current.upperBound, type: type) else {
                return nil
            }
            current = found
        }
        return current
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

    /// 等待（waitingToPlayAtSpecifiedRate）自愈：原逻辑只处理 item.failed，等待状态永远不自愈
    private func recoverFromWaiting() {
        guard isActive, expectsPlaying else { return }
        logDetailedStatus("等待超时")
        guard waitingRecoveries < 2 else {
            if waitingRecoveries == 2 {
                waitingRecoveries = 3
                DiagnosticsLog.write("[播放] 等待自愈已达上限，不再自动重试（需手动重开）")
            }
            return
        }
        guard Date().timeIntervalSince(lastWaitingRecovery) > 5 else { return }
        lastWaitingRecovery = Date()
        waitingRecoveries += 1
        let seconds = player.currentTime().seconds
        let position = seconds.isFinite && seconds > 0 ? seconds : lastSaved
        DiagnosticsLog.write("[播放] 等待超时自愈 第\(waitingRecoveries)次 位置=\(Int(position))s 原因=\(player.reasonForWaitingToPlay?.rawValue ?? "-")")
        waitingTicks = 0
        loadItem(startAt: position)
        play()
    }

    /// D1：详细状态（用于判断"播放器没发请求"还是"服务端没收到"）
    private func logDetailedStatus(_ tag: String) {
        lastStatusLogAt = Date()
        lastLoggedCtl = player.timeControlStatus.rawValue
        let item = player.currentItem
        let pos = player.currentTime().seconds
        let loaded = item?.loadedTimeRanges.first?.timeRangeValue.end.seconds ?? 0
        let keepUp = item?.isPlaybackLikelyToKeepUp ?? false
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
        var errorText = "-"
        if let e = item?.error { let ns = e as NSError; errorText = "\(ns.domain)/\(ns.code)" }
        var sinceRequest = "-"
        if let s = session?.secondsSinceLastRequest { sinceRequest = String(format: "%.0f", s) }
        let requests = session?.requestCount ?? 0
        DiagnosticsLog.write("[播放] \(tag) ctl=\(player.timeControlStatus.rawValue) reason=\(reason) keepUp=\(keepUp) loaded=\(String(format: "%.0f", loaded))s pos=\(String(format: "%.0f", pos))s itemStatus=\(item?.status.rawValue ?? -1) err=\(errorText) 距上次请求=\(sinceRequest)s 请求数=\(requests)")
        if let entry = item?.accessLog()?.events.last {
            DiagnosticsLog.write("[播放] access 停顿=\(entry.numberOfStalls) 字节=\(entry.numberOfBytesTransferred) 耗时=\(String(format: "%.0f", entry.transferDuration * 1000))ms uri=\(entry.uri ?? "-")")
        }
    }

    private func recoverIfNeeded(force: Bool) {
        guard isActive, expectsPlaying else { return }
        guard recoveryAttempts < 3 else { return }
        let failed = player.currentItem?.status == .failed
        guard force || failed else { return }
        recoveryAttempts += 1
        waitingTicks = 0

        let seconds = player.currentTime().seconds
        let position = seconds.isFinite && seconds > 0 ? seconds : lastSaved
        DiagnosticsLog.write("[播放] 自愈第 \(recoveryAttempts) 次，位置=\(Int(position))s 失败=\(failed)")
        loadItem(startAt: position)
        play()
    }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(self[startIndex + offset + index]) }
        return value
    }

    func u64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(self[startIndex + offset + index]) }
        return value
    }

    func ascii(at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "????" }
        return String(decoding: self[(startIndex + offset)..<(startIndex + offset + length)], as: UTF8.self)
    }
}
