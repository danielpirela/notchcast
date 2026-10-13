import Foundation

/// Every file Notchcast touches lives under ~/.claude/notchcast (or $NOTCHCAST_HOME).
enum Paths {
    static let home: URL = {
        if let custom = ProcessInfo.processInfo.environment["NOTCHCAST_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notchcast")
    }()

    static var socket: String { home.appendingPathComponent("run/voice.sock").path }
    static var muteFlag: URL { home.appendingPathComponent("muted") }
    static var python: URL { home.appendingPathComponent("venv/bin/python") }
    static var workerScript: URL { home.appendingPathComponent("tts_worker.py") }
    static let defaultVoice = "es_MX-claude-high"

    /// Voice name from ~/.claude/notchcast/voice (one line), falling back to `defaultVoice`.
    static var voiceName: String {
        let file = home.appendingPathComponent("voice")
        let name = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exists = FileManager.default.fileExists(atPath: home.appendingPathComponent("voices/\(name).onnx").path)
        return !name.isEmpty && exists ? name : defaultVoice
    }

    static var voiceModel: URL { home.appendingPathComponent("voices/\(voiceName).onnx") }
    static var voiceConfig: URL { home.appendingPathComponent("voices/\(voiceName).onnx.json") }
    static var workerLog: URL { home.appendingPathComponent("logs/worker.log") }

    static func voiceSampleRate() -> Double {
        guard let data = try? Data(contentsOf: voiceConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audio = json["audio"] as? [String: Any],
              let rate = audio["sample_rate"] as? Double
        else { return 22050 }
        return rate
    }
}
