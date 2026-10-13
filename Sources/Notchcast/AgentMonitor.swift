// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import Foundation

/// Tracks what each Claude Code session is doing, from hook events forwarded by hook/event.sh.
@MainActor
final class AgentMonitor: ObservableObject {
    enum Activity: String {
        case thinking, working, waiting, question, idle
    }

    struct Session: Identifiable {
        let id: String
        var project: String
        var activity: Activity
        var tool: String?
        var subagents: Set<String> = []
        var startedAt: Date
        var updatedAt: Date
    }

    @Published private(set) var sessions: [String: Session] = [:]
    var onChange: (() -> Void)?

    /// Sessions that went quiet this long (crash, closed terminal) are forgotten.
    private static let staleAfter: TimeInterval = 15 * 60
    private var sweeper: Timer?

    init() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweeper = timer
    }

    /// The session to show in the island: waiting beats working beats thinking.
    var focus: Session? {
        let rank: [Activity: Int] = [.question: 4, .waiting: 3, .working: 2, .thinking: 1, .idle: 0]
        return sessions.values
            .filter { $0.activity != .idle }
            .max { (rank[$0.activity]!, $0.updatedAt) < (rank[$1.activity]!, $1.updatedAt) }
    }

    var isActive: Bool { focus != nil }

    var activeSessions: [Session] {
        sessions.values.filter { $0.activity != .idle }.sorted { $0.startedAt < $1.startedAt }
    }

    func handle(_ payload: [String: Any]) {
        guard let event = payload["hook_event_name"] as? String,
              let id = payload["session_id"] as? String
        else { return }
        let now = Date()
        let agentID = payload["agent_id"] as? String
        let project = (payload["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Claude Code"
        var session = sessions[id]
            ?? Session(id: id, project: project, activity: .idle, startedAt: now, updatedAt: now)
        session.project = project
        session.updatedAt = now

        switch event {
        case "UserPromptSubmit":
            if session.activity == .idle { session.startedAt = now }
            session.activity = .thinking
            session.tool = nil
        case "PreToolUse":
            if let agentID {
                session.subagents.insert(agentID)
            } else {
                let tool = payload["tool_name"] as? String
                session.activity = tool == "AskUserQuestion" ? .question : .working
                session.tool = tool
            }
        case "PostToolUse", "PostToolUseFailure":
            if agentID == nil, session.activity != .idle {
                session.activity = .thinking
                session.tool = nil
            }
        case "SubagentStart":
            if let agentID { session.subagents.insert(agentID) }
        case "SubagentStop":
            if let agentID { session.subagents.remove(agentID) }
        case "PermissionRequest":
            session.activity = .waiting
        case "Notification":
            switch payload["notification_type"] as? String {
            case "permission_prompt":
                session.activity = .waiting
            case "agent_needs_input", "elicitation_dialog":
                session.activity = .question
            case "idle_prompt":
                session.activity = .idle
            default:
                break
            }
        case "Stop", "StopFailure":
            guard agentID == nil else { break }
            session.activity = .idle
            session.tool = nil
            session.subagents.removeAll()
        case "SessionEnd":
            sessions[id] = nil
            onChange?()
            return
        default:
            return
        }
        sessions[id] = session
        onChange?()
    }

    private func sweep() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        let before = sessions.count
        sessions = sessions.filter { $0.value.updatedAt > cutoff }
        if sessions.count != before { onChange?() }
    }
}

extension AgentMonitor.Activity {
    /// Short label for the compact island.
    var label: String {
        switch self {
        case .thinking: return "Pensando"
        case .working: return "Trabajando"
        case .waiting: return "Te espera"
        case .question: return "Pregunta"
        case .idle: return "Listo"
        }
    }

    var driftMood: DriftMood {
        switch self {
        case .thinking: return .thinking
        case .working: return .working
        case .waiting: return .waiting
        case .question: return .question
        case .idle: return .idle
        }
    }
}
