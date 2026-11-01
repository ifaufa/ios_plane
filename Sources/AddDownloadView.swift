import SwiftUI
import UIKit

struct AddDownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var title = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("m3u8 地址") {
                    TextField("https://example.com/video.m3u8", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("标题（可选）") {
                    TextField("留空则使用文件名", text: $title)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("新建下载")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") { startDownload() }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if urlText.isEmpty, let clipboard = UIPasteboard.general.string,
                   clipboard.lowercased().contains(".m3u8") {
                    urlText = clipboard
                }
            }
        }
    }

    private func startDownload() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            error = "URL 无效，请输入 http(s) 开头的 m3u8 地址"
            return
        }
        let finalTitle = title.trimmingCharacters(in: .whitespaces)
        let resolved = finalTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : finalTitle
        downloads.start(url: url, title: resolved)
        dismiss()
    }
}
