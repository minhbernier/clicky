//
//  ProactiveSuggestionView.swift
//  leanring-buddy
//
//  The proactive-suggestion bubble's content — an icon, a short one-line-ish
//  nudge, and two actions: Dismiss / Act on it. Presented as a floating panel
//  by ProactiveManager, styled like ConnectorRecommendationView (same surface,
//  border, and shadow tokens) but deliberately smaller and lower-key, since
//  this is an unsolicited suggestion rather than something the user asked for.
//

import SwiftUI

struct ProactiveSuggestionView: View {
    let suggestion: ProactiveSuggestion

    /// User tapped "Dismiss" — just close the bubble.
    let onDismiss: () -> Void
    /// User tapped "Act on it" — send the suggestion text to the main chat,
    /// then close the bubble.
    let onActOnIt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            headerRow
            actionRow
        }
        .padding(DS.Spacing.lg)
        .frame(width: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
    }

    // MARK: - Header (icon + suggestion text)

    private var headerRow: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            iconTile
            Text(suggestion.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    private var iconTile: some View {
        Image(systemName: "lightbulb.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(DS.Colors.accentText)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    // MARK: - Actions (Dismiss / Act on it)

    private var actionRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(DSTertiaryButtonStyle())

            Button(action: onActOnIt) {
                Label("Act on it", systemImage: "arrow.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
        }
    }
}
