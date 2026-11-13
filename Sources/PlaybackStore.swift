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
    @Published var errorNotice: String?

    let player = AVPlayer()

    var onProgress: ((UUID, Double) -> Void)?
    var onClose: (() -> Void)?

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
    private var loadStartedAt: Date?
    private var loadReported = false
    private var didMuteProbe = false
    private var intendedStart: Double = 0
    private var scrubbing = false
    private var expectsPlayingBeforeScrub = false
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
                play()
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
        recoveryAttempts = 0
        waitingTicks = 0
        pauseTicks = 0
        pauseRecoveries = 0

        configureAudioSession()

        let resumePosition = video.lastPosition ?? 0
        var seekable = true
        if !isHLS {
            seekable = Self.hasSyncSampleTable(url) ?? false
        }
        let startAt = seekable ? resumePosition : 0
        intendedStart = startAt
        didMuteProbe = false
        if !seekable, resumePosition > 3 {
            DiagnosticsLog.write("[播放] 该文件缺少同步样本表(stss)，忽略续播进度 \(Int(resumePosition))s，改为从头播放")
        }

        loadItem(startAt: startAt)
        play()
        attachObserver()
        startHealthTimer()
        Task { await reportAssetInfo() }
        DiagnosticsLog.write("[播放] 打开 \(video.title) 源=\(url.lastPathComponent) 续播=\(Int(startAt))s 可精确seek=\(seekable)")
    }

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
                        toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
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
        expectsPlaying = false
        if notify { onClose?() }
    }

    // MARK: - 播放控制（用户意图入口，全屏与悬浮窗共用）

    func play() {
        expectsPlaying = true
        if player.rate == 0 { player.play() }
        isPlaying = player.rate > 0
    }

    func pause() {
        expectsPlaying = false
        pauseTicks = 0
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        if expectsPlaying || player.rate > 0 { pause() } else { play() }
    }

    /// 拖动进度条：先暂停并记住原意图（幂等，避免重复进入覆盖原意图）
    func beginScrub() {
        guard !scrubbing else { return }
        expectsPlayingBeforeScrub = expectsPlaying
        DiagnosticsLog.write("[播放] 开始拖动 原意图=\(expectsPlaying)")
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
        player.play()
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

    private func detachObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
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
        }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let silentlyPaused = player.rate == 0
            && player.timeControlStatus == .paused
            && player.currentItem?.status == .readyToPlay

        if failed || waiting {
            waitingTicks += 1
            pauseTicks = 0
            if failed || waitingTicks >= 8 {
                recoverIfNeeded(force: failed)
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
            }
        }
    }

    /// 探测 MP4 是否含同步样本表（stss）；缺失时精确 seek 不可靠
    private static func hasSyncSampleTable(_ url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var offset: UInt64 = 0
        while offset + 8 <= size {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var boxSize = UInt64(header.u32(at: 0))
            let type = header.ascii(at: 4, length: 4)
            var headerLength: UInt64 = 8
            if boxSize == 1, header.count >= 16 {
                boxSize = header.u64(at: 8)
                headerLength = 16
            } else if boxSize == 0 {
                boxSize = size - offset
            }
            guard boxSize >= headerLength else { break }
            if type == "moov" {
                try? handle.seek(toOffset: offset)
                guard let data = try? handle.read(upToCount: Int(min(boxSize, 16 << 20))) else { return nil }
                return data.range(of: Data("stss".utf8)) != nil
            }
            offset += boxSize
        }
        return nil
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