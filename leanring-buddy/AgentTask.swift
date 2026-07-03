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

/// A single file artifact the proxy recorded for an agent task's latest
/// completed turn (a diff, a screenshot, a saved doc, etc.), fetched from the
/// proxy's `/agents/{id}/artifacts` route once the turn settles to `.done`.
/// Rendered as a clickable chip on the task card.
struct AgentTaskArtifact: Identifiable, Equatable {
    /// The artifact's absolute filesystem path. Also its stable identity —
    /// the proxy doesn't assign artifacts a separate id, and a path is unique
    /// per file.
    var id: String { path }
    let path: String
    /// Short display label for the chip (e.g. "Diff", "Screenshot").
    let title: String
    /// Whether the file still existed on disk as of the fetch. `false` keeps
    /// the chip visible but dimmed/disabled — the agent did produce it, even
    /// if it's since been moved or deleted — rather than hiding it entirely.
    let exists: Bool
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
    /// The proxy's cumulative set of artifacts for this task: every file it
    /// has recorded across all of the task's turns so far, deduped by path —
    /// not just the most recent turn's. Empty until the first successful
    /// fetch after a turn settles to `.done` or `.needsConfirmation`.
    var artifacts: [AgentTaskArtifact] = []

    /// The most recent assistant reply, used as the card's one-line preview.
    var latestAssistantMessageText: String? {
        transcript.last(where: { $0.role == .assistant })?.text
    }
}
