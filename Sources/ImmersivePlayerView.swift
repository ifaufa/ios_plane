import SwiftUI
import AVKit
import UIKit

/// 全屏播放：复用悬浮窗的同一个 player，附手势与精简控制条
struct ImmersivePlayerView: View {
    @ObservedObject var store: PlaybackStore
    @StateObject private var gestures = PlayerGestureModel()
    @Environment(\.dismiss) private var dismiss

    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerHostView(player: store.player, model: gestures)
                .ignoresSafeArea()

            if let hud = gestures.hud {
                PlayerHUDView(hud: hud)
                    .allowsHitTesting(false)
            }

            if gestures.chromeVisible {
                chrome
            }
        }
        .statusBarHidden(false)
        .onAppear { attachObserver() }
        .onDisappear { detachObserver() }
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 14) {
                Button {
                    store.exitFullscreen()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.45), in: Circle())
                }

                Text(store.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Button {
                    store.close()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    Text(Self.formatTime(isScrubbing ? scrubTime : currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 60, alignment: .leading)

                    Slider(value: Binding(
                        get: { isScrubbing ? scrubTime : currentTime },
                        set: { value in
                            isScrubbing = true
                            scrubTime = value
                        }
                    ), in: 0...max(1, duration), onEditingChanged: { editing in
                        if !editing {
                            store.player.seek(to: CMTime(seconds: scrubTime, preferredTimescale: 600),
                                              toleranceBefore: .zero, toleranceAfter: .zero)
                            currentTime = scrubTime
                            isScrubbing = false
                        }
                    })
                    .tint(.white)

                    Text(Self.formatTime(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 60, alignment: .trailing)

                    Button {
                        store.togglePlay()
                        gestures.pokeChrome()
                    } label: {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
        }
    }

    private func attachObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = store.player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            if !isScrubbing { currentTime = seconds }
            if let total = store.player.currentItem?.duration.seconds, total.isFinite, total > 0 {
                duration = total
            }
            let playing = store.player.rate > 0
            if gestures.isPlaying != playing { gestures.isPlaying = playing }
        }
    }

    private func detachObserver() {
        if let timeObserver {
            store.player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
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
