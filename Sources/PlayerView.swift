import SwiftUI
import AVKit
import UIKit

struct PlayerView: View {
    @ObservedObject var store: PlaybackStore

    @Environment(\.dismiss) private var dismiss
    private var player: AVPlayer { store.player }
    private var title: String { store.title }
    private var startPosition: Double { 0 }
    @StateObject private var gestures = PlayerGestureModel()
    @State private var immersive = true
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

            if let next = store.countdownNext {
                countdownCard(next: next)
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
                    store.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.45), in: Circle())
                        .contentShape(Circle())
                }

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Button {
                    store.exitFullscreen()
                    gestures.pokeChrome()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.45), in: Circle())
                        .contentShape(Circle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, immersive ? 8 : 16)

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

                if store.isAirPlaying {
                    Label("投屏中", systemImage: "airplayvideo")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.18), in: Capsule())
                }

                AirPlayRouteButton()
                    .frame(width: 30, height: 30)

                Spacer()
            }

            markingBar

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
                        store.beginScrub()
                        gestures.isPlaying = false
                    } else {
                        player.seek(to: CMTime(seconds: scrubTime, preferredTimescale: 600),
                                    toleranceBefore: .zero,
                                    toleranceAfter: .zero)
                        isScrubbing = false
                        store.endScrub()
                        gestures.isPlaying = store.isPlaying
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

    // MARK: - 片头片尾打点

    private var markingBar: some View {
        HStack(spacing: 8) {
            Button {
                store.markIntroHere()
            } label: {
                Label("片头", systemImage: "text.insert")
            }

            if let timing = store.seriesTiming, timing.intro > 0 || timing.outro > 0 {
                Button { store.adjustIntro(by: -5) } label: { Image(systemName: "minus") }
                Text("片头 \(Int(store.seriesTiming?.intro ?? 0))s")
                    .font(.caption2.monospacedDigit())
                Button { store.adjustIntro(by: 5) } label: { Image(systemName: "plus") }
            }

            Button {
                store.markOutroHere()
            } label: {
                Label("片尾", systemImage: "text.append")
            }

            if let outro = store.seriesTiming?.outro, outro > 0 {
                Text("片尾 \(Int(outro))s")
                    .font(.caption2.monospacedDigit())
            }

            Spacer(minLength: 0)

            Button {
                store.skipForThisEpisode()
            } label: {
                Text("本集不跳过")
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.white.opacity(0.92))
        .labelStyle(.titleAndIcon)
    }

    private func countdownCard(next: VideoItem) -> some View {
        VStack(spacing: 10) {
            Text("\(store.countdownRemaining) 秒后播放下一集")
                .font(.subheadline.weight(.semibold))
            Text(next.title)
                .font(.caption)
                .opacity(0.85)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button {
                store.cancelCountdown()
            } label: {
                Text("取消")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.18), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 28)
        .padding(.bottom, 120)
    }

    // MARK: - 播放控制

    private func togglePlay() {
        store.togglePlay()
        gestures.isPlaying = store.isPlaying
        gestures.pokeChrome()
    }

    private func startPlayback() {
        UIApplication.shared.isIdleTimerDisabled = true
        initialBrightness = ScreenBrightness.current
        OrientationLock.apply(.landscape)

        if store.expectsPlaying, player.rate == 0 { player.play() }
        gestures.isPlaying = player.rate > 0
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
                store.reportProgress(seconds)
            }
        }
    }
    private func stopPlayback() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        let current = player.currentTime().seconds
        if current.isFinite { store.reportProgress(current) }

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

/// 系统 AirPlay 路由选择按钮（Apple TV / 支持 AirPlay 2 的电视）
struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}