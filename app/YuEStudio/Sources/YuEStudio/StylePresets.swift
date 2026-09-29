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

/// The singer, which YuE2 reads from the style text rather than a request field.
///
/// Writing the choice straight into the style keeps it honest: it is visible in the prompt,
/// it applies to every way a song is started, and there is only ever one such tag.
enum Vocal {
    static let choices: [(key: String, label: String, tag: String)] = [
        ("auto", "자동", ""),
        ("female", "여성", "female vocal"),
        ("male", "남성", "male vocal"),
        ("duet", "듀엣", "male and female duet vocals"),
    ]

    static func tag(_ key: String) -> String { choices.first { $0.key == key }?.tag ?? "" }

    /// Style text naming exactly the chosen singer.
    ///
    /// A hand-written phrase like "soaring male vocals" is rewritten in place rather than left
    /// to contradict an appended tag — switching to 여성 gives "soaring female vocals" and keeps
    /// the adjective. Only when no phrase names a singer is the plain tag added.
    static func apply(_ style: String, _ key: String) -> String {
        var parts = style.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        parts.removeAll { part in
            choices.contains { !$0.tag.isEmpty && $0.tag.caseInsensitiveCompare(part) == .orderedSame }
        }
        guard let gender = ["female": "female", "male": "male", "duet": "male and female"][key] else {
            return parts.joined(separator: ", ")          // 자동: name no singer at all
        }
        // "male and female" first so it is not half-matched by "male".
        let namesSinger = "\\b(male and female|female|male)\\b"
        var named = false
        for i in parts.indices where parts[i].lowercased().contains("vocal") {
            guard parts[i].range(of: namesSinger, options: [.regularExpression, .caseInsensitive]) != nil
            else { continue }
            named = true        // already names a singer, even when it is the one chosen
            parts[i] = parts[i].replacingOccurrences(of: namesSinger, with: gender,
                                                     options: [.regularExpression, .caseInsensitive])
        }
        if !named { parts.append(tag(key)) }
        return parts.joined(separator: ", ")
    }
}
