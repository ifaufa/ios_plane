import Foundation
import Network

/// 极简本地 HTTP 服务：把分片目录按标准 HLS 提供给 AVPlayer（仅监听 127.0.0.1）
final class LocalHTTPServer {
    static let shared = LocalHTTPServer()

    private var listener: NWListener?
    private var root: URL?
    private(set) var port: UInt16?
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
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

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
        self.listener = listener
        self.root = newRoot
        self.port = assignedPort
        DiagnosticsLog.write("[本地服务] 已启动 端口=\(assignedPort) 根目录=\(newRoot.lastPathComponent)")
        return assignedPort
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
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        path = path.removingPercentEncoding ?? path
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.contains("..") else {
            send(status: "404 Not Found", headers: [:], body: Data(), to: connection)
            return
        }

        let fileURL = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            DiagnosticsLog.write("[本地服务] 404 \(name)")
            send(status: "404 Not Found", headers: [:], body: Data(), to: connection)
            return
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
            DiagnosticsLog.write("[本地服务] \(method) \(name) 206 \(sub.count)B")
            send(status: "206 Partial Content",
                 headers: [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)",
                    "Content-Length": "\(sub.count)"
                 ],
                 body: isHead ? Data() : sub, to: connection)
        } else {
            DiagnosticsLog.write("[本地服务] \(method) \(name) 200 \(data.count)B")
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
