import Foundation

/// 分片任务落盘状态（支持杀进程后续传）
struct SegmentJobState: Codable {
    var id: String
    var title: String
    var sourceURL: String
    var container: String        // ts | mp4
    var segmentURLs: [String]
    var durations: [Double]
    var completed: [Int]
    var mediaSequence: Int
    var totalDuration: Double
    var createdAt: Date
    var updatedAt: Date
    var initURL: String?
    var keyURI: String?
    var keyIV: String?
    var paused: Bool
    var failure: String?
}

/// 分片下载引擎：后台 URLSession + 全局 8 / 每任务 4 并发 + 断点续传
@MainActor
final class SegmentRunner: NSObject, ObservableObject {
    static let shared = SegmentRunner()

    static let globalConcurrency = 8
    static let perJobConcurrency = 4
    static let maxRetry = 5

    /// 进度回调（jobId, 0...1）
    var onProgress: ((String, Double) -> Void)?
    /// 全部分片下载完成的回调（jobId, 分片目录）
    var onAllSegmentsDownloaded: ((String, URL) -> Void)?
    /// 失败回调
    var onFailure: ((String, String) -> Void)?

    private var jobs: [String: SegmentJobState] = [:]
    private var dirs: [String: URL] = [:]
    /// 目录名（哈希）-> 任务 ID，用于任务回调反查
    private var hashToID: [String: String] = [:]
    private var activeTasks: [Int: (jobId: String, index: Int)] = [:]
    private var retries: [String: Int] = [:]          // "jobId#index" -> 次数
    private var keyCache: [String: Data] = [:]
    private var finishing: Set<String> = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.local.planem3u8.segments")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static var workRoot: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DownloadWork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override init() {
        super.init()
        _ = session
    }

    var activeSegmentCount: Int { activeTasks.count }

    /// 任务 ID（完整 URL，含 : 和 /）不能直接当目录名，用哈希
    static func directoryName(for id: String) -> String {
        String(MediaCrypto.sha256Hex(Data(id.utf8)).prefix(24))
    }

    // MARK: - 对外接口

    /// 启动分片下载（第一次调用会拉取并解析播放列表）
    func start(id: String, title: String, url: URL) {
        guard jobs[id] == nil else { return }
        Task { @MainActor in
            do {
                let playlist = try await PlaylistParser.load(url)
                guard !playlist.isDRM else { throw PlaylistError.drmProtected }

                let dirName = Self.directoryName(for: id)
                let dir = Self.workRoot.appendingPathComponent(dirName, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                var state = SegmentJobState(
                    id: id,
                    title: title,
                    sourceURL: url.absoluteString,
                    container: playlist.initSegment != nil ? "mp4" : "ts",
                    segmentURLs: playlist.segments.map { $0.url.absoluteString },
                    durations: playlist.segments.map { $0.duration },
                    completed: [],
                    mediaSequence: playlist.mediaSequence,
                    totalDuration: playlist.totalDuration,
                    createdAt: Date(),
                    updatedAt: Date(),
                    initURL: playlist.initSegment?.absoluteString,
                    keyURI: playlist.key?.uri.absoluteString,
                    keyIV: playlist.key?.iv?.base64EncodedString(),
                    paused: false,
                    failure: nil
                )
                state.updatedAt = Date()
                jobs[id] = state
                dirs[id] = dir
                hashToID[dirName] = id
                persist(id)

                // 有 init 段（fMP4）时先下它
                if let initURL = playlist.initSegment {
                    try await downloadInitSegment(url: initURL, dir: dir)
                }
                pump()
            } catch {
                onFailure?(id, error.localizedDescription)
            }
        }
    }

    func pause(_ id: String) {
        guard var job = jobs[id] else { return }
        job.paused = true
        jobs[id] = job
        persist(id)
        cancelActive(for: id)
    }

    func resume(_ id: String) {
        guard var job = jobs[id] else { return }
        job.paused = false
        job.failure = nil
        jobs[id] = job
        persist(id)
        pump()
    }

    func remove(_ id: String) {
        cancelActive(for: id)
        jobs.removeValue(forKey: id)
        if let dir = dirs.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: dir)
        }
        keyCache.removeValue(forKey: id)
        hashToID.removeValue(forKey: Self.directoryName(for: id))
    }

    /// 重启后恢复未完成任务（递归扫描，兼容旧版本把 URL 当目录名产生的嵌套结构）
    func restore() -> [SegmentJobState] {
        let fm = FileManager.default
        let root = Self.workRoot
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }

        var stateFiles: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "state.json" {
            stateFiles.append(url)
        }

        var result: [SegmentJobState] = []
        for stateURL in stateFiles {
            guard let data = try? Data(contentsOf: stateURL),
                  let state = try? Self.decoder().decode(SegmentJobState.self, from: data) else { continue }
            guard state.completed.count < state.segmentURLs.count else { continue }

            let sourceDir = stateURL.deletingLastPathComponent()
            let dirName = Self.directoryName(for: state.id)
            let targetDir = root.appendingPathComponent(dirName, isDirectory: true)

            // 旧目录结构（如 DownloadWork/https:/host/x.m3u8）迁移到哈希目录
            if sourceDir.standardizedFileURL.path != targetDir.standardizedFileURL.path {
                if fm.fileExists(atPath: targetDir.path) {
                    try? fm.removeItem(at: targetDir)
                }
                try? fm.moveItem(at: sourceDir, to: targetDir)
            }

            var resumed = state
            resumed.paused = true
            resumed.failure = nil
            jobs[state.id] = resumed
            dirs[state.id] = targetDir
            hashToID[dirName] = state.id
            persist(state.id)
            result.append(resumed)
        }
        return result
    }

    func state(of id: String) -> SegmentJobState? { jobs[id] }

    /// 成功后释放内存状态（不删除磁盘目录，目录已由调用方移走）
    func release(_ id: String) {
        jobs.removeValue(forKey: id)
        dirs.removeValue(forKey: id)
        keyCache.removeValue(forKey: id)
        hashToID.removeValue(forKey: Self.directoryName(for: id))
        retries = retries.filter { !$0.key.hasPrefix("\(id)#") }
    }

    // MARK: - 调度

    private func pump() {
        guard activeTasks.count < Self.globalConcurrency else { return }
        for (id, job) in jobs where !job.paused && job.failure == nil {
            guard !finishing.contains(id) else { continue }
            let jobActive = activeTasks.values.filter { $0.jobId == id }.count
            guard jobActive < Self.perJobConcurrency else { continue }

            let done = Set(job.completed)
            let pending = job.segmentURLs.indices.filter { !done.contains($0) && !isActive(id: id, index: $0) }
            for index in pending {
                guard activeTasks.count < Self.globalConcurrency else { return }
                guard activeTasks.values.filter({ $0.jobId == id }).count < Self.perJobConcurrency else { break }
                startSegment(jobId: id, index: index, urlString: job.segmentURLs[index])
            }
        }
    }

    private func isActive(id: String, index: Int) -> Bool {
        activeTasks.values.contains { $0.jobId == id && $0.index == index }
    }

    private func startSegment(jobId: String, index: Int, urlString: String) {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        for (key, value) in RequestSettings.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(Self.directoryName(for: jobId))#\(index)"
        activeTasks[task.taskIdentifier] = (jobId, index)
        task.resume()
    }

    private func cancelActive(for id: String) {
        let prefix = "\(Self.directoryName(for: id))#"
        session.getAllTasks { tasks in
            for task in tasks where (task.taskDescription ?? "").hasPrefix(prefix) {
                task.cancel()
            }
        }
    }

    // MARK: - 落盘

    private func persist(_ id: String) {
        guard var job = jobs[id], let dir = dirs[id] else { return }
        job.updatedAt = Date()
        jobs[id] = job
        guard let data = try? Self.encoder().encode(job) else { return }
        try? data.write(to: dir.appendingPathComponent("state.json"), options: .atomic)
    }

    private func markCompleted(jobId: String, index: Int) {
        guard var job = jobs[jobId] else { return }
        if !job.completed.contains(index) {
            job.completed.append(index)
            job.completed.sort()
        }
        jobs[jobId] = job
        persist(jobId)

        let total = job.segmentURLs.count
        let progress = total > 0 ? Double(job.completed.count) / Double(total) : 0
        onProgress?(jobId, progress)

        if job.completed.count == total, !finishing.contains(jobId) {
            finishing.insert(jobId)
            finish(jobId)
        }
    }

    private func finish(_ jobId: String) {
        guard let dir = dirs[jobId], let job = jobs[jobId] else { return }
        do {
            let playlistURL = try LocalHLS.writePlaylist(state: job, dir: dir)
            onAllSegmentsDownloaded?(jobId, playlistURL)
        } catch {
            jobs[jobId]?.failure = error.localizedDescription
            persist(jobId)
            onFailure?(jobId, error.localizedDescription)
        }
        finishing.remove(jobId)
    }

    // MARK: - 工具

    private func downloadInitSegment(url: URL, dir: URL) async throws {
        var request = URLRequest(url: url)
        for (key, value) in RequestSettings.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlaylistError.network("init 片段下载失败")
        }
        try data.write(to: dir.appendingPathComponent("init.mp4"), options: .atomic)
    }

    fileprivate func keyData(jobId: String) async throws -> Data? {
        guard let job = jobs[jobId], let keyURI = job.keyURI, let url = URL(string: keyURI) else { return nil }
        if let cached = keyCache[jobId] { return cached }
        var request = URLRequest(url: url)
        for (key, value) in RequestSettings.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count == 16 else {
            throw PlaylistError.network("获取解密密钥失败")
        }
        keyCache[jobId] = data
        return data
    }

    fileprivate func iv(for jobId: String, index: Int) -> Data {
        if let encoded = jobs[jobId]?.keyIV, let data = Data(base64Encoded: encoded), data.count == 16 {
            return data
        }
        let sequence = (jobs[jobId]?.mediaSequence ?? 0) + index
        return PlaylistParser.defaultIV(sequence: sequence)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - URLSession 回调

extension SegmentRunner: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let description = downloadTask.taskDescription ?? ""
        let parts = description.split(separator: "#")
        guard parts.count == 2,
              let index = Int(parts[1]) else { return }
        let hash = String(parts[0])

        Task { @MainActor in
            guard let jobId = self.hashToID[hash], let dir = self.dirs[jobId] else { return }
            do {
                var data = try Data(contentsOf: location, options: .mappedIfSafe)
                if let key = try await self.keyData(jobId: jobId) {
                    let iv = self.iv(for: jobId, index: index)
                    guard let plain = MediaCrypto.decrypt(data: data, key: key, iv: iv) else {
                        throw PlaylistError.network("分片解密失败")
                    }
                    data = plain
                }
                let fileURL = dir.appendingPathComponent(String(format: "seg-%06d.ts", index))
                try data.write(to: fileURL, options: .atomic)
                self.activeTasks.removeValue(forKey: downloadTask.taskIdentifier)
                self.retries.removeValue(forKey: "\(jobId)#\(index)")
                self.markCompleted(jobId: jobId, index: index)
                self.pump()
            } catch {
                self.handleFailure(jobId: jobId, index: index, message: error.localizedDescription, taskId: downloadTask.taskIdentifier)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let description = task.taskDescription ?? ""
        let parts = description.split(separator: "#")
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        let hash = String(parts[0])

        Task { @MainActor in
            if (error as NSError).code == NSURLErrorCancelled {
                self.activeTasks.removeValue(forKey: task.taskIdentifier)
                return
            }
            guard let jobId = self.hashToID[hash] else { return }
            self.handleFailure(jobId: jobId, index: index, message: error.localizedDescription, taskId: task.taskIdentifier)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Self.backgroundCompletion?()
            Self.backgroundCompletion = nil
        }
    }

    static var backgroundCompletion: (() -> Void)?
}

private extension SegmentRunner {
    func handleFailure(jobId: String, index: Int, message: String, taskId: Int) {
        activeTasks.removeValue(forKey: taskId)
        let key = "\(jobId)#\(index)"
        let attempt = (retries[key] ?? 0) + 1
        retries[key] = attempt

        if attempt > Self.maxRetry {
            jobs[jobId]?.failure = "分片 \(index + 1) 下载失败：\(message)"
            if let id = jobs[jobId]?.id { persist(id) }
            onFailure?(jobId, jobs[jobId]?.failure ?? message)
            return
        }

        let delay = min(8.0, pow(2.0, Double(attempt - 1)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let job = self.jobs[jobId], !job.paused, job.failure == nil else { return }
            self.pump()
        }
    }
}
