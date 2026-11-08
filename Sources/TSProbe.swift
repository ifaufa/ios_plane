import Foundation

/// 粗查 TS 分片：是否含 PAT/PMT、出现哪些 PID（用于判断流是否自描述）
enum TSProbe {
    static func describe(fileURL: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "无法读取" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 188 * 300), !data.isEmpty else {
            return "空文件"
        }

        var pids = Set<Int>()
        var hasPAT = false
        var hasPMT = false
        var packets = 0
        var index = 0
        let bytes = [UInt8](data)

        while index + 188 <= bytes.count {
            if bytes[index] != 0x47 {
                index += 1
                continue
            }
            packets += 1
            let pid = (Int(bytes[index + 1] & 0x1F) << 8) | Int(bytes[index + 2])
            pids.insert(pid)
            if pid == 0 { hasPAT = true }
            if pid == 0x1000 || pid == 0x1001 || pid == 0x0FFF { hasPMT = true }
            index += 188
        }

        let list = pids.sorted().prefix(10).map(String.init).joined(separator: ",")
        return "TS包=\(packets) 有PAT=\(hasPAT) 可能PMT=\(hasPMT) PIDs=[\(list)]"
    }
}
