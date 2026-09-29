import Foundation
import AppKit

/// Pre-download required models for SheetSage2 transcription
class ModelDownloader {
    /// Download MERT model before transcription
    static func downloadMERTModel(completion: @escaping (Result<Void, Error>) -> Void) {
        let modelPath = (Paths.models.appendingPathComponent("hub/models--m-a-p--MERT-v2-FullSong")).path
        let configPath = "\(modelPath)/configuration_mert2.py"
        
        // Check if already downloaded
        if FileManager.default.fileExists(atPath: configPath) {
            completion(.success(()))
            return
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/huggingface-cli")
        task.arguments = [
            "download",
            "m-a-p/MERT-v2-FullSong",
            "--local-dir", modelPath,
            "--endpoint", "https://hf-mirror.com"
        ]
        
        // Read HF_TOKEN from .env file
        if let envPath = Bundle.main.resourceURL?.appendingPathComponent(".env").path,
           let envContent = try? String(contentsOfFile: envPath),
           let hfLine = envContent.components(separatedBy: "\n").first(where: { $0.hasPrefix("HF_TOKEN=") }) {
            let token = hfLine.replacingOccurrences(of: "HF_TOKEN=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            task.environment = ["HF_TOKEN": token]
        }
        
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe
        
        do {
            try task.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            print("MERT download: \(output)")
            
            if FileManager.default.fileExists(atPath: configPath) {
                completion(.success(()))
            } else {
                completion(.failure(NSError(
                    domain: "ModelDownloadError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "MERT model download failed: \(output)"]
                )))
            }
        } catch {
            completion(.failure(error))
        }
    }
}
