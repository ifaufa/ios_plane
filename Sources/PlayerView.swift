import SwiftUI
import AVKit
import UIKit

struct PlayerView: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var immersive = false
    @State private var chromeVisible = true

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
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
        .onDisappear {
            player.pause()
            UIApplication.shared.isIdleTimerDisabled = false
        }
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
