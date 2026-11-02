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
    let maxConcurrent = 5
    /// 进度停滞多少秒判定为卡住
    let stallTimeout: CFTimeInterval = 30

    weak var library: VideoLibrary?
    @Published private(set) var tasks: [DownloadTaskInfo] = []

    private var pending: [(url: URL, title: String)] = []
    private var pendingTitles: [String: String] = [:]
    private var durations: [String: Double] = [:]
    private var progressMarks: [String: CFTimeInterval] = [:]
    /// 继续下载时记录的基线进度，用于判断是否从头开始
    private var resumeBaseline: [String: Double] = [:]
    private var stallTimer: Timer?

    private lazy var session: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.local.planem3u8.downloads")
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        Task { @MainActor in
            let all = (try? await self.session.allTasks) ?? []
            for case let task as AVAssetDownloadTask in all {
                guard let desc = task.taskDescription, let url = URL(string: desc) else { continue }
                if !self.tasks.contains(where: { $0.id == desc }) {
                    self.tasks.append(DownloadTaskInfo(id: desc, url: url, title: url.lastPathComponent, progress: 0, status: .downloading))
                }
            }
            self.startNextIfNeeded()
            self.startStallMonitor()
        }
    }

    var activeCount: Int {
        tasks.filter { $0.status.isActive }.count
    }

    // MARK: - 用户操作

    func start(url: URL, title: String) {
        let id = url.absoluteString
        guard !tasks.contains(where: { $0.id == id }) else { return }

        if activeCount < maxConcurrent {
            begin(url: url, title: title)
        } else {
            pending.append((url, title))
            tasks.append(DownloadTaskInfo(id: id, url: url, title: title, progress: 0, status: .queued))
        }
    }

    func pause(_ info: DownloadTaskInfo) {
        switch info.status {
        case .queued:
            pending.removeAll { $0.url.absoluteString == info.id }
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
        if activeCount < maxConcurrent {
            begin(url: info.url, title: info.title)
        } else {
            pending.append((info.url, info.title))
        }
    }

    /// 彻底移除任务（不写入视频库）
    func remove(_ info: DownloadTaskInfo) {
        pending.removeAll { $0.url.absoluteString == info.id }
        tasks.removeAll { $0.id == info.id }
        pendingTitles.removeValue(forKey: info.id)
        durations.removeValue(forKey: info.id)
        progressMarks.removeValue(forKey: info.id)
        cancelSessionTask(id: info.id)
        startNextIfNeeded()
    }

    // MARK: - 队列调度

    private func begin(url: URL, title: String) {
        let id = url.absoluteString
        let asset = AVURLAsset(url: url)
        guard let task = session.makeAssetDownloadTask(asset: asset,
                                                       assetTitle: title,
                                                       assetArtworkData: nil,
                                                       options: nil) else { return }
        task.taskDescription = id
        pendingTitles[id] = title
        progressMarks[id] = CACurrentMediaTime()

        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].status = .downloading
            tasks[index].stalled = false
        } else {
            tasks.append(DownloadTaskInfo(id: id, url: url, title: title, progress: 0, status: .downloading))
        }
        task.resume()
    }

    private func startNextIfNeeded() {
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
