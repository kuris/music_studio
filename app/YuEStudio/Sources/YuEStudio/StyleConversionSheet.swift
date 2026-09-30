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
    @AppStorage("melodyAdherence") private var adherence = 1.0
    // A cover follows the main form's quality setting rather than forcing its own, so the
    // choice stays in one place; the sheet shows which one it will use.
    @AppStorage("qualityMode") private var qualityMode = "draft-gpu"
    @AppStorage("batch") private var batch = 2
    @AppStorage("randomSeed") private var randomSeed = false
    @AppStorage("matchGenreTempo") private var matchGenreTempo = true
    private var quality: String { qualityMode.hasPrefix("draft") ? "draft" : "full" }
    private var engines: String { qualityMode.hasSuffix("-ane") ? "gpu+ane" : "gpu" }
    @State private var selectedStyle = ""
    @State private var converting = false
    @State private var writing = false        // Gemini is writing the style out



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
                    ForEach(Vocal.choices, id: \.key) { Text($0.label).tag($0.key) }
                }.pickerStyle(.segmented).labelsHidden()
                    // 악기 is the same choice as the main form's 연주곡 switch.
                    .onChange(of: vocal) { _, new in instrumental = (new == Vocal.instrumental) }
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
            Button(action: { Task { await convert() } }) {
                HStack {
                    if converting {
                        ProgressView()
                        Text(writing ? "스타일 작성 중 (Gemini)..." : "생성 중...")
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
                if let planned = plannedTempo {
                    Label("템포 \(planned.from) → \(planned.to) BPM (\(planned.ratio)) · 길이 ×\(String(format: "%.2f", Double(planned.from) / Double(planned.to)))",
                          systemImage: "metronome")
                        .foregroundStyle(Color.accentColor)
                }
                Toggle("장르 템포에 맞춰 조정", isOn: $matchGenreTempo)
                    .toggleStyle(.checkbox).font(.caption)
                    .help("원곡 템포를 장르 쪽으로 옮깁니다. 같은 곡으로 들리는 배수(1/2, 2/3, 3/4, 4/3, 1.5, 2배)만 씁니다.")
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

    /// Move the score toward the genre's tempo, returning the tempo the style should name.
    /// The ABC is rewritten as well — it is what the melody is played from, so leaving it at the
    /// original speed under a style naming another is two instructions that contradict.
    private func retimeForGenre(_ tag: String) -> Int? {
        let original = Score.tempo(abc)
        guard matchGenreTempo, let original, let genre = StylePresets.tempo(tag),
              let fitted = Score.tempoFitting(original: original, genre: genre),
              fitted.bpm != original
        else { return original }
        abc = Score.withTempo(abc, fitted.bpm)
        backend.append("템포: \(original) → \(fitted.bpm) BPM (\(fitted.ratio), \(tag) 기준 \(genre))")
        return fitted.bpm
    }

    /// What the tempo will become if this conversion runs, for the carry-over line to show.
    private var plannedTempo: (from: Int, to: Int, ratio: String)? {
        guard matchGenreTempo, !selectedStyle.isEmpty,
              let original = Score.tempo(abc), let genre = StylePresets.tempo(selectedStyle),
              let fitted = Score.tempoFitting(original: original, genre: genre),
              fitted.bpm != original
        else { return nil }
        return (original, fitted.bpm, fitted.ratio)
    }

    /// "제목_스타일_커버", built from whatever name the song already carries.
    /// Write the style for the chosen genre, then start the cover.
    ///
    /// A conversion replaces the style outright. Appending would stack two genres and two
    /// tempos, which read as contradictory instructions.
    private func convert() async {
        converting = true
        if let preset = StylePresets.prompt(selectedStyle) {
            let bpm = retimeForGenre(selectedStyle)
            let plain = StyleWriter.atTempo(preset, bpm)
            // The preset is one line and names a genre; Gemini writes it out for this song,
            // against what the transcription says the song actually is. Anything short of an
            // answer we can use — no key, no network, a refusal — leaves the preset standing.
            writing = true
            let (written, note) = await StyleWriter.enrich(preset: preset, tempo: bpm,
                                                           analysis: Score.analysis(abc),
                                                           title: title.isEmpty ? titleAuto : title,
                                                           lyrics: lyrics, instrumental: instrumental)
            writing = false
            backend.append("스타일 작성: \(note)")     // why the style reads as it does
            style = Vocal.apply(StyleWriter.atTempo(written ?? plain, bpm), vocal)
            backend.append("스타일: \(style)")
        }
        title = Self.coverTitle(from: title.isEmpty ? titleAuto : title, style: selectedStyle)
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
            instrumental: instrumental,
            semanticTemperature: abc.isEmpty ? nil : adherence
        )
        converting = false
        dismiss()
    }

    static func coverTitle(from name: String, style: String) -> String {
        let base = name.split(separator: "_").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !base.isEmpty else { return "\(style)_커버" }
        return "\(base)_\(style)_커버"
    }

}
