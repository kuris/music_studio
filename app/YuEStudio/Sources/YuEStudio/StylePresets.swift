import Foundation

/// The style presets, in the order they are offered.
///
/// One list for both places that offer them — the chips above the style prompt and the style
/// conversion sheet. They used to be two copies, which drifted: the chip read "K-pop 댄스"
/// while the prompt was filed under "K-pop 스", so that chip did nothing at all.
enum StylePresets {
    struct Preset: Identifiable {
        let name: String        // the chip's label
        let prompt: String      // what goes into the style field
        var id: String { name }
    }

    static let all: [Preset] = [
        Preset(name: "시티팝", prompt: "Korean city pop, warm analog synth, smooth bass, 95 BPM"),
        Preset(name: "트로트", prompt: "Korean trot, accordion, brass, upbeat rhythm, 120 BPM"),
        Preset(name: "발라드", prompt: "Korean ballad, piano, strings, emotional, 70 BPM"),
        Preset(name: "K-pop 댄스", prompt: "K-pop dance, electronic, energetic, 128 BPM"),
        Preset(name: "R&B", prompt: "R&B, soulful vocals, smooth production, 90 BPM"),
        Preset(name: "어쿠스틱 포크", prompt: "Acoustic folk, guitar, warm, 85 BPM"),
        Preset(name: "신스웨이브", prompt: "Synthwave, retro 80s, neon, 110 BPM"),
        Preset(name: "록 밴드", prompt: "Rock band, electric guitar, drums, 130 BPM"),
        Preset(name: "메탈", prompt: "Heavy metal, distorted guitars, double kick drums, aggressive, 150 BPM"),
        Preset(name: "재즈 보사노바", prompt: "Jazz bossa nova, piano, light percussion, 100 BPM"),
        Preset(name: "동요", prompt: "Children's song, simple melody, playful, 110 BPM"),
    ]

    static let names: [String] = all.map(\.name)
    static func prompt(_ name: String) -> String? { all.first { $0.name == name }?.prompt }
}
