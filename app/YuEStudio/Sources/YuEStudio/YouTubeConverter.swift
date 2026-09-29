import Foundation
import AppKit

/// YouTube to MP3 converter using yt-dlp
class YouTubeConverter: ObservableObject {
    @Published var isConverting = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""

    private var process: Process?

    /// Convert YouTube URL to local MP3 file
    func convertYouTubeToMP3(urlString: String, outputDir: URL) async throws -> URL? {
        guard let url = URL(string: urlString) else {
            throw ConversionError.invalidURL
        }

        isConverting = true
        progress = 0.1
        statusMessage = "YouTube 링크 분석 중..."

        // Create output directory
        let outputURL = outputDir.appendingPathComponent("youtube_audio")
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        // Use yt-dlp to download and convert to MP3
        let ytDlpPath = "/opt/homebrew/bin/yt-dlp"  // Homebrew path
        guard FileManager.default.fileExists(atPath: ytDlpPath) else {
            throw ConversionError.ytDlpNotFound
        }

        let outputTemplate = outputURL.appendingPathComponent("%(title)s.%(ext)s").path
        let args = [
            ytDlpPath,
            "--no-playlist",
            "-f", "bestaudio/best",
            "--extract-audio",
            "--audio-format", "mp3",
            "--output", outputTemplate,
            "--no-overwrites",
            urlString
        ]

        process = Process()
        process?.executableURL = URL(fileURLWithPath: "/bin/sh")
        process?.arguments = ["-c", args.joined(separator: " ")]
        process?.currentDirectoryURL = outputURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process?.standardOutput = outputPipe
        process?.standardError = errorPipe

        try process?.run()

        // Read output for progress
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        print("yt-dlp output: \(outputText)")

        // Wait for process to finish
        process?.waitUntilExit()

        if process?.terminationStatus ?? 1 != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ConversionError.conversionFailed(errorText)
        }

        // Find the output MP3 file
        let files = try FileManager.default.contentsOfDirectory(at: outputURL, includingPropertiesForKeys: nil)
        let mp3Files = files.filter { $0.pathExtension == "mp3" }

        guard let mp3File = mp3Files.first else {
            throw ConversionError.noOutputFile
        }

        progress = 1.0
        statusMessage = "변환 완료: \(mp3File.lastPathComponent)"
        isConverting = false

        return mp3File
    }

    func cancel() {
        process?.terminate()
        isConverting = false
        statusMessage = "변환 취소됨"
    }
}

enum ConversionError: LocalizedError {
    case invalidURL
    case ytDlpNotFound
    case conversionFailed(String)
    case noOutputFile

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "유효하지 않은 YouTube 링크입니다."
        case .ytDlpNotFound:
            return "yt-dlp가 설치되어 있지 않습니다. Homebrew로 설치하세요: `brew install yt-dlp`"
        case .conversionFailed(let message):
            return "변환 실패: \(message)"
        case .noOutputFile:
            return "MP3 파일을 찾을 수 없습니다."
        }
    }
}
