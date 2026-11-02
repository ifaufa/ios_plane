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
    @State private var chromeVisible = true
    @State private var timeObserver: Any?
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

            if chromeVisible {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
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
                        } label: {
                            Image(systemName: immersive
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, immersive ? 8 : 12)

                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
        .onAppear { startPlayback() }
        .onDisappear { stopPlayback() }
    }

    private func startPlayback() {
        UIApplication.shared.isIdleTimerDisabled = true
        initialBrightness = ScreenBrightness.current
        OrientationLock.apply(.landscape)

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if startPosition > 3 {
            player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero)
        }
        player.play()

        let interval = CMTime(seconds: 5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            onProgress(seconds)
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
}
