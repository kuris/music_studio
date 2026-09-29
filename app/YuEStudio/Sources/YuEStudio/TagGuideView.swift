import SwiftUI

struct TagGuideView: View {
    @Environment(\.dismiss) private var dismiss

    let tagExamples = [
        ("[Verse]", "가사: 4-6줄, 구체적인 이미지와 스토리 전개"),
        ("[Pre-Chorus]", "전주: 2-4줄, 후렴부로 이어지는 연결"),
        ("[Chorus]", "후렴: 4줄, 가장 기억에 남는 훅과 메신지"),
        ("[Bridge]", "브리지: 3-4줄, 새로운 관점이나 전환"),
        ("[Outro]", "아웃트로: 2-3줄, 곡 마무리")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("가사 구조 태그 안내")
                .font(.headline)

            Text("가사에 구조 태그를 사용하면 곡의 흐름이 명확해지고 AI가 더 잘 이해합니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Tag Examples List
            VStack(alignment: .leading, spacing: 12) {
                ForEach(tagExamples, id: \.0) { tag, description in
                    HStack(alignment: .top, spacing: 12) {
                        Text(tag)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.purple)
                            .frame(width: 100, alignment: .leading)
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }
            }

            // Example Lyrics
            VStack(alignment: .leading, spacing: 8) {
                Text("예시:")
                    .font(.subheadline)
                Text("""
[Verse]
밤하늘 아래 걸어요
별빛이 비추는 길에서
너의 미소가 보여요
모든 게 아름답게 변해요

[Chorus]
새벽 두 시의 우리
두려움 없이 걸어요
도시의 별 아래에서
우리의 이야기가 시작돼요
""")
                    .font(.system(.caption, design: .monospaced))
                    .padding(12)
                    .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            // Buttons
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500, height: 450)
    }
}
