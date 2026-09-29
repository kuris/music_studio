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

    static let size = CGSize(width: 1280, height: 720)
    static let fade = 0.6                       // seconds of cross-fade between slides
    static let minimumSlide = 1.6               // a cue shorter than this still gets room to read

    /// FFmpeg, wherever this machine keeps it. The app already relies on Homebrew for yt-dlp.
    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
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

    /// The timed lines the transcriber wrote next to the song.
    static func cues(inDirectory directory: URL, duration: Double) throws -> [Cue] {
        let path = directory.appendingPathComponent("lyrics.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = object["lines"] as? [[String: Any]], !lines.isEmpty else { throw Failure.noCues }
        var cues = lines.compactMap { line -> Cue? in
            guard var text = (line["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let start = line["start"] as? Double else { return nil }
            // Section markers are structure, not words to put on screen. The recognised text
            // should not carry them, but a line is dropped rather than shown as "[Chorus]".
            text = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "",
                                             options: .regularExpression)
                       .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Cue(start: start, end: (line["end"] as? Double) ?? start + 3, text: text)
        }.sorted { $0.start < $1.start }
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
    @MainActor
    static func slide(text: String, title: String, seed: Int, index: Int, count: Int) throws -> Data {
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

        let body = NSMutableParagraphStyle()
        body.alignment = .center
        body.lineSpacing = 12
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)

        if text.isEmpty {                               // the title card
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 62, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                .paragraphStyle: body, .shadow: shadow,
            ]
            draw(title, attributes: attributes, in: rect.insetBy(dx: 110, dy: 0))
        } else {
            // Long lines need a smaller face to stay on two lines at this width.
            let points: CGFloat = text.count > 26 ? 44 : (text.count > 16 ? 54 : 64)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: points, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: body, .shadow: shadow,
            ]
            draw(text, attributes: attributes, in: rect.insetBy(dx: 110, dy: 0))

            if !title.isEmpty {
                let caption = NSMutableParagraphStyle()
                caption.alignment = .center
                let small: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 22, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                    .paragraphStyle: caption,
                ]
                let line = title as NSString
                let height = line.boundingRect(with: CGSize(width: rect.width - 160, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin], attributes: small).height
                line.draw(with: CGRect(x: 80, y: 46, width: rect.width - 160, height: height),
                          options: [.usesLineFragmentOrigin], attributes: small)
            }
        }

        context.flushGraphics()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure.render("이미지를 PNG로 변환하지 못했습니다")
        }
        return png
    }

    /// Centre a block of text vertically in `rect`.
    @MainActor
    private static func draw(_ text: String, attributes: [NSAttributedString.Key: Any], in rect: CGRect) {
        let string = text as NSString
        let bounds = CGSize(width: rect.width, height: .greatestFiniteMagnitude)
        let height = string.boundingRect(with: bounds, options: [.usesLineFragmentOrigin], attributes: attributes).height
        let box = CGRect(x: rect.minX, y: (size.height - height) / 2, width: rect.width, height: height)
        string.draw(with: box, options: [.usesLineFragmentOrigin], attributes: attributes)
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
            let png = try slide(text: cue.text, title: title, seed: seed, index: i, count: cues.count)
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
    static func encode(slides: [(url: URL, hold: Double)], audio: URL,
                       progress: (@Sendable (String) -> Void)? = nil) throws -> URL {
        guard let ffmpeg = ffmpeg else { throw Failure.noFFmpeg }
        guard !slides.isEmpty else { throw Failure.noCues }
        let directory = audio.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory.appendingPathComponent("slides")) }

        var arguments: [String] = ["-hide_banner", "-loglevel", "error", "-y"]
        for slide in slides {
            arguments += ["-loop", "1", "-t", String(format: "%.3f", slide.hold), "-i", slide.url.path]
        }
        arguments += ["-i", audio.path]

        // One xfade per gap; each offset is where the outgoing slide starts dissolving.
        var filter = "", label = "0", offset = 0.0
        for i in 1..<max(slides.count, 1) {
            offset += slides[i - 1].hold - fade
            let out = i == slides.count - 1 ? "v" : "x\(i)"
            filter += "[\(label)][\(i)]xfade=transition=fade:duration=\(String(format: "%.2f", fade))"
                + ":offset=\(String(format: "%.3f", max(0, offset)))[\(out)];"
            label = out
        }
        if !filter.isEmpty { arguments += ["-filter_complex", String(filter.dropLast())] }
        arguments += ["-map", slides.count == 1 ? "0:v" : "[v]", "-map", "\(slides.count):a",
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
