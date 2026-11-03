import Foundation

struct M3U8Variant: Hashable, Identifiable {
    var id: String { url }
    var url: String
    var bandwidth: Int?
    var resolution: String?
}

struct M3U8Info: Equatable {
    var isMaster = false
    var variants: [M3U8Variant] = []
    var duration: Double = 0
    var segmentCount: Int = 0
    var encrypted = false
    var drm = false
}

enum M3U8InspectResult: Equatable {
    case available(M3U8Info)
    case invalid(String)
    case unreachable(String)
}

enum M3U8Inspector {
    /// 拉取播放列表头部并解析，不下载媒体数据
    static func inspect(_ url: URL) async -> M3U8InspectResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        for (key, value) in RequestSettings.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("没有 HTTP 响应")
            }
            guard (200..<300).contains(http.statusCode) || http.statusCode == 206 else {
                return .unreachable("HTTP \(http.statusCode)")
            }
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            return parse(text, baseURL: url)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func parse(_ text: String, baseURL: URL) -> M3U8InspectResult {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix("#EXTM3U") }) else {
            return .invalid("不是 m3u8 播放列表")
        }

        var info = M3U8Info()

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            info.isMaster = true
            var pending: M3U8Variant?
            for line in lines {
                if line.hasPrefix("#EXT-X-STREAM-INF") {
                    let attrs = parseAttributes(line)
                    pending = M3U8Variant(
                        url: "",
                        bandwidth: Int(attrs["BANDWIDTH"] ?? ""),
                        resolution: attrs["RESOLUTION"]
                    )
                } else if !line.isEmpty, !line.hasPrefix("#"), var variant = pending {
                    variant.url = URL(string: line, relativeTo: baseURL)?.absoluteString ?? line
                    info.variants.append(variant)
                    pending = nil
                }
            }
            if info.variants.isEmpty { return .invalid("主列表里没有可用码率") }
            return .available(info)
        }

        for line in lines {
            if line.hasPrefix("#EXTINF") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                if let seconds = Double(value) {
                    info.duration += seconds
                    info.segmentCount += 1
                }
            } else if line.hasPrefix("#EXT-X-KEY") {
                let attrs = parseAttributes(line)
                let method = (attrs["METHOD"] ?? "").uppercased()
                if method == "AES-128" {
                    info.encrypted = true
                } else if method.contains("SAMPLE-AES") {
                    info.encrypted = true
                    info.drm = true
                }
            }
        }

        if info.segmentCount == 0 {
            return .invalid("列表中没有分片（可能是直播流）")
        }
        return .available(info)
    }

    private static func parseAttributes(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let colon = line.firstIndex(of: ":") else { return result }
        let body = line[line.index(after: colon)...]
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

        for char in body {
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
            if readingValue {
                value.append(char)
            } else {
                key.append(char)
            }
        }
        flush()
        return result
    }
}
