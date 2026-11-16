import Foundation
import Network

/// 极简本地 HTTP 服务：把分片目录按标准 HLS 提供给 AVPlayer（仅监听 127.0.0.1）
final class LocalHTTPServer {
    static let shared = LocalHTTPServer()

    private var listener: NWListener?
    private var root: URL?
    private(set) var port: UInt16?
    /// 一次性访问令牌（AirPlay 时电视需带此参数，防止同网段他人访问）
    private(set) var token: String = ""
    private let queue = DispatchQueue(label: "local.http.server")

    /// 允许多实例：每个 root 独立端口，互不干扰（播放 / 校验 / 转换各用各的）
    init() {}

    /// 启动或复用服务；root 变化会重启
    @discardableResult
    func start(root newRoot: URL) throws -> UInt16 {
        if let port, let root, root.standardizedFileURL == newRoot.standardizedFileURL,
           listener != nil {
            return port
        }
        stop()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 不再限定 127.0.0.1：改为监听所有接口，便于 AirPlay 时电视访问局域网地址。
        // 通过一次性 token 限制访问，token 不匹配直接 403。

        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var assignedPort: UInt16?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                assignedPort = listener.port?.rawValue
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, root: newRoot)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)

        guard let assignedPort else {
            listener.cancel()
            throw NSError(domain: "LocalHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "本地服务启动失败"])
        }
        self.token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
        self.listener = listener
        self.root = newRoot
        self.port = assignedPort
        DiagnosticsLog.write("[本地服务] 已启动 端口=\(assignedPort) 根目录=\(newRoot.lastPathComponent)")
        return assignedPort
    }

    // MARK: - 请求统计（供播放诊断使用）

    private let statsLock = NSLock()
    private var _requestCount = 0
    private var _lastRequestAt: Date?

    var requestCount: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return _requestCount
    }

    var secondsSinceLastRequest: TimeInterval? {
        statsLock.lock(); defer { statsLock.unlock() }
        guard let _lastRequestAt else { return nil }
        return Date().timeIntervalSince(_lastRequestAt)
    }

    private func noteRequest(_ message: String) {
        statsLock.lock()
        _requestCount += 1
        _lastRequestAt = Date()
        statsLock.unlock()
        DiagnosticsLog.write(message)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        root = nil
    }

    var isRunning: Bool { port != nil }

    // MARK: - 请求处理

    private func handle(_ connection: NWConnection, root: URL) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), root: root)
    }

    private func receive(on connection: NWConnection, buffer: Data, root: URL) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let headerRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: accumulated[..<headerRange.lowerBound], as: UTF8.self)
                self.respond(to: connection, header: header, root: root)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated, root: root)
        }
    }

    /// 判断连接是否来自本机回环
    private func isLoopback(_ connection: NWConnection) -> Bool {
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case .ipv4(let address): return address == .loopback
            case .ipv6(let address): return address == .loopback
            default: return false
            }
        }
        return false
    }

    /// 手机在局域网中的 IPv4 地址（无 Wi-Fi 时返回 nil）
    static func lanIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var result: String?
        var cursor = first
        while true {
            let flags = Int32(cursor.pointee.ifa_flags)
            if let addr = cursor.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: cursor.pointee.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let value = String(cString: host)
                        if !value.isEmpty, !value.hasPrefix("169.254") {
                            result = value
                            break
                        }
                    }
                }
            }
            guard let next = cursor.pointee.ifa_next else { break }
            cursor = next
        }
        return result
    }
    /// 给播放列表中的 URI 注入 token：
    /// - 媒体行：seg-000001.ts  → seg-000001.ts?t=xxx
    /// - 标签属性：URI="key.bin" → URI="key.bin?t=xxx"
    private func rewritePlaylist(_ text: String, token: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for raw in lines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                output.append(line)
                continue
            }
            if trimmed.hasPrefix("#") {
                output.append(appendTokenToTag(line, token: token))
                continue
            }
            output.append(appendTokenToURI(line, token: token))
        }
        return output.joined(separator: "\n")
    }

    private func appendTokenToTag(_ line: String, token: String) -> String {
        guard line.contains("URI=\"") else { return line }
        guard let regex = try? NSRegularExpression(pattern: "URI=\"([^\"]+)\"") else { return line }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var result = line
        let matches = regex.matches(in: line, range: range).reversed()
        for match in matches {
            guard match.numberOfRanges > 1,
                  let uriRange = Range(match.range(at: 1), in: result) else { continue }
            let value = String(result[uriRange])
            guard !value.contains("t=") else { continue }
            let separator = value.contains("?") ? "&" : "?"
            result.replaceSubrange(uriRange, with: value + "\(separator)t=\(token)")
        }
        return result
    }

    private func appendTokenToURI(_ line: String, token: String) -> String {
        guard !line.contains("t=") else { return line }
        let separator = line.contains("?") ? "&" : "?"
        return line + "\(separator)t=\(token)"
    }
    private func respond(to connection: NWConnection, header: String, root: URL) {
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", headers: [:], body: Data(), to: connection)
            return
        }
        let method = String(parts[0]).uppercased()
        var path = String(parts[1])

        // 访问控制：本机回环直接放行；局域网访问必须带正确 token（AirPlay 时电视使用局域网地址）
        let rawTarget = path
        if !isLoopback(connection), !token.isEmpty, !rawTarget.contains("t=\(token)") {
            noteRequest("[本地服务] 403 缺少令牌 \(rawTarget)")
            send(status: "403 Forbidden", headers: [:], body: Data(), to: connection)
            return
        }

        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        path = path.removingPercentEncoding ?? path
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.contains("..") else {
            send(status: "404 Not Found", headers: [:], body: Data(), to: connection)
            return
        }

        let fileURL = root.appendingPathComponent(name)
        guard var data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            noteRequest("[本地服务] 404 \(name)")
            send(status: "404 Not Found", headers: [:], body: Data(), to: connection)
            return
        }

        // 播放列表改写：把一次性 token 注入到每个分片/密钥/初始化段 URI 中。
        // AVPlayer 解析相对路径时不会继承播放列表的 query，若不注入，分片请求会缺 token 被 403。
        if !token.isEmpty, name.lowercased().hasSuffix(".m3u8"),
           let text = String(data: data, encoding: .utf8) {
            let rewritten = rewritePlaylist(text, token: token)
            if let encoded = rewritten.data(using: .utf8) {
                data = encoded
            }
        }

        var rangeHeader: String?
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                rangeHeader = String(line.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        let contentType = mimeType(for: name)
        let isHead = method == "HEAD"

        if let rangeHeader, let range = parseRange(rangeHeader, total: data.count) {
            let sub = data.subdata(in: range)
            noteRequest("[本地服务] \(method) \(name) 206 \(sub.count)B")
            send(status: "206 Partial Content",
                 headers: [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)",
                    "Content-Length": "\(sub.count)"
                 ],
                 body: isHead ? Data() : sub, to: connection)
        } else {
            noteRequest("[本地服务] \(method) \(name) 200 \(data.count)B")
            send(status: "200 OK",
                 headers: [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Length": "\(data.count)"
                 ],
                 body: isHead ? Data() : data, to: connection)
        }
    }

    private func send(status: String, headers: [String: String], body: Data, to connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Connection: close\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let start = Int(parts[0]) ?? 0
        let endPart = parts[1].trimmingCharacters(in: .whitespaces)
        let end = endPart.isEmpty ? total - 1 : (Int(endPart) ?? total - 1)
        let lower = max(0, min(start, total))
        let upper = max(lower, min(end + 1, total))
        guard lower < upper else { return nil }
        return lower..<upper
    }

    private func mimeType(for name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".mp4") { return "video/mp4" }
        return "video/mp2t"
    }
}
