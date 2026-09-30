import Foundation
import AppKit

/// Songs are written as FLAC; this makes the MP3 beside them.
///
/// The two switches over the library list have promised this since they were added and never
/// did anything — nothing in the app converted a thing. ffmpeg does the work, the same install
/// the YouTube converter already needs, so this asks for nothing new.
@MainActor
final class AudioExport: ObservableObject {
    /// Songs mid-conversion, by id, so their row can show a spinner instead of a button.
    @Published private(set) var working: Set<String> = []
    /// Songs whose MP3 this session made — a published set is what redraws the row when one lands.
    @Published private(set) var made: Set<String> = []
    @Published var failure = ""
    /// Where to report what happened, so a deletion is never silent. Set by the view.
    var log: ((String) -> Void)?

    /// Songs already offered to the auto-export, so a list redraw does not convert them again.
    private var offered: Set<String> = []

    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static var installed: Bool { FileManager.default.fileExists(atPath: ffmpeg) }

    /// Where a song's MP3 belongs: beside its FLAC, same name.
    static func mp3(for song: Song) -> URL {
        URL(fileURLWithPath: song.path).deletingPathExtension().appendingPathExtension("mp3")
    }

    static func onDisk(_ song: Song) -> Bool {
        FileManager.default.fileExists(atPath: mp3(for: song).path)
    }

    /// True when the row should offer to reveal the MP3 rather than make it.
    func ready(_ song: Song) -> Bool { made.contains(song.id) || Self.onDisk(song) }

    /// `clearOriginal` removes the FLAC once the MP3 is verified — the point of keeping only one
    /// copy. It is a lossless master being thrown away, so it goes only after an encode that
    /// returned cleanly and left a file of a believable size, and it is always written to the log.
    @discardableResult
    func convert(_ song: Song, clearOriginal: Bool = false) async -> URL? {
        let source = URL(fileURLWithPath: song.path)
        let target = Self.mp3(for: song)
        guard Self.installed else {
            failure = "ffmpeg가 없습니다 — brew install ffmpeg"
            return nil
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            failure = "\(song.rowName): 원본 FLAC이 없습니다"
            return nil
        }
        if FileManager.default.fileExists(atPath: target.path) {
            made.insert(song.id)
            if clearOriginal { clear(source, having: target, of: song) }
            return target
        }
        working.insert(song.id)
        defer { working.remove(song.id) }
        if let trouble = await Self.encode(source, target) {
            try? FileManager.default.removeItem(at: target)     // a half-written file is worse than none
            failure = "\(song.rowName): MP3 변환 실패 — \(trouble)"
            return nil
        }
        made.insert(song.id)
        log?("\(song.rowName): MP3 저장 — \(target.lastPathComponent)")
        if clearOriginal { clear(source, having: target, of: song) }
        return target
    }

    /// Drop the FLAC now that the MP3 stands in for it — never on a suspect encode.
    private func clear(_ source: URL, having target: URL, of song: Song) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 8 * 1024 else {
            failure = "\(song.rowName): MP3가 너무 작아 원본을 남겨뒀습니다"
            return
        }
        do {
            try fm.removeItem(at: source)
            log?("\(song.rowName): 원본 FLAC 삭제 (MP3 \(size / 1024) KB 보관)")
        } catch {
            failure = "\(song.rowName): 원본을 지우지 못했습니다 — \(error.localizedDescription)"
        }
    }

    /// Convert every finished song that has no MP3 yet, once each.
    func autoExport(_ songs: [Song], clearOriginal: Bool = false) async {
        for song in songs where song.status == .ready && !offered.contains(song.id) {
            offered.insert(song.id)
            await convert(song, clearOriginal: clearOriginal)
        }
    }

    func reveal(_ song: Song) {
        NSWorkspace.shared.activateFileViewerSelecting([Self.mp3(for: song)])
    }

    /// Runs ffmpeg off the main thread; nil on success, else the line worth showing.
    ///
    /// `-q:a 0` is LAME's best VBR setting (~245 kbps), which is the point of keeping a FLAC
    /// master around — the MP3 is for carrying the song elsewhere, not for saving space.
    private static func encode(_ source: URL, _ target: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = ["-y", "-hide_banner", "-loglevel", "error",
                                     "-i", source.path,
                                     "-codec:a", "libmp3lame", "-q:a", "0",
                                     target.path]
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                    return
                }
                // Drained before waiting: a full pipe would block ffmpeg and neither would finish.
                let spill = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let tail = String(data: spill, encoding: .utf8)?
                    .split(separator: "\n").last.map(String.init) ?? ""
                continuation.resume(returning: tail.isEmpty ? "ffmpeg 종료 코드 \(process.terminationStatus)" : tail)
            }
        }
    }
}
