import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable(description: "Original song lyrics")
struct WrittenLyrics {
    @Guide(description: "Verse 1: four to six lines that set a scene with concrete images; no line repeated", .count(4...6))
    var verse1: [String]
    @Guide(description: "Chorus: four lines with the hook, memorable and singable; different from the verses", .count(3...5))
    var chorus: [String]
    @Guide(description: "Verse 2: four to six lines that move the story on with new images, not those of verse 1", .count(4...6))
    var verse2: [String]
    @Guide(description: "Bridge: three or four lines with a turn or a new perspective", .count(2...4))
    var bridge: [String]
    @Guide(description: "Outro: two or three complete closing lines that end the song", .count(2...3))
    var outro: [String]
    @Guide(description: "One word for the mood of the song")
    var mood: String
}
#endif

/// The Gemini flash models this app knows, newest last-resort first.
///
/// One list, so the settings picker and the style writer's fallback chain cannot drift apart.
enum Gemini {
    static let flashLine = ["gemini-3.5-flash", "gemini-3.6-flash",
                            "gemini-3.7-flash", "gemini-3.8-flash"]

    /// Asked only after every model above has refused. Quotas are counted per model, so a
    /// previous generation still has its own allowance on a key whose 3.x is spent — which is
    /// the difference between a written style and the bare preset on a busy night.
    static let lastResort = ["gemini-2.5-flash", "gemini-2.0-flash"]
}

/// Gemini REST API or on-device model for lyric writing and song title generation.
enum TitleSuggester {
    static var geminiApiKey: String {
        UserDefaults.standard.string(forKey: "geminiApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var geminiModel: String {
        let saved = UserDefaults.standard.string(forKey: "geminiModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? "gemini-3.5-flash" : saved
    }

    /// Returns true if either Gemini API key is provided or local Apple FoundationModels is available.
    static var modelAvailable: Bool {
        if !geminiApiKey.isEmpty { return true }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Write lyrics using Gemini API (priority) or FoundationModels on Mac.
    static func writeLyrics(style: String, title: String, about: String) async -> Result<String, Error>? {
        let key = geminiApiKey
        if !key.isEmpty {
            return await writeLyricsViaGemini(apiKey: key, model: geminiModel, style: style, title: title, about: about)
        }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions:
            "You write original, vivid song lyrics with varied imagery and no repeated lines except the chorus. Plain words, one phrase per line, no chord names, no markdown.")
        let request = "Write lyrics for a song.\nStyle: \(style.isEmpty ? "a popular song" : style)"
            + (title.isEmpty ? "" : "\nTitle: \(title)") + (about.isEmpty ? "" : "\nThe song is about: \(about)")
        do {
            let l = try await session.respond(to: request, generating: WrittenLyrics.self,
                                              options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 1500)).content
            let clean: ([String]) -> [String] = { $0.map(scrubLine).filter { !$0.isEmpty } }
            let sections: [[String]] = [
                ["[Verse]"], clean(l.verse1), ["", "[Chorus]"], clean(l.chorus), ["", "[Verse]"], clean(l.verse2),
                ["", "[Chorus]"], clean(l.chorus), ["", "[Bridge]"], clean(l.bridge), ["", "[Outro]"], clean(l.outro),
            ]
            return .success(sections.flatMap { $0 }.joined(separator: "\n"))
        } catch {
            return .failure(error)
        }
        #else
        return nil
        #endif
    }

    public static func writeLyricsViaGemini(apiKey: String, model: String, style: String, title: String, about: String) async -> Result<String, Error> {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            return .failure(NSError(domain: "TitleSuggester", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini URL"]))
        }

        let prompt = """
        You are a professional songwriter and lyricist.
        Write original, emotional song lyrics with standard structure tags like [Verse], [Pre-Chorus], [Chorus], [Bridge], [Outro].
        Match the requested language (Korean or English as requested), musical style, and theme.
        Only output the lyrics and section tags without extra commentary.

        Style: \(style.isEmpty ? "K-Pop ballad" : style)
        Title: \(title.isEmpty ? "Untitled" : title)
        Theme/Story: \(about.isEmpty ? "Heartfelt story" : about)

        After writing the lyrics, provide a brief style description (1-2 sentences) that matches the lyrics' mood, genre, and instrumentation.
        Format: "LYRICS\n\nSTYLE: <style description>"
        """

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.85,
                "maxOutputTokens": 2048
            ]
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let errBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(NSError(domain: "GeminiAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Gemini API error (\(http.statusCode)): \(errBody)"]))
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else {
                return .failure(NSError(domain: "GeminiAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Gemini response"]))
            }

            // Parse response: lyrics + style suggestion
            let resultText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let styleRange = resultText.range(of: "\nSTYLE: ", options: .backwards) {
                let lyrics = String(resultText[..<styleRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let suggestedStyle = String(resultText[resultText.index(after: styleRange.upperBound)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(lyrics)  // Return lyrics; style update handled in ContentView
            }

            return .success(resultText)
        } catch {
            return .failure(error)
        }
    }

    /// Strip structured-output debris (stray brackets, quotes, commas) from the ends of a line.
    private static func scrubLine(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, "]}\",".contains(last) { t.removeLast() }
        while let first = t.first, "[{\"".contains(first) { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func suggest(lyrics: String, style: String, instrumental: Bool) async -> String {
        let key = geminiApiKey
        if !key.isEmpty {
            if let title = await fromGemini(apiKey: key, model: geminiModel, lyrics: lyrics, style: style, instrumental: instrumental), !title.isEmpty {
                return title
            }
        }
        if let title = await fromModel(lyrics: lyrics, style: style, instrumental: instrumental), !title.isEmpty { return title }
        return fallback(lyrics: lyrics, style: style, instrumental: instrumental)
    }

    private static func fromGemini(apiKey: String, model: String, lyrics: String, style: String, instrumental: Bool) async -> String? {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }

        let body = instrumental || lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "An instrumental piece in this style: \(style)"
            : "Lyrics:\n" + String(lyrics.prefix(1500))

        let prompt = """
        You name songs. Given lyrics or a style description, reply with ONE evocative title of 2 to 5 words.
        Respond with the title ONLY in Korean or English (matching the language of the lyrics), no quotes, no explanation.

        \(body)
        """

        let payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.7, "maxOutputTokens": 60]
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else { return nil }

            return clean(text)
        } catch {
            return nil
        }
    }

    private static func fromModel(lyrics: String, style: String, instrumental: Bool) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let words = lyrics.split(whereSeparator: { $0.isWhitespace }).filter { !$0.hasPrefix("[") }
        let body = instrumental || words.count < 3
            ? "An instrumental piece in this style: \(style)"
            : "Lyrics:\n" + String(lyrics.prefix(3000))
        let session = LanguageModelSession(instructions:
            "You name songs. Given lyrics or a style description, reply with one evocative title of two to five words. Title only: no quotes, no punctuation at the end, no explanation.")
        do {
            let reply = try await session.respond(to: body).content
            return clean(reply)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func clean(_ text: String) -> String {
        var t = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.!,:; "))
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let capped = t.split(separator: " ").prefix(8).joined(separator: " ")
        return String(capped.prefix(60))
    }

    /// The first line of lyrics with words in it, up to five words; or the style's first words.
    static func fallback(lyrics: String, style: String, instrumental: Bool) -> String {
        let lines = lyrics.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if !instrumental, let line = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("[") }) {
            return clean(line.split(separator: " ").prefix(5).joined(separator: " ").capitalized)
        }
        return clean(style.split(separator: " ").prefix(4).joined(separator: " ").capitalized)
    }
}
