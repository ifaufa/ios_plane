import UIKit
import AVKit
import MediaPlayer
import SwiftUI

// MARK: - HUD 状态

struct PlayerHUD: Equatable {
    enum Kind: Equatable {
        case volume
        case brightness
        case seek
        case stepForward
        case stepBackward
        case fastForward
        case rewind

        /// 是否需要横向进度条（音量/亮度）
        var usesBar: Bool { self == .volume || self == .brightness }
    }
    var kind: Kind
    var progress: Double   // 0...1，音量/亮度/进度占比
    var text: String       // 主文案
    var detail: String     // 次文案
}

@MainActor
final class PlayerGestureModel: ObservableObject {
    @Published var hud: PlayerHUD?
    @Published var isPlaying = false
    /// 自绘控制层是否可见
    @Published var chromeVisible = true

    private var hideTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?

    func toggleChrome() {
        chromeVisible.toggle()
        if chromeVisible { scheduleAutoHide() }
    }

    func pokeChrome() {
        chromeVisible = true
        scheduleAutoHide()
    }

    func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard chromeVisible, isPlaying else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { chromeVisible = false }
        }
    }

    func show(_ hud: PlayerHUD) {
        hideTask?.cancel()
        self.hud = hud
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { hud = nil }
        }
    }

    func hideNow() {
        hideTask?.cancel()
        hud = nil
    }
}

// MARK: - 系统音量（无公开 API，通过 MPVolumeView 的 UISlider 调整）

final class SystemVolume {
    static let shared = SystemVolume()

    private let volumeView = MPVolumeView()

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    private init() {
        volumeView.showsRouteButton = false
        volumeView.frame = CGRect(x: -3000, y: -3000, width: 120, height: 40)
        volumeView.alpha = 0.01
        attachToWindow()
    }

    var value: Float {
        if let slider { return slider.value }
        return AVAudioSession.sharedInstance().outputVolume
    }

    /// 返回 false 表示无法控制系统音量，调用方应退化为调整播放器音量
    @discardableResult
    func set(_ newValue: Float) -> Bool {
        let clamped = max(0, min(1, newValue))
        guard let slider else { return false }
        slider.value = clamped
        return true
    }

    private func attachToWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first else { return }
            if self.volumeView.superview == nil {
                window.addSubview(self.volumeView)
            }
        }
    }
}

// MARK: - 屏幕亮度

enum ScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    static var current: CGFloat {
        screen?.brightness ?? 0.5
    }

    static func set(_ value: CGFloat) {
        let clamped = max(0.02, min(1.0, value))
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach { $0.screen.brightness = clamped }
    }
}

// MARK: - 播放器容器（承载 AVPlayerViewController 并叠加手势）

final class PlayerHostViewController: UIViewController, UIGestureRecognizerDelegate {
    private let playerViewController = AVPlayerViewController()
    private let player: AVPlayer
    private let model: PlayerGestureModel

    private var pan: UIPanGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var singleTap: UITapGestureRecognizer!
    private var longPress: UILongPressGestureRecognizer!

    private enum SpeedMode { case none, rate, stepping }
    private var speedMode: SpeedMode = .none
    private var wasPlayingBeforeSpeed = false
    private var fastForwardMonitor: Timer?
    private var lastCheckAt: CFTimeInterval = 0
    private var lastCheckPosition: Double = 0
    private var previewTimer: Timer?
    private var previewTarget: Double = 0
    private var previewStep: Double = 0

    private enum PanMode { case undecided, seek, volume, brightness }
    private var mode: PanMode = .undecided
    private var anchor: CGPoint = .zero
    private var isRightSide = true
    private var baseVolume: Float = 0
    private var baseBrightness: CGFloat = 0.5
    private var baseTime: Double = 0
    private var duration: Double = 0
    private var seekTarget: Double = 0
    private var lastSeekAt: CFTimeInterval = 0

    init(player: AVPlayer, model: PlayerGestureModel) {
        self.player = player
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        addChild(playerViewController)
        playerViewController.view.frame = view.bounds
        playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerViewController.player = player
        playerViewController.showsPlaybackControls = false
        playerViewController.videoGravity = .resizeAspect
        playerViewController.allowsPictureInPicturePlayback = true
        playerViewController.updatesNowPlayingInfoCenter = true
        playerViewController.entersFullScreenWhenPlaybackBegins = false
        view.addSubview(playerViewController.view)
        playerViewController.didMove(toParent: self)

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 12
        longPress.delegate = self
        view.addGestureRecognizer(longPress)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        endSpeedChange()
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        model.toggleChrome()
    }

    // 让我们的手势与 AVKit 内部手势并行，保证控制条仍可点按
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let width = max(1, view.bounds.width)
        let x = gesture.location(in: view).x

        if x < width / 3 {
            stepSeek(by: -10, kind: .stepBackward, label: "—10 秒")
        } else if x > width * 2 / 3 {
            stepSeek(by: 10, kind: .stepForward, label: "＋10 秒")
        } else {
            PlaybackStore.shared.togglePlay()
            model.isPlaying = PlaybackStore.shared.isPlaying
            model.pokeChrome()
        }
    }

    private func stepSeek(by delta: Double, kind: PlayerHUD.Kind, label: String) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let target = max(0, min(durationSeconds(), current + delta))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
        model.show(PlayerHUD(kind: kind,
                             progress: durationSeconds() > 0 ? target / durationSeconds() : 0,
                             text: label,
                             detail: Self.format(target)))
        model.scheduleHide()
    }

    // MARK: 长按倍速

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let x = gesture.location(in: view).x
            if x > view.bounds.midX {
                beginFastForward()
            } else {
                beginRewind()
            }
        case .ended, .cancelled, .failed:
            endSpeedChange()
        default:
            break
        }
    }

    /// 快进：先尝试真实 2.0× 播放，检测到没有真正推进则自动切换为步进预览
    private func beginFastForward() {
        wasPlayingBeforeSpeed = player.rate > 0
        speedMode = .rate
        player.playImmediately(atRate: 2.0)

        lastCheckAt = CACurrentMediaTime()
        lastCheckPosition = player.currentTime().seconds
        fastForwardMonitor?.invalidate()
        fastForwardMonitor = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFastForward() }
        }
        model.show(PlayerHUD(kind: .fastForward,
                             progress: progressFraction(),
                             text: "2.0×",
                             detail: "快进播放中"))
    }

    private func checkFastForward() {
        guard speedMode == .rate else { return }
        let now = CACurrentMediaTime()
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        let elapsed = now - lastCheckAt
        let moved = position - lastCheckPosition
        let ratio = elapsed > 0 ? moved / elapsed : 0

        // 期望接近 2.0；低于 1.3 说明没有真正加速（HLS 不支持高倍速会反复等待）
        if ratio < 1.3 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            switchToSteppingPreview()
            return
        }
        lastCheckAt = now
        lastCheckPosition = position
        model.show(PlayerHUD(kind: .fastForward,
                             progress: progressFraction(),
                             text: "2.0×",
                             detail: "快进播放中"))
    }

    private func switchToSteppingPreview() {
        fastForwardMonitor?.invalidate()
        fastForwardMonitor = nil
        speedMode = .stepping
        PlaybackStore.shared.pauseForPreview()
        previewTarget = max(0, player.currentTime().seconds)
        previewStep = 0.25
        startPreviewTimer()
        model.show(PlayerHUD(kind: .fastForward,
                             progress: progressFraction(),
                             text: "预览",
                             detail: "快进预览（该源不支持高倍速播放）"))
    }

    private func beginRewind() {
        wasPlayingBeforeSpeed = player.rate > 0
        speedMode = .stepping
        PlaybackStore.shared.pauseForPreview()
        previewTarget = max(0, player.currentTime().seconds)
        previewStep = -0.25
        startPreviewTimer()
        model.show(PlayerHUD(kind: .rewind,
                             progress: progressFraction(),
                             text: "2.5×",
                             detail: "后退中"))
    }

    private func startPreviewTimer() {
        previewTimer?.invalidate()
        // 每 0.1 秒移动 0.25 秒音视频 = 2.5 倍速
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepPreview() }
        }
    }

    private func stepPreview() {
        let total = durationSeconds()
        previewTarget = max(0, min(total > 0 ? total : previewTarget, previewTarget + previewStep))
        player.seek(to: CMTime(seconds: previewTarget, preferredTimescale: 600),
                    toleranceBefore: .positiveInfinity,
                    toleranceAfter: .positiveInfinity)

        let kind: PlayerHUD.Kind = previewStep > 0 ? .fastForward : .rewind
        let verb = previewStep > 0 ? "快进预览中" : "后退中"
        model.show(PlayerHUD(kind: kind,
                             progress: progressFraction(),
                             text: "2.5×",
                             detail: "\(verb) \(Self.format(previewTarget))"))

        if previewStep < 0 && previewTarget <= 0 {
            endSpeedChange()
        } else if previewStep > 0 && total > 0 && previewTarget >= total - 0.05 {
            endSpeedChange()
        }
    }

    private func endSpeedChange() {
        fastForwardMonitor?.invalidate()
        fastForwardMonitor = nil
        previewTimer?.invalidate()
        previewTimer = nil
        speedMode = .none

        if wasPlayingBeforeSpeed {
            PlaybackStore.shared.resumeAfterPreview()
        } else {
            PlaybackStore.shared.pauseForPreview()
        }
        wasPlayingBeforeSpeed = false
        model.isPlaying = player.rate > 0
        model.scheduleHide()
    }

    private func durationSeconds() -> Double {
        let total = player.currentItem?.duration.seconds ?? 0
        return total.isFinite && total > 0 ? total : 0
    }

    private func progressFraction() -> Double {
        let total = durationSeconds()
        guard total > 0 else { return 0 }
        let current = player.currentTime().seconds
        guard current.isFinite else { return 0 }
        return max(0, min(1, current / total))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            anchor = translation
            mode = .undecided
            isRightSide = gesture.location(in: view).x > view.bounds.midX
            baseVolume = SystemVolume.shared.value
            baseBrightness = ScreenBrightness.current
            let current = player.currentTime().seconds
            baseTime = current.isFinite ? current : 0
            let total = player.currentItem?.duration.seconds ?? 0
            duration = total.isFinite ? total : 0
            seekTarget = baseTime

        case .changed:
            let dx = translation.x - anchor.x
            let dy = translation.y - anchor.y
            if mode == .undecided {
                guard max(abs(dx), abs(dy)) > 12 else { return }
                mode = abs(dx) > abs(dy) * 1.2 ? .seek : (isRightSide ? .volume : .brightness)
            }
            applyGesture(dx: dx, dy: dy)

        case .ended, .cancelled, .failed:
            finishGesture()

        default:
            break
        }
    }

    private func applyGesture(dx: CGFloat, dy: CGFloat) {
        let height = max(1, view.bounds.height)
        let width = max(1, view.bounds.width)
        let fullRange = height * 0.7

        switch mode {
        case .volume:
            let target = max(0, min(1, baseVolume + Float(-dy / fullRange)))
            if !SystemVolume.shared.set(target) {
                player.volume = target   // 无法控制系统音量时退化为播放器音量
            }
            model.show(PlayerHUD(kind: .volume,
                                 progress: Double(target),
                                 text: "\(Int(target * 100))%",
                                 detail: "音量"))

        case .brightness:
            let target = max(0, min(1, baseBrightness - dy / fullRange))
            ScreenBrightness.set(target)
            model.show(PlayerHUD(kind: .brightness,
                                 progress: Double(target),
                                 text: "\(Int(target * 100))%",
                                 detail: "亮度"))

        case .seek:
            guard duration > 0 else { return }
            let delta = Double(dx / width) * duration
            seekTarget = max(0, min(duration, baseTime + delta))
            let now = CACurrentMediaTime()
            if now - lastSeekAt > 0.12 {
                lastSeekAt = now
                player.seek(to: CMTime(seconds: seekTarget, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero)
            }
            model.show(PlayerHUD(kind: .seek,
                                 progress: duration > 0 ? seekTarget / duration : 0,
                                 text: "\(Self.format(seekTarget)) / \(Self.format(duration))",
                                 detail: String(format: "%+.0f 秒", delta)))

        case .undecided:
            break
        }
    }

    private func finishGesture() {
        if mode == .seek {
            player.seek(to: CMTime(seconds: seekTarget, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero)
        }
        if mode != .undecided {
            model.scheduleHide()
        }
        mode = .undecided
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - SwiftUI 包装

struct PlayerHostView: UIViewControllerRepresentable {
    let player: AVPlayer
    let model: PlayerGestureModel

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        PlayerHostViewController(player: player, model: model)
    }

    func updateUIViewController(_ controller: PlayerHostViewController, context: Context) {}
}

// MARK: - HUD 视图

struct PlayerHUDView: View {
    let hud: PlayerHUD

    private var icon: String {
        switch hud.kind {
        case .volume: return hud.progress <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .seek: return "arrow.left.and.right"
        case .stepForward: return "goforward.10"
        case .stepBackward: return "gobackward.10"
        case .fastForward: return "forward.fill"
        case .rewind: return "backward.fill"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(hud.detail)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.white)

            if !hud.kind.usesBar {
                Text(hud.text)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white)
                            .frame(width: max(0, geo.size.width * hud.progress))
                    }
                }
                .frame(width: 120, height: 5)

                Text(hud.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .transition(.opacity)
    }
}
