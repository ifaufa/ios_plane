import Foundation

/// 自检 MP4 结构：顶层 box、moov 子 box、以及表格条目数
enum MP4Inspector {
    static func describe(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无法打开文件" }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return "无法读取大小" }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: Int(min(fileSize, 9_000_000))) else { return "读取失败" }

        var offset = 0
        var parts: [String] = []
        while offset + 8 <= head.count {
            let size = Int(head.u64(at: offset))
            let type = head.ascii(at: offset + 4, length: 4)
            var boxSize = size
            var headerLength = 8
            if size == 1 {
                guard offset + 16 <= head.count else { break }
                boxSize = Int(head.u64(at: offset + 8))
                headerLength = 16
            } else if size == 0 {
                boxSize = head.count - offset
            }
            guard boxSize >= headerLength, offset + boxSize <= head.count else {
                parts.append("\(type)(size=\(boxSize) 越界)")
                break
            }
            if type == "moov" {
                parts.append("moov[\(moovChildren(head, start: offset + headerLength, size: boxSize))]")
            } else if type == "mdat" {
                parts.append("mdat(size=\(boxSize))")
            } else {
                parts.append("\(type)(size=\(boxSize))")
            }
            offset += boxSize
        }

        let declaredEnd = offset
        return "文件=\(fileSize)B box总长=\(declaredEnd)B \(parts.joined(separator: " "))"
    }

    private static func moovChildren(_ data: Data, start: Int, size: Int) -> String {
        var offset = start
        let end = start + size
        var names: [String] = []
        while offset + 8 <= end {
            let childSize = Int(data.u64(at: offset))
            let type = data.ascii(at: offset + 4, length: 4)
            guard childSize >= 8, offset + childSize <= end else {
                names.append("\(type)(bad)")
                break
            }
            if type == "trak" {
                names.append("trak{\(trakChildren(data, start: offset + 8, size: childSize - 8))}")
            } else {
                names.append("\(type)")
            }
            offset += childSize
        }
        return names.joined(separator: ",")
    }

    private static func trakChildren(_ data: Data, start: Int, size: Int) -> String {
        var offset = start
        let end = start + size
        var names: [String] = []
        while offset + 8 <= end {
            let childSize = Int(data.u64(at: offset))
            let type = data.ascii(at: offset + 4, length: 4)
            guard childSize >= 8, offset + childSize <= end else { break }
            if type == "mdia" {
                names.append("mdia{\(mdiaChildren(data, start: offset + 8, size: childSize - 8))}")
            } else {
                names.append("\(type)")
            }
            offset += childSize
        }
        return names.joined(separator: ",")
    }

    private static func mdiaChildren(_ data: Data, start: Int, size: Int) -> String {
        var offset = start
        let end = start + size
        var names: [String] = []
        while offset + 8 <= end {
            let childSize = Int(data.u64(at: offset))
            let type = data.ascii(at: offset + 4, length: 4)
            guard childSize >= 8, offset + childSize <= end else { break }
            if type == "minf" {
                names.append("minf{\(minfChildren(data, start: offset + 8, size: childSize - 8))}")
            } else {
                names.append("\(type)")
            }
            offset += childSize
        }
        return names.joined(separator: ",")
    }

    private static func minfChildren(_ data: Data, start: Int, size: Int) -> String {
        var offset = start
        let end = start + size
        var names: [String] = []
        while offset + 8 <= end {
            let childSize = Int(data.u64(at: offset))
            let type = data.ascii(at: offset + 4, length: 4)
            guard childSize >= 8, offset + childSize <= end else { break }
            if type == "stbl" {
                names.append("stbl{\(stblChildren(data, start: offset + 8, size: childSize - 8))}")
            } else {
                names.append("\(type)")
            }
            offset += childSize
        }
        return names.joined(separator: ",")
    }

    private static func stblChildren(_ data: Data, start: Int, size: Int) -> String {
        var offset = start
        let end = start + size
        var names: [String] = []
        while offset + 8 <= end {
            let childSize = Int(data.u64(at: offset))
            let type = data.ascii(at: offset + 4, length: 4)
            guard childSize >= 8, offset + childSize <= end else { break }
            names.append("\(type):\(childSize)")
            offset += childSize
        }
        return names.joined(separator: ",")
    }
}

private extension Data {
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
