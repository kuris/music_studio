import Foundation

/// Lay published lyrics out under the sections the transcriber found.
///
/// The transcription gives two different things, and only one of them is trustworthy. The
/// *words* Whisper heard are often wrong — sung Korean defeats it regularly. The *timeline*
/// is not: SheetSage2's structure.lab says where each section runs, and even a misheard line
/// is timed roughly where it was actually sung. So the real lyrics are matched line-by-line
/// against the misheard ones to borrow their clocks, and then dropped into their sections.
enum LyricsStructurer {

    struct Fitted {
        let text: String
        let anchors: Int        // real lines that found their moment in the recording
        let sections: Int       // section tags the result carries
        let timed: Bool         // false when the layout had to fall back to section lengths

        var note: String {
            if sections == 0 { return "전사된 곡 구조가 없어 가사를 그대로 넣었습니다." }
            if timed { return "벅스 가사를 전사된 구조에 맞췄습니다 — 구간 \(sections)개, 타이밍 기준 \(anchors)줄." }
            return "벅스 가사를 구간 길이에 비례해 \(sections)개 구간으로 나눴습니다 — 확인해 주세요."
        }
    }

    /// structure.lab labels → the tags the lyrics field documents. Kept in step with
    /// tools/lyrics_asr.py's SECTION_TAGS, which tags the recognised words the same way.
    static let sectionTags: [String: String] = [
        "intro": "[Intro]", "verse": "[Verse]", "pre-chorus": "[Pre-Chorus]",
        "prechorus": "[Pre-Chorus]", "chorus": "[Chorus]", "bridge": "[Bridge]",
        "interlude": "[Interlude]", "outro": "[Outro]", "solo": "[Interlude]",
    ]

    /// Sections that carry singing when the words have to be spread by length alone.
    private static let sungLabels: Set<String> = ["verse", "pre-chorus", "prechorus", "chorus", "bridge"]

    struct Section { let start: Double; let end: Double; let label: String }

    // MARK: - Entry point

    /// Fit `lyrics` to the structure in `outputDir`, using the timings in `srtPath` as anchors.
    static func fit(lyrics: String, srtPath: String, outputDir: String) -> Fitted {
        let lines = lyrics.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }      // a tag already in the source is ours to redo
        let sections = readSections(outputDir)
        guard !lines.isEmpty else { return Fitted(text: "", anchors: 0, sections: 0, timed: false) }
        guard !sections.isEmpty else {
            return Fitted(text: lines.joined(separator: "\n"), anchors: 0, sections: 0, timed: false)
        }

        let heard = readSRT(srtPath)
        let anchors = align(lines, to: heard)
        // Two anchors is the least that can pin a stretch of song down at both ends; below
        // that the "timing" is one guess extrapolated over the whole track, and the sections'
        // own lengths are the better guide.
        guard anchors.count >= 2 else {
            let text = spread(lines, over: sections)
            return Fitted(text: text.0, anchors: anchors.count, sections: text.1, timed: false)
        }

        let times = interpolate(anchors: anchors, count: lines.count, sections: sections)
        let laid = layOut(lines, times: times, sections: sections)
        return Fitted(text: laid.0, anchors: anchors.count, sections: laid.1, timed: true)
    }

    // MARK: - Reading what the transcriber left behind

    /// structure.lab as sections, merging the repeats it emits for one continuous part.
    static func readSections(_ outputDir: String) -> [Section] {
        guard !outputDir.isEmpty,
              let text = try? String(contentsOf: URL(fileURLWithPath: outputDir)
                  .appendingPathComponent("structure.lab"), encoding: .utf8)
        else { return [] }
        var out: [Section] = []
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, let start = Double(parts[0]), let end = Double(parts[1]) else { continue }
            let label = parts[2].trimmingCharacters(in: .whitespaces).lowercased()
            if let last = out.last, last.label == label {
                out[out.count - 1] = Section(start: last.start, end: end, label: label)
            } else {
                out.append(Section(start: start, end: end, label: label))
            }
        }
        return out
    }

    /// lyrics.srt as (start seconds, text) — the misheard lines, with the clocks worth keeping.
    static func readSRT(_ path: String) -> [(time: Double, text: String)] {
        guard !path.isEmpty,
              let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        else { return [] }
        var out: [(Double, String)] = []
        for block in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let rows = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let clock = rows.first(where: { $0.contains("-->") }),
                  let start = seconds(String(clock.components(separatedBy: "-->")[0]))
            else { continue }
            let body = rows.drop(while: { !$0.contains("-->") }).dropFirst()
                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { out.append((start, body)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + s
    }

    // MARK: - Matching real lines to misheard ones

    /// Real line index → the moment the recording sang something like it.
    ///
    /// A Needleman–Wunsch pass over the similarity grid: both lyrics run in the same order, so
    /// the match has to be monotonic, and gaps are free because either side skips lines the
    /// other does not have (ad-libs Whisper caught, repeats the sheet writes out once).
    static func align(_ lines: [String], to heard: [(time: Double, text: String)]) -> [(index: Int, time: Double)] {
        guard !lines.isEmpty, !heard.isEmpty else { return [] }
        // Below this a "match" is two lines that merely share a syllable; taking it would drag
        // the whole alignment out of step, so the score has to clear it to be worth a diagonal.
        let floor = 0.34
        let real = lines.map(key)
        let sung = heard.map { key($0.text) }

        var score = [[Double]](repeating: [Double](repeating: 0, count: sung.count + 1), count: real.count + 1)
        for i in 1...real.count {
            for j in 1...sung.count {
                let diagonal = score[i - 1][j - 1] + similarity(real[i - 1], sung[j - 1]) - floor
                score[i][j] = max(score[i - 1][j], score[i][j - 1], diagonal)
            }
        }

        var out: [(Int, Double)] = []
        var i = real.count, j = sung.count
        while i > 0 && j > 0 {
            let gain = similarity(real[i - 1], sung[j - 1]) - floor
            if score[i][j] == score[i - 1][j - 1] + gain && gain > 0 {
                out.append((i - 1, heard[j - 1].time)); i -= 1; j -= 1
            } else if score[i][j] == score[i - 1][j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return out.reversed()
    }

    /// Dice coefficient over jamo bigrams: a misheard syllable that keeps its consonant or its
    /// vowel still scores, which whole-syllable comparison would throw away entirely.
    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        guard a.count > 1, b.count > 1 else { return a.isEmpty || b.isEmpty ? 0 : (a == b ? 1 : 0) }
        var counts: [String: Int] = [:]
        for k in 0..<(a.count - 1) { counts[String(a[k...k + 1]), default: 0] += 1 }
        var shared = 0
        for k in 0..<(b.count - 1) {
            let gram = String(b[k...k + 1])
            if let n = counts[gram], n > 0 { counts[gram] = n - 1; shared += 1 }
        }
        return 2 * Double(shared) / Double((a.count - 1) + (b.count - 1))
    }

    /// A line reduced to comparable jamo: punctuation and spacing gone, Hangul taken apart.
    static func key(_ line: String) -> [Character] {
        var out: [Character] = []
        for scalar in line.lowercased().unicodeScalars {
            guard CharacterSet.alphanumerics.contains(scalar) else { continue }
            let value = scalar.value
            guard (0xAC00...0xD7A3).contains(value) else { out.append(Character(scalar)); continue }
            let index = value - 0xAC00
            out.append(Character(UnicodeScalar(0x1100 + index / 588)!))
            out.append(Character(UnicodeScalar(0x1161 + (index % 588) / 28)!))
            if index % 28 > 0 { out.append(Character(UnicodeScalar(0x11A7 + index % 28)!)) }
        }
        return out
    }

    // MARK: - Placing every line on the clock

    /// Anchored lines keep their moment; the rest are spaced evenly between their neighbours,
    /// and the ends run on at the pace the anchors set.
    static func interpolate(anchors: [(index: Int, time: Double)], count: Int,
                            sections: [Section]) -> [Double] {
        let songStart = sections.first?.start ?? 0
        let songEnd = max(sections.last?.end ?? 0, songStart + 1)
        let first = anchors[0], last = anchors[anchors.count - 1]
        let pace = last.index > first.index
            ? max(0.2, (last.time - first.time) / Double(last.index - first.index))
            : (songEnd - songStart) / Double(max(count, 1))

        var times = [Double](repeating: 0, count: count)
        for i in 0..<count {
            if i <= first.index {
                times[i] = max(songStart, first.time - Double(first.index - i) * pace)
            } else if i >= last.index {
                times[i] = min(songEnd - 0.001, last.time + Double(i - last.index) * pace)
            } else {
                let next = anchors.first { $0.index >= i }!
                let previous = anchors.last { $0.index <= i }!
                times[i] = previous.index == next.index ? previous.time
                    : previous.time + (next.time - previous.time)
                        * Double(i - previous.index) / Double(next.index - previous.index)
            }
        }
        return times
    }

    /// Which section a moment belongs to, clamped at both ends of the timeline.
    private static func section(_ sections: [Section], at seconds: Double) -> Int {
        if seconds < sections[0].start { return 0 }
        for (i, s) in sections.enumerated() where s.start <= seconds && seconds < s.end { return i }
        return sections.count - 1
    }

    /// The documented tag for a structure.lab label, or a readable one for a label we do not map.
    static func tag(for label: String) -> String {
        if let known = sectionTags[label] { return known }
        guard !label.isEmpty else { return "[Interlude]" }
        return "[" + label.prefix(1).uppercased() + label.dropFirst() + "]"
    }

    /// Every section the transcription found, in order, each under its own tag.
    ///
    /// A section with no words is still written out. Bare markers are how this app already
    /// asks for a part with no singing — src/yue2/instrumental.py builds its default structure
    /// out of exactly that — so dropping the silent intro or the instrumental break would take
    /// those bars out of the song rather than leave them wordless.
    private static func render(_ sections: [Section], _ buckets: [[String]]) -> (String, Int) {
        var out: [String] = []
        for (section, lines) in zip(sections, buckets) {
            if !out.isEmpty { out.append("") }
            out.append(tag(for: section.label))
            out.append(contentsOf: lines)
        }
        return (out.joined(separator: "\n"), sections.count)
    }

    /// Timed lines → tagged text: each line goes to the section its moment falls in.
    private static func layOut(_ lines: [String], times: [Double], sections: [Section]) -> (String, Int) {
        var buckets = [[String]](repeating: [], count: sections.count)
        for (line, time) in zip(lines, times) {
            buckets[section(sections, at: time)].append(line)
        }
        return render(sections, buckets)
    }

    /// No usable timings: hand each sung section a share of the lines matching its length.
    /// The instrumental sections still get their markers — they just get no words.
    private static func spread(_ lines: [String], over sections: [Section]) -> (String, Int) {
        var targets = sections.indices.filter { sungLabels.contains(sections[$0].label) && sections[$0].end > sections[$0].start }
        if targets.isEmpty { targets = sections.indices.filter { sections[$0].end > sections[$0].start } }
        if targets.isEmpty { targets = Array(sections.indices) }

        let total = targets.reduce(0.0) { $0 + max(1, sections[$1].end - sections[$1].start) }
        // Largest-remainder shares, so every section gets at least a line and none is lost.
        var shares = targets.map {
            max(1, Int((Double(lines.count) * max(1, sections[$0].end - sections[$0].start) / total).rounded(.down)))
        }
        var slack = lines.count - shares.reduce(0, +)
        var cursor = 0
        while slack != 0 {
            let i = cursor % shares.count
            if slack > 0 { shares[i] += 1; slack -= 1 }
            else if shares[i] > 1 { shares[i] -= 1; slack += 1 }
            else if shares.allSatisfy({ $0 <= 1 }) { break }
            cursor += 1
        }

        var buckets = [[String]](repeating: [], count: sections.count)
        var index = 0
        for (target, share) in zip(targets, shares) where index < lines.count {
            let end = min(lines.count, index + share)
            buckets[target] = Array(lines[index..<end])
            index = end
        }
        if index < lines.count, let last = targets.last {      // rounding leftovers
            buckets[last].append(contentsOf: lines[index...])
        }
        return render(sections, buckets)
    }
}
