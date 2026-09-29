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
        
        // Add HF_TOKEN if set in environment
        if let hfToken = ProcessInfo.processInfo.environment["HF_TOKEN"] {
            task.environment = ["HF_TOKEN": hfToken]
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
