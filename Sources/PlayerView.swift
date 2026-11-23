import SwiftUI
import AVKit
import UIKit

struct PlayerView: View {
    static let autoLandscapeKey = "playback.autoLandscape"

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
    @State private var showLoopPanel = false
    @State private var lastLongPressAt = Date.distantPast
    /// 手动解锁旋转后，本次播放不再自动锁定方向
    @State private var orientationUnlocked = false
    @State private var showEditor = false

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

            if let notice = store.loopNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 72)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .statusBarHidden(immersive)
        .sheet(isPresented: $showLoopPanel) {
            LoopRangeSheet(store: store, duration: duration)
        }
        .sheet(isPresented: $showEditor) {
            SegmentEditSheet(playback: store)
        }
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

                Button {
                    toggleOrientationUnlock()
                } label: {
                    Image(systemName: orientationUnlocked ? "lock.rotation.open" : "lock.rotation")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(orientationUnlocked ? 1 : 0.75))
                        .frame(width: 28, height: 28)
                }

                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "scissors")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                }

                Spacer()

                loopControls
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
                        store.handleSeek(to: scrubTime)
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

    // MARK: - A-B 循环控制条

    private var loopMarkTitle: String {
        if let start = store.loopStart, store.loopEnd != nil {
            return "重设"
        } else if store.loopStart != nil {
            return "设 B"
        }
        return "设 A"
    }

    private var loopRangeTitle: String {
        guard let start = store.loopStart else { return "" }
        if let end = store.loopEnd {
            return "A " + Self.formatTime(start) + " ↔ B " + Self.formatTime(end)
        }
        return "A " + Self.formatTime(start)
    }

    private var loopControls: some View {
        HStack(spacing: 6) {
            Text(loopMarkTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.16), in: Capsule())
                .contentShape(Capsule())
                .onTapGesture {
                    if Date().timeIntervalSince(lastLongPressAt) < 0.6 { return }
                    store.markLoopPoint()
                }
                .onLongPressGesture(minimumDuration: 0.6) {
                    lastLongPressAt = Date()
                    store.clearLoopPoints()
                    store.stopLooping()
                }

            if store.loopStart != nil {
                Button {
                    showLoopPanel = true
                } label: {
                    Text(loopRangeTitle)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(store.isLooping ? Color.cyan : .white.opacity(0.9))
                        .underline()
                }
            }

            Button {
                store.toggleLooping()
            } label: {
                Text(store.isLooping ? "循环中" : "循环")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(store.isLooping ? Color.cyan.opacity(0.45) : Color.white.opacity(0.16),
                                in: Capsule())
            }
            .disabled(store.loopStart == nil || store.loopEnd == nil)
            .opacity((store.loopStart == nil || store.loopEnd == nil) ? 0.45 : 1)
        }
    }

    private var markingBar: some View {
        HStack(spacing: 10) {
            Button {
                store.markIntroHere()
            } label: {
                Label("片头", systemImage: "text.insert")
            }

            if let intro = store.seriesTiming?.introLength, intro > 0 {
                Text(PlaybackStore.timeText(intro))
                    .font(.caption2.monospacedDigit())
                    .opacity(0.85)
            }

            Divider().frame(height: 14).overlay(.white.opacity(0.3))

            Button {
                store.markOutroHere()
            } label: {
                Label("片尾", systemImage: "text.append")
            }

            if let outro = store.seriesTiming?.outroLength, outro > 0 {
                Text(PlaybackStore.timeText(outro))
                    .font(.caption2.monospacedDigit())
                    .opacity(0.85)
            } else if store.seriesTiming != nil {
                Text("无片尾")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
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
        applyOrientationForCurrentVideo()

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
    /// 按视频画幅决定播放方向：
    /// 横视频 → 锁横屏（保持原有体验）；竖视频 → 锁竖屏；接近方形 → 跟随设备
    /// 设置里关闭「播放时自动旋转为横屏」后，一律跟随设备
    private func applyOrientationForCurrentVideo() {
        guard !orientationUnlocked else {
            OrientationLock.apply(.all)
            return
        }
        let autoLandscape = (UserDefaults.standard.object(forKey: PlayerView.autoLandscapeKey) as? Bool) ?? true
        guard autoLandscape else {
            OrientationLock.apply(.all)
            return
        }
        guard let item = player.currentItem else {
            OrientationLock.apply(.landscape)
            return
        }
        Task { @MainActor in
            let displaySize = await Self.videoDisplaySize(item: item)
            guard !orientationUnlocked else { return }
            guard displaySize.width > 1, displaySize.height > 1 else {
                DiagnosticsLog.write("[播放] 方向：尺寸未知，按横屏处理")
                OrientationLock.apply(.landscape)
                return
            }
            let ratio = displaySize.width / displaySize.height
            let mask: UIInterfaceOrientationMask
            let label: String
            if ratio >= 1.2 {
                mask = .landscape; label = "横视频 → 横屏"
            } else if ratio <= 1 / 1.2 {
                mask = .portrait; label = "竖视频 → 竖屏"
            } else {
                mask = .all; label = "近似方形 → 跟随设备"
            }
            let width = Int(displaySize.width)
            let height = Int(displaySize.height)
            let detail = "[播放] 方向：" + label + "（" + String(width) + "x" + String(height) + "）"
            DiagnosticsLog.write(detail)
            OrientationLock.apply(mask)
        }
    }

    /// 视频的显示尺寸（已叠加旋转信息；竖拍视频常见 1920x1080 + 90° 变换）
    private static func videoDisplaySize(item: AVPlayerItem) async -> CGSize {
        guard let tracks = try? await item.asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return .zero }
        guard let natural = try? await track.load(.naturalSize) else { return .zero }
        guard let transform = try? await track.load(.preferredTransform) else {
            return natural
        }
        let rotated = natural.applying(transform)
        return CGSize(width: abs(rotated.width), height: abs(rotated.height))
    }

    private func toggleOrientationUnlock() {
        orientationUnlocked.toggle()
        if orientationUnlocked {
            OrientationLock.apply(.all)
            DiagnosticsLog.write("[播放] 方向：已解锁，跟随设备旋转")
        } else {
            applyOrientationForCurrentVideo()
            DiagnosticsLog.write("[播放] 方向：已恢复自动锁定")
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

// MARK: - 循环区间微调面板

private struct LoopRangeSheet: View {
    @ObservedObject var store: PlaybackStore
    let duration: Double
    @Environment(\.dismiss) private var dismiss

    private var rangeText: String {
        guard let start = store.loopStart, let end = store.loopEnd else { return "未设置" }
        return String(format: "%.1f 秒", max(0, end - start))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    adjustRow(title: "起点 A", value: store.loopStart) { store.adjustLoopStart(by: $0) }
                    Button("用当前时间设为 A") { store.setLoopStartToCurrent() }
                } header: {
                    Text("起点 A")
                } footer: {
                    Text("A 必须早于 B 至少 1 秒；调整后立即生效。")
                }

                Section {
                    adjustRow(title: "终点 B", value: store.loopEnd) { store.adjustLoopEnd(by: $0) }
                    Button("用当前时间设为 B") { store.setLoopEndToCurrent() }
                        .disabled(store.loopStart == nil)
                } header: {
                    Text("终点 B")
                }

                Section {
                    HStack {
                        Text("区间长度")
                        Spacer()
                        Text(rangeText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("循环状态")
                        Spacer()
                        Text(store.isLooping ? "循环中" : "未开启")
                            .foregroundStyle(store.isLooping ? Color.accentColor : .secondary)
                    }
                }

                Section {
                    Button("清空区间", role: .destructive) {
                        store.clearLoopPoints()
                        dismiss()
                    }
                }
            }
            .navigationTitle("循环区间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func adjustRow(title: String,
                           value: Double?,
                           onAdjust: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text(value.map { PlaybackStore.timeText($0) } ?? "未设置")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach([(-5.0, "-5s"), (-1.0, "-1s"), (1.0, "+1s"), (5.0, "+5s")], id: \.0) { item in
                    Button(item.1) { onAdjust(item.0) }
                        .buttonStyle(.bordered)
                        .frame(minWidth: 54, minHeight: 40)
                        .disabled(value == nil)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 分片剪辑面板

private struct SegmentEditSheet: View {
    @ObservedObject var playback: PlaybackStore
    @ObservedObject var editor = SegmentEditStore.shared
    @Environment(\.dismiss) private var dismiss

    private var totalDuration: Double {
        let value = playback.player.currentItem?.duration.seconds ?? 0
        return value.isFinite && value > 0 ? value : 0
    }

    private var selectionStart: Double? { playback.loopStart }
    private var selectionEnd: Double? { playback.loopEnd }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let a = selectionStart, let b = selectionEnd, b > a {
                        HStack {
                            Text("选区")
                            Spacer()
                            Text(Self.rangeText(a, b))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button("剪掉这一段（保留其余）") {
                            editor.cutOut(start: a, end: b, duration: totalDuration)
                        }
                        Button("只保留这一段") {
                            editor.keepOnly(start: a, end: b)
                        }
                    } else {
                        Text("请先用播放器上的「设 A / 设 B」选出区间")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("选区")
                } footer: {
                    Text("切点会自动吸附到最近的关键帧（误差通常 ≤1 秒），不重新编码、无画质损失。原片不会被修改。")
                }

                Section {
                    if editor.ranges.isEmpty {
                        Text("暂无区间")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editor.ranges) { range in
                            HStack {
                                Text(Self.rangeText(range.start, range.end))
                                    .monospacedDigit()
                                Spacer()
                                Text(PlaybackStore.timeText(max(0, range.end - range.start)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    editor.remove(range.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("清空清单", role: .destructive) { editor.clear() }
                    }
                } header: {
                    Text("剪辑清单（\(editor.ranges.count) 段 · 共 \(PlaybackStore.timeText(editor.totalDuration))）")
                }

                Section {
                    Button {
                        Task { await editor.export(source: playback.currentVideo) }
                    } label: {
                        HStack {
                            Text(editor.isExporting ? "导出中…" : "导出为新的分片视频")
                            Spacer()
                            if editor.isExporting { ProgressView() }
                        }
                    }
                    .disabled(editor.ranges.isEmpty || editor.isExporting)

                    if editor.isExporting {
                        ProgressView(value: editor.progress)
                    }
                } footer: {
                    Text("导出后会在视频库顶部生成一个新条目（原片保留，可自行删除）。")
                }
            }
            .navigationTitle("剪辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("剪辑", isPresented: Binding(
                get: { editor.notice != nil },
                set: { if !$0 { editor.notice = nil } }
            )) {
                Button("好") { editor.notice = nil }
            } message: {
                Text(editor.notice ?? "")
            }
        }
    }

    private static func rangeText(_ start: Double, _ end: Double) -> String {
        PlaybackStore.timeText(start) + " – " + PlaybackStore.timeText(end)
    }
}
