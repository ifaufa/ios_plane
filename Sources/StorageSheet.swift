import SwiftUI

/// 存储空间概览与清理
struct StorageSheet: View {
    @ObservedObject var library: VideoLibrary
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let size: Int64
    }

    @State private var segmentsSize: Int64 = 0
    @State private var mp4Size: Int64 = 0
    @State private var freeSpace: Int64 = 0
    @State private var topRows: [Row] = []
    @State private var loading = true
    @State private var notice: String?
    @State private var confirmCleanupSegments = false
    @State private var confirmCleanupMP4 = false

    private static let lowSpaceThreshold: Int64 = 3_000_000_000

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("视频库占用", Self.format(segmentsSize + mp4Size), highlighted: false)
                    row("　分片", Self.format(segmentsSize), highlighted: false)
                    row("　MP4", Self.format(mp4Size), highlighted: false)
                    row("设备剩余空间", Self.format(freeSpace), highlighted: freeSpace > 0 && freeSpace < Self.lowSpaceThreshold)
                } header: {
                    Text("概览")
                } footer: {
                    if freeSpace > 0 && freeSpace < Self.lowSpaceThreshold {
                        Text("剩余空间不足 3GB，建议清理分片或删除已看完的内容。")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if loading {
                        HStack {
                            ProgressView()
                            Text("统计中…").foregroundStyle(.secondary)
                        }
                    } else if topRows.isEmpty {
                        Text("暂无条目").foregroundStyle(.secondary)
                    } else {
                        ForEach(topRows) { item in
                            HStack {
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Text(Self.format(item.size))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("占用最大的条目")
                }

                Section {
                    Button("清理所有分片（保留 MP4）") { confirmCleanupSegments = true }
                        .disabled(segmentsSize == 0)
                    Button("删除所有 MP4（保留分片）") { confirmCleanupMP4 = true }
                        .disabled(mp4Size == 0)
                } footer: {
                    Text("清理后如需再次编辑或播放，需要重新下载。")
                }
            }
            .navigationTitle("存储空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await recompute() }
            .confirmationDialog("清理所有分片？", isPresented: $confirmCleanupSegments, titleVisibility: .visible) {
                Button("清理", role: .destructive) {
                    let freed = library.cleanupAllSegments()
                    notice = "已释放 \(Self.format(freed))"
                    Task { await recompute() }
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("删除所有 MP4？", isPresented: $confirmCleanupMP4, titleVisibility: .visible) {
                Button("删除 MP4", role: .destructive) {
                    let freed = library.cleanupAllMP4KeepingSegments()
                    notice = "已释放 \(Self.format(freed))（分片已保留）"
                    Task { await recompute() }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("已清理", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
    }

    private func row(_ title: String, _ value: String, highlighted: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(highlighted ? Color.orange : .secondary)
        }
    }

    private func recompute() async {
        loading = true
        let snapshot = library.items
        let assets = VideoLibrary.assetsDir
        let result = await Task.detached(priority: .utility) { () -> (Int64, Int64, [Row], Int64) in
            var segments: Int64 = 0
            var mp4: Int64 = 0
            var rows: [Row] = []
            for item in snapshot {
                var size: Int64 = 0
                if item.fileName.lowercased().hasSuffix(".m3u8") {
                    let dir = assets.appendingPathComponent((item.fileName as NSString).deletingLastPathComponent)
                    size = Self.directorySize(dir)
                    segments += size
                } else {
                    size = Self.fileSize(assets.appendingPathComponent(item.fileName))
                    mp4 += size
                    if let name = item.segmentDirName, !name.isEmpty {
                        let dir = assets.appendingPathComponent(name, isDirectory: true)
                        segments += Self.directorySize(dir)
                    }
                }
                rows.append(Row(title: item.title, size: size))
            }
            let top = Array(rows.sorted { $0.size > $1.size }.prefix(10))
            return (segments, mp4, top, Self.freeSpace())
        }.value

        segmentsSize = result.0
        mp4Size = result.1
        topRows = result.2
        freeSpace = result.3
        loading = false
    }

    // MARK: - 文件工具

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    nonisolated private static func freeSpace() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return free
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
