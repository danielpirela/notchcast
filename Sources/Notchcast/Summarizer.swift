import Foundation

/// Runs summarize.py as a short-lived process: the model is loaded, used once and freed on exit.
@MainActor
final class Summarizer {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static let timeout: TimeInterval = 60
    private var process: Process?

    func summarize(_ text: String, config: AppConfig,
                   completion: @escaping @MainActor (Result<String, Failure>) -> Void) {
        cancel()

        let process = Process()
        process.executableURL = Paths.python
        var arguments = ["-I", Paths.summarizeScript.path, "--backend", config.backend.rawValue]
        switch config.backend {
        case .mlx:
            arguments += ["--model", Paths.models.appendingPathComponent(config.mlxModel).path]
        case .ollama:
            arguments += ["--model", config.ollamaModel, "--url", config.ollamaURL]
        }
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Self.logHandle()

        do {
            try process.run()
        } catch {
            completion(.failure(Failure(description: "cannot start summarizer: \(error)")))
            return
        }
        self.process = process

        let input = Data(text.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.process === process { self.process = nil }
                    guard status == 0,
                          let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
                          let summary = json["summary"] as? String, !summary.isEmpty
                    else {
                        completion(.failure(Failure(description: "summarizer exited with \(status)")))
                        return
                    }
                    completion(.success(summary))
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self, weak process] in
            MainActor.assumeIsolated {
                guard let process, process.isRunning, self?.process === process else { return }
                NSLog("Notchcast: summarizer timed out")
                process.terminate()
            }
        }
    }

    func cancel() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private static func logHandle() -> FileHandle {
        let url = Paths.summarizerLog
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return .nullDevice }
        handle.seekToEndOfFile()
        return handle
    }
}
