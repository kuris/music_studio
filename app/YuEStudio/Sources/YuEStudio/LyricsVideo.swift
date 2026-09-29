import Foundation
import AppKit

/// A lyric video for a finished song: its own words, timed from its own audio.
///
/// The slides are drawn here rather than by FFmpeg. Homebrew's build carries no `drawtext`
/// (it is compiled without libfreetype) and no subtitle filter, and drawing them with
/// Core Graphics picks up the system's Korean fonts for free. FFmpeg only cross-fades the
/// finished images against the song.
enum LyricsVideo {
    struct Cue { let start: Double; let end: Double; let text: String }

    static let size = CGSize(width: 720, height: 1280)      // 9:16, for phones
    /// The visualiser band, measured from the top, and the room left above it for words.
    static let bandTop: CGFloat = 660, bandHeight: CGFloat = 300
    static let fade = 0.6                       // seconds of cross-fade between slides
    static let minimumSlide = 1.6               // a cue shorter than this still gets room to read

    /// FFmpeg, wherever this machine keeps it. The app already relies on Homebrew for yt-dlp.
    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What the audio looks like. Each is an FFmpeg graph ending in a 720x1280 frame whose
    /// background is black, so screen-blending it over a slide shows only the visualiser.
    enum Style: String, CaseIterable, Identifiable {
        case bars, wave, spectrum, circle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bars: return "막대"; case .wave: return "파형"
            case .spectrum: return "스펙트럼"; case .circle: return "원형"
            }
        }
        /// Built against the song's own audio; `gain` lifts a quiet mix into the band.
        func filter(colour: String, second: String) -> String {
            let band = Int(bandHeight), top = Int(bandTop)
            switch self {
            case .bars:
                // Rendered tiny and scaled with nearest-neighbour: that is what makes the
                // bars chunky instead of a smooth hill.
                return "showfreqs=size=45x150:mode=bar:ascale=cbrt:fscale=log:win_size=1024"
                    + ":averaging=1:colors=\(colour),scale=684:\(band):flags=neighbor"
                    + ",pad=720:1280:18:\(top):black"
            case .wave:
                return "showwaves=size=720x\(band):mode=cline:colors=\(colour)|\(second):draw=full"
                    + ",pad=720:1280:0:\(top):black"
            case .spectrum:
                return "showcqt=size=720x\(band):sono_h=0:axis_h=0:bar_h=\(band):count=6"
                    + ":cscheme=0.6|0.4|1|1|0.6|0.9,pad=720:1280:0:\(top):black"
            case .circle:
                return "avectorscope=size=560x560:mode=polar:rate=30:rc=60:gc=150:bc=255:zoom=1.6"
                    + ",pad=720:1280:80:\(top - 130):black"
            }
        }
    }

    enum Failure: LocalizedError {
        case noFFmpeg, noCues, render(String), encode(String)
        var errorDescription: String? {
            switch self {
            case .noFFmpeg: return "ffmpeg을 찾을 수 없습니다 — brew install ffmpeg 후 다시 시도하세요"
            case .noCues: return "가사를 인식하지 못해 영상을 만들 수 없습니다"
            case .render(let m): return "슬라이드 생성 실패: \(m)"
            case .encode(let m): return "영상 인코딩 실패: \(m)"
            }
        }
    }

    // MARK: - Cues

    /// The lines the song was asked to sing, timed against what the recording actually sings.
    ///
    /// The words are the ones typed into the form — `request.json` keeps them verbatim beside the
    /// audio. Whisper only supplies the clock: it mishears sung Korean often enough ("투명한" heard
    /// as "두 명의") that using its text put words on screen the song was never given.
    static func cues(inDirectory directory: URL, songDirectory: URL, duration: Double) throws -> [Cue] {
        let heard = recognised(inDirectory: directory)
        let written = writtenLines(inDirectory: songDirectory)
        var cues = written.isEmpty ? heard : timed(written, against: heard, duration: duration)
        guard !cues.isEmpty else { throw Failure.noCues }
        // Stretch each cue to the next one so the video never cuts to nothing between lines,
        // and let the last slide hold to the end of the song.
        for i in cues.indices {
            let next = i + 1 < cues.count ? cues[i + 1].start : max(duration, cues[i].end)
            cues[i] = Cue(start: cues[i].start, end: max(next, cues[i].start + minimumSlide), text: cues[i].text)
        }
        if cues[0].start > 0.5 {                       // a title card over the intro
            cues.insert(Cue(start: 0, end: cues[0].start, text: ""), at: 0)
        }
        return cues
    }

    /// Section markers are structure, not words to put on screen.
    private static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The lyrics the song was generated from, one displayable line each.
    static func writtenLines(inDirectory directory: URL) -> [String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyrics = object["lyrics"] as? String else { return [] }
        return lyrics.components(separatedBy: .newlines).map(spoken).filter { !$0.isEmpty }
    }

    /// The timed lines the transcriber wrote next to the song; empty when it recognised nothing.
    static func recognised(inDirectory directory: URL) -> [Cue] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("lyrics.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = object["lines"] as? [[String: Any]] else { return [] }
        return lines.compactMap { line -> Cue? in
            guard let start = line["start"] as? Double else { return nil }
            let text = spoken((line["text"] as? String) ?? "")
            guard !text.isEmpty else { return nil }
            return Cue(start: start, end: (line["end"] as? Double) ?? start + 3, text: text)
        }.sorted { $0.start < $1.start }
    }

    // MARK: - Lining the written words up with the sung ones

    /// Letters and digits only, lowercased. Whisper spaces and punctuates sung Korean its own
    /// way, so only the bare characters of the two texts can be compared.
    private static func folded(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A Hangul syllable's (initial, medial, final); nil for anything else.
    private static func parts(_ character: Character) -> (Int, Int, Int)? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
        let code = Int(scalar.value) - 0xAC00
        return (code / 588, (code % 588) / 28, code % 28)
    }

    /// How alike two characters are. Hangul is judged by its parts, so a swallowed final
    /// consonant ("기대여" for "기대어") still reads as very nearly the same syllable.
    private static func affinity(_ a: Character, _ b: Character) -> Int {
        if a == b { return 2 }
        if let x = parts(a), let y = parts(b) {
            if x.0 == y.0 && x.1 == y.1 { return 1 }
            if x.0 == y.0 || x.1 == y.1 { return 0 }
        }
        return -1
    }

    /// Needleman–Wunsch: for each written character, the sung one it was heard as, or nil when
    /// nothing matched. Being monotonic is what makes it safe on repeated choruses — a line can
    /// only ever match after the line before it.
    private static func alignment(_ written: [Character], _ sung: [Character]) -> [Int?] {
        let n = written.count, m = sung.count
        guard n > 0, m > 0 else { return Array(repeating: nil, count: n) }
        let gap = -1
        var previous = (0...m).map { $0 * gap }
        var current = [Int](repeating: 0, count: m + 1)
        // One move per cell: diagonal (1), up (2, a written character nothing was sung for),
        // left (3, something sung that was never written).
        var moves = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
        for i in 1...n {
            let row = i * (m + 1)
            current[0] = i * gap
            moves[row] = 2
            let character = written[i - 1]
            for j in 1...m {
                var best = previous[j - 1] + affinity(character, sung[j - 1])
                var move: UInt8 = 1
                if previous[j] + gap > best { best = previous[j] + gap; move = 2 }
                if current[j - 1] + gap > best { best = current[j - 1] + gap; move = 3 }
                current[j] = best
                moves[row + j] = move
            }
            swap(&previous, &current)
        }
        var mapped = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            switch moves[i * (m + 1) + j] {
            case 1: mapped[i - 1] = j - 1; i -= 1; j -= 1
            case 2: i -= 1
            default: j -= 1
            }
        }
        return mapped
    }

    /// The written lines on the recording's clock.
    private static func timed(_ lines: [String], against heard: [Cue], duration: Double) -> [Cue] {
        // A moment for every recognised character, spread evenly across the cue it came from.
        var sung: [Character] = [], clock: [Double] = []
        for cue in heard {
            let characters = folded(cue.text)
            guard !characters.isEmpty else { continue }
            let span = max(cue.end, cue.start + 0.1) - cue.start
            for (k, character) in characters.enumerated() {
                sung.append(character)
                clock.append(cue.start + span * Double(k) / Double(characters.count))
            }
        }
        var written: [Character] = [], owner: [Int] = []
        for (index, line) in lines.enumerated() {
            for character in folded(line) { written.append(character); owner.append(index) }
        }
        // A line starts when the first of its characters was heard — but only once enough of
        // the line was heard to believe it. A single stray character matching is how a song
        // that stops early used to drag all its remaining lines into the last few seconds.
        var found = [Double?](repeating: nil, count: lines.count)
        var matched = [Int](repeating: 0, count: lines.count)
        var length = [Int](repeating: 0, count: lines.count)
        let mapping = alignment(written, sung)
        for (k, j) in mapping.enumerated() {
            length[owner[k]] += 1
            guard let j else { continue }
            matched[owner[k]] += 1
            if found[owner[k]] == nil { found[owner[k]] = clock[j] }
        }
        for i in found.indices where Double(matched[i]) < Double(length[i]) / 3 {
            found[i] = nil
        }
        guard found.contains(where: { $0 != nil }) else { return spread(lines, over: duration) }

        // Lines nothing matched — a phrase the singer swallowed, or one the model skipped — are
        // spaced evenly between the lines on either side that did land.
        var starts = [Double](repeating: 0, count: lines.count)
        var last = -1
        for i in found.indices {
            guard let time = found[i] else { continue }
            let from = last < 0 ? 0 : starts[last]
            for gap in (last + 1)..<i {
                starts[gap] = from + (time - from) * Double(gap - last) / Double(i - last)
            }
            starts[i] = time
            last = i
        }
        var shown = lines.count
        if last < lines.count - 1 {
            // Nothing matched after `last`: the song ran out before its closing lines. Keep only
            // as many as there is room to read rather than flashing the rest past the end.
            let room = max(0, duration - starts[last])
            let fits = min(lines.count - 1 - last, Int(room / minimumSlide))
            let each = room / Double(fits + 1)
            for gap in 0..<fits { starts[last + 1 + gap] = starts[last] + each * Double(gap + 1) }
            shown = last + 1 + fits
        }

        var cues: [Cue] = []
        for i in 0..<shown {
            let start = max(cues.last.map { $0.start + 0.4 } ?? 0, starts[i])
            cues.append(Cue(start: start, end: start + minimumSlide, text: lines[i]))
        }
        return cues
    }

    /// Nothing usable was recognised: lay the written lines out evenly, so the video is still
    /// made from the right words even when the clock has to be guessed.
    private static func spread(_ lines: [String], over duration: Double) -> [Cue] {
        let each = max(minimumSlide, (duration > 0 ? duration : Double(lines.count) * 3) / Double(max(1, lines.count)))
        return lines.enumerated().map { index, line in
            Cue(start: Double(index) * each, end: Double(index + 1) * each, text: line)
        }
    }

    // MARK: - Subtitles

    /// The same cues as a SubRip file, for cutting the video in an editor instead of here.
    /// The title card carries no words, so it is left out rather than written as a blank cue.
    static func subtitles(_ cues: [Cue]) -> String {
        func stamp(_ seconds: Double) -> String {
            let total = max(0, seconds)
            let whole = Int(total)
            return String(format: "%02d:%02d:%02d,%03d", whole / 3600, (whole % 3600) / 60, whole % 60,
                          Int(((total - Double(whole)) * 1000).rounded()))
        }
        var blocks: [String] = []
        for cue in cues where !cue.text.isEmpty {
            blocks.append("\(blocks.count + 1)\n\(stamp(cue.start)) --> \(stamp(max(cue.end, cue.start + 0.2)))\n\(cue.text)\n")
        }
        return blocks.joined(separator: "\n")
    }

    /// Writes the cues beside the song as lyrics.srt. Returns the file.
    @discardableResult
    static func writeSubtitles(cues: [Cue], into directory: URL) throws -> URL {
        let text = subtitles(cues)
        guard !text.isEmpty else { throw Failure.noCues }
        let file = directory.appendingPathComponent("lyrics.srt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Slides

    /// Two hues derived from the seed, so a song's video looks the same every time it is built.
    private static func palette(seed: Int, index: Int, count: Int) -> (NSColor, NSColor) {
        let base = Double(abs(seed) % 360) / 360.0
        let drift = count > 1 ? Double(index) / Double(count) * 0.22 : 0
        let hue = (base + drift).truncatingRemainder(dividingBy: 1)
        return (NSColor(hue: hue, saturation: 0.55, brightness: 0.20, alpha: 1),
                NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.70, brightness: 0.06, alpha: 1))
    }

    /// AppKit drawing and text layout belong to the main thread; NSImage.lockFocus off it
    /// silently produced no bitmap at all.
    /// Two bright accents for the visualiser, matched to the slide gradient's hue.
    static func accents(seed: Int) -> (String, String) {
        let hue = Double(abs(seed) % 360) / 360.0
        func hex(_ h: Double) -> String {
            let c = NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 1, alpha: 1)
            return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        return (hex(hue + 0.5), hex(hue + 0.62))
    }

    @MainActor
    static func slide(text: String, next: String, title: String, seed: Int,
                      index: Int, count: Int) throws -> Data {
        let rect = CGRect(origin: .zero, size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw Failure.render("비트맵을 만들 수 없습니다")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let (top, bottom) = palette(seed: seed, index: index, count: count)
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -70)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineSpacing = 8

        // Words sit above the visualiser band, which is measured from the top of the frame.
        let words = CGRect(x: 56, y: size.height - bandTop + 40,
                           width: size.width - 112, height: bandTop - 160)

        if text.isEmpty {                               // the opening title card
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 52, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.94),
                .paragraphStyle: centred, .shadow: shadow,
            ]
            draw(title, attributes: attributes, in: words, verticalAnchor: 0.5)
        } else {
            let points: CGFloat = text.count > 22 ? 40 : (text.count > 14 ? 46 : 54)
            let now: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: points, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: centred, .shadow: shadow,
            ]
            let height = draw(text, attributes: now, in: words, verticalAnchor: 0.62)
            // The line that comes next, dimmed: two lines read as a lyric sheet rather than
            // a single card, and it tells the singer what is coming.
            if !next.isEmpty {
                let ahead: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: points * 0.72, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.42),
                    .paragraphStyle: centred, .shadow: shadow,
                ]
                let below = CGRect(x: words.minX, y: words.minY,
                                   width: words.width,
                                   height: max(0, words.height * 0.62 - height / 2 - 18))
                draw(next, attributes: ahead, in: below, verticalAnchor: 1.0)
            }
        }

        if !title.isEmpty && !text.isEmpty {
            let caption = NSMutableParagraphStyle()
            caption.alignment = .center
            let small: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .paragraphStyle: caption,
            ]
            (title as NSString).draw(with: CGRect(x: 40, y: size.height - 76, width: size.width - 80, height: 30),
                                     options: [.usesLineFragmentOrigin], attributes: small)
        }

        context.flushGraphics()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure.render("이미지를 PNG로 변환하지 못했습니다")
        }
        return png
    }

    /// Centre a block of text vertically in `rect`.
    /// Draws `text` inside `rect`, positioned by `verticalAnchor` (0 bottom … 1 top).
    /// Returns the height it took, so the next block can be placed under it.
    @MainActor
    @discardableResult
    private static func draw(_ text: String, attributes: [NSAttributedString.Key: Any],
                             in rect: CGRect, verticalAnchor: CGFloat) -> CGFloat {
        let string = text as NSString
        let bounds = CGSize(width: rect.width, height: .greatestFiniteMagnitude)
        let height = string.boundingRect(with: bounds, options: [.usesLineFragmentOrigin], attributes: attributes).height
        let y = rect.minY + (rect.height - height) * verticalAnchor
        string.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: height),
                    options: [.usesLineFragmentOrigin], attributes: attributes)
        return height
    }

    // MARK: - Assembly

    /// Draws every slide next to the song. Returns each file with how long it is held.
    @MainActor
    static func renderSlides(cues: [Cue], title: String, seed: Int, into directory: URL,
                             progress: (@Sendable (String) -> Void)? = nil) throws -> [(url: URL, hold: Double)] {
        let slides = directory.appendingPathComponent("slides", isDirectory: true)
        try? FileManager.default.removeItem(at: slides)
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        var made: [(url: URL, hold: Double)] = []
        for (i, cue) in cues.enumerated() {
            progress?("슬라이드 \(i + 1)/\(cues.count)")
            let png = try slide(text: cue.text, next: i + 1 < cues.count ? cues[i + 1].text : "",
                                title: title, seed: seed, index: i, count: cues.count)
            let file = slides.appendingPathComponent(String(format: "slide%03d.png", i))
            try png.write(to: file)
            // Held for its own cue plus the fade it hands to the next one.
            let hold = max(minimumSlide, cue.end - cue.start) + (i + 1 < cues.count ? fade : 0)
            made.append((file, hold))
        }
        return made
    }

    /// Cross-fades the drawn slides against the song. Returns the finished file.
    @discardableResult
    static func encode(slides: [(url: URL, hold: Double)], audio: URL, style: Style, seed: Int,
                       progress: (@Sendable (String) -> Void)? = nil) throws -> URL {
        guard let ffmpeg = ffmpeg else { throw Failure.noFFmpeg }
        guard !slides.isEmpty else { throw Failure.noCues }
        let directory = audio.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory.appendingPathComponent("slides")) }

        // The song comes first so the visualiser can split off it; the slides follow.
        var arguments: [String] = ["-hide_banner", "-loglevel", "error", "-y", "-i", audio.path]
        for slide in slides {
            arguments += ["-loop", "1", "-t", String(format: "%.3f", slide.hold), "-i", slide.url.path]
        }

        // One xfade per gap; each offset is where the outgoing slide starts dissolving.
        // Slide i is input i+1, the song being input 0.
        var filter = "[0:a]asplit=2[aout][avis];", label = "1", offset = 0.0
        for i in 1..<max(slides.count, 1) {
            offset += slides[i - 1].hold - fade
            let out = "x\(i)"
            filter += "[\(label)][\(i + 1)]xfade=transition=fade:duration=\(String(format: "%.2f", fade))"
                + ":offset=\(String(format: "%.3f", max(0, offset)))[\(out)];"
            label = out
        }
        let colours = accents(seed: seed)
        // Both sides are forced to one pixel format first: blending a filter's native format
        // against the PNGs silently wrecked the colours.
        filter += "[avis]\(style.filter(colour: colours.0, second: colours.1)),format=gbrp[eq];"
        filter += "[\(label)]format=gbrp[base];[base][eq]blend=all_mode=screen[v]"

        arguments += ["-filter_complex", filter,
                      "-map", "[v]", "-map", "[aout]",
                      "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-r", "30",
                      "-c:a", "aac", "-b:a", "192k", "-shortest"]
        let output = directory.appendingPathComponent("lyrics-video.mp4")
        arguments.append(output.path)

        progress?("영상 인코딩 중 (\(slides.count)장)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffmpeg)
        task.arguments = arguments
        let errors = Pipe()
        task.standardError = errors
        task.standardOutput = Pipe()
        try task.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            let message = String(data: data, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? "exit \(task.terminationStatus)"
            throw Failure.encode(message)
        }
        return output
    }
}
