import SwiftUI
import AppKit

/// Reading and rewriting the parts of an ABC score the form cares about.
enum Score {
    /// The tempo from the ABC's Q: header (e.g. "Q:1/4=68").
    static func tempo(_ abc: String) -> Int? {
        guard let line = abc.split(separator: "\n").first(where: { $0.hasPrefix("Q:") }),
              let equals = line.lastIndex(of: "="),
              let bpm = Int(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)),
              bpm > 20, bpm < 300 else { return nil }
        return bpm
    }

    /// The same score at a new tempo. A score without a Q: header gets one after its L: line,
    /// which is where ABC expects it.
    static func withTempo(_ abc: String, _ bpm: Int) -> String {
        var lines = abc.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let i = lines.firstIndex(where: { $0.hasPrefix("Q:") }) {
            let beat = lines[i].drop(while: { $0 != ":" }).dropFirst()
                .prefix(while: { $0 != "=" }).trimmingCharacters(in: .whitespaces)
            lines[i] = "Q:\(beat.isEmpty ? "1/4" : beat)=\(bpm)"
        } else if let i = lines.firstIndex(where: { $0.hasPrefix("L:") }) {
            lines.insert("Q:1/4=\(bpm)", at: i + 1)
        } else {
            return abc
        }
        return lines.joined(separator: "\n")
    }

    /// What the transcription says about the song, in the words a style writer needs: key,
    /// metre, tempo, length and — the part that shapes an arrangement most — the run of
    /// sections the transcriber marked ("% intro", "% verse", …) and whether the score carries
    /// a separate instrumental line beside the vocal one.
    static func analysis(_ abc: String) -> String {
        let lines = abc.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func header(_ prefix: String) -> String? {
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        var out: [String] = []
        if let key = header("K:") { out.append("key: \(key)") }
        let metre = header("M:")
        if let metre { out.append("metre: \(metre)") }
        let bpm = tempo(abc)
        if let bpm { out.append("tempo: \(bpm) BPM") }

        // The body only: headers and voice declarations carry no bars.
        let body = lines.filter { $0.count < 2 || $0.dropFirst().first != ":" }
        let bars = body.joined(separator: "\n").components(separatedBy: "|").count - 1
        // One voice's bars are the song's bars; a two-voice score counts each bar once per voice.
        // The voices are named, not counted: "V: Vocal" heads every one of its body lines too.
        let named = Set(lines.filter { $0.hasPrefix("V:") }.compactMap {
            $0.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        })
        let songBars = bars / max(1, named.count)
        if songBars > 3 {
            var length = "\(songBars) bars"
            let beats = metre.flatMap { Int($0.split(separator: "/").first ?? "") } ?? 4
            if let bpm, bpm > 0 {
                let seconds = Int(Double(songBars * beats) / Double(bpm) * 60)
                length += String(format: ", about %d:%02d", seconds / 60, seconds % 60)
            }
            out.append("length: \(length)")
        }

        // "% intro", "% verse", … in the order the transcriber marked them.
        var sections: [String] = []
        for line in lines where line.hasPrefix("%") && !line.hasPrefix("%%") {
            let name = line.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, name.count < 20, sections.last != name else { continue }
            sections.append(name)
        }
        if !sections.isEmpty { out.append("structure: " + sections.joined(separator: " → ")) }

        if lines.contains(where: { $0.contains("name=\"Ins Melody\"") || $0.hasPrefix("V: Ins") }) {
            out.append("parts: a vocal melody line and a separate instrumental melody line")
        }
        return out.joined(separator: "\n")
    }

    /// Style text restating a tempo it already mentions. YuE2 takes the tempo from the ABC and
    /// the style has to describe it consistently, so the two are changed together.
    static func styleAtTempo(_ style: String, _ bpm: Int) -> String {
        style.replacingOccurrences(of: "\\d+ BPM", with: "\(bpm) BPM", options: .regularExpression)
    }
}

/// Edit the melody score already in the form. Until this existed a transcription could only be
/// corrected in the review sheet, before "Use melody" — after that the score was fixed for good.
struct ScoreEditSheet: View {
    @Binding var abc: String
    @Binding var style: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var bpm = 0
    @State private var originalBPM: Int?

    /// Write the score out so it can be opened in a real ABC editor.
    private func exportScore() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "melody.abc"
        panel.message = "멜로디 악보를 ABC 파일로 저장합니다"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Score.withTempo(draft, bpm).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Read a score back in, so an edit made elsewhere returns to the form.
    private func importScore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "ABC 악보 파일을 선택하세요"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        draft = text
        originalBPM = Score.tempo(text)
        bpm = originalBPM ?? bpm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("멜로디 악보 편집").font(.headline)
            Text("전사된 ABC 악보입니다. 틀린 음을 고치거나 템포를 바꿀 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("템포").font(.callout).bold()
                if originalBPM == nil {
                    Text("이 악보에는 Q: 헤더가 없습니다 — 저장하면 추가됩니다")
                        .font(.caption).foregroundStyle(.orange)
                }
                Stepper(value: $bpm, in: 40...220, step: 2) {
                    Text("\(bpm) BPM").font(.callout).monospacedDigit()
                }.frame(width: 160)
                if let original = originalBPM, bpm != original {
                    Text("원래 \(original) · 길이 ×\(String(format: "%.2f", Double(original) / Double(bpm)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            TextEditor(text: $draft)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("저장하면 스타일 프롬프트의 BPM도 같은 값으로 맞춥니다.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("파일로 저장") { exportScore() }
                Button("불러오기") { importScore() }
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") {
                    abc = Score.withTempo(draft, bpm)
                    style = Score.styleAtTempo(style, bpm)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding().frame(width: 680, height: 560)
        .onAppear {
            draft = abc
            originalBPM = Score.tempo(abc)
            bpm = originalBPM ?? 100
        }
    }
}
