import SwiftUI
import UIKit

struct AddDownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var rows: [Candidate] = []
    @State private var isChecking = false
    @State private var hint: String?
    @State private var pendingUnsupported: [(url: URL, title: String, detail: String)] = []
    @State private var showUnsupported = false
    @State private var isProbing = false

    var body: some View {
        NavigationStack {
            List {
                editorSection
                if !rows.isEmpty {
                    resultSection
                }
            }
            .navigationTitle("手动填写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加 \(selectedCount) 个") { submit() }
                        .disabled(selectedCount == 0)
                }
            }
            .overlay { checkingOverlay }
            .alert("提示", isPresented: hintBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(hint ?? "")
            }
            .alert("检测到不支持的编码", isPresented: $showUnsupported) {
                Button("取消", role: .cancel) { pendingUnsupported = [] }
                Button("仍然下载") {
                    for item in pendingUnsupported { downloads.start(url: item.url, title: item.title) }
                    pendingUnsupported = []
                    dismiss()
                }
            } message: {
                Text(unsupportedMessage)
            }
            .onAppear(perform: fillFromClipboard)
        }
    }

    // MARK: - 子视图

    private var editorSection: some View {
        Section("粘贴内容（可多行，自动识别链接）") {
            TextEditor(text: $text)
                .frame(minHeight: 96)
                .font(.system(.footnote, design: .monospaced))

            HStack {
                Button {
                    text = UIPasteboard.general.string ?? text
                    recognize()
                } label: {
                    Label("粘贴并识别", systemImage: "doc.on.clipboard")
                }
                Spacer()
                Button("识别链接", action: recognize)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.footnote)
        }
    }

    private var resultSection: some View {
        Section("检测结果（\(selectedCount)/\(rows.count) 已选）") {
            ForEach(rows.indices, id: \.self) { index in
                CandidateRow(candidate: $rows[index]) {
                    toggle(rows[index].id)
                }
            }
            Button("全选可用", action: selectAll)
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var checkingOverlay: some View {
        if isChecking {
            ProgressView("检查中…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var hintBinding: Binding<Bool> {
        Binding(get: { hint != nil }, set: { if !$0 { hint = nil } })
    }

    // MARK: - 数据

    private var selectedCount: Int {
        rows.filter { $0.selected && $0.isSelectable }.count
    }

    private func toggle(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].selected.toggle()
    }

    private func selectAll() {
        for index in rows.indices where rows[index].isSelectable {
            rows[index].selected = true
        }
    }

    private func fillFromClipboard() {
        guard text.isEmpty,
              let clipboard = UIPasteboard.general.string,
              clipboard.lowercased().contains(".m3u8") else { return }
        text = clipboard
        recognize()
    }

    private func recognize() {
        let entries = LinkParser.parse(text)
        guard !entries.isEmpty else {
            hint = "没有识别到 http(s) 链接"
            return
        }
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for entry in entries {
            guard let url = URL(string: entry.url) else { continue }
            let id = url.absoluteString
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            candidates.append(Candidate(id: id, url: url, title: entry.title, sources: [.manual]))
        }
        rows = candidates
        check()
    }

    private func check() {
        guard !rows.isEmpty else { return }
        isChecking = true
        let snapshot = rows
        Task { @MainActor in
            let results = await Self.inspectAll(snapshot.map { $0.url })
            var updated = snapshot
            for (index, result) in results.enumerated() where index < updated.count {
                Self.apply(result, at: index, to: &updated)
            }
            rows = updated
            isChecking = false
        }
    }

    private func submit() {
        var items: [(url: URL, title: String, codecs: String?)] = []
        for row in rows where row.selected && row.isSelectable {
            var target = row.url
            var title = row.title
            var codecs: String?
            if let info = row.info, info.isMaster,
               let best = info.variants.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }),
               let variantURL = URL(string: best.url) {
                target = variantURL
                codecs = best.codecs
                if let resolution = best.resolution { title += " \(resolution)" }
            } else if let info = row.info {
                codecs = info.variants.first?.codecs
            }
            items.append((target, title, codecs))
        }
        guard !items.isEmpty else { return }

        isProbing = true
        Task {
            var unsupported: [(url: URL, title: String, detail: String)] = []
            var startable: [(URL, String)] = []
            for item in items {
                let verdict = await CodecProbe.probe(playlistURL: item.url, codecsHint: item.codecs)
                DiagnosticsLog.write("[编码预检] \(item.title) \(verdict.detail) 支持=\(verdict.supported)")
                if verdict.supported {
                    startable.append((item.url, item.title))
                } else {
                    unsupported.append((item.url, item.title, verdict.detail))
                }
            }
            await MainActor.run {
                isProbing = false
                for (url, title) in startable { downloads.start(url: url, title: title) }
                if unsupported.isEmpty {
                    dismiss()
                } else {
                    pendingUnsupported = unsupported
                    showUnsupported = true
                }
            }
        }
    }

    private var unsupportedMessage: String {
        let lines = pendingUnsupported.prefix(4).map { "· \($0.title)：\($0.detail)" }
        let more = pendingUnsupported.count > 4 ? "\n… 另有 \(pendingUnsupported.count - 4) 个" : ""
        return (["以下视频为 10-bit H.264，iOS 无法在 App 内播放与转换 MP4："] + lines + [more, "", "建议取消下载，或在外部播放器/电脑上使用。"])
            .joined(separator: "\n")
    }

    // MARK: - 无状态工具

    private nonisolated static func inspectAll(_ urls: [URL]) async -> [M3U8InspectResult] {
        var results = [M3U8InspectResult](repeating: .invalid("未检查"), count: urls.count)
        await withTaskGroup(of: (Int, M3U8InspectResult).self) { group in
            var next = 0
            let limit = 3
            while next < min(limit, urls.count) {
                let index = next
                group.addTask { (index, await M3U8Inspector.inspect(urls[index])) }
                next += 1
            }
            while let (index, result) = await group.next() {
                results[index] = result
                if next < urls.count {
                    let following = next
                    group.addTask { (following, await M3U8Inspector.inspect(urls[following])) }
                    next += 1
                }
            }
        }
        return results
    }

    private nonisolated static func apply(_ result: M3U8InspectResult, at index: Int, to list: inout [Candidate]) {
        guard index < list.count else { return }
        switch result {
        case .available(let info):
            list[index].info = info
            list[index].state = info.drm ? .invalid("受 DRM 保护") : .available
        case .invalid(let reason):
            list[index].state = .invalid(reason)
        case .unreachable(let reason):
            list[index].state = .unreachable(reason)
        }
    }
}
