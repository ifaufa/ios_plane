import SwiftUI
import AVFoundation
import UIKit

/// AVPlayerLayer 宿主（悬浮窗与全屏共用同一个 player）
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerContainer {
        let view = PlayerLayerContainer()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainer, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = videoGravity
    }

    final class PlayerLayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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
    @State private var hudText: String?
    @State private var hudToken = 0

    private var displayWidth: CGFloat { CGFloat(max(200, min(480, width))) }
    private var displayHeight: CGFloat { displayWidth * 9 / 16 + 44 }

    var body: some View {
        GeometryReader { geometry in
            let maxX = max(8, geometry.size.width - displayWidth - 8)
            let maxY = max(8, geometry.size.height - displayHeight - 60)
            let baseX = storedX <= 0 ? maxX : min(storedX, Double(maxX))
            let baseY = storedY <= 0 ? maxY : min(storedY, Double(maxY))

            VStack(spacing: 0) {
                ZStack {
                    PlayerSurface(player: store.player)

                    // 单击＝播放/暂停；双击左半＝-10s，右半＝+10s
                    PlayerTapOverlay(
                        onSingleTap: { togglePlay() },
                        onDoubleTap: { isLeft in seek(by: isLeft ? -10 : 10) }
                    )
                    .background(Color.clear)

                    if let hudText {
                        Text(hudText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.62), in: Capsule())
                            .transition(.opacity)
                    }
                }
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

    // MARK: - 手势动作

    private func togglePlay() {
        store.togglePlay()
        showHUD(store.isPlaying ? "播放" : "暂停")
    }

    private func seek(by delta: Double) {
        let current = store.player.currentTime().seconds
        guard current.isFinite else { return }
        let total = store.player.currentItem?.duration.seconds ?? 0
        var target = current + delta
        if target < 0 { target = 0 }
        if total.isFinite, total > 0, target > total - 0.5 { target = max(0, total - 0.5) }
        store.player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                          toleranceBefore: .zero,
                          toleranceAfter: .zero)
        showHUD(delta < 0 ? "−10 秒" : "+10 秒")
        DiagnosticsLog.write("[播放] 悬浮窗双击 \(delta < 0 ? "快退" : "快进") 目标=\(Int(target))s")
    }

    private func showHUD(_ text: String) {
        hudToken += 1
        let token = hudToken
        withAnimation(.easeOut(duration: 0.12)) { hudText = text }
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if token == hudToken {
                withAnimation(.easeIn(duration: 0.2)) { hudText = nil }
            }
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

/// 单击/双击点击层（双击分区判定左右半屏）
struct PlayerTapOverlay: UIViewRepresentable {
    let onSingleTap: () -> Void
    let onDoubleTap: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onDoubleTap: onDoubleTap)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let double = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingle(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTap = onDoubleTap
    }

    final class Coordinator: NSObject {
        var onSingleTap: () -> Void
        var onDoubleTap: (Bool) -> Void

        init(onSingleTap: @escaping () -> Void, onDoubleTap: @escaping (Bool) -> Void) {
            self.onSingleTap = onSingleTap
            self.onDoubleTap = onDoubleTap
        }

        @objc func handleSingle(_ gesture: UITapGestureRecognizer) {
            onSingleTap()
        }

        @objc func handleDouble(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let x = gesture.location(in: view).x
            onDoubleTap(x < view.bounds.midX)
        }
    }
}