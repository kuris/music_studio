import Foundation

/// Where things live. Packaged app: payload in the bundle, runtime under Application Support.
/// Development (swift run from the repo): the repo's .venv and tools/ are used directly.
struct Paths {
    static let support: URL = {
        if let o = ProcessInfo.processInfo.environment["YUE_STUDIO_SUPPORT"] { return URL(fileURLWithPath: o) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YuE Studio")
    }()
    static let payload: URL? = {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("payload"),
              FileManager.default.fileExists(atPath: r.appendingPathComponent("uv").path) else { return nil }
        return r
    }()
    static var packaged: Bool { payload != nil }
    static let repoRoot: URL = { var u = URL(fileURLWithPath: #filePath); for _ in 0..<5 { u.deleteLastPathComponent() }; return u }()
    static var python: URL { packaged ? support.appendingPathComponent("env/bin/python") : repoRoot.appendingPathComponent(".venv/bin/python") }
    static var worker: URL {
        if let o = ProcessInfo.processInfo.environment["YUE_STUDIO_WORKER"] { return URL(fileURLWithPath: o) }   // tests
        return packaged ? support.appendingPathComponent("src/tools/yue2_worker.py") : repoRoot.appendingPathComponent("tools/yue2_worker.py")
    }
    static var src: URL { support.appendingPathComponent("src") }
    static var models: URL {
        let base = ProcessInfo.processInfo.environment["YUE_STUDIO_HF_HOME"].map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("models")
        return base
    }
    static var aneCache: URL { support.appendingPathComponent("ane-cache") }
    static var output: URL {
        packaged ? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("YuE Studio")
                 : repoRoot.appendingPathComponent("outputs/app")
    }
    static var installedMarker: URL { support.appendingPathComponent("installed.json") }
    static var bundledVersion: String { (try? String(contentsOf: payload!.appendingPathComponent("version.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev" }
    /// Hash of what the Python environment is built from; unchanged means the venv can be reused.
    static var bundledRecipe: String { (try? String(contentsOf: payload!.appendingPathComponent("recipe.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev" }
    // SheetSage2 transcription lives in a second environment (its pins conflict with YuE's).
    static var sheetsageEnv: URL { support.appendingPathComponent("sheetsage-env") }
    static var sheetsagePython: URL { packaged ? sheetsageEnv.appendingPathComponent("bin/python") : repoRoot.appendingPathComponent(".venv-sheetsage2/bin/python") }
    static var sheetsageMarker: URL { support.appendingPathComponent("sheetsage-installed.json") }
    /// Every repo the worker loads at runtime; installers fetch these before the worker is used.
    static let cachedRepos = ["m-a-p--YuE2-3B", "m-a-p--YuE2-Vae", "m-a-p--SheetSage2",
                              "m-a-p--MERT-v2-FullSong", "openai--whisper-large-v3-turbo"]
    static var modelsCached: Bool {
        let hub = models.appendingPathComponent("hub")
        return cachedRepos.allSatisfy {
            FileManager.default.fileExists(atPath: hub.appendingPathComponent("models--\($0)/refs/main").path)
        }
    }
    static var workerEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"; env["TQDM_DISABLE"] = "1"
        env["YUE2_OUTPUT_DIR"] = output.path; env["YUE2_ANE_CACHE"] = aneCache.path
        env["YUE2_SHEETSAGE_PYTHON"] = sheetsagePython.path   // worker cwd differs between modes
        if packaged {
            env["HF_HOME"] = models.path
            env["HF_HUB_DISABLE_TELEMETRY"] = "1"
            // Models are downloaded once by the installers. Once they are all cached the worker
            // never needs the Hub again, so pin it offline: a blocked or flaky huggingface.co then
            // cannot turn a fully cached model into a "couldn't connect" failure mid-transcription.
            if modelsCached { env["HF_HUB_OFFLINE"] = "1" }
            // Read HF_TOKEN from .env file
            if let envPath = Bundle.main.resourceURL?.appendingPathComponent(".env").path,
               let envContent = try? String(contentsOfFile: envPath),
               let hfLine = envContent.components(separatedBy: "\n").first(where: { $0.hasPrefix("HF_TOKEN=") }) {
                let token = hfLine.replacingOccurrences(of: "HF_TOKEN=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                env["HF_TOKEN"] = token
            }
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}
