import SwiftUI
import AVKit
import UIKit
import UniformTypeIdentifiers

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
    @ObservedObject private var subtitles = SubtitleCenter.shared
    @State private var subtitleTime: Double = 0
    @State private var subtitleObserver: Any?
    @State private var showSubtitleImporter = false
    @AppStorage(SegmentEditStore.enabledKey) private var editEnabled = true
    /// 全屏常驻时钟：0 关闭，1 仅时间，2 时间+日期
    @AppStorage("playback.clockMode") private var clockMode = 0

    private static let clockDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return formatter
    }()

    private static let clockTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()

    private static func clockDate(_ date: Date) -> String {
        clockDateFormatter.string(from: date)
    }

    private static func clockTime(_ date: Date) -> String {
        clockTimeFormatter.string(from: date)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerHostView(player: player, model: gestures)
                .ignoresSafeArea()

            if let hud = gestures.hud {
                PlayerHUDView(hud: hud)
                    .allowsHitTesting(false)
            }

            subtitleOverlay

            // 常驻时钟：仅在控制条隐藏时显示（控制条展开时顶部已有完整日期时间）
            if clockMode > 0, !gestures.chromeVisible {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .semibold))
                        Text(clockMode == 2
                             ? Self.clockDate(context.date) + " " + Self.clockTime(context.date)
                             : Self.clockTime(context.date))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
                }
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 10)
                .padding(.trailing, 14)
                .transition(.opacity)
            }

            if gestures.chromeVisible {
                chrome
            }

            if let next = store.countdownNext {
                countdownCard(next: next)
            }

            if store.isFinished {
                VStack(spacing: 12) {
                    Text("已播放完")
                        .font(.headline)
                    Button {
                        store.player.seek(to: .zero)
                        store.play()
                    } label: {
                        Text("重新播放")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
            }

            if store.isMarkingPoints {
                HStack(spacing: 8) {
                    Button {
                        if gestures.chromeVisible {
                            gestures.chromeVisible = false
                        } else {
                            gestures.pokeChrome()
                        }
                    } label: {
                        Text("控制条")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                    Text("左=－1s ｜ 中上=设A 中下=设B ｜ 右=＋1s")
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Button("完成") { store.isMarkingPoints = false }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.22), in: Capsule())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.75), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 44)
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
        .fileImporter(isPresented: $showSubtitleImporter,
                      allowedContentTypes: subtitleTypes,
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if SubtitleCenter.shared.importFile(from: url) {
                DiagnosticsLog.write("[字幕] 导入成功 " + url.lastPathComponent)
            }
        }
        .sheet(isPresented: $showLoopPanel) {
            LoopRangeSheet(store: store, duration: duration)
        }
        .sheet(isPresented: $showEditor) {
            SegmentEditSheet(playback: store)
        }
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        .onChange(of: store.videoID) { _ in
            // 连播切集：播放器不重建，需要重新准备该集的字幕
            SubtitleCenter.shared.prepare(for: store.currentVideo)
        }
        .onDisappear { SubtitleCenter.shared.clear() }
        .onChange(of: store.gravityMode) { mode in
            gestures.show(PlayerHUD(kind: .seek, progress: 0, text: mode.title, detail: mode.detail))
        }
        .onChange(of: store.isMarkingPoints) { active in
            if active {
                gestures.chromeVisible = true
                DiagnosticsLog.write("[手势] 进入设点模式（顶部 150pt 让给提示条，其余由 UIKit 四区处理）")
            } else {
                DiagnosticsLog.write("[手势] 退出设点模式")
            }
        }
        .onAppear {
            startPlayback()
            if store.pendingOpenEditor {
                store.pendingOpenEditor = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showEditor = true }
            }
        }
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

            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 6) {
                    Text(Self.clockDate(context.date))
                        .font(.caption2)
                    Text("·")
                        .opacity(0.5)
                    Text(Self.clockTime(context.date))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.black.opacity(0.4), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            }
            .allowsHitTesting(false)
            .padding(.top, 6)

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

                if editEnabled {
                    Button {
                        showEditor = true
                    } label: {
                        Image(systemName: "scissors")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 28, height: 28)
                    }
                }

                subtitleMenu
                gravityMenu
                rateMenu

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

    private var gravityMenu: some View {
        Menu {
            ForEach(PlaybackStore.VideoGravityMode.allCases, id: \.self) { mode in
                Button(gravityLabel(mode)) { store.setGravity(mode) }
            }
        } label: {
            Image(systemName: store.gravityMode.icon)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
        } primaryAction: {
            store.cycleGravity()
        }
    }

    private func gravityLabel(_ mode: PlaybackStore.VideoGravityMode) -> String {
        let mark = store.gravityMode == mode ? "✓ " : ""
        return mark + mode.title + "（" + mode.detail + "）"
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button {
                    store.setPlaybackRate(Float(value))
                } label: {
                    if abs(Double(store.playbackRate) - value) < 0.01 {
                        Label(Self.rateText(value), systemImage: "checkmark")
                    } else {
                        Text(Self.rateText(value))
                    }
                }
            }
        } label: {
            Text(Self.rateText(Double(store.playbackRate)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 28)
        }
    }

    private static func rateText(_ value: Double) -> String {
        if abs(value - 1.0) < 0.01 { return "1×" }
        return String(format: "%g×", value)
    }

    // MARK: - 字幕

    @ViewBuilder
    private var subtitleOverlay: some View {
        let texts = subtitles.texts(at: subtitleTime)
        if texts.primary != nil || texts.secondary != nil {
            VStack(spacing: 4) {
                if let primary = texts.primary {
                    subtitleLine(primary, scale: 1.0)
                }
                if let secondary = texts.secondary {
                    subtitleLine(secondary, scale: 0.82)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: subtitles.positionIndex == 0 ? .bottom : .center)
            .padding(.bottom, subtitles.positionIndex == 0 ? 96 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: texts.primary)
        }
    }

    private func subtitleLine(_ text: String, scale: CGFloat) -> some View {
        Text(text)
            .font(.system(size: subtitles.fontSize * scale, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(subtitles.textColor)
            .padding(.horizontal, subtitles.backgroundIndex == 2 ? 4 : 10)
            .padding(.vertical, subtitles.backgroundIndex == 2 ? 1 : 4)
            .background(subtitleBackground)
            .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
    }

    @ViewBuilder
    private var subtitleBackground: some View {
        switch subtitles.backgroundIndex {
        case 0:
            Color.clear
        case 2:
            Color.clear   // 仅描边效果（靠 shadow 实现）
        default:
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55))
        }
    }

    private var subtitleTypes: [UTType] {
        var types: [UTType] = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
        types.append(.plainText)
        return types
    }

    @ViewBuilder
    private var subtitleMenu: some View {
        Menu {
            Button("关闭主字幕") { subtitles.selectPrimary(nil) }
            ForEach(subtitles.tracks) { track in
                Button((subtitles.primary?.id == track.id ? "✓ " : "") + track.title) {
                    subtitles.selectPrimary(track)
                }
            }

            if subtitles.tracks.count > 1 {
                Menu("次字幕（双语）") {
                    Button("关闭次字幕") { subtitles.selectSecondary(nil) }
                    ForEach(subtitles.tracks) { track in
                        Button((subtitles.secondary?.id == track.id ? "✓ " : "") + track.title) {
                            subtitles.selectSecondary(track)
                        }
                    }
                }
            }

            Divider()
            Menu("字号") {
                Button("小") { subtitles.fontSizeIndex = 0; subtitles.persistStyle() }
                Button("中") { subtitles.fontSizeIndex = 1; subtitles.persistStyle() }
                Button("大") { subtitles.fontSizeIndex = 2; subtitles.persistStyle() }
            }
            Menu("位置") {
                Button("底部") { subtitles.positionIndex = 0; subtitles.persistStyle() }
                Button("居中") { subtitles.positionIndex = 1; subtitles.persistStyle() }
            }
            Menu("背景") {
                Button("无") { subtitles.backgroundIndex = 0; subtitles.persistStyle() }
                Button("半透明") { subtitles.backgroundIndex = 1; subtitles.persistStyle() }
                Button("描边") { subtitles.backgroundIndex = 2; subtitles.persistStyle() }
            }
            Menu("颜色") {
                Button("白色") { subtitles.colorIndex = 0; subtitles.persistStyle() }
                Button("黄色") { subtitles.colorIndex = 1; subtitles.persistStyle() }
                Button("青色") { subtitles.colorIndex = 2; subtitles.persistStyle() }
                Button("绿色") { subtitles.colorIndex = 3; subtitles.persistStyle() }
                Button("粉色") { subtitles.colorIndex = 4; subtitles.persistStyle() }
            }
            Menu("时间偏移") {
                Button("−0.5 秒") { subtitles.adjustOffset(-0.5) }
                Button("−0.1 秒") { subtitles.adjustOffset(-0.1) }
                Button("+0.1 秒") { subtitles.adjustOffset(0.1) }
                Button("+0.5 秒") { subtitles.adjustOffset(0.5) }
            }
            Divider()
            Button("加载字幕文件…") { showSubtitleImporter = true }
        } label: {
            Image(systemName: subtitles.isActive ? "captions.bubble.fill" : "captions.bubble")
                .font(.caption)
                .foregroundStyle(.white.opacity(subtitles.hasSubtitles ? 1 : 0.75))
                .frame(width: 28, height: 28)
        }
    }

    private func startPlayback() {
        UIApplication.shared.isIdleTimerDisabled = true
        initialBrightness = ScreenBrightness.current
        applyOrientationForCurrentVideo()

        SubtitleCenter.shared.prepare(for: store.currentVideo)
        if subtitleObserver == nil {
            let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
            subtitleObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                let seconds = time.seconds
                if seconds.isFinite { subtitleTime = seconds }
            }
        }

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
        if let subtitleObserver {
            player.removeTimeObserver(subtitleObserver)
            self.subtitleObserver = nil
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

    private var aBinding: Binding<Double>? {
        guard store.loopStart != nil else { return nil }
        return Binding(get: { store.loopStart ?? 0 }, set: { store.updateLoopStart($0) })
    }

    private var bBinding: Binding<Double>? {
        guard store.loopEnd != nil else { return nil }
        return Binding(get: { store.loopEnd ?? 0 }, set: { store.updateLoopEnd($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    adjustRow(title: "起点 A", binding: aBinding, onAdjust: { store.adjustLoopStart(by: $0) })
                    Button("用当前时间设为 A") { store.setLoopStartToCurrent() }
                } header: {
                    Text("起点 A")
                } footer: {
                    Text("A 必须早于 B 至少 1 秒；调整后立即生效。")
                }

                Section {
                    adjustRow(title: "终点 B", binding: bBinding, onAdjust: { store.adjustLoopEnd(by: $0) })
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
            .onAppear {
                let a = store.loopStart.map { String(format: "%.1f", $0) } ?? "nil"
                let b = store.loopEnd.map { String(format: "%.1f", $0) } ?? "nil"
                DiagnosticsLog.write("[循环] 面板打开 A=\(a)s B=\(b)s")
            }
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
                           binding: Binding<Double>?,
                           onAdjust: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                if let binding {
                    TimeMaskField(value: binding,
                                  maxSeconds: max(1, duration))
                        .frame(width: 112, height: 34)
                } else {
                    Text("未设置")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                ForEach([(-5.0, "-5s"), (-1.0, "-1s"), (1.0, "+1s"), (5.0, "+5s")], id: \.0) { item in
                    Button(item.1) { onAdjust(item.0) }
                        .buttonStyle(.bordered)
                        .frame(minWidth: 54, minHeight: 40)
                        .disabled(binding == nil)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 分片剪辑面板

