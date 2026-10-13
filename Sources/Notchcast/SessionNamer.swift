// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import Foundation

/// Finds a human name for a Claude Code session: its title, else its project folder, else what you asked.
/// The title comes from the session transcript (`custom-title` entries). That format isn't documented,
/// so every step falls back gracefully.
enum SessionNamer {
    private static let tailBytes = 512 * 1024
    private static let scratchFolder = try! NSRegularExpression(pattern: #"^scratch-\d{4}-\d{2}-\d{2}-[0-9a-f]+$"#)

    static func name(transcript: String?, cwd: String?) -> String {
        let entries = transcript.map(tailEntries) ?? []
        if let title = lastValue(in: entries, type: "custom-title", key: "customTitle") {
            return title
        }
        if let cwd, !cwd.isEmpty, !isScratch(cwd) {
            return (cwd as NSString).lastPathComponent
        }
        if let prompt = lastValue(in: entries, type: "last-prompt", key: "lastPrompt") {
            return shorten(prompt)
        }
        return "Claude Code"
    }

    private static func isScratch(_ cwd: String) -> Bool {
        let folder = (cwd as NSString).lastPathComponent
        let range = NSRange(folder.startIndex..., in: folder)
        return cwd.contains("/scratch-workspaces/")
            || scratchFolder.firstMatch(in: folder, range: range) != nil
            || cwd.hasPrefix("/tmp") || cwd.hasPrefix("/private/tmp")
    }

    /// Parses the JSON lines at the end of the transcript (titles are re-written often, so the tail has them).
    private static func tailEntries(_ path: String) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.contains("\"custom-title\"") || line.contains("\"last-prompt\"") else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    private static func lastValue(in entries: [[String: Any]], type: String, key: String) -> String? {
        for entry in entries.reversed() where entry["type"] as? String == type {
            if let value = (entry[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func shorten(_ prompt: String) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace).prefix(5)
        let short = words.joined(separator: " ")
        return words.count < prompt.split(whereSeparator: \.isWhitespace).count ? short + "…" : short
    }
}
