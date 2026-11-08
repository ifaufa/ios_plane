import Foundation

struct MediaSegment: Hashable {
    var url: URL
    var duration: Double
}

struct MediaKey: Hashable {
    var method: String
    var uri: URL
    var iv: Data?
}

struct ParsedMediaPlaylist {
    var segments: [MediaSegment]
    var key: MediaKey?
    var initSegment: URL?
    var endList: Bool
    var hasDiscontinuity: Bool
    var hasByteRange: Bool
    var mediaSequence: Int
    var targetDuration: Double

    var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    var isEncrypted: Bool { key != nil }
    var isDRM: Bool { (key?.method.uppercased() ?? "").contains("SAMPLE-AES") }
}

enum PlaylistError: LocalizedError {
    case notPlaylist(String)
    case liveStream
    case drmProtected
    case byteRangeUnsupported
    case discontinuityUnsupported
    case empty
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notPlaylist(let detail): return "不是有效的 m3u8 播放列表（\(detail)）"
        case .liveStream: return "这是直播流，分片引擎不支持"
        case .drmProtected: return "受 DRM 保护（SAMPLE-AES），无法下载"
        case .byteRangeUnsupported: return "使用了 BYTERANGE 单文件多段，暂不支持"
        case .discontinuityUnsupported: return "包含 DISCONTINUITY 结构，暂不支持"
        case .empty: return "播放列表里没有分片"
        case .network(let detail): return "拉取播放列表失败：\(detail)"
        }
    }
}

enum PlaylistParser {
    static let maxPlaylistBytes = 4 * 1024 * 1024

    /// 拉取并解析（自动跟随 master playlist，选最高码率）
    static func load(_ url: URL) async throws -> ParsedMediaPlaylist {
        let text = try await fetch(url)
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = bestVariant(in: text, baseURL: url) else {
                throw PlaylistError.notPlaylist("主列表里没有可用码率")
            }
            let variantText = try await fetch(variant)
            return try parseMedia(variantText, baseURL: variant, origin: url)
        }
        return try parseMedia(text, baseURL: url, origin: url)
    }

    static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (key, value) in RequestSettings.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw PlaylistError.network("HTTP \(code)")
            }
            guard data.count <= maxPlaylistBytes else {
                throw PlaylistError.notPlaylist("播放列表过大")
            }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        } catch let error as PlaylistError {
            throw error
        } catch {
            throw PlaylistError.network(error.localizedDescription)
        }
    }

    static func bestVariant(in text: String, baseURL: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        var pendingBandwidth = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = bandwidth(from: line)
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL) {
                    if best == nil || pendingBandwidth > best!.bandwidth {
                        best = (pendingBandwidth, url)
                    }
                }
                pendingBandwidth = 0
            }
        }
        return best?.url
    }

    static func parseMedia(_ text: String, baseURL: URL, origin: URL) throws -> ParsedMediaPlaylist {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix("#EXTM3U") }) else {
            throw PlaylistError.notPlaylist("缺少 #EXTM3U")
        }

        var segments: [MediaSegment] = []
        var key: MediaKey?
        var initSegment: URL?
        var hasDiscontinuity = false
        var hasByteRange = false
        var mediaSequence = 0
        var targetDuration: Double = 0
        var pendingDuration: Double?
        var endList = false

        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                mediaSequence = Int(line.split(separator: ":").last.map(String.init) ?? "") ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION") {
                targetDuration = Double(line.split(separator: ":").last.map(String.init) ?? "") ?? 0
            } else if line.hasPrefix("#EXTINF") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                pendingDuration = Double(value) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY") {
                let attrs = attributes(in: line)
                let method = (attrs["METHOD"] ?? "").uppercased()
                if method == "NONE" {
                    key = nil
                } else if method.contains("SAMPLE-AES") {
                    throw PlaylistError.drmProtected
                } else if method == "AES-128", let uriText = attrs["URI"], let uri = URL(string: uriText, relativeTo: baseURL) {
                    var iv: Data?
                    if let ivText = attrs["IV"] {
                        iv = dataFromHex(ivText)
                    }
                    key = MediaKey(method: method, uri: uri, iv: iv)
                } else {
                    throw PlaylistError.drmProtected
                }
            } else if line.hasPrefix("#EXT-X-MAP") {
                let attrs = attributes(in: line)
                if let uriText = attrs["URI"] {
                    initSegment = URL(string: uriText, relativeTo: baseURL)
                }
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
                hasDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                hasByteRange = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                endList = true
            } else if !line.hasPrefix("#") {
                if let duration = pendingDuration, let url = URL(string: line, relativeTo: baseURL) {
                    segments.append(MediaSegment(url: url, duration: duration))
                }
                pendingDuration = nil
            }
        }

        guard !segments.isEmpty else { throw PlaylistError.empty }
        guard endList else { throw PlaylistError.liveStream }
        guard !hasByteRange else { throw PlaylistError.byteRangeUnsupported }
        guard !hasDiscontinuity else { throw PlaylistError.discontinuityUnsupported }

        return ParsedMediaPlaylist(
            segments: segments,
            key: key,
            initSegment: initSegment,
            endList: endList,
            hasDiscontinuity: hasDiscontinuity,
            hasByteRange: hasByteRange,
            mediaSequence: mediaSequence,
            targetDuration: targetDuration
        )
    }

    /// 默认 IV：媒体序号作为 128 位大端整数
    static func defaultIV(sequence: Int) -> Data {
        var value = UInt64(sequence)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in stride(from: 15, through: 8, by: -1) {
            bytes[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        return Data(bytes)
    }

    static func dataFromHex(_ text: String) -> Data? {
        var hex = text.uppercased()
        if hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func bandwidth(from line: String) -> Int {
        let attrs = attributes(in: line)
        return Int(attrs["BANDWIDTH"] ?? "") ?? 0
    }

    static func attributes(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let colon = line.firstIndex(of: ":") else { return result }
        var key = ""
        var value = ""
        var readingValue = false
        var inQuotes = false

        func flush() {
            if !key.isEmpty { result[key] = value }
            key = ""
            value = ""
            readingValue = false
        }

        for char in line[line.index(after: colon)...] {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes && char == "=" && !readingValue {
                readingValue = true
                continue
            }
            if !inQuotes && char == "," {
                flush()
                continue
            }
            if readingValue { value.append(char) } else { key.append(char) }
        }
        flush()
        return result
    }
}
