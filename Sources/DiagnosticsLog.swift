import Foundation
import SwiftUI

/// 诊断日志：写入 Documents/diagnostics.log，可在「文件」App 或 App 内查看
enum DiagnosticsLog {
    static let fileName = "diagnostics.log"
    private static let queue = DispatchQueue(label: "diagnostics.log")
    private static let maxBytes = 512 * 1024

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static func write(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
               size.intValue > maxBytes {
                let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                let tail = String(existing.suffix(maxBytes / 2))
                try? ("[日志已截断]\n" + tail).write(to: fileURL, atomically: true, encoding: .utf8)
            }
            if let handle = try? FileHandle(forWritingTo: ensureFile()) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }

    static func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "（暂无日志）"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func hexPrefix(_ data: Data, count: Int = 8) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func ensureFile() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        return fileURL
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

/// 日志查看页
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .navigationTitle("诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                }
            }
            .onAppear {
                DiagnosticsLog.write("[ui] 打开诊断日志")
                waitForFlush()
            }
        }
    }

    private func waitForFlush() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            text = DiagnosticsLog.read()
        }
    }
}
