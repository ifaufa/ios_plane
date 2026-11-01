import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var downloads: DownloadManager
    @State private var showAdd = false
    @State private var playing: VideoItem?

    var body: some View {
        NavigationStack {
            List {
                if !downloads.tasks.isEmpty {
                    Section("下载中") {
                        ForEach(downloads.tasks) { task in
                            DownloadRow(task: task)
                                .swipeActions {
                                    Button("取消", role: .destructive) {
                                        downloads.cancel(task)
                                    }
                                }
                        }
                    }
                }
                Section("视频库 (\(library.items.count))") {
                    ForEach(library.items) { item in
                        LibraryRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { playing = item }
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    library.remove(item)
                                }
                            }
                    }
                }
            }
            .navigationTitle("PlaneM3U8")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddDownloadView()
            }
            .fullScreenCover(item: $playing) { item in
                PlayerView(url: library.localURL(for: item), title: item.title)
            }
        }
    }
}

private struct DownloadRow: View {
    let task: DownloadTaskInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title).font(.headline).lineLimit(1)
            switch task.status {
            case .downloading:
                ProgressView(value: task.progress)
                Text("\(Int(task.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text("失败：\(message)")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LibraryRow: View {
    let item: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.headline).lineLimit(1)
            HStack {
                Text(item.duration > 0 ? Self.formatDuration(item.duration) : "--:--")
                Text(Self.formatSize(item.fileSize))
                Text(item.createdAt, style: .date)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
