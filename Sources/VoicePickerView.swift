import SwiftUI
import AVFoundation

/// 音色选择（独立页面：滚动稳定，可分组、试听、搜索）
struct VoicePickerView: View {
    @AppStorage(SubtitleSpeaker.voiceKey) private var voiceID = ""
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var previewing: String?

    private var filtered: [AVSpeechSynthesisVoice] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return SubtitleSpeaker.cachedVoices }
        return SubtitleSpeaker.cachedVoices.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
                || $0.language.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var chineseVoices: [AVSpeechSynthesisVoice] {
        filtered.filter { $0.language.hasPrefix("zh") }
    }

    private var englishVoices: [AVSpeechSynthesisVoice] {
        filtered.filter { $0.language.hasPrefix("en") }
    }

    var body: some View {
        List {
            Section {
                Button {
                    voiceID = ""
                    dismiss()
                } label: {
                    row(title: "自动（跟随语言）", subtitle: "按字幕语种自动选择", selected: voiceID.isEmpty, identifier: "")
                }
                .buttonStyle(.plain)
            }

            if !chineseVoices.isEmpty {
                Section("中文") {
                    ForEach(chineseVoices, id: \.identifier) { voice in
                        voiceRow(voice)
                    }
                }
            }

            if !englishVoices.isEmpty {
                Section("英文") {
                    ForEach(englishVoices, id: \.identifier) { voice in
                        voiceRow(voice)
                    }
                }
            }

            if filtered.isEmpty {
                Section {
                    Text("没有匹配的音色")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索音色或语言")
        .navigationTitle("选择音色")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { SubtitleSpeaker.shared.stopAll() }
    }

    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        HStack(spacing: 10) {
            Button {
                voiceID = voice.identifier
                dismiss()
            } label: {
                row(title: voice.name,
                    subtitle: voice.language + (voice.quality == .enhanced ? " · 增强" : ""),
                    selected: voiceID == voice.identifier,
                    identifier: voice.identifier)
            }
            .buttonStyle(.plain)

            Button {
                previewing = voice.identifier
                SubtitleSpeaker.shared.preview(voiceID: voice.identifier)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if previewing == voice.identifier { previewing = nil }
                }
            } label: {
                Image(systemName: previewing == voice.identifier ? "speaker.wave.3.fill" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
        }
    }

    private func row(title: String, subtitle: String, selected: Bool, identifier: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}
