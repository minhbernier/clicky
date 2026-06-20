//
//  AgentTaskCardView.swift
//  leanring-buddy
//
//  Reusable SwiftUI pieces for rendering an agent task: the colored status pill
//  and the task card. Shared by the right-side task panel and the Agents tab so
//  both render tasks identically. Dark aesthetic using the DS design system.
//

import SwiftUI

/// A small colored pill showing an agent task's current status.
struct AgentTaskStatusPill: View {
    let status: AgentTaskStatus

    var body: some View {
        HStack(spacing: 5) {
            if status == .running {
                // A spinning indicator reads as "actively working" better than a dot.
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(pillColor)
                    .frame(width: 6, height: 6)
            }

            Text(status.displayLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(pillColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(pillColor.opacity(0.12))
        )
    }

    private var pillColor: Color {
        switch status {
        case .running: return DS.Colors.blue400
        case .needsConfirmation: return DS.Colors.warning
        case .done: return DS.Colors.success
        case .error: return DS.Colors.destructiveText
        }
    }
}

/// A single agent task card: title, status pill, and a one-line preview of the
/// agent's latest reply. Tapping it selects the task (for follow-up targeting).
struct AgentTaskCardView: View {
    let agentTask: AgentTask
    let isSelected: Bool
    let onSelect: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(agentTask.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                AgentTaskStatusPill(status: agentTask.status)
            }

            if let latestAssistantMessageText = agentTask.latestAssistantMessageText {
                Text(latestAssistantMessageText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.10 : (isHovered ? 0.07 : 0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(isSelected ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: isSelected ? 1 : 0.5)
        )
        .overlay(alignment: .topTrailing) {
            // A dismiss affordance appears on hover so finished cards can be cleared.
            if isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .pointerCursor()
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
