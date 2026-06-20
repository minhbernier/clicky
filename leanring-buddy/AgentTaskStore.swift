//
//  AgentTaskStore.swift
//  leanring-buddy
//
//  Centralized observable store of the user's agent tasks. Owned by
//  CompanionManager so task state lives in one place and both the right-side
//  task panel and the Agents tab observe the same source of truth.
//

import Combine
import Foundation

@MainActor
final class AgentTaskStore: ObservableObject {
    /// All agent tasks, newest first. The right-side panel and Agents tab both
    /// render from this list.
    @Published private(set) var agentTasks: [AgentTask] = []

    /// The task the follow-up inputs (panel field, Agents-tab buttons) currently
    /// target. Defaults to the newest task whenever a new one is created.
    @Published var selectedAgentTaskID: UUID?

    // MARK: - Creating and updating tasks

    /// Creates a new agent task seeded with the user's first request and returns
    /// its id so the caller can update it as the turn progresses.
    @discardableResult
    func createAgentTask(title: String, initialUserMessage: String) -> UUID {
        let now = Date()
        var newAgentTask = AgentTask(
            title: title,
            status: .running,
            transcript: [],
            createdAt: now,
            updatedAt: now
        )
        let trimmedInitialUserMessage = initialUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInitialUserMessage.isEmpty {
            newAgentTask.transcript.append(
                AgentTaskMessage(role: .user, text: trimmedInitialUserMessage, createdAt: now)
            )
        }
        // Newest task on top so the most recent work is always visible first.
        agentTasks.insert(newAgentTask, at: 0)
        selectedAgentTaskID = newAgentTask.id
        return newAgentTask.id
    }

    func appendUserMessage(_ text: String, toTaskWithID agentTaskID: UUID) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        mutateAgentTask(withID: agentTaskID) { agentTask in
            agentTask.transcript.append(AgentTaskMessage(role: .user, text: trimmedText))
        }
    }

    func appendAssistantMessage(_ text: String, toTaskWithID agentTaskID: UUID) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        mutateAgentTask(withID: agentTaskID) { agentTask in
            agentTask.transcript.append(AgentTaskMessage(role: .assistant, text: trimmedText))
        }
    }

    func updateStatus(_ status: AgentTaskStatus, forTaskWithID agentTaskID: UUID) {
        mutateAgentTask(withID: agentTaskID) { agentTask in
            agentTask.status = status
        }
    }

    func agentTask(withID agentTaskID: UUID) -> AgentTask? {
        agentTasks.first(where: { $0.id == agentTaskID })
    }

    /// Removes a single task (used by the card's dismiss button).
    func removeAgentTask(withID agentTaskID: UUID) {
        agentTasks.removeAll(where: { $0.id == agentTaskID })
        if selectedAgentTaskID == agentTaskID {
            selectedAgentTaskID = agentTasks.first?.id
        }
    }

    // MARK: - Private

    /// Applies an in-place edit to a task by id and refreshes its updatedAt.
    /// Reassigns the whole array element so @Published fires for SwiftUI.
    private func mutateAgentTask(withID agentTaskID: UUID, _ mutate: (inout AgentTask) -> Void) {
        guard let index = agentTasks.firstIndex(where: { $0.id == agentTaskID }) else { return }
        var updatedAgentTask = agentTasks[index]
        mutate(&updatedAgentTask)
        updatedAgentTask.updatedAt = Date()
        agentTasks[index] = updatedAgentTask
    }
}

/// Decides whether a spoken/typed request is an "agent task" worth tracking as a
/// card, and derives a short title for it. The heuristic intentionally mirrors
/// the proxy's POWER_KEYWORDS so the app only spawns a card for requests the
/// proxy would route to its power session — plain "what is this?" screen
/// questions stay card-free.
enum AgentTaskClassifier {
    /// Keyword set mirrored from clicky-max-proxy/proxy.py POWER_KEYWORDS. Kept
    /// in sync manually; if the proxy's list changes, update this too.
    private static let agentTaskKeywords: [String] = [
        // connectors
        "email", "emails", "inbox", "gmail", "unread", "my mail", "calendar",
        "schedule", "meeting", "meetings", "appointment", "agenda", "event",
        "events", "free time", "availability", "my day", "drive", "my files",
        "google doc", "spreadsheet",
        // actions / editing / agents
        "edit", "change", "fix", "update", "write", "create", "delete", "remove",
        "rename", "refactor", "commit", "install", "build", "run ", "open ",
        "launch", "agent", "agents", "send", "reply", "draft", "make a", "add ",
        "file", "folder", "script", "code", "terminal", "command", "do this",
    ]

    /// Returns true when the request reads like a multi-step / power-session job
    /// rather than a quick screen question.
    static func looksLikeAgentTask(_ userMessage: String) -> Bool {
        let lowercasedMessage = userMessage.lowercased()
        return agentTaskKeywords.contains(where: { lowercasedMessage.contains($0) })
    }

    /// Builds a short, title-cased label (max ~6 words) from the user's request
    /// for use as the task card's title.
    static func makeTitle(from userMessage: String) -> String {
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return "New task" }

        let words = trimmedMessage.split(whereSeparator: { $0.isWhitespace })
        let firstWords = words.prefix(6).joined(separator: " ")
        let truncated = firstWords.count < trimmedMessage.count ? firstWords + "…" : firstWords

        // Capitalize the first character so titles read like headings.
        return truncated.prefix(1).uppercased() + truncated.dropFirst()
    }
}
