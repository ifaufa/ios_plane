import Foundation
import Combine

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
    /// 断点起始分片索引（时间轴不连续处）
    var discontinuities: [Int]? = nil
    /// 断点处更换密钥的分片索引
    var keyChanges: [Int]? = nil
    /// 被判定为插入内容而剔除的分片索引
    var excluded: [Int]? = nil
}

/// 分片下载引擎：后台 URLSession + 全局 8 / 每任务 4 并发 + 断点续传
@MainActor
final class SegmentRunner: NSObject, ObservableObject {
    static let shared = SegmentRunner()

    /// 剔除插入内容后的用户提示（UI 监听）
    @Published var excludedNotice: String?

    static let perTaskKey = "segments.perTask"
    static let globalKey = "segments.global"
    static let maxRetry = 5

    /// 每任务并发（可选 4/6/8/10，默认 8）
    static var perJobConcurrency: Int {
        let value = UserDefaults.standard.integer(forKey: perTaskKey)
        return value > 0 ? value : 8
    }

    /// 全局并发（可选 8/12/16/20/32，默认 20）
    static var globalConcurrency: Int {
        let value = UserDefaults.standard.integer(forKey: globalKey)
        return value > 0 ? value : 20
    }

    /// 写入节流：累计 5 个分片或超过 2 秒才落盘
    private var pendingWrites: [String: Int] = [:]
    private var lastPersist: [String: Date] = [:]
    private var speedSamples: [String: [(time: Date, bytes: Int64)]] = [:]
    private var jobBytes: [String: Int64] = [:]

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

    /// 当前下载速度（字节/秒）
    func speed(of id: String) -> Double {
        guard let samples = speedSamples[id], let first = samples.first, let last = samples.last, samples.count > 1 else {
            return 0
        }
        let elapsed = last.time.timeIntervalSince(first.time)
        guard elapsed > 0.2 else { return 0 }
        return Double(last.bytes - first.bytes) / elapsed
    }

    func totalBytes(of id: String) -> Int64 { jobBytes[id] ?? 0 }

    /// 任务 ID（完整 URL，含 : 和 /）不能直接当目录名，用哈希
    static func directoryName(for id: String) -> String {
        String(MediaCrypto.sha256Hex(Data(id.utf8)).prefix(24))
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }

    /// 清理同一任务的旧工作目录（历史残留可能污染合并结果）
    static func cleanupOldDirectories(for id: String) {
        let fm = FileManager.default
        let root = workRoot
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let stateURL = entry.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: stateURL),
                  let state = try? decoder().decode(SegmentJobState.self, from: data) else { continue }
            if state.id == id { try? fm.removeItem(at: entry) }
        }
    }

    // MARK: - 对外接口

    /// 启动分片下载（第一次调用会拉取并解析播放列表）
    func start(id: String, title: String, url: URL) {
        guard jobs[id] == nil else { return }
        Task { @MainActor in
            do {
                DiagnosticsLog.write("[1 播放列表] 开始解析 \(url.absoluteString)")
                let playlist = try await PlaylistParser.load(url)
                DiagnosticsLog.write("[2 结构] 段数=\(playlist.segments.count) 时长=\(String(format: "%.1f", playlist.totalDuration))s 容器=\(playlist.initSegment != nil ? "mp4" : "ts") 有MAP=\(playlist.initSegment != nil) 加密=\(playlist.key != nil) keyURI=\(playlist.key?.uri.absoluteString ?? "-") IV=\(playlist.key?.iv.map { DiagnosticsLog.hexPrefix($0, count: 16) } ?? "-")")
                guard !playlist.isDRM else { throw PlaylistError.drmProtected }

                // 每次新建独立目录（带时间戳），避免复用旧目录导致分片混入
                let dirName = Self.directoryName(for: id) + "-" + Self.stamp()
                Self.cleanupOldDirectories(for: id)
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
                    failure: nil,
                    discontinuities: playlist.discontinuities,
                    keyChanges: playlist.keyChanges,
                    excluded: nil
                )
                state.updatedAt = Date()
                jobs[id] = state
                dirs[id] = dir
                // 关键：taskDescription 用的是 directoryName(id)（无时间戳后缀），
                // 映射键必须一致，否则新任务下载的分片会被静默丢弃
                hashToID[Self.directoryName(for: id)] = id
                persist(id)

                // 有 init 段（fMP4）时先下它
                if let initURL = playlist.initSegment {
                    try await downloadInitSegment(url: initURL, dir: dir)
                }
                pump()
            } catch {
                DiagnosticsLog.write("[1 播放列表] 失败：\(error.localizedDescription)")
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

        if job.completed.count >= job.segmentURLs.count, !finishing.contains(id) {
            // 分片已下满但收尾失败过：直接重跑收尾，而不是傻等新分片
            finishing.insert(id)
            finish(id)
        } else {
            pump()
        }
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
            // 注意：不能因为"分片已下满"就跳过——那通常意味着收尾失败，仍需恢复出来重新收尾

            let sourceDir = stateURL.deletingLastPathComponent()

            var resumed = state
            resumed.paused = true
            resumed.failure = nil
            jobs[state.id] = resumed
            dirs[state.id] = sourceDir
            hashToID[Self.directoryName(for: state.id)] = state.id
            persist(state.id)
            result.append(resumed)
        }
        return result
    }

    func state(of id: String) -> SegmentJobState? { jobs[id] }

    /// 后台唤醒时先恢复任务映射，否则回调找不到对应任务会把分片丢掉
    func prepareForBackgroundEvents() {
        guard jobs.isEmpty else { return }
        _ = restore()
    }

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

    private func markCompleted(jobId: String, index: Int, bytes: Int64) {
        guard var job = jobs[jobId] else { return }
        if !job.completed.contains(index) {
            job.completed.append(index)
            job.completed.sort()
        }
        jobs[jobId] = job

        jobBytes[jobId, default: 0] += bytes
        var samples = speedSamples[jobId] ?? []
        samples.append((Date(), jobBytes[jobId] ?? 0))
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
        speedSamples[jobId] = samples

        // 写入节流：每 5 个分片或超过 2 秒落盘一次
        pendingWrites[jobId, default: 0] += 1
        let lastWrite = lastPersist[jobId] ?? .distantPast
        if pendingWrites[jobId, default: 0] >= 5 || Date().timeIntervalSince(lastWrite) > 2 {
            pendingWrites[jobId] = 0
            lastPersist[jobId] = Date()
            persist(jobId)
        }

        let total = job.segmentURLs.count
        let progress = total > 0 ? Double(job.completed.count) / Double(total) : 0
        onProgress?(jobId, progress)

        if job.completed.count == total, !finishing.contains(jobId) {
            finishing.insert(jobId)
            persist(jobId)
            finish(jobId)
        }
    }

    private func finish(_ jobId: String) {
        guard let dir = dirs[jobId], var job = jobs[jobId] else { return }
        DiagnosticsLog.write("[5 分片完成] \(job.completed.count)/\(job.segmentURLs.count) 累计=\(jobBytes[jobId] ?? 0)B 目录=\(dir.lastPathComponent)")

        // 断点插入内容识别（S1 默认；S2 可选剔除换密钥的区间）
        if let discontinuities = job.discontinuities, !discontinuities.isEmpty {
            let dropKeyChanged = UserDefaults.standard.bool(forKey: AdFilter.dropKeyChangedKey)
            let useFingerprint = UserDefaults.standard.bool(forKey: AdFilter.fingerprintKey)
            let result = AdFilter.analyze(state: job, dir: dir, dropKeyChanged: dropKeyChanged, useFingerprint: useFingerprint)
            job.excluded = result.excluded.isEmpty ? nil : result.excluded
            jobs[jobId] = job
            persist(jobId)
            if result.excluded.isEmpty {
                DiagnosticsLog.write("[5 断点] 检出 \(discontinuities.count) 处断点，未发现插入内容")
            } else {
                DiagnosticsLog.write("[5 断点] 剔除 \(result.excluded.count) 个分片：\(result.descriptions.joined(separator: "，"))")
                excludedNotice = "已剔除 \(result.excluded.count) 个分片（广告段）"
            }
        }

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
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        DiagnosticsLog.write("[3 密钥] 请求 \(keyURI) 状态=\(status) 字节数=\(data.count) 头=\(DiagnosticsLog.hexPrefix(data))")
        guard (200..<300).contains(status), data.count == 16 else {
            throw PlaylistError.network("获取解密密钥失败（HTTP \(status)，返回 \(data.count) 字节）")
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

        // 系统给的临时文件只在本次回调内有效，必须先同步搬走，之后才能异步处理
        let staging: URL
        do {
            let fm = FileManager.default
            let target = fm.temporaryDirectory.appendingPathComponent("plane-seg-\(UUID().uuidString).bin")
            try fm.moveItem(at: location, to: target)
            staging = target
        } catch {
            Task { @MainActor in
                guard let jobId = self.hashToID[hash] else { return }
                self.handleFailure(jobId: jobId,
                                   index: index,
                                   message: "临时文件已失效：\(error.localizedDescription)",
                                   taskId: downloadTask.taskIdentifier)
            }
            return
        }

        Task {
            guard let jobId = await MainActor.run(body: { self.hashToID[hash] }) else {
                DiagnosticsLog.write("[4 分片] 未找到任务映射 hash=\(hash) 已丢弃该分片")
                try? FileManager.default.removeItem(at: staging)
                return
            }
            let dir = await MainActor.run { self.dirs[jobId] }
            guard let dir else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            let key = try? await self.keyData(jobId: jobId)
            let iv = await MainActor.run { self.iv(for: jobId, index: index) }

            do {
                // 解密与写盘放在后台执行，避免阻塞主线程（并发高时这是主要瓶颈）
                var data = try Data(contentsOf: staging, options: .mappedIfSafe)
                try? FileManager.default.removeItem(at: staging)
                let rawPrefix = DiagnosticsLog.hexPrefix(data)
                let rawCount = data.count

                if let key {
                    guard let plain = MediaCrypto.decrypt(data: data, key: key, iv: iv) else {
                        DiagnosticsLog.write("[4 分片] #\(index) 解密失败 原始=\(rawCount)B 头=\(rawPrefix)")
                        throw PlaylistError.network("分片解密失败")
                    }
                    data = plain
                }
                if index < 3 {
                    DiagnosticsLog.write("[4 分片] #\(index) 原始=\(rawCount)B 解前头=\(rawPrefix) 解后=\(data.count)B 头=\(DiagnosticsLog.hexPrefix(data)) key=\(key == nil ? "无" : "有")")
                }
                let fileURL = dir.appendingPathComponent(String(format: "seg-%06d.ts", index))
                try data.write(to: fileURL, options: .atomic)
                let bytes = Int64(data.count)

                await MainActor.run {
                    self.activeTasks.removeValue(forKey: downloadTask.taskIdentifier)
                    self.retries.removeValue(forKey: "\(jobId)#\(index)")
                    self.markCompleted(jobId: jobId, index: index, bytes: bytes)
                    self.pump()
                }
            } catch {
                await MainActor.run {
                    self.handleFailure(jobId: jobId,
                                       index: index,
                                       message: error.localizedDescription,
                                       taskId: downloadTask.taskIdentifier)
                }
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

        DiagnosticsLog.write("[! 分片失败] #\(index) 第\(attempt)次 \(message)")

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
