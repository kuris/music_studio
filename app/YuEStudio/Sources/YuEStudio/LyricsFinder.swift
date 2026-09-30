import Foundation

/// A track 벅스 knows about, from a title/artist search.
struct LyricsCandidate: Identifiable, Hashable {
    let id: String              // 벅스 track id
    let title: String
    let artist: String
    let album: String

    var label: String { artist.isEmpty ? title : "\(title) · \(artist)" }
}

enum LyricsLookupError: LocalizedError {
    case emptyQuery
    case network(String)
    case noResults(String)
    case noLyrics

    var errorDescription: String? {
        switch self {
        case .emptyQuery:        return "검색할 곡 이름이 없습니다."
        case .network(let why):  return "벅스에 연결하지 못했습니다: \(why)"
        case .noResults(let q):  return "벅스에서 \"\(q)\"를 찾지 못했습니다."
        case .noLyrics:          return "이 곡은 벅스에 가사가 등록되어 있지 않습니다."
        }
    }
}

/// Published lyrics from 벅스, for a song the transcriber only guessed at.
///
/// Whisper mishears sung Korean often enough that a cover ends up singing near-nonsense.
/// The *sections* it lays those words out under, though, come from SheetSage2's structure.lab
/// and are sound — so the words get replaced and the structure kept (see `LyricsStructurer`).
enum LyricsFinder {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    // MARK: - Search

    /// Tracks matching `query`, best match first — 벅스 already orders its search that way.
    static func search(_ query: String, limit: Int = 8) async throws -> [LyricsCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LyricsLookupError.emptyQuery }
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
        let html = try await fetch("https://music.bugs.co.kr/search/track?q=\(escaped)")
        let found = parseSearch(html, limit: limit)
        if found.isEmpty { throw LyricsLookupError.noResults(trimmed) }
        return found
    }

    /// One row per `<tr trackId="…">`, with the title/artist/album 벅스 puts in `title=` attributes.
    static func parseSearch(_ html: String, limit: Int = 8) -> [LyricsCandidate] {
        var out: [LyricsCandidate] = []
        var seen = Set<String>()
        for row in html.components(separatedBy: "<tr ").dropFirst() {
            guard let id = firstMatch(#"trackId="(\d+)""#, in: row), !seen.contains(id) else { continue }
            // The row's own <p class="title"> / <p class="artist"> blocks each carry the
            // readable name on their <a title="…">; the album sits on an <a class="album">.
            let title = attribute(after: #"<p class="title""#, in: row)
            guard !title.isEmpty else { continue }
            seen.insert(id)
            out.append(LyricsCandidate(id: id, title: title,
                                       artist: attribute(after: #"<p class="artist""#, in: row),
                                       album: attribute(after: #"class="album""#, in: row)))
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Lyrics

    /// The registered lyrics of one track, or `.noLyrics` when 벅스 has none for it.
    static func lyrics(trackID: String) async throws -> String {
        try parseLyrics(await fetch("https://music.bugs.co.kr/track/\(trackID)"))
    }

    /// 벅스 keeps the words verbatim inside `<div class="lyricsContainer">…<xmp>…</xmp>`.
    /// The `<xmp>` body is literal text, so nothing has to be entity-decoded out of it.
    static func parseLyrics(_ html: String) throws -> String {
        guard let container = html.range(of: #"<div class="lyricsContainer">"#),
              let open = html.range(of: "<xmp>", range: container.upperBound..<html.endIndex),
              let close = html.range(of: "</xmp>", range: open.upperBound..<html.endIndex)
        else { throw LyricsLookupError.noLyrics }
        let body = String(html[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { throw LyricsLookupError.noLyrics }
        return body
    }

    // MARK: - Query from a downloaded file name

    /// What to type into 벅스 for a file yt-dlp named after its YouTube title.
    ///
    /// "원미연 - 이별여행 (1990年) [MV].mp3" → "원미연 이별여행". The bracketed matter YouTube
    /// uploaders add ("Official M/V", "가사", "4K remaster") is noise in a track search.
    static func searchQuery(for url: URL) -> String {
        let (artist, title) = split(url.deletingPathExtension().lastPathComponent)
        return [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The artist and title a downloaded file name spells out; either may come back empty.
    static func split(_ rawName: String) -> (artist: String, title: String) {
        var name = strip(rawName)
        var artist = ""
        // "아티스트 - 제목" is how all but a few uploads are named. A second dash belongs to the
        // title far more often than to the artist, so the split is on the first one.
        for separator in [" - ", " – ", " — ", " _ ", "-"] {
            guard let range = name.range(of: separator) else { continue }
            artist = strip(String(name[..<range.lowerBound]))
            name = strip(String(name[range.upperBound...]))
            break
        }
        return (artist, name)
    }

    /// Drop the brackets, the uploader's tags and the leading track number.
    private static func strip(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"[\(\[{【][^\)\]}】]*[\)\]}】]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(?i)\b(official|officia|m/?v|music\s*video|lyrics?|lyric\s*video|audio|visualizer|"#
              + #"live|full\s*ver(sion)?|remaster(ed)?|hd|hq|4k|1080p|mp3|가사|자막|뮤직비디오|공식|음원)\b"#,
            with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*\d{1,2}\s*[\.\)]\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[｜|/·・]+"#, with: " ", options: .regularExpression)
        // "아티스트 _ 곡" is how the big K-pop channels name an upload; keep the underscore
        // readable as the separator it is rather than letting it collapse into the title.
        s = s.replacingOccurrences(of: #"\s*_\s*"#, with: " _ ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—_,"))
    }

    // MARK: - Plumbing

    private static func fetch(_ address: String) async throws -> String {
        guard let url = URL(string: address) else { throw LyricsLookupError.network("잘못된 주소") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ko-KR,ko;q=0.9", forHTTPHeaderField: "Accept-Language")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw LyricsLookupError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LyricsLookupError.network("HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LyricsLookupError.network("응답을 읽지 못했습니다")
        }
        return text
    }

    /// The first `title="…"` after `marker`, entity-decoded — how 벅스 spells every name in a row.
    private static func attribute(after marker: String, in row: String) -> String {
        guard let start = row.range(of: marker) else { return "" }
        let tail = String(row[start.upperBound...].prefix(600))
        return decode(firstMatch(#"title="([^"]*)""#, in: tail) ?? "")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func decode(_ text: String) -> String {
        var s = text
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: character)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension LyricsFinder {
    /// Is this result the song in hand, rather than a cover or a same-titled stranger?
    ///
    /// Only a confident match is worth filling in without being asked; anything less is put
    /// to the user as a list, because the wrong lyrics are worse than the misheard ones.
    static func matches(_ candidate: LyricsCandidate, artist: String, title: String) -> Bool {
        let sameTitle = LyricsStructurer.similarity(LyricsStructurer.key(candidate.title),
                                                    LyricsStructurer.key(title))
        guard sameTitle >= 0.8 else { return false }
        guard !artist.isEmpty else { return true }
        // The uploader writes "아이유(IU)" where 벅스 writes "아이유", so the artist only has to be close.
        return LyricsStructurer.similarity(LyricsStructurer.key(candidate.artist),
                                           LyricsStructurer.key(artist)) >= 0.6
    }
}
