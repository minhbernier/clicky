//
//  AgentTaskPanelView.swift
//  leanring-buddy
//
//  SwiftUI content for the floating right-side task panel. Shows a vertical list
//  of agent task cards and a "follow up with agent…" input at the bottom that
//  routes a typed message back to the selected task through the same /chat path.
//  Dark aesthetic using the DS design system.
//

import SwiftUI

struct AgentTaskPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var followUpText: String = ""

    /// The task the follow-up field targets — the explicitly selected one, or
    /// the newest task if nothing is selected yet.
    private var targetedAgentTask: AgentTask? {
        let store = companionManager.agentTaskStore
        if let selectedAgentTaskID = store.selectedAgentTaskID,
           let selectedAgentTask = store.agentTask(withID: selectedAgentTaskID) {
            return selectedAgentTask
        }
        return store.agentTasks.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            Divider()
                .background(DS.Colors.borderSubtle)

            taskCardList

            Divider()
                .background(DS.Colors.borderSubtle)

            followUpInputRow
                .padding(12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)

            Text("Agents")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("\(companionManager.agentTaskStore.agentTasks.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .clickyHideAgentTaskPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Task Cards

    private var taskCardList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(companionManager.agentTaskStore.agentTasks) { agentTask in
                    AgentTaskCardView(
                        agentTask: agentTask,
                        isSelected: agentTask.id == targetedAgentTask?.id,
                        onSelect: {
                            companionManager.agentTaskStore.selectedAgentTaskID = agentTask.id
                        },
                        onDismiss: {
                            companionManager.agentTaskStore.removeAgentTask(withID: agentTask.id)
                        }
                    )
                }
            }
            .padding(12)
        }
        // Cap the height so the panel doesn't grow unbounded with many tasks;
        // the list scrolls instead.
        .frame(maxHeight: 420)
    }

    // MARK: - Follow Up Input

    private var followUpInputRow: some View {
        HStack(spacing: 8) {
            TextField("follow up with agent…", text: $followUpText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .onSubmit(sendFollowUp)

            Button(action: sendFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(isFollowUpSendable ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!isFollowUpSendable)
        }
    }

    private var isFollowUpSendable: Bool {
        !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && targetedAgentTask != nil
    }

    private func sendFollowUp() {
        guard isFollowUpSendable, let targetedAgentTask else { return }
        companionManager.sendFollowUpText(followUpText, toAgentTaskID: targetedAgentTask.id)
        followUpText = ""
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}
