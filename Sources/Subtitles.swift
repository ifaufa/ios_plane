import Foundation
import SwiftUI

// MARK: - 数据模型

struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

struct SubtitleTrack: Identifiable, Equatable {
    let id: UUID
    /// 所属视频（防止切换视频时串台）
    var videoID: UUID?
    var title: String
    /// 相对 Assets 的路径
    var fileName: String
    var cues: [SubtitleCue]
    var offset: Double = 0

    static func == (lhs: SubtitleTrack, rhs: SubtitleTrack) -> Bool { lhs.id == rhs.id }

    func text(at time: Double) -> String? {
        let t = time - offset
        // cue 数量通常上千，二分定位
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if t < cue.start {
                high = mid - 1
            } else if t > cue.end {
                low = mid + 1
            } else {
                return cue.text
            }
        }
        return nil
    }
}

// MARK: - 解析

enum SubtitleParser {
    static let supportedExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    static func parse(url: URL) -> [SubtitleCue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = decode(data) else { return nil }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ass", "ssa": return parseASS(text)
        case "vtt": return parseWebVTT(text)
        default: return parseSRT(text)
        }
    }

    // MARK: 编码探测（中文 SRT 常见 GBK）

    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return text }
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)))
        if let text = String(data: data, encoding: big5) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        return nil
    }

    // MARK: SRT

    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTimeRange(lines[timeLineIndex]) else { continue }
            let body = lines.dropFirst(timeLineIndex + 1).joined(separator: "\n")
            let cleaned = cleanText(body)
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: WebVTT

    private static func parseWebVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var currentTime: (Double, Double)?
        var buffer: [String] = []

        func flush() {
            guard let (start, end) = currentTime else { buffer.removeAll(); return }
            let cleaned = cleanText(buffer.joined(separator: "\n"))
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
            buffer.removeAll()
        }

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-->") {
                flush()
                currentTime = parseTimeRange(trimmed)
                continue
            }
            if trimmed.isEmpty {
                flush()
                currentTime = nil
                continue
            }
            if trimmed.hasPrefix("WEBVTT") || trimmed.hasPrefix("NOTE")
                || trimmed.hasPrefix("STYLE") || trimmed.hasPrefix("REGION") {
                continue
            }
            if currentTime != nil { buffer.append(trimmed) }
        }
        flush()
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            guard line.hasPrefix("Dialogue:") else { continue }
            let body = String(line.dropFirst("Dialogue:".count))
            let parts = body.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard parts.count >= 10 else { continue }
            let start = parseASSTime(String(parts[1]))
            let end = parseASSTime(String(parts[2]))
            guard let start, let end else { continue }
            let cleaned = cleanText(String(parts[9]))
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseASSTime(_ raw: String) -> Double? {
        // 0:00:12.34
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    // MARK: 通用

    private static func parseTimeRange(_ line: String) -> (Double, Double)? {
        let pieces = line.components(separatedBy: "-->")
        guard pieces.count >= 2 else { return nil }
        let startText = pieces[0].trimmingCharacters(in: .whitespaces)
        // 结束时间后面可能跟着 VTT 定位参数
        let endText = pieces[1].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        guard let start = parseTime(startText), let end = parseTime(endText) else { return nil }
        return (start, max(start, end))
    }

    private static func parseTime(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        default:
            return nil
        }
    }

    /// 去样式标签；ASS 的 \N 转换行
    private static func cleanText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
        while let start = text.firstIndex(of: "{"), let end = text[start...].firstIndex(of: "}") {
            text.removeSubrange(start...end)
        }
        // WebVTT 内联标签 <c> </c> <00:00:01.000>
        if text.contains("<") {
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
