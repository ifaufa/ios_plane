import SwiftUI
import AVFoundation
import UIKit

/// AVPlayerLayer 宿主（悬浮窗与全屏共用同一个 player）
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerContainer {
        let view = PlayerLayerContainer()
        view.layer.player = player
        view.layer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainer, context: Context) {
        if uiView.layer.player !== player {
            uiView.layer.player = player
        }
        uiView.layer.videoGravity = videoGravity
    }

    final class PlayerLayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layer: AVPlayerLayer { self.layer as! AVPlayerLayer }
    }
}

/// 可拖动、可缩放的悬浮播放窗（仅三个按钮：关闭 / 全屏 / 播放暂停）
struct MiniPlayerWindow: View {
    @ObservedObject var store: PlaybackStore

    @AppStorage("mini.width") private var width: Double = 280
    @AppStorage("mini.x") private var storedX: Double = 0
    @AppStorage("mini.y") private var storedY: Double = 0

    @State private var dragOffset: CGSize = .zero
    @State private var resizeStart: Double = 0

    private var displayWidth: CGFloat { CGFloat(max(200, min(480, width))) }
    private var displayHeight: CGFloat { displayWidth * 9 / 16 + 44 }

    var body: some View {
        GeometryReader { geometry in
            let maxX = max(8, geometry.size.width - displayWidth - 8)
            let maxY = max(8, geometry.size.height - displayHeight - 60)
            let baseX = storedX <= 0 ? maxX : min(storedX, Double(maxX))
            let baseY = storedY <= 0 ? maxY : min(storedY, Double(maxY))

            VStack(spacing: 0) {
                PlayerSurface(player: store.player)
                    .frame(width: displayWidth - 8, height: displayWidth * 9 / 16)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)

                controls
                    .frame(height: 40)
            }
            .frame(width: displayWidth, height: displayHeight)
            .background(Color.black.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .overlay(alignment: .bottomTrailing) {
                resizeHandle
            }
            .position(
                x: baseX + Double(displayWidth) / 2 + dragOffset.width,
                y: baseY + Double(displayHeight) / 2 + dragOffset.height
            )
            .gesture(
                DragGesture()
                    .onChanged { value in dragOffset = value.translation }
                    .onEnded { value in
                        let newX = baseX + value.translation.width
                        let newY = baseY + value.translation.height
                        storedX = Double(min(max(8, newX), maxX))
                        storedY = Double(min(max(8, newY), maxY))
                        dragOffset = .zero
                    }
            )
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                store.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                store.enterFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                store.togglePlay()
            } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 26, height: 26)
            .background(Color.white.opacity(0.12), in: Circle())
            .padding(6)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        width = min(480, max(200, width + Double(value.translation.width) * 0.5))
                    }
            )
    }
}
