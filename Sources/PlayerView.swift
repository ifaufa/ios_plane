import SwiftUI
import AVKit
import UIKit

struct PlayerView: View {
    let url: URL
    let title: String
    let startPosition: Double
    let onProgress: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @StateObject private var gestures = PlayerGestureModel()
    @State private var immersive = false
    @State private var timeObserver: Any?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var lastSavedTime: Double = 0
    @State private var initialBrightness: CGFloat = -1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerHostView(player: player, model: gestures)
                .ignoresSafeArea()

            if let hud = gestures.hud {
                PlayerHUDView(hud: hud)
                    .allowsHitTesting(false)
            }

            if gestures.chromeVisible {
                chrome
            }
        }
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        .onAppear { startPlayback() }
        .onDisappear { stopPlayback() }
    }

    // MARK: - 自绘控制层

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                }

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { immersive.toggle() }
                    gestures.pokeChrome()
                } label: {
                    Image(systemName: immersive
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, immersive ? 6 : 12)

            Spacer()

            bottomBar
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .transition(.opacity)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { togglePlay() } label: {
                    Image(systemName: gestures.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 32, height: 32)
                }

                Text("\(Self.formatTime(displayedTime)) / \(Self.formatTime(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()
            }

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : currentTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubTime = currentTime
                        player.pause()
                        gestures.isPlaying = false
                    } else {
                        player.seek(to: CMTime(seconds: scrubTime, preferredTimescale: 600),
                                    toleranceBefore: .zero,
                                    toleranceAfter: .zero)
                        isScrubbing = false
                        player.play()
                        gestures.isPlaying = true
                    }
                    gestures.pokeChrome()
                }
            )
            .tint(.white)
            .disabled(duration <= 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
    }

    private var displayedTime: Double {
        isScrubbing ? scrubTime : currentTime
    }

    // MARK: - 播放控制

    private func togglePlay() {
        if player.rate > 0 {
            player.pause()
            gestures.isPlaying = false
        } else {
            player.play()
            gestures.isPlaying = true
        }
        gestures.pokeChrome()
    }

    private func startPlayback() {
        UIApplication.shared.isIdleTimerDisabled = true
        initialBrightness = ScreenBrightness.current
        OrientationLock.apply(.landscape)

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain   // 倍速播放时保持音调不变
        player.replaceCurrentItem(with: item)
        if startPosition > 3 {
            player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero)
            currentTime = startPosition
            lastSavedTime = startPosition
        }
        player.play()
        gestures.isPlaying = true
        gestures.pokeChrome()

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            if !isScrubbing { currentTime = seconds }
            if let total = player.currentItem?.duration.seconds, total.isFinite, total > 0 {
                duration = total
            }
            let playing = player.rate > 0
            if gestures.isPlaying != playing {
                gestures.isPlaying = playing
                if playing { gestures.scheduleAutoHide() }
            }
            if abs(seconds - lastSavedTime) >= 5 {
                lastSavedTime = seconds
                onProgress(seconds)
            }
        }
    }

    private func stopPlayback() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        let current = player.currentTime().seconds
        if current.isFinite { onProgress(current) }

        player.pause()
        if initialBrightness >= 0 {
            ScreenBrightness.set(initialBrightness)
            initialBrightness = -1
        }
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationLock.apply(.all)
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
