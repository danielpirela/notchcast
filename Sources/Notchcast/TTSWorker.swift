// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import Foundation

/// Owns the long-lived Piper process (model stays loaded) and decodes its framed PCM output.
final class TTSWorker: @unchecked Sendable {
    private static let readyIndex: UInt32 = 0xFFFF_FFFE
    private static let headerSize = 12

    /// Called on the main actor with (generation, sentence index, raw s16le PCM).
    var onChunk: (@MainActor (UInt32, Int, Data) -> Void)?
    /// Called on the main actor when the process dies unexpectedly.
    var onCrash: (@MainActor () -> Void)?
    @MainActor private(set) var isReady = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let io = DispatchQueue(label: "notchcast.tts")
    private var shuttingDown = false

    @MainActor
    func start() {
        isReady = false
        io.sync { buffer = Data() }

        let process = Process()
        process.executableURL = Paths.python
        process.arguments = ["-I", "-u", Paths.workerScript.path, Paths.voiceModel.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        FileManager.default.createFile(atPath: Paths.workerLog.path, contents: nil)
        process.standardError = (try? FileHandle(forWritingTo: Paths.workerLog)) ?? FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.io.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleExit() }
            }
        }

        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
        } catch {
            NSLog("Notchcast: cannot start Piper worker: \(error)")
        }
    }

    @MainActor
    func shutdown() {
        shuttingDown = true
        process?.terminate()
    }

    func speak(generation: UInt32, index: Int, text: String) {
        send(["cmd": "speak", "gen": generation, "idx": index, "text": text])
    }

    /// Drops every queued or in-flight job whose generation is lower than `generation`.
    func cancel(below generation: UInt32) {
        send(["cmd": "cancel", "below": generation])
    }

    private func send(_ message: [String: Any]) {
        guard let input, var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(UInt8(ascii: "\n"))
        do { try input.write(contentsOf: line) } catch { NSLog("Notchcast: worker write failed: \(error)") }
    }

    @MainActor
    private func handleExit() {
        isReady = false
        input = nil
        process = nil
        guard !shuttingDown else { return }
        onCrash?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while buffer.count >= Self.headerSize {
            let (gen, idx, length) = buffer.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian,
                 raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian,
                 Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian))
            }
            let total = Self.headerSize + length
            guard buffer.count >= total else { return }
            let start = buffer.startIndex
            let payload = buffer.subdata(in: (start + Self.headerSize)..<(start + total))
            buffer = Data(buffer.dropFirst(total))

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if idx == Self.readyIndex {
                        self.isReady = true
                    } else {
                        self.onChunk?(gen, Int(idx), payload)
                    }
                }
            }
        }
    }
}
