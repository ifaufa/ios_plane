import Foundation

/// 从任意文本中提取链接，支持 `标题$链接` 形式的标题前缀
enum LinkParser {
    struct Entry: Equatable {
        var title: String?
        var url: String
    }

    private static let regex = try? NSRegularExpression(
        pattern: "https?://[^\\s\"'<>，。、）】\\]$]+",
        options: [.caseInsensitive]
    )

    static func parse(_ text: String) -> [Entry] {
        guard let regex else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        var entries: [Entry] = []
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let prefix = String(text[cursor..<range.lowerBound])
            let url = String(text[range])
            entries.append(Entry(title: title(from: prefix), url: url))
            cursor = range.upperBound
        }
        return entries
    }

    /// 规则：最后一个 `$` 之前是标题；标题中不保留 `$`
    private static func title(from prefix: String) -> String? {
        guard let lastDollar = prefix.lastIndex(of: "$") else { return nil }
        var title = String(prefix[..<lastDollar])
        title = title.replacingOccurrences(of: "$", with: "")
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func defaultTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? (url.host ?? "视频") : name
    }
}
