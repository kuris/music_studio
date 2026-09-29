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
    @State private var selectedStyle = ""
    @State private var converting = false

    /// Appended to the style prompt: YuE2 takes the singer from the style text.
    static let vocalTags = ["auto": "", "female": "female vocal", "male": "male vocal",
                            "duet": "male and female duet vocals"]

    let styleTags = [
        "시티팝": "Korean city pop, warm analog synth, smooth bass, 95 BPM",
        "트로트": "Korean trot, accordion, brass, upbeat rhythm, 120 BPM",
        "발라드": "Korean ballad, piano, strings, emotional, 70 BPM",
        "K-pop 스": "K-pop dance, electronic, energetic, 128 BPM",
        "R&B": "R&B, soulful vocals, smooth production, 90 BPM",
        "어쿠스틱 포크": "Acoustic folk, guitar, warm, 85 BPM",
        "신스웨이브": "Synthwave, retro 80s, neon, 110 BPM",
        "록 밴드": "Rock band, electric guitar, drums, 130 BPM",
        "재즈 보사노바": "Jazz bossa nova, piano, light percussion, 100 BPM",
        "동요": "Children's song, simple melody, playful, 110 BPM"
    ]

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

            // Style Selection Grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                    ForEach(Array(styleTags.keys), id: \.self) { tag in
                        Button(action: {
                            selectedStyle = tag
                        }) {
                            VStack(spacing: 4) {
                                Text(tag)
                                    .font(.headline)
                                Text(styleTags[tag] ?? "")
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
                if let prompt = styleTags[selectedStyle] {
                    style = Self.withVocal(Self.atMelodyTempo(prompt, abc), vocal)
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
                        randomSeed: false,
                        batch: 1,
                        maxTokens: Int(maxSeconds * 25),
                        engine: "auto",
                        abc: abc,
                        abcOpen: abcOpen,
                        quality: "full",
                        engines: "gpu+ane",
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
                Label("멜로디 유지" + (Self.melodyTempo(abc).map { " · \($0) BPM" } ?? ""),
                      systemImage: "checkmark.circle")
            }
            Label(lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? "가사 없음 — 연주곡으로 생성됩니다"
                  : "가사 \(lyrics.split(separator: "\n").filter { !$0.hasPrefix("[") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)줄 사용",
                  systemImage: lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.orange : Color.secondary)
            if !selectedStyle.isEmpty {
                Label("제목: \(Self.coverTitle(from: title.isEmpty ? titleAuto : title, style: selectedStyle))",
                      systemImage: "textformat")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The melody's own tempo, read from the ABC's Q: header (e.g. "Q:1/4=68").
    static func melodyTempo(_ abc: String) -> Int? {
        guard let line = abc.split(separator: "\n").first(where: { $0.hasPrefix("Q:") }),
              let equals = line.lastIndex(of: "="),
              let bpm = Int(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)),
              bpm > 20, bpm < 300 else { return nil }
        return bpm
    }

    /// A preset's BPM restated as the transcribed melody's. YuE2 takes tempo from the ABC,
    /// and the docs require the style to describe it consistently — a preset's stock BPM
    /// would otherwise contradict the score by a factor of two.
    static func atMelodyTempo(_ prompt: String, _ abc: String) -> String {
        guard let bpm = melodyTempo(abc) else { return prompt }
        return prompt.replacingOccurrences(of: "\\d+ BPM", with: "\(bpm) BPM",
                                           options: .regularExpression)
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
