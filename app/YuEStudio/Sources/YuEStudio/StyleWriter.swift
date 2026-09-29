import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A full style prompt written around a preset, for one particular song.
///
/// The presets are a single line each — "Korean city pop, warm analog synth, smooth bass, 95 BPM"
/// — which names a genre and describes nothing else. A model is asked to write that line out in
/// full for the song at hand: the key, metre, tempo and section order the transcription found,
/// and the mood of its words.
///
/// One refusal is not an answer. Gemini turns "high demand" away with a 503 often enough that a
/// single try left the cover running on the bare preset, so a busy model is asked again, then a
/// different Gemini model, then the on-device model; the preset stands only when none of them
/// will write. Whichever happened comes back as a line for the log.
enum StyleWriter {
    /// How long the whole attempt may take before the preset is used instead. Generous,
    /// because nothing waits on it: the preset is in the field from the first moment and the
    /// written style replaces it if and when it arrives.
    private static let deadline = 45.0
    private static let clock = "\u{23F1}"     // the deadline task's stand-in for a model name

    /// A richer style for this song, with a line for the log saying how it went.
    static func enrich(preset: String, tempo: Int?, analysis: String, title: String,
                       lyrics: String, instrumental: Bool) async -> (style: String?, note: String) {
        let ask = prompt(preset: preset, tempo: tempo, analysis: analysis,
                         title: title, lyrics: lyrics, instrumental: instrumental)
        var trouble: [String] = []

        let key = TitleSuggester.geminiApiKey
        if key.isEmpty {
            trouble.append("Gemini API 키 없음")
        } else {
            var models: [String] = []
            for model in [TitleSuggester.geminiModel] + Gemini.flashLine
            where !models.contains(model) { models.append(model) }

            // All of them at once. Asked one after another, a model that turns us away for load
            // costs the whole wait before the next is even tried, and four of those ran to half
            // a minute; raced, the first line back wins and the rest are cancelled.
            let raced = await withTaskGroup(of: (String, Answer).self) { group -> (String?, [String]) in
                for model in models {
                    group.addTask { (model, await gemini(model: model, key: key, prompt: ask)) }
                }
                // And a clock, so the wait has an end whatever the models do. Nobody should sit
                // on "스타일 작성 중" wondering whether it is still going.
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                    return (clock, .no("시간 초과"))
                }
                var notes: [String] = []
                for await (model, answer) in group {
                    if model == clock {
                        group.cancelAll()
                        return (nil, notes + ["\(Int(deadline))초 안에 답이 없었습니다"])
                    }
                    switch answer {
                    case .wrote(let line):
                        group.cancelAll()
                        return ("\(model)|\(line)", notes)     // which model wrote it, for the log
                    case .again(let why), .no(let why):
                        notes.append("\(model) \(why)")
                        // Every model has now refused: fall back at once rather than sit out
                        // the rest of the clock.
                        if notes.count == models.count { group.cancelAll(); return (nil, notes) }
                    }
                }
                return (nil, notes)
            }
            if let tagged = raced.0, let bar = tagged.firstIndex(of: "|") {
                let model = String(tagged[..<bar])
                let line = String(tagged[tagged.index(after: bar)...])
                return (line, "Gemini \(model)가 스타일을 썼습니다 "
                        + "(\(line.split(separator: ",").count)개 항목)"
                        + (raced.1.isEmpty ? "" : " · 다른 모델: \(raced.1.joined(separator: " · "))"))
            }
            trouble += raced.1

            // The whole flash line turned us away. Older models keep their own quota, so one
            // last ask before the preset stands.
            for model in Gemini.lastResort where !models.contains(model) {
                switch await gemini(model: model, key: key, prompt: ask) {
                case .wrote(let line):
                    return (line, "Gemini \(model)가 스타일을 썼습니다 "
                            + "(\(line.split(separator: ",").count)개 항목)"
                            + " · 앞선 모델: \(raced.1.joined(separator: " · "))")
                case .again(let why), .no(let why):
                    trouble.append("\(model) \(why)")
                }
            }
        }

        trouble.append(onDeviceState())
        if let line = await onDevice(prompt: ask) {
            return (line, "기기 내 모델이 스타일을 썼습니다 (\(line.split(separator: ",").count)개 항목)"
                    + " · Gemini: \(trouble.joined(separator: " · "))")
        }
        return (nil, "기본 프롬프트를 씁니다 — " + trouble.joined(separator: " · "))
    }

    // MARK: - The request

    /// What we ask for, in the words both models get.
    private static func prompt(preset: String, tempo: Int?, analysis: String, title: String,
                               lyrics: String, instrumental: Bool) -> String {
        // The singer is chosen elsewhere in the form and written into the style after this, so
        // the prompt asks for the delivery without a gender rather than contradicting that choice.
        // An instrumental is not a song with the singing removed: something else has to carry the
        // tune, and the sections are where it gets to do so.
        let voiceRule = instrumental
            ? """
              There are no vocals. Name the instrument that carries the melody in the singer's \
              place and give it something to do across the sections — a riff that opens, a \
              countermelody under the verses, a solo where the bridge falls. Never mention a \
              singer, a voice, vocals or lyrics.
              """
            : """
              Describe the vocal delivery, the harmonies and how the voice is treated, but never \
              state the singer's gender.
              """
        let words = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = instrumental || words.isEmpty
            ? "No lyrics — an instrumental piece."
            : "Lyrics (for mood only, do not quote them):\n\(String(words.prefix(600)))"

        return """
        Write the style prompt for this song. Reply with the line itself and nothing else.

        The form to follow — its shape, not its content:
        Symphonic melodic death metal, twin harmonised lead guitars, low-tuned rhythm guitars, \
        orchestral string pads, blast-beat double kick, half-time chorus groove, arpeggiated \
        clean intro, palm-muted verses, octave-lead choruses, guitar solo at the bridge, outro \
        thinning to clean guitar, dense modern mix, scooped mids, glacial reverb, wintry and \
        defiant, 63 BPM

        So: 14 to 20 comma-separated descriptors in English, each a few words, never a sentence. \
        Between them they name the genre and sub-genre, what carries the melody, the supporting \
        instruments, the groove, how the arrangement changes from section to section, the \
        production and the mood — and the tempo comes last as "<number> BPM".

        Keep the preset's genre and the song's tempo. The melody was transcribed, so the key, \
        metre, length and run of sections below are this song's: arrange the genre to them. \
        \(voiceRule)

        Preset genre: \(preset)
        The song, as transcribed:
        \(analysis.isEmpty ? (tempo.map { "tempo: \($0) BPM" } ?? "no score") : analysis)
        Song title: \(title.isEmpty ? "untitled" : title)
        \(about)
        """
    }

    /// What one call to a model came to.
    private enum Answer: Sendable {
        case wrote(String)
        case again(String)      // busy, unreachable, or an answer worth asking again for
        case no(String)         // this model will not serve this request at all
    }

    /// One model, asked once — first with thinking switched off, and again with the field left
    /// out if the model does not know it.
    ///
    /// These flash models think before they answer and spend the same budget doing it, which put
    /// the only model that would write us a style past a 20-second wait. The style is a list of
    /// descriptors; it does not need deliberation.
    private static func gemini(model: String, key: String, prompt: String) async -> Answer {
        let answer = await ask(model: model, key: key, prompt: prompt, thinking: false)
        if case .no(let why) = answer, why.hasPrefix("오류 400") {
            return await ask(model: model, key: key, prompt: prompt, thinking: true)
        }
        return answer
    }

    private static func ask(model: String, key: String, prompt: String, thinking: Bool) async -> Answer {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/"
                            + "\(model):generateContent?key=\(key)") else { return .no("주소 오류") }
        // A schema, because a model asked in prose for "one line" sometimes answers with its
        // plan for the line instead — a numbered list restating the instructions.
        var payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.8,
                // Room to spare: these models think before they answer, and thinking spends the
                // same budget — at 900 the style itself was being cut off mid-word.
                "maxOutputTokens": 4096,
                "responseMimeType": "application/json",
                "responseSchema": ["type": "OBJECT",
                                   "properties": ["style": ["type": "STRING"]],
                                   "required": ["style"]],
            ],
        ]
        if !thinking {
            var config = payload["generationConfig"] as? [String: Any] ?? [:]
            config["thinkingConfig"] = ["thinkingBudget": 0]
            payload["generationConfig"] = config
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = deadline    // the group's clock stops it anyway

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                let body = (String(data: data, encoding: .utf8) ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                let why = "오류 \(status): \(body.prefix(120))"
                // Overload and rate limits pass; a bad request or a wrong model name will not.
                return [429, 500, 502, 503, 504].contains(status) ? .again(why) : .no(why)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else {
                return .again("응답을 읽지 못함")
            }
            let answer = styleValue(text)
            guard let line = usable(answer) else {
                let stopped = (candidates.first?["finishReason"] as? String).map { " [\($0)]" } ?? ""
                return .again("스타일 한 줄이 아님\(stopped): "
                              + answer.trimmingCharacters(in: .whitespacesAndNewlines)
                                  .replacingOccurrences(of: "\n", with: " ").prefix(100))
            }
            return .wrote(line)
        } catch {
            return .again("호출 실패: \(error.localizedDescription)")
        }
    }

    /// The style the schema asked for — or as much of it as arrived.
    ///
    /// A model that spends its budget thinking is cut off mid-string, and JSON that stops in the
    /// middle is still worth the descriptors it did carry. Whole answers parse; a truncated one
    /// is read out by hand and trimmed back to its last complete descriptor.
    static func styleValue(_ text: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let style = object["style"] as? String { return style }
        guard let opening = text.range(of: "\"style\"\\s*:\\s*\"", options: .regularExpression) else {
            return text
        }
        var value = String(text[opening.upperBound...])
        if let closing = value.range(of: "(?<!\\\\)\"", options: .regularExpression) {
            value = String(value[..<closing.lowerBound])          // the whole string, just unparsed
        } else if let lastComma = value.lastIndex(of: ",") {
            value = String(value[..<lastComma])                   // cut off: keep what is complete
        }
        return value.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Whether the Mac's own model is there to ask — in words, because a fallback that quietly
    /// does nothing looks exactly like one that was never written.
    private static func onDeviceState() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "기기 내 모델 사용 가능"
            case .unavailable(.appleIntelligenceNotEnabled): return "기기 내 모델: Apple Intelligence 꺼짐"
            case .unavailable(.modelNotReady): return "기기 내 모델: 아직 내려받는 중"
            case .unavailable(let reason): return "기기 내 모델 사용 불가 (\(reason))"
            }
        }
        return "기기 내 모델: macOS 26 필요"
        #else
        return "기기 내 모델: 이 빌드에 없음"
        #endif
    }

    /// The model on this Mac, for when Gemini will not answer at all.
    private static func onDevice(prompt: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions:
            "You write style prompts for a music model. Answer with ONE line of comma-separated "
            + "descriptors in English — 14 to 20 of them, each a few words. No sentences, no "
            + "explanation, no markdown, no line breaks.")
        for _ in 0..<2 {
            guard let reply = try? await session.respond(to: prompt).content else { return nil }
            if let line = usable(reply) { return line }
        }
        return nil
        #else
        return nil
        #endif
    }

    // MARK: - Reading the answer

    /// One line of descriptors, or nil if what came back is not one.
    ///
    /// A model that answers with a paragraph, a code fence or a bare genre name is not an
    /// improvement on the preset. One that explains itself first and then writes the line is,
    /// though — so every line of the answer is considered, longest first, before giving up.
    static func usable(_ text: String) -> String? {
        let body = text.replacingOccurrences(of: "```", with: " ")
        let lines = body.components(separatedBy: .newlines).sorted { $0.count > $1.count }
        for candidate in lines {
            if let line = descriptors(candidate) { return line }
        }
        // A single line the sender wrapped: try it back as one.
        return descriptors(body.replacingOccurrences(of: "\n", with: " "))
    }

    /// One string read as a list of descriptors, or nil if it does not read as one.
    private static func descriptors(_ text: String) -> String? {
        var line = text.replacingOccurrences(of: "^\\s*(style|prompt|style prompt)\\s*:\\s*", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        line = line.replacingOccurrences(of: "^\\s*[0-9]+[.)]\\s*", with: "",
                                         options: .regularExpression)
        let strip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'*-•.;"))
        let parts = line.split(separator: ",")
            .map { $0.trimmingCharacters(in: strip) }
            .filter { !$0.isEmpty }
        guard parts.count >= 6, parts.count <= 40 else { return nil }
        // Descriptors, not prose: a part running to a whole clause is a sentence in disguise.
        guard parts.allSatisfy({ $0.split(separator: " ").count <= 12 }) else { return nil }
        // Nor a restatement of what was asked for.
        guard !parts.contains(where: { $0.lowercased().contains("descriptor") }) else { return nil }
        let joined = parts.joined(separator: ", ")
        return joined.count <= 1200 ? joined : nil
    }

    /// The style stating this tempo — rewriting the BPM it names, or naming it when it names none.
    static func atTempo(_ style: String, _ bpm: Int?) -> String {
        guard let bpm else { return style }
        if style.range(of: "\\d+ ?BPM", options: [.regularExpression, .caseInsensitive]) != nil {
            return Score.styleAtTempo(style, bpm)
        }
        return style + ", \(bpm) BPM"
    }
}
