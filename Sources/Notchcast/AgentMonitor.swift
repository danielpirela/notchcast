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
        /// Tool calls still running (by tool_use_id); parallel calls finish out of order.
        var runningTools: [String: String] = [:]
        var startedAt: Date
        var updatedAt: Date

        /// Background subagents keep a session busy after Claude's own turn ends.
        var shown: Activity { activity == .idle && !subagents.isEmpty ? .working : activity }
    }

    @Published private(set) var sessions: [String: Session] = [:]
    /// Last events received, for troubleshooting (`--cmd events`). Memory only.
    private(set) var recentEvents: [String] = []
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
            .filter { $0.shown != .idle }
            .max { (rank[$0.shown]!, $0.updatedAt) < (rank[$1.shown]!, $1.updatedAt) }
    }

    var isActive: Bool { focus != nil }

    var activeSessions: [Session] {
        sessions.values.filter { $0.shown != .idle }.sorted { $0.startedAt < $1.startedAt }
    }

    func handle(_ payload: [String: Any]) {
        guard let event = payload["hook_event_name"] as? String,
              let id = payload["session_id"] as? String
        else { return }
        let now = Date()
        let agentID = payload["agent_id"] as? String
        recentEvents.append([event, String(id.suffix(6)), agentID.map { "agent:" + $0.suffix(6) } ?? "main",
                             payload["tool_name"] as? String ?? ""].joined(separator: " "))
        if recentEvents.count > 60 { recentEvents.removeFirst(recentEvents.count - 60) }
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
            session.runningTools.removeAll()
        case "PreToolUse":
            if let agentID {
                session.subagents.insert(agentID)
            } else {
                let tool = payload["tool_name"] as? String ?? ""
                let callID = payload["tool_use_id"] as? String ?? UUID().uuidString
                session.runningTools[callID] = tool
                session.activity = tool == "AskUserQuestion" ? .question : .working
                session.tool = tool
            }
        case "PostToolUse", "PostToolUseFailure":
            guard agentID == nil, session.activity != .idle else { break }
            if let callID = payload["tool_use_id"] as? String {
                session.runningTools[callID] = nil
            } else if let tool = payload["tool_name"] as? String,
                      let key = session.runningTools.first(where: { $0.value == tool })?.key {
                session.runningTools[key] = nil
            }
            if let still = session.runningTools.values.first {
                session.activity = still == "AskUserQuestion" ? .question : .working
                session.tool = still
            } else {
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
            session.runningTools.removeAll()
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
