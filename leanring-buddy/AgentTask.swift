//
//  AgentTask.swift
//  leanring-buddy
//
//  Data model for an "agent task" — a multi-step request the user handed to
//  Micky's power session (e.g. "research the clicky diffs", "draft a reply to
//  this email"). Each task is surfaced as a card in the right-side task panel
//  and in the Agents tab of the menu bar panel, where the user can follow up
//  by text or voice.
//

import Foundation

/// The lifecycle status of an agent task, rendered as a colored pill on its card.
enum AgentTaskStatus {
    /// The agent is actively working on the most recent turn.
    case running
    /// The agent described a mutating action and is waiting for the user to
    /// confirm (say or type "yes") before it proceeds. Mirrors the proxy's
    /// confirmation gate.
    case needsConfirmation
    /// The agent finished its most recent turn successfully.
    case done
    /// The most recent turn failed.
    case error

    /// Short human-readable label shown inside the status pill.
    var displayLabel: String {
        switch self {
        case .running: return "Running"
        case .needsConfirmation: return "Needs confirmation"
        case .done: return "Done"
        case .error: return "Error"
        }
    }
}

/// One entry in an agent task's transcript — either what the user asked or
/// what the agent replied. Kept as a flat list so the follow-up view can render
/// the full back-and-forth in order.
struct AgentTaskMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let createdAt: Date

    init(role: Role, text: String, createdAt: Date = Date()) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// A single agent/task shown in the task panel and the Agents tab. Represents
/// one ongoing line of work with Micky's power session and its full transcript.
struct AgentTask: Identifiable {
    let id = UUID()
    /// Short title derived from the user's first request (e.g. "Research clicky diffs").
    var title: String
    var status: AgentTaskStatus
    /// The full ordered back-and-forth for this task.
    var transcript: [AgentTaskMessage]
    let createdAt: Date
    var updatedAt: Date

    /// The most recent assistant reply, used as the card's one-line preview.
    var latestAssistantMessageText: String? {
        transcript.last(where: { $0.role == .assistant })?.text
    }
}
