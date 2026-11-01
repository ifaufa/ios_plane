import Foundation
import AVFoundation

struct DownloadTaskInfo: Identifiable, Equatable {
    let id: String            // 以源 URL 字符串作为标识
    let url: URL
    var title: String
    var progress: Double      // 0...1
    var status: Status

    enum Status: Equatable {
        case downloading
        case failed(String)
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    /// 后台传输完成后由 AppDelegate 回填，事件处理完后调用
    static var backgroundCompletionHandler: (() -> Void)?

    weak var library: VideoLibrary?
    @Published private(set) var tasks: [DownloadTaskInfo] = []

    /// taskDescription（源 URL）-> 标题，跨进程重启仍可查
    private var pendingTitles: [String: String] = [:]
    private var durations: [String: Double] = [:]

    private lazy var session: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.local.planem3u8.downloads")
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        // 应用重启后恢复仍在进行的后台任务
        Task { @MainActor in
            let all = (try? await self.session.allTasks) ?? []
            for case let task as AVAssetDownloadTask in all {
                guard let desc = task.taskDescription, let url = URL(string: desc) else { continue }
                if !self.tasks.contains(where: { $0.id == desc }) {
                    self.tasks.append(DownloadTaskInfo(id: desc, url: url, title: url.lastPathComponent, progress: 0, status: .downloading))
                }
            }
        }
    }

    var isBusy: Bool {
        tasks.contains { $0.status == .downloading }
    }

    func start(url: URL, title: String) {
        let id = url.absoluteString
        guard !tasks.contains(where: { $0.id == id }) else { return }
        let asset = AVURLAsset(url: url)
        guard let task = session.makeAssetDownloadTask(asset: asset, assetTitle: title, assetArtworkData: nil, options: nil) else { return }
        task.taskDescription = id
        pendingTitles[id] = title
        tasks.append(DownloadTaskInfo(id: id, url: url, title: title, progress: 0, status: .downloading))
        task.resume()
    }

    func cancel(_ info: DownloadTaskInfo) {
        Task { @MainActor in
            let all = (try? await self.session.allTasks) ?? []
            for case let task as AVAssetDownloadTask in all where task.taskDescription == info.id {
                task.cancel()
            }
            self.tasks.removeAll { $0.id == info.id }
        }
    }

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
    }
}

// MARK: - AVAssetDownloadDelegate

extension DownloadManager: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            let id = assetDownloadTask.taskDescription ?? assetDownloadTask.urlAsset.url.absoluteString
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
                    createdAt: Date()
                )
                self.library?.add(item)
                self.finishTask(id: id)
            } catch {
                self.update(id) { $0.status = .failed(error.localizedDescription) }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }   // 成功路径由 didFinishDownloadingTo 处理
        Task { @MainActor in
            let id = task.taskDescription ?? ""
            if (error as NSError).code == NSURLErrorCancelled {
                self.finishTask(id: id)
            } else {
                self.update(id) { $0.status = .failed(error.localizedDescription) }
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
            self.update(id) { $0.progress = progress }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Self.backgroundCompletionHandler?()
            Self.backgroundCompletionHandler = nil
        }
    }
}
