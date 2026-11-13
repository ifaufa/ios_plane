import Foundation
import AVFoundation
import QuartzCore

struct DownloadTaskInfo: Identifiable, Equatable {
    let id: String            // 以源 URL 字符串作为标识
    let url: URL
    var title: String
    var progress: Double      // 0...1
    var status: Status
    /// 进度长时间无变化
    var stalled: Bool = false
    /// 继续后进度回退，说明该源不支持断点续传
    var restartedFromZero: Bool = false
    /// 实时下载速度（字节/秒）
    var speed: Double = 0
    /// 编码预检结果（支持 / 不支持 / 未知）
    var codecStatus: String? = nil

    enum Status: Equatable {
        case queued
        case downloading
        case paused
        case failed(String)

        var isActive: Bool { self == .downloading }
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static var backgroundCompletionHandler: (() -> Void)?

    /// 同时下载上限，超出后排队
    static let maxConcurrentKey = "downloads.maxConcurrent"

    /// 同时下载的任务数（1–5，默认 5）
    var maxConcurrent: Int {
        let value = UserDefaults.standard.integer(forKey: Self.maxConcurrentKey)
        return value <= 0 ? 5 : min(5, max(1, value))
    }
    /// 进度停滞多少秒判定为卡住
    let stallTimeout: CFTimeInterval = 30

    weak var library: VideoLibrary?
    @Published private(set) var tasks: [DownloadTaskInfo] = []

    /// 下载引擎：默认分片（可断点续传），可在设置里切回系统引擎
    static let engineKey = "download.engine"
    var useSegmentEngine: Bool {
        (UserDefaults.standard.string(forKey: Self.engineKey) ?? "segment") == "segment"
    }

    private var pending: [(url: URL, title: String)] = []
    /// 因并发上限被挂起的"已有分片任务"（恢复而非重建，避免丢进度）
    private var pendingSegmentResume: [String] = []
    private var pendingTitles: [String: String] = [:]
    private var durations: [String: Double] = [:]
    private var progressMarks: [String: CFTimeInterval] = [:]
    /// 继续下载时记录的基线进度，用于判断是否从头开始
    private var resumeBaseline: [String: Double] = [:]
    private var stallTimer: Timer?
    private var speedTimer: Timer?

    private lazy var session: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.local.planem3u8.downloads")
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        wireSegmentEngine()
        Task { @MainActor in
            for job in SegmentRunner.shared.restore() {
                if !self.tasks.contains(where: { $0.id == job.id }), let url = URL(string: job.sourceURL) {
                    self.tasks.append(DownloadTaskInfo(
                        id: job.id,
                        url: url,
                        title: job.title,
                        progress: Double(job.completed.count) / Double(max(1, job.segmentURLs.count)),
                        status: .paused
                    ))
                }
            }
            let all = (try? await self.session.allTasks) ?? []
            for case let task as AVAssetDownloadTask in all {
                guard let desc = task.taskDescription, let url = URL(string: desc) else { continue }
                if !self.tasks.contains(where: { $0.id == desc }) {
                    self.tasks.append(DownloadTaskInfo(id: desc, url: url, title: url.lastPathComponent, progress: 0, status: .downloading))
                }
            }
            self.startNextIfNeeded()
            self.startStallMonitor()
            self.startSpeedMonitor()
        }
    }

    private func startSpeedMonitor() {
        speedTimer?.invalidate()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSpeeds() }
        }
    }

    private func refreshSpeeds() {
        for task in tasks where task.status.isActive {
            let speed = SegmentRunner.shared.speed(of: task.id)
            update(task.id) { $0.speed = speed }
        }
    }

    var activeCount: Int {
        tasks.filter { $0.status.isActive }.count
    }

    // MARK: - 用户操作

    func start(url: URL, title: String, codecStatus: String? = nil) {
        let id = url.absoluteString
        guard !tasks.contains(where: { $0.id == id }) else { return }

        if activeCount < maxConcurrent {
            begin(url: url, title: title)
            update(id) { $0.codecStatus = codecStatus }
        } else {
            pending.append((url, title))
            tasks.append(DownloadTaskInfo(id: id, url: url, title: title, progress: 0,
                                          status: .queued, codecStatus: codecStatus))
        }
    }

    func pause(_ info: DownloadTaskInfo) {
        if SegmentRunner.shared.state(of: info.id) != nil {
            SegmentRunner.shared.pause(info.id)
            update(info.id) { $0.status = .paused; $0.stalled = false }
            startNextIfNeeded()
            return
        }
        switch info.status {
        case .queued:
            pending.removeAll { $0.url.absoluteString == info.id }
        pendingSegmentResume.removeAll { $0 == info.id }
            update(info.id) { $0.status = .paused }
        case .downloading:
            update(info.id) { $0.status = .paused; $0.stalled = false }
            progressMarks.removeValue(forKey: info.id)
            cancelSessionTask(id: info.id)
            startNextIfNeeded()
        case .paused, .failed:
            break
        }
    }

    func resume(_ info: DownloadTaskInfo) {
        guard info.status == .paused || isFailed(info.status) else { return }
        resumeBaseline[info.id] = info.progress
        update(info.id) { $0.status = .queued; $0.stalled = false }

        if SegmentRunner.shared.state(of: info.id) != nil {
            if activeCount < maxConcurrent {
                SegmentRunner.shared.resume(info.id)
                update(info.id) { $0.status = .downloading }
            } else {
                if !pendingSegmentResume.contains(info.id) { pendingSegmentResume.append(info.id) }
                update(info.id) { $0.status = .queued }
            }
            return
        }
        if activeCount < maxConcurrent {
            begin(url: info.url, title: info.title)
        } else {
            pending.append((info.url, info.title))
        }
    }

    /// 彻底移除任务（不写入视频库）
    func remove(_ info: DownloadTaskInfo) {
        SegmentRunner.shared.remove(info.id)
        pending.removeAll { $0.url.absoluteString == info.id }
        pendingSegmentResume.removeAll { $0 == info.id }
        tasks.removeAll { $0.id == info.id }
        pendingTitles.removeValue(forKey: info.id)
        durations.removeValue(forKey: info.id)
        progressMarks.removeValue(forKey: info.id)
        cancelSessionTask(id: info.id)
        startNextIfNeeded()
    }

    // MARK: - 分片引擎回调

    private func wireSegmentEngine() {
        SegmentRunner.shared.onProgress = { [weak self] id, progress in
            self?.update(id) { $0.progress = progress }
        }
        SegmentRunner.shared.onFailure = { [weak self] id, message in
            guard let self else { return }
            self.update(id) { $0.status = .failed(message); $0.stalled = false }
            self.startNextIfNeeded()
        }
        SegmentRunner.shared.onAllSegmentsDownloaded = { [weak self] id, playlistURL in
            guard let self else { return }
            Task { await self.finalizeSegmentJob(id: id, playlistURL: playlistURL) }
        }
    }

    /// 全部分片下载完成后：优先保留分片态（可播），失败则合并成单文件兜底
    private func finalizeSegmentJob(id: String, playlistURL: URL) async {
        guard let state = SegmentRunner.shared.state(of: id) else { return }
        let workDir = playlistURL.deletingLastPathComponent()
        let title = pendingTitles[id] ?? state.title

        if let issue = Self.validateSegments(state: state, dir: workDir) {
            DiagnosticsLog.write("[6 分片态校验] 分片自检异常：\(issue)")
        }
        if state.container == "ts" {
            let first = workDir.appendingPathComponent(LocalHLS.fileName(index: 0))
            DiagnosticsLog.write("[6 分片态校验] TS结构 \(TSProbe.describe(fileURL: first))")
        }

        var verify = LocalHLS.VerifyResult(playable: false, duration: 0, detail: "本地服务启动失败")
        do {
            // 使用独立会话，避免打断正在播放的视频
            let session = try LocalHLS.open(playlistURL: playlistURL)
            defer { session.stop() }
            let check = await LocalHLS.selfCheck(session.url)
            DiagnosticsLog.write("[本地服务自检] \(check)")
            verify = await LocalHLS.verifyByPlayer(session.url)
        } catch {
            verify = LocalHLS.VerifyResult(playable: false, duration: 0, detail: error.localizedDescription)
        }
        DiagnosticsLog.write("[6 分片态校验] playable=\(verify.playable) \(verify.detail) 容器=\(state.container) 段数=\(state.durations.count)")

        if verify.playable {
            let folder = UUID().uuidString
            let destination = VideoLibrary.assetsDir.appendingPathComponent(folder, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: workDir, to: destination)
                let item = VideoItem(
                    id: UUID(),
                    title: title,
                    sourceURL: id,
                    fileName: "\(folder)/index.m3u8",
                    duration: verify.duration,
                    fileSize: Self.directorySize(destination),
                    createdAt: Date(),
                    lastPosition: nil
                )
                library?.add(item)
                SegmentRunner.shared.release(id)
                finishTask(id: id)
                return
            } catch {
                DiagnosticsLog.write("[6 分片态校验] 入库失败：\(error.localizedDescription)")
            }
        }

        // 分片态无法被系统解析：仅 fMP4（init+fragments）有合并兜底价值，TS 合并产物 iOS 也解不了
        guard state.container == "mp4" else {
            DiagnosticsLog.write("[7 放弃] TS 分片无法解析，提示改用系统引擎")
            update(id) {
                $0.status = .failed("分片无法被系统解析（\(verify.detail)）。可在设置中切换到系统引擎重新下载该视频。")
            }
            startNextIfNeeded()
            return
        }

        do {
            let report = try LocalHLS.merge(state: state, dir: workDir, container: "mp4")
            let sum = report.segmentSizes.reduce(0, +)
            DiagnosticsLog.write("[7 合并] 文件=\(report.url.lastPathComponent) 大小=\(report.bytes)B 分片和=\(sum)B")
            guard report.bytes == sum else {
                throw PlaylistError.network("合并大小与分片总和不一致")
            }
            let mergedVerify = await LocalHLS.verify(report.url)
            DiagnosticsLog.write("[7 合并] 校验 playable=\(mergedVerify.playable) \(mergedVerify.detail)")
            guard mergedVerify.playable else {
                throw PlaylistError.network("合并后仍无法解析出音视频轨道")
            }

            let fileName = UUID().uuidString + ".mp4"
            let destination = VideoLibrary.assetsDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: report.url, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? report.bytes
            let item = VideoItem(
                id: UUID(),
                title: title,
                sourceURL: id,
                fileName: fileName,
                duration: mergedVerify.duration,
                fileSize: size,
                createdAt: Date(),
                lastPosition: nil
            )
            library?.add(item)
            SegmentRunner.shared.release(id)
            finishTask(id: id)
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
            startNextIfNeeded()
        }
    }

    /// 逐片检查头部字节，防止把密文/坏片拼进成品
    private static func validateSegments(state: SegmentJobState, dir: URL) -> String? {
        for index in state.durations.indices {
            let fileURL = dir.appendingPathComponent(LocalHLS.fileName(index: index))
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                return "分片 \(index + 1) 无法读取"
            }
            let head = (try? handle.read(upToCount: 64)) ?? Data()
            try? handle.close()
            guard let first = head.first else { return "分片 \(index + 1) 为空" }

            if state.container == "mp4" {
                let signature = String(data: head.prefix(4), encoding: .ascii) ?? ""
                let valid = ["ftyp", "moof", "styp", "sidx", "mdat", "free"].contains(signature)
                if !valid { return "分片 \(index + 1) 头部异常（\(signature)）" }
            } else if first != 0x47 {
                return "分片 \(index + 1) 不是有效的 TS 数据（首字节 \(String(format: "%02x", first))）"
            }
        }
        return nil
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        for case let sub as String in enumerator {
            let fileURL = url.appendingPathComponent(sub)
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - 队列调度

    private func begin(url: URL, title: String) {
        let id = url.absoluteString
        pendingTitles[id] = title
        progressMarks[id] = CACurrentMediaTime()

        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].status = .downloading
            tasks[index].stalled = false
        } else {
            tasks.append(DownloadTaskInfo(id: id, url: url, title: title, progress: 0, status: .downloading))
        }

        if useSegmentEngine {
            SegmentRunner.shared.start(id: id, title: title, url: url)
            return
        }

        let asset = Self.makeAsset(url: url)
        guard let task = session.makeAssetDownloadTask(asset: asset,
                                                       assetTitle: title,
                                                       assetArtworkData: nil,
                                                       options: nil) else { return }
        task.taskDescription = id
        task.resume()
    }

    /// 支持 Referer/UA 等防盗链请求头（AVAssetDownloadURLSession 需要以此方式注入）
    private static func makeAsset(url: URL) -> AVURLAsset {
        let headers = RequestSettings.headers
        guard !headers.isEmpty else { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    private func startNextIfNeeded() {
        // 先恢复被并发上限挂起的分片任务（保留已有进度）
        while activeCount < maxConcurrent, !pendingSegmentResume.isEmpty {
            let id = pendingSegmentResume.removeFirst()
            guard let task = tasks.first(where: { $0.id == id }) else { continue }
            SegmentRunner.shared.resume(id)
            update(id) { $0.status = .downloading; $0.stalled = false }
        }
        while activeCount < maxConcurrent, !pending.isEmpty {
            let next = pending.removeFirst()
            begin(url: next.url, title: next.title)
        }
    }

    private func cancelSessionTask(id: String) {
        Task { @MainActor in
            let all = (try? await self.session.allTasks) ?? []
            for case let task as AVAssetDownloadTask in all where task.taskDescription == id {
                task.cancel()
            }
        }
    }

    private func isFailed(_ status: DownloadTaskInfo.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    // MARK: - 卡滞检测

    private func startStallMonitor() {
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStalls() }
        }
    }

    private func checkStalls() {
        let now = CACurrentMediaTime()
        for task in tasks where task.status.isActive {
            guard let mark = progressMarks[task.id] else { continue }
            if now - mark > stallTimeout, !task.stalled {
                update(task.id) { $0.stalled = true }
            }
        }
    }

    // MARK: - 内部

    private func update(_ id: String, _ mutate: (inout DownloadTaskInfo) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[idx])
    }

    private func duration(of task: URLSessionTask, id: String) async -> Double {
        if let d = durations[id] { return d }
        guard let assetTask = task as? AVAssetDownloadTask,
              let d = try? await assetTask.urlAsset.load(.duration),
              d.isNumeric, d.seconds > 0 else { return 0 }
        durations[id] = d.seconds
        return d.seconds
    }

    private func finishTask(id: String) {
        tasks.removeAll { $0.id == id }
        pendingTitles.removeValue(forKey: id)
        durations.removeValue(forKey: id)
        progressMarks.removeValue(forKey: id)
        startNextIfNeeded()
    }
}

// MARK: - AVAssetDownloadDelegate

extension DownloadManager: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            let id = assetDownloadTask.taskDescription ?? assetDownloadTask.urlAsset.url.absoluteString

            // 关键：暂停/删除时 AVFoundation 也会回调“下载完成”并给出残缺资产，
            // 只有任务仍处于下载中才算真正完成，否则清理残片、不写入视频库。
            let known = self.tasks.first(where: { $0.id == id })
            guard let known, known.status.isActive else {
                try? FileManager.default.removeItem(at: location)
                self.progressMarks.removeValue(forKey: id)
                self.resumeBaseline.removeValue(forKey: id)
                return
            }

            let fileName = UUID().uuidString + ".movpkg"
            let dest = VideoLibrary.assetsDir.appendingPathComponent(fileName)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let durationSeconds = await self.duration(of: assetDownloadTask, id: id)
                let title = self.pendingTitles[id] ?? assetDownloadTask.urlAsset.url.deletingPathExtension().lastPathComponent
                let item = VideoItem(
                    id: UUID(),
                    title: title,
                    sourceURL: id,
                    fileName: fileName,
                    duration: durationSeconds,
                    fileSize: size,
                    createdAt: Date(),
                    lastPosition: nil
                )
                self.library?.add(item)
                self.finishTask(id: id)
            } catch {
                self.update(id) { $0.status = .failed(error.localizedDescription) }
                self.startNextIfNeeded()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            let id = task.taskDescription ?? ""
            // 用户主动取消（暂停/删除）已由对应方法处理状态，这里不再覆盖
            if (error as NSError).code == NSURLErrorCancelled {
                self.progressMarks.removeValue(forKey: id)
                self.startNextIfNeeded()
            } else {
                self.update(id) { $0.status = .failed(error.localizedDescription); $0.stalled = false }
                self.progressMarks.removeValue(forKey: id)
                self.startNextIfNeeded()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didLoad timeRange: CMTimeRange,
                                totalTimeRangesLoaded loadedRanges: [NSValue],
                                timeRangeExpectedToLoad expectedRange: CMTimeRange) {
        Task { @MainActor in
            let id = assetDownloadTask.taskDescription ?? assetDownloadTask.urlAsset.url.absoluteString
            let loaded = loadedRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
            let total = await self.duration(of: assetDownloadTask, id: id)
            let expected = expectedRange.duration.seconds
            let denominator = total > 0 ? total : (expected > 0 ? expected : 0)
            guard denominator > 0 else { return }
            let progress = min(1.0, loaded / denominator)
            self.progressMarks[id] = CACurrentMediaTime()

            if let baseline = self.resumeBaseline[id], baseline > 0.02 {
                if progress + 0.05 < baseline {
                    self.resumeBaseline.removeValue(forKey: id)
                    self.update(id) { $0.restartedFromZero = true }
                } else if progress >= baseline {
                    self.resumeBaseline.removeValue(forKey: id)
                    self.update(id) { $0.restartedFromZero = false }
                }
            }

            self.update(id) { $0.progress = progress; $0.stalled = false }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Self.backgroundCompletionHandler?()
            Self.backgroundCompletionHandler = nil
        }
    }
}
