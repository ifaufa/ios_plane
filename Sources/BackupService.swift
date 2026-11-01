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
    }

    /// 打包 Documents/Assets 下的全部文件 + 台账，返回临时归档文件与打包文件数
    static func makeArchive(items: [VideoItem]) throws -> (url: URL, files: Int) {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("PlaneBackup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let payloadURL = tmpDir.appendingPathComponent("payload.bin")
        guard fm.createFile(atPath: payloadURL.path, contents: nil) else {
            throw ArchiveError(message: "无法创建临时文件")
        }
        let payloadHandle = try FileHandle(forWritingTo: payloadURL)
        var entries: [BackupManifest.Entry] = []
        var offset: UInt64 = 0

        for file in try collectFiles() {
            let size = try fileSize(at: file.url)
            let reader = try FileHandle(forReadingFrom: file.url)
            while let data = try reader.read(upToCount: chunk), !data.isEmpty {
                try payloadHandle.write(contentsOf: data)
            }
            try reader.close()
            entries.append(.init(path: file.path, offset: offset, length: size))
            offset += size
        }
        try payloadHandle.close()

        let manifest = BackupManifest(version: 1, createdAt: Date(), library: items, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let archiveURL = tmpDir.appendingPathComponent("PlaneM3U8-\(formatter.string(from: Date())).plbk")
        guard fm.createFile(atPath: archiveURL.path, contents: nil) else {
            throw ArchiveError(message: "无法创建备份文件")
        }
        let out = try FileHandle(forWritingTo: archiveURL)
        try out.write(contentsOf: magic)
        var length = UInt64(manifestData.count).littleEndian
        try out.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try out.write(contentsOf: manifestData)

        let inHandle = try FileHandle(forReadingFrom: payloadURL)
        while let data = try inHandle.read(upToCount: chunk), !data.isEmpty {
            try out.write(contentsOf: data)
        }
        try inHandle.close()
        try out.close()
        try? fm.removeItem(at: payloadURL)
        return (archiveURL, entries.count)
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
                             library: manifest.library)
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

    private struct SourceFile { let path: String; let url: URL }

    private static func collectFiles() throws -> [SourceFile] {
        let fm = FileManager.default
        let assets = VideoLibrary.assetsDir
        // 用相对路径枚举，避免 /var 与 /private/var 前缀不一致导致相对路径算错
        guard let enumerator = fm.enumerator(atPath: assets.path) else { return [] }
        var result: [SourceFile] = []
        for case let subPath as String in enumerator {
            let url = assets.appendingPathComponent(subPath)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            result.append(SourceFile(path: "Assets/" + subPath, url: url))
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

    func backup(items: [VideoItem]) {
        isWorking = true
        progressText = "正在打包备份…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BackupService.makeArchive(items: items)
                }.value
                if result.files == 0, !items.isEmpty {
                    alert = AlertInfo(title: "备份未包含视频",
                                      message: "未在 Documents/Assets 中找到任何视频文件，本次备份只含台账，请确认视频仍在列表中没有显示「文件已丢失」。")
                } else {
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

                var message = "共 \(result.total) 个文件条目，成功恢复 \(result.restored) 个，合并 \(result.library.count) 条记录。"
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
