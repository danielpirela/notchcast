// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import Foundation

enum SummaryBackend: String, Codable, CaseIterable {
    case mlx, ollama
}

/// User settings persisted in ~/.claude/notchcast/config.json. Missing keys fall back to defaults.
struct AppConfig: Codable, Equatable {
    var summarize = true
    var backend: SummaryBackend = .mlx
    var mlxModel = "Qwen3-4B-Instruct-2507-4bit"
    var ollamaModel = "qwen3:4b-instruct-2507-q4_K_M"
    var ollamaURL = "http://127.0.0.1:11434"
    /// Answers shorter than this are spoken as-is (summarizing them would only add latency).
    var minChars = 300
    /// Show what Claude Code is doing (thinking, tools, subagents) while it works.
    var showAgentStatus = true
    /// With no keyboard/mouse input for this long, answers wait in the queue until you're back.
    var awayAfterSeconds = 120

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        summarize = try c.decodeIfPresent(Bool.self, forKey: .summarize) ?? defaults.summarize
        backend = try c.decodeIfPresent(SummaryBackend.self, forKey: .backend) ?? defaults.backend
        mlxModel = try c.decodeIfPresent(String.self, forKey: .mlxModel) ?? defaults.mlxModel
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? defaults.ollamaModel
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? defaults.ollamaURL
        minChars = try c.decodeIfPresent(Int.self, forKey: .minChars) ?? defaults.minChars
        showAgentStatus = try c.decodeIfPresent(Bool.self, forKey: .showAgentStatus) ?? defaults.showAgentStatus
        awayAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .awayAfterSeconds) ?? defaults.awayAfterSeconds
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: Paths.config),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Paths.config, options: .atomic)
    }
}
