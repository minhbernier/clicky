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

            if !agentTask.artifacts.isEmpty {
                AgentTaskArtifactsRow(artifacts: agentTask.artifacts)
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

/// A single artifact chip on a task card: a doc icon + short title, clickable
/// to reveal the file in its default app via NSWorkspace. Rendered dimmed and
/// disabled with a strikethrough title when the file no longer exists on disk
/// (moved or deleted since the proxy recorded it) — the agent still did
/// produce it, so the chip stays visible rather than disappearing.
struct AgentTaskArtifactChip: View {
    let artifact: AgentTaskArtifact

    @State private var isHovered = false

    var body: some View {
        Button(action: openArtifact) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10, weight: .medium))
                Text(artifact.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(!artifact.exists)
            }
            // Titles are unbounded proxy data — cap the chip's content width so a
            // long title truncates with an ellipsis instead of drawing past the
            // task card's edge. ConnectorChipFlowLayout sizes each subview at its
            // own ideal width, so without this cap nothing else constrains it.
            .frame(maxWidth: 240, alignment: .leading)
            .foregroundColor(artifact.exists ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(
                Capsule().fill(artifact.exists && isHovered ? DS.Colors.surface4 : DS.Colors.surface3)
            )
            .overlay(
                Capsule().strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!artifact.exists)
        .pointerCursor(isEnabled: artifact.exists)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func openArtifact() {
        NSWorkspace.shared.open(URL(fileURLWithPath: artifact.path))
    }
}

/// A compact, wrapping row of artifact chips shown under a task's preview
/// text once the proxy has recorded files for its latest completed turn.
/// Reuses ConnectorChipFlowLayout (defined in ConnectorRecommendationView.swift)
/// so chips wrap onto new rows instead of overflowing the card's fixed width.
struct AgentTaskArtifactsRow: View {
    let artifacts: [AgentTaskArtifact]

    var body: some View {
        ConnectorChipFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(artifacts) { artifact in
                AgentTaskArtifactChip(artifact: artifact)
            }
        }
    }
}
