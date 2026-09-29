import SwiftUI

struct StyleConversionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var backend: Backend
    @AppStorage("style") private var style = ""
    @State private var selectedStyle = ""
    @State private var converting = false

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
                // Generate cover song
                Task {
                    await backend.generate(
                        title: "",
                        style: style,
                        lyrics: "",
                        cot: "melody",
                        seed: 831001,
                        randomSeed: false,
                        batch: 1,
                        maxTokens: 3000,
                        engine: "auto",
                        abc: "", // Will use existing ABC from background
                        abcOpen: false,
                        quality: "full",
                        engines: "gpu+ane",
                        instrumental: false
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

            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 600)
    }
}
