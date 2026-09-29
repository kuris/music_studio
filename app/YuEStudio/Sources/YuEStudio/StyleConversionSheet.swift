import SwiftUI

struct StyleConversionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var backend: Backend
    @AppStorage("style") private var style = ""
    @AppStorage("styleVocal") private var vocal = "auto"
    // The cover keeps the form's melody and words — the same values the main Generate button uses.
    @AppStorage("lyrics") private var lyrics = ""
    @AppStorage("abc") private var abc = ""
    @AppStorage("abcOpen") private var abcOpen = false
    @AppStorage("title") private var title = ""
    @AppStorage("titleAuto") private var titleAuto = ""
    @AppStorage("seed") private var seed = 831001
    @AppStorage("maxSeconds") private var maxSeconds = 120.0
    @AppStorage("instrumental") private var instrumental = false
    // A cover follows the main form's quality setting rather than forcing its own, so the
    // choice stays in one place; the sheet shows which one it will use.
    @AppStorage("qualityMode") private var qualityMode = "draft-gpu"
    @AppStorage("batch") private var batch = 2
    @AppStorage("randomSeed") private var randomSeed = false
    private var quality: String { qualityMode.hasPrefix("draft") ? "draft" : "full" }
    private var engines: String { qualityMode.hasSuffix("-ane") ? "gpu+ane" : "gpu" }
    @State private var selectedStyle = ""
    @State private var converting = false

    /// Appended to the style prompt: YuE2 takes the singer from the style text.
    static let vocalTags = ["auto": "", "female": "female vocal", "male": "male vocal",
                            "duet": "male and female duet vocals"]


    var body: some View {
        VStack(spacing: 20) {
            Text("스타일 변환")
                .font(.headline)

            Text("원곡의 멜로디를 유지하면서 스타일을 변경합니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Vocal Selection
            VStack(alignment: .leading, spacing: 6) {
                Text("보컬").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $vocal) {
                    Text("자동").tag("auto")
                    Text("여성").tag("female")
                    Text("남성").tag("male")
                    Text("듀엣").tag("duet")
                }.pickerStyle(.segmented).labelsHidden()
            }.frame(maxWidth: .infinity, alignment: .leading)

            // How many candidates to generate. Shared with the main Generate button, which
            // has no control of its own. The worker batches tokenizing by what memory allows
            // and queues the rest, so asking for more than that still works.
            VStack(alignment: .leading, spacing: 6) {
                Text("동시 생성").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $batch) {
                    ForEach(1...4, id: \.self) { Text("\($0)곡").tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }.frame(maxWidth: .infinity, alignment: .leading)

            // Style Selection Grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                    ForEach(StylePresets.all) { preset in
                        let tag = preset.name
                        Button(action: {
                            selectedStyle = tag
                        }) {
                            VStack(spacing: 4) {
                                Text(tag)
                                    .font(.headline)
                                Text(preset.prompt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                selectedStyle == tag
                                ? Color.purple.opacity(0.2)
                                : Color.gray.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selectedStyle == tag ? Color.purple : Color.clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }

            // Convert Button
            Button(action: {
                converting = true
                // Apply selected style
                // A conversion replaces the style outright. Appending would stack two
                // genres and two tempos, which read as contradictory instructions.
                if let prompt = StylePresets.prompt(selectedStyle) {
                    style = Self.withVocal(Score.tempo(abc).map { Score.styleAtTempo(prompt, $0) } ?? prompt, vocal)
                }
                title = Self.coverTitle(from: title.isEmpty ? titleAuto : title, style: selectedStyle)
                // Generate cover song
                Task {
                    backend.generate(
                        title: title.trimmingCharacters(in: .whitespaces),
                        style: style,
                        lyrics: lyrics,
                        cot: "melody",
                        seed: seed,
                        randomSeed: randomSeed,
                        batch: batch,
                        maxTokens: Int(maxSeconds * 25),
                        engine: "auto",
                        abc: abc,
                        abcOpen: abcOpen,
                        quality: quality,
                        engines: engines,
                        instrumental: instrumental
                    )
                    converting = false
                    dismiss()
                }
            }) {
                HStack {
                    if converting {
                        ProgressView()
                        Text("생성 중...")
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("변환하기")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    LinearGradient(
                        colors: [.purple, .pink],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(.white)
                .font(.headline)
            }
            .disabled(selectedStyle.isEmpty || converting)

            carryOver

            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 660)
    }

    /// What the conversion takes from the form, so nothing silently goes missing.
    private var carryOver: some View {
        VStack(alignment: .leading, spacing: 3) {
            if abc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("전사된 멜로디가 없습니다 — 먼저 원곡을 전사하세요", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label("멜로디 유지" + (Score.tempo(abc).map { " · \($0) BPM" } ?? ""),
                      systemImage: "checkmark.circle")
            }
            Label(lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? "가사 없음 — 연주곡으로 생성됩니다"
                  : "가사 \(lyrics.split(separator: "\n").filter { !$0.hasPrefix("[") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)줄 사용",
                  systemImage: lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.orange : Color.secondary)
            Label("품질: " + (quality == "draft" ? "draft · 8단계 (빠른 미리보기)"
                                                : "full · 32단계" + (engines == "gpu" ? " · GPU" : " · Neural Engine + GPU"))
                  + " · \(batch)곡",
                  systemImage: "dial.medium")
            if !selectedStyle.isEmpty {
                Label("제목: \(Self.coverTitle(from: title.isEmpty ? titleAuto : title, style: selectedStyle))",
                      systemImage: "textformat")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "제목_스타일_커버", built from whatever name the song already carries.
    static func coverTitle(from name: String, style: String) -> String {
        let base = name.split(separator: "_").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !base.isEmpty else { return "\(style)_커버" }
        return "\(base)_\(style)_커버"
    }

    /// Style text carrying exactly one vocal tag — the chosen one, or none for "자동".
    static func withVocal(_ style: String, _ vocal: String) -> String {
        var parts = style.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in
                !part.isEmpty && !vocalTags.values.contains { !$0.isEmpty && $0.caseInsensitiveCompare(part) == .orderedSame }
            }
        if let tag = vocalTags[vocal], !tag.isEmpty { parts.append(tag) }
        return parts.joined(separator: ", ")
    }
}
