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

    /// Replaces a task's title — used when the model-generated label arrives
    /// asynchronously and upgrades the instant placeholder name.
    func setTitle(_ title: String, forTaskWithID agentTaskID: UUID) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        mutateAgentTask(withID: agentTaskID) { agentTask in
            agentTask.title = trimmedTitle
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
    /// ACTION / verb keywords. A request only becomes its own tracked agent when
    /// it asks Micky to DO something (edit, draft, research, launch, …) — not when
    /// it merely looks something up. This keeps quick connector/screen questions
    /// ("what's on my calendar?", "what does this code do?") card-free, while
    /// "draft a reply to this email" or "research the clicky diffs" spawn an agent.
    /// Mirrors the proxy's action + agent/research keyword groups (manually synced).
    private static let actionKeywords: [String] = [
        // edits / actions
        "edit", "change", "fix", "update", "write", "create", "delete", "remove",
        "rename", "refactor", "commit", "install", "build", "run", "open",
        "send", "reply", "draft", "add", "schedule", "make a", "do this",
        // agent / research launches
        "agent", "agents", "research", "investigate", "deep dive", "deep-dive",
        "look into", "dig into", "sub-agent", "subagent", "launch",
    ]

    /// Returns true when the request asks Micky to DO a task (worth tracking as
    /// its own agent), rather than a quick lookup or screen question.
    static func looksLikeAgentTask(_ userMessage: String) -> Bool {
        textMatchesAnyKeyword(userMessage.lowercased(), actionKeywords)
    }

    /// Keyword match: word boundaries for single words (so "run" doesn't fire
    /// inside "running"), substring for multi-word / hyphenated phrases.
    private static func textMatchesAnyKeyword(_ lowercasedMessage: String, _ keywords: [String]) -> Bool {
        let trimmedKeywords = keywords.map { $0.trimmingCharacters(in: .whitespaces) }
        let phraseKeywords = trimmedKeywords.filter { $0.contains(" ") || $0.contains("-") }
        if phraseKeywords.contains(where: { lowercasedMessage.contains($0) }) {
            return true
        }
        let singleWordKeywords = Set(trimmedKeywords.filter { !$0.contains(" ") && !$0.contains("-") })
        let messageWords = lowercasedMessage.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return messageWords.contains(where: { singleWordKeywords.contains($0) })
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
