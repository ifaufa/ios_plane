import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 清单

struct BackupManifest: Codable {
    struct Entry: Codable {
        var path: String      // 相对 Documents 的路径，如 "Assets/xxx.movpkg/..."
        var offset: UInt64
        var length: UInt64
    }
    var version: Int
    var createdAt: Date
    var library: [VideoItem]
    var entries: [Entry]
    /// 收藏夹（旧备份没有该字段）
    var bookmarks: [Bookmark]?
    /// 收藏分组（更旧的备份没有该字段）
    var bookmarkFolders: [BookmarkFolder]?
}

// MARK: - 归档读写

enum BackupService {
    static let magic = Data("PLBKV1".utf8)
    static let chunk: Int = 1 << 20

    struct ArchiveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct RestoreResult {
        var restored: Int
        var total: Int
        var skipped: [String]
        var library: [VideoItem]
        var bookmarks: [Bookmark]
        var bookmarkFolders: [BookmarkFolder]
    }

    /// 打包 Documents/Assets 下的全部文件 + 台账 + 收藏夹
    /// 直接写最终归档（不再生成中间 payload），峰值占用从 3 份降到 2 份
    static func makeArchive(items: [VideoItem], bookmarks: [Bookmark], bookmarkFolders: [BookmarkFolder] = []) throws -> (url: URL, files: Int) {
        let fm = FileManager.default
        cleanupStaleTemps()

        // 先扫描一遍，拿到路径与大小，才能把偏移量写进清单
        let sources = try collectFiles()
        var entries: [BackupManifest.Entry] = []
        var offset: UInt64 = 0
        for source in sources {
            entries.append(.init(path: source.path, offset: offset, length: source.size))
            offset += source.size
        }
        let payloadSize = offset

        let manifest = BackupManifest(version: 1,
                                      createdAt: Date(),
                                      library: items,
                                      entries: entries,
                                      bookmarks: bookmarks,
                                      bookmarkFolders: bookmarkFolders)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)

        // 空间预检：只保留一份归档 + 少量余量
        let required = payloadSize + UInt64(manifestData.count) + 256 * 1024 * 1024
        if let available = availableCapacity(), available < Int64(required) {
            throw ArchiveError(message: "可用空间不足：需要约 \(Self.gb(required))，当前仅剩 \(Self.gb(UInt64(available)))。请清理空间或删除部分视频后重试。")
        }

        let tmpDir = fm.temporaryDirectory.appendingPathComponent("PlaneBackup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let archiveURL = tmpDir.appendingPathComponent("PlaneM3U8-\(formatter.string(from: Date())).plbk")
        guard fm.createFile(atPath: archiveURL.path, contents: nil) else {
            throw ArchiveError(message: "无法创建备份文件")
        }
        let out = try FileHandle(forWritingTo: archiveURL)

        do {
            try out.write(contentsOf: magic)
            var length = UInt64(manifestData.count).littleEndian
            try out.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
            try out.write(contentsOf: manifestData)

            var written: UInt64 = 0
            for source in sources {
                let reader = try FileHandle(forReadingFrom: source.url)
                while let data = try reader.read(upToCount: chunk), !data.isEmpty {
                    try out.write(contentsOf: data)
                    written += UInt64(data.count)
                }
                try reader.close()
            }
            try out.close()

            guard written == payloadSize else {
                try? fm.removeItem(at: archiveURL)
                throw ArchiveError(message: "备份期间素材发生变化（预期 \(payloadSize) 字节，实际 \(written) 字节），已放弃本次备份。")
            }
        } catch {
            try? out.close()
            try? fm.removeItem(at: tmpDir)
            throw error
        }

        return (archiveURL, entries.count)
    }

    /// 清理历史失败遗留的临时备份目录（每次可能残留数 GB）
    static func cleanupStaleTemps() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("PlaneBackup-") {
            try? fm.removeItem(at: item)
        }
    }

    private static func availableCapacity() -> Int64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// 解包恢复到 Documents，返回恢复的文件数与台账条目
    static func restore(from archive: URL) throws -> RestoreResult {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count > magic.count + 8, data.prefix(magic.count) == magic else {
            throw ArchiveError(message: "不是有效的备份文件")
        }
        var manifestLength: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &manifestLength) { buf in
            data.copyBytes(to: buf, from: magic.count..<(magic.count + 8))
        }
        let manifestStart = magic.count + 8
        let manifestEnd = manifestStart + Int(manifestLength)
        guard manifestEnd <= data.count else {
            throw ArchiveError(message: "备份文件已损坏")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: data.subdata(in: manifestStart..<manifestEnd))

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // 恢复同样做空间预检，避免写到一半失败
        let needed = manifest.entries.reduce(UInt64(0)) { $0 + $1.length } + 256 * 1024 * 1024
        if let available = availableCapacity(), available < Int64(needed) {
            throw ArchiveError(message: "可用空间不足：恢复需要约 \(gb(needed))，当前仅剩 \(gb(UInt64(available)))。")
        }

        var restored = 0
        var skipped: [String] = []

        for entry in manifest.entries {
            guard let relative = normalize(entry.path) else {
                skipped.append("\(entry.path)（路径非法）")
                continue
            }
            let dest = docs.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                guard fm.createFile(atPath: dest.path, contents: nil) else {
                    skipped.append("\(relative)（无法创建文件）")
                    continue
                }
                let writer = try FileHandle(forWritingTo: dest)
                var remaining = Int(entry.length)
                var cursor = manifestEnd + Int(entry.offset)
                while remaining > 0 {
                    let size = min(chunk, remaining)
                    let slice = data.subdata(in: cursor..<(cursor + size))
                    try writer.write(contentsOf: slice)
                    cursor += size
                    remaining -= size
                }
                try writer.close()
                restored += 1
            } catch {
                skipped.append("\(relative)（\(error.localizedDescription)）")
            }
        }
        return RestoreResult(restored: restored,
                             total: manifest.entries.count,
                             skipped: skipped,
                             library: manifest.library,
                             bookmarks: manifest.bookmarks ?? [],
                             bookmarkFolders: manifest.bookmarkFolders ?? [])
    }

    /// 兼容历史备份中的绝对路径（/private/var/... 或 /var/... 前缀差异）
    private static func normalize(_ rawPath: String) -> String? {
        var path = rawPath
        if let range = path.range(of: "/Documents/") {
            path = String(path[range.upperBound...])
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, !path.contains("..") else { return nil }
        return path
    }

    // MARK: 私有

    private struct SourceFile { let path: String; let url: URL; let size: UInt64 }

    private static func collectFiles() throws -> [SourceFile] {
        let fm = FileManager.default
        let assets = VideoLibrary.assetsDir
        // 用相对路径枚举，避免 /var 与 /private/var 前缀不一致导致相对路径算错
        guard let enumerator = fm.enumerator(atPath: assets.path) else { return [] }
        var result: [SourceFile] = []
        for case let subPath as String in enumerator {
            let url = assets.appendingPathComponent(subPath)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            result.append(SourceFile(path: "Assets/" + subPath,
                                     url: url,
                                     size: UInt64(values?.fileSize ?? 0)))
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values.fileSize ?? 0)
    }
}

// MARK: - 归档导出（文件 URL 方式，避免大文件进内存）

struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}

// MARK: - 界面状态

@MainActor
final class BackupManager: ObservableObject {
    struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var isWorking = false
    @Published var progressText = ""
    @Published var alert: AlertInfo?
    @Published var exportURL: URL?
    private var exportDirectory: URL?

    init() {
        // 启动即清理上次失败遗留的临时备份，避免占用数 GB 空间
        BackupService.cleanupStaleTemps()
    }

    /// 导出结束（无论成功或取消）后清理临时归档
    func finishExport() {
        if let directory = exportDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        exportDirectory = nil
        exportURL = nil
    }

    func backup(items: [VideoItem], bookmarks: [Bookmark], bookmarkFolders: [BookmarkFolder] = []) {
        isWorking = true
        progressText = "正在打包备份…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BackupService.makeArchive(items: items, bookmarks: bookmarks, bookmarkFolders: bookmarkFolders)
                }.value
                if result.files == 0, !items.isEmpty {
                    alert = AlertInfo(title: "备份未包含视频",
                                      message: "未在 Documents/Assets 中找到任何视频文件，本次备份只含台账，请确认视频仍在列表中没有显示「文件已丢失」。")
                } else {
                    exportDirectory = result.url.deletingLastPathComponent()
                    exportURL = result.url
                }
            } catch {
                alert = AlertInfo(title: "备份失败", message: error.localizedDescription)
            }
            isWorking = false
        }
    }

    func restore(from pickedURL: URL, library: VideoLibrary) {
        isWorking = true
        progressText = "正在恢复备份…"
        Task {
            let accessing = pickedURL.startAccessingSecurityScopedResource()
            defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BackupService.restore(from: pickedURL)
                }.value
                library.merge(result.library)
                let addedBookmarks = BookmarkStore.shared.merge(result.bookmarks, folders: result.bookmarkFolders)

                var message = "共 \(result.total) 个文件条目，成功恢复 \(result.restored) 个，合并 \(result.library.count) 条记录、\(addedBookmarks) 条收藏。"
                if !result.skipped.isEmpty {
                    let preview = result.skipped.prefix(3).joined(separator: "；")
                    message += "\n\n跳过 \(result.skipped.count) 个：\(preview)"
                }
                if result.restored == 0, result.total > 0 {
                    message += "\n\n未恢复任何文件，请把这条信息反馈给我。"
                }
                alert = AlertInfo(title: result.restored > 0 ? "恢复完成" : "恢复不完整",
                                  message: message)
            } catch {
                alert = AlertInfo(title: "恢复失败", message: error.localizedDescription)
            }
            isWorking = false
        }
    }
}
