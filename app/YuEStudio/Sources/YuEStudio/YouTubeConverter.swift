import Foundation
import AppKit

/// YouTube to MP3 converter using yt-dlp with real-time progress logging
class YouTubeConverter: ObservableObject {
    @Published var isConverting = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var logs: [LogLine] = []

    private var process: Process?
    private var downloadPercent: Double = 0

    private func addLog(_ message: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        logs.append(LogLine(time: f.string(from: Date()), message: message))
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    /// Convert YouTube URL to local MP3 file with real-time progress
    func convertYouTubeToMP3(urlString: String, outputDir: URL) async throws -> URL? {
        guard let url = URL(string: urlString) else {
            throw ConversionError.invalidURL
        }

        isConverting = true
        progress = 0.05
        downloadPercent = 0
        addLog("▶ YouTube 변환 시작")
        addLog("  링크: \(urlString)")

        // Create output directory
        let outputURL = outputDir.appendingPathComponent("youtube_audio")
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        addLog("  출력 디렉토리: \(outputURL.path)")

        // Use yt-dlp to download and convert to MP3
        let ytDlpPath = "/opt/homebrew/bin/yt-dlp"
        guard FileManager.default.fileExists(atPath: ytDlpPath) else {
            throw ConversionError.ytDlpNotFound
        }

        let outputTemplate = outputURL.appendingPathComponent("%(title)s.%(ext)s").path
        let args = [
            ytDlpPath,
            "--no-playlist",
            // 720p 이하 비디오의 최고 품질 오디오 추출 (더 안정적, 빠른 다운로드)
            "-f", "bestvideo[height<=720]+bestaudio/best[height<=720]/bestaudio/best",
            "--extract-audio",
            "--audio-format", "mp3",
            "--audio-quality", "0",
            "--output", outputTemplate,
            "--overwrite",  // 같은 이름 파일 덮어쓰기
            "--no-warnings",
            urlString
        ]

        addLog("  yt-dlp 실행: \(args.joined(separator: " "))")

        process = Process()
        process?.executableURL = URL(fileURLWithPath: ytDlpPath)
        process?.arguments = args  // Pass as separate arguments, not joined string
        process?.currentDirectoryURL = outputURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process?.standardOutput = outputPipe
        process?.standardError = errorPipe

        // Real-time stdout reading
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""

            // Parse yt-dlp progress lines
            let progressLines = text.components(separatedBy: "\n").filter { $0.contains("[download]") }
            for line in progressLines {
                // Extract percentage
                if let percentRange = line.range(of: #"(\d+\.?\d*)%"#) {
                    let percentStr = String(line[percentRange])
                    if let percent = Double(percentStr) {
                        self.downloadPercent = percent
                        self.progress = max(self.progress, 0.05 + 0.85 * (percent / 100.0))
                        self.addLog("  다운로드: \(percentStr)%")
                    }
                }

                // Extract speed
                if let speedRange = line.range(of: #"at ([\d.]+)MiB/s"#) {
                    let speedStr = String(line[speedRange])
                    self.addLog("  속도: \(speedStr) MiB/s")
                }

                // Extract ETA
                if let etaRange = line.range(of: #"ETA (\d+:\d+)"#) {
                    let etaStr = String(line[etaRange])
                    self.addLog("  남은 시간: \(etaStr)")
                }

                // Status messages
                if line.contains("has already been downloaded") {
                    self.addLog("  이미 다운로드됨")
                }
                if line.contains("Downloading") {
                    let filename = line.replacingOccurrences(of: "#[download] #", with: "")
                    self.addLog("  다운로드 중: \(filename)")
                }
            }

            // Extract audio / format info
            if text.contains("Extracting audio") {
                self.addLog("  오디오 추출 중...")
            }
            if text.contains("Merging formats") {
                self.addLog("  포맷 병합 중...")
            }
            if text.contains("Writing audio") || text.contains("Writing") {
                self.addLog("  MP3 파일 저장 중...")
            }
        }

        // Real-time stderr reading
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for line in lines {
                self.addLog("  [stderr] \(line)")
            }
        }

        addLog("  yt-dlp 프로세스 시작")

        try process?.run()

        // Wait for process to finish
        process?.waitUntilExit()

        let exitStatus = process?.terminationStatus ?? -1

        if exitStatus != 0 {
            addLog("✗ 변환 실패: yt-dlp exit code \(exitStatus)")
            throw ConversionError.conversionFailed("yt-dlp exited with code \(exitStatus)")
        }

        addLog("✓ yt-dlp 완료")

        // Find the output MP3 file
        let files = try FileManager.default.contentsOfDirectory(at: outputURL, includingPropertiesForKeys: nil)
        let mp3Files = files.filter { $0.pathExtension == "mp3" }

        guard let mp3File = mp3Files.first else {
            addLog("✗ MP3 파일을 찾을 수 없음")
            throw ConversionError.noOutputFile
        }

        // Get file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: mp3File.path)
        let fileSize = fileAttributes[.size] as? NSNumber ?? 0
        let fileSizeMB = Double(fileSize.int64Value) / (1024 * 1024)

        progress = 1.0
        statusMessage = "완료: \(mp3File.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB)"
        addLog("✓ MP3 생성: \(mp3File.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB)")
        addLog("  총 완료: \(String(format: "%.0f", progress * 100))%")
        isConverting = false
        downloadPercent = 0

        return mp3File
    }

    func cancel() {
        process?.terminate()
        isConverting = false
        statusMessage = "변환 취소됨"
        addLog("변환 취소됨")
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
            return "yt-dlp가 설치되어 있지 않습니다. `brew install yt-dlp`"
        case .conversionFailed(let message):
            return "변환 실패: \(message)"
        case .noOutputFile:
            return "MP3 파일을 찾을 수 없습니다."
        }
    }
}
