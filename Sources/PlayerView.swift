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
    @State private var immersive = false
    @State private var chromeVisible = true
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerViewControllerRepresentable(player: player)
                .ignoresSafeArea()

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
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationLock.apply(.all)
    }
}

/// 用 AVPlayerViewController 承载原生控制条（进度、音量、字幕、画中画）
private struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.updatesNowPlayingInfoCenter = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
