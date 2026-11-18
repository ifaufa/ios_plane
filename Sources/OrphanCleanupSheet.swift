import SwiftUI

/// 扫描并清理 Assets 里「没有台账引用」的孤立目录/文件
struct OrphanCleanupSheet: View {
    @ObservedObject var library: VideoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var scan: VideoLibrary.OrphanScan?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                if let scan {
                    if scan.isEmpty {
                        Section {
                            Text("没有发现孤立文件，视频库与磁盘一致。")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            row("孤立项目", "\(scan.entries.count) 个")
                            row("占用空间", Self.sizeText(scan.totalBytes))
                            if scan.recentCount > 0 {
                                row("其中 10 分钟内（疑似写入中）", "\(scan.recentCount) 个")
                            }
                        }

                        Section("清单（按占用大小）") {
                            ForEach(scan.entries.prefix(20)) { entry in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Text(entry.isDirectory ? "目录" : "文件")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Self.sizeText(entry.size))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if scan.entries.count > 20 {
                                Text("仅显示前 20 项，其余 \(scan.entries.count - 20) 项会在清理时一并处理")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section {
                            Button("清理（跳过 10 分钟内的）", role: .destructive) {
                                clean(includeRecent: false)
                            }
                            .disabled(scan.removableCount == 0)

                            Button("全部清理（含最近 10 分钟）", role: .destructive) {
                                clean(includeRecent: true)
                            }
                        } footer: {
                            Text("「全部清理」会连同最近 10 分钟内修改的文件一并删除；若正在转换，请等转换结束后再操作。")
                        }
                    }
                } else {
                    Section {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("清理孤立文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        scan = library.scanOrphans()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { scan = library.scanOrphans() }
            .alert("清理完成", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func clean(includeRecent: Bool) {
        let result = library.cleanOrphans(includeRecent: includeRecent)
        scan = library.scanOrphans()
        message = "已清理 \(result.count) 项，释放 \(Self.sizeText(result.freed))。"
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
