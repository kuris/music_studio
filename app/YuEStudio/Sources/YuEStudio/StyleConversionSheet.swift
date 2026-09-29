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
                if let prompt = styleTags[selectedStyle] {
                    if style.isEmpty || style.contains("Korean") {
                        style = prompt
                    } else {
                        style = style + ", " + prompt
                    }
                }
                // The singer is part of the style prompt; replace any previous choice
                // rather than stacking contradictory ones.
                style = Self.withVocal(style, vocal)
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

            if abc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("전사된 멜로디가 없습니다 — 먼저 원곡을 전사하면 그 멜로디를 유지한 채 스타일만 바뀝니다.")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 660)
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
