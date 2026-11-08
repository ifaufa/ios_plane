import Foundation

/// MP4 结构自检：按文件真实大小遍历顶层 box，并展开 moov 到 stbl 各表
enum MP4Inspector {
    static func describe(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无法打开文件" }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return "无法读取大小" }

        var offset: UInt64 = 0
        var parts: [String] = []

        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            var size = UInt64(header.u32(at: 0))
            let type = header.ascii(at: 4, length: 4)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 {
                size = header.u64(at: 8)
                headerLength = 16
            } else if size == 0 {
                size = fileSize - offset
            }
            guard size >= headerLength, offset + size <= fileSize else {
                parts.append("\(type)(bad size=\(size) at \(offset))")
                break
            }
            if type == "moov" {
                try? handle.seek(toOffset: offset + headerLength)
                let body = (try? handle.read(upToCount: Int(min(size - headerLength, 4_000_000)))) ?? Data()
                parts.append("moov[\(dump(body, limit: 4))]")
            } else {
                parts.append("\(type)(\(size)B)")
            }
            offset += size
        }
        return "文件=\(fileSize)B 结束于=\(offset)B \(parts.joined(separator: " "))"
    }

    /// 渐进展开：已知容器 box 递归，叶子只显示大小
    private static func dump(_ data: Data, limit: Int) -> String {
        var offset = 0
        var names: [String] = []
        while offset + 8 <= data.count {
            let size = Int(data.u32(at: offset))
            let type = data.ascii(at: offset + 4, length: 4)
            guard size >= 8, offset + size <= data.count else {
                names.append("\(type)(bad)")
                break
            }
            let child = data.subdata(in: (offset + 8)..<(offset + size))
            if ["trak", "mdia", "minf", "stbl"].contains(type) {
                names.append("\(type){\(dump(child, limit: limit - 1))}")
            } else if type == "stsd" {
                names.append("stsd{\(dumpSampleEntry(child))}")
            } else if type == "stsz" {
                let count = child.count >= 8 ? Int(child.u32(at: 4)) : -1
                names.append("stsz(\(count))")
            } else if type == "stco" || type == "co64" {
                let count = child.count >= 4 ? Int(child.u32(at: 0)) : -1
                names.append("\(type)(\(count))")
            } else if type == "stts" || type == "ctts" || type == "stsc" || type == "stss" {
                // FullBox：version/flags(4) + entry_count(4)
                let count = child.count >= 8 ? Int(child.u32(at: 4)) : -1
                names.append("\(type)(entries=\(count))")
            } else {
                names.append("\(type)(\(size))")
            }
            offset += size
        }
        return names.joined(separator: ",")
    }

    private static func dumpSampleEntry(_ data: Data) -> String {
        // stsd: version/flags(4) + entry_count(4) + entry
        guard data.count >= 8 else { return "empty" }
        let count = Int(data.u32(at: 4))
        guard count > 0, data.count >= 16 else { return "count=\(count)" }
        let entrySize = Int(data.u32(at: 8))
        let entryType = data.ascii(at: 12, length: 4)
        var inner: [String] = []
        if entrySize >= 16, 8 + entrySize <= data.count {
            var cursor = 16 + 78
            let end = min(data.count, 8 + entrySize)
            while cursor + 8 <= end {
                let size = Int(data.u32(at: cursor))
                let type = data.ascii(at: cursor + 4, length: 4)
                guard size >= 8, cursor + size <= end else {
                    inner.append("\(type)(bad)")
                    break
                }
                inner.append("\(type)(\(size))")
                cursor += size
            }
        }
        return "count=\(count) \(entryType) size=\(entrySize) [\(inner.joined(separator: ","))]"
    }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(self[self.startIndex + offset + index])
        }
        return value
    }

    func u64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(self[self.startIndex + offset + index])
        }
        return value
    }

    func ascii(at offset: Int, length: Int) -> String {
        guard offset + length <= count else { return "????" }
        let slice = self[(startIndex + offset)..<(startIndex + offset + length)]
        return String(decoding: slice, as: UTF8.self)
    }
}
