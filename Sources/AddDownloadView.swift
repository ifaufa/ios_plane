import SwiftUI
import UIKit

struct AddDownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var rows: [Candidate] = []
    @State private var isChecking = false
    @State private var hint: String?

    var body: some View {
        NavigationStack {
            List {
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
                        Button("识别链接") { recognize() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .font(.footnote)
                }

                if !rows.isEmpty {
                    Section("检测结果（\(rows.filter { $0.selected }.count)/\(rows.count) 已选）") {
                        ForEach(rows) { row in
                            Button {
                                toggle(row.id)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: row.selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(row.isSelectable ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(row.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(row.isSelectable ? .secondary : .red)
                                        Text(row.url.absoluteString)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .disabled(!row.isSelectable)
                        }
                        Button("全选可用") { selectAll() }
                            .font(.footnote)
                    }
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
            .overlay {
                if isChecking {
                    ProgressView("检查中…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .alert("提示", isPresented: Binding(
                get: { hint != nil },
                set: { if !$0 { hint = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(hint ?? "")
            }
            .onAppear {
                if text.isEmpty, let clipboard = UIPasteboard.general.string,
                   clipboard.lowercased().contains(".m3u8") {
                    text = clipboard
                    recognize()
                }
            }
        }
    }

    private var selectedCount: Int { rows.filter { $0.selected && $0.isSelectable }.count }

    private func toggle(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].selected.toggle()
    }

    private func selectAll() {
        for index in rows.indices where rows[index].isSelectable {
            rows[index].selected = true
        }
    }

    private func recognize() {
        let links = BrowserModel.extractLinks(from: text)
        guard !links.isEmpty else {
            hint = "没有识别到 http(s) 链接"
            return
        }
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for link in links {
            guard let url = URL(string: link) else { continue }
            let id = url.absoluteString
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            candidates.append(Candidate(id: id, url: url, sources: [.manual]))
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

    private func submit() {
        for row in rows where row.selected && row.isSelectable {
            var target = row.url
            var title = row.title
            if let info = row.info, info.isMaster,
               let best = info.variants.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }),
               let variantURL = URL(string: best.url) {
                target = variantURL
                if let resolution = best.resolution { title += " \(resolution)" }
            }
            downloads.start(url: target, title: title)
        }
        dismiss()
    }
}
