// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import CoreGraphics
import Foundation

/// A final answer waiting to be read, tagged with the Claude Code session it came from.
struct QueuedAnswer: Identifiable, Equatable {
    let id = UUID()
    let session: String
    let project: String
    let text: String
    let receivedAt: Date
}

/// Answers from several sessions, read one after another instead of interrupting each other.
/// Lives only in memory.
@MainActor
final class AnswerQueue: ObservableObject {
    @Published private(set) var pending: [QueuedAnswer] = []
    @Published private(set) var current: QueuedAnswer?

    var isEmpty: Bool { pending.isEmpty }

    /// When each session last sent an answer, to tell whether you're juggling several.
    private var lastAnswerBySession: [String: Date] = [:]
    private static let recentWindow: TimeInterval = 30 * 60

    /// Adds an answer; a newer answer from the same session replaces its unread one.
    func enqueue(_ answer: QueuedAnswer) {
        lastAnswerBySession[answer.session] = answer.receivedAt
        pending.removeAll { $0.session == answer.session }
        pending.append(answer)
    }

    /// Other sessions that sent answers in the last 30 minutes.
    func recentSessions(excluding session: String, now: Date = Date()) -> Set<String> {
        Set(lastAnswerBySession.filter { $0.key != session && now.timeIntervalSince($0.value) < Self.recentWindow }.keys)
    }

    func next() -> QueuedAnswer? {
        guard !pending.isEmpty else { return nil }
        current = pending.removeFirst()
        return current
    }

    func moveToFront(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.insert(pending.remove(at: index), at: 0)
    }

    func remove(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    func clear() {
        pending.removeAll()
    }

    /// Spoken lead-in so you know where an answer comes from ("Hace 5 minutos, en notchcast.").
    /// Omitted when you only work in one project and the answer is fresh.
    static func intro(for answer: QueuedAnswer, multipleSessions: Bool, now: Date = Date()) -> String? {
        let minutes = Int(now.timeIntervalSince(answer.receivedAt) / 60)
        switch (minutes, multipleSessions) {
        case (0, false):
            return nil
        case (0, true):
            return "En \(answer.project)."
        case (1, _):
            return "Hace un minuto, en \(answer.project)."
        default:
            return "Hace \(minutes) minutos, en \(answer.project)."
        }
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere on the Mac.
    static var secondsSinceUserInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
