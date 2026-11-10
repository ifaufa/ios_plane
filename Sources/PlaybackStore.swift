import SwiftUI
import AVKit
import UIKit

/// 共享播放器：悬浮窗与全屏共用同一 AVPlayer 实例，切换形态不重建、不丢进度
@MainActor
final class PlaybackStore: ObservableObject {
    static let shared = PlaybackStore()

    @Published private(set) var videoID: UUID?
    @Published private(set) var title: String = ""
    @Published var isFullscreen = false
    @Published var isPlaying = false

    let player = AVPlayer()

    /// 进度回调（由 ContentView 注入）
    var onProgress: ((UUID, Double) -> Void)?
    /// 关闭时回调，用于恢复亮度/方向等
    var onClose: (() -> Void)?

    private var timeObserver: Any?
    private var lastSaved: Double = 0
    private var startPosition: Double = 0

    var isActive: Bool { videoID != nil }

    func open(video: VideoItem, url: URL) {
        if videoID == video.id { return }
        close(notify: false)

        videoID = video.id
        title = video.title
        startPosition = video.lastPosition ?? 0
        lastSaved = video.lastPosition ?? 0

        // 分片态走本地 HTTP 服务
        let item: AVPlayerItem
        if url.pathExtension.lowercased() == "m3u8", let http = try? LocalHLS.playbackURL(playlistURL: url) {
            item = AVPlayerItem(url: http)
        } else {
            item = AVPlayerItem(url: url)
        }
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        if startPosition > 3 {
            player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        isPlaying = true

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.isPlaying = self.player.rate > 0
            if abs(seconds - self.lastSaved) >= 5 {
                self.lastSaved = seconds
                if let id = self.videoID { self.onProgress?(id, seconds) }
            }
        }
    }

    /// 由全屏页定期上报进度（用于视频库断点记忆）
    func reportProgress(_ seconds: Double) {
        guard let id = videoID else { return }
        onProgress?(id, seconds)
    }

    func togglePlay() {
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func enterFullscreen() { isFullscreen = true }

    func exitFullscreen() { isFullscreen = false }

    /// 关闭播放（保存进度并释放）
    func close(notify: Bool = true) {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        let seconds = player.currentTime().seconds
        if seconds.isFinite, let id = videoID, abs(seconds - lastSaved) >= 1 {
            onProgress?(id, seconds)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        LocalHLS.stopPlayback()

        videoID = nil
        title = ""
        isPlaying = false
        isFullscreen = false
        if notify { onClose?() }
    }
}
