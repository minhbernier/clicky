//
//  ConnectorRecommendationView.swift
//  leanring-buddy
//
//  The connector-recommendation popup card — Micky's take on HeyClicky's
//  "Connect Discord to …" prompt. Shows the two app icons, a title, the sample
//  actions Micky could perform once connected, and No / Not now / Yes actions.
//  Presented as a floating banner by ConnectorRecommendationManager.
//

import SwiftUI

struct ConnectorRecommendationView: View {
    let recommendation: ConnectorRecommendation

    /// User tapped "Yes" — start the OAuth connect flow.
    let onConnect: () -> Void
    /// User tapped "Not now" — dismiss for now; it may resurface later.
    let onNotNow: () -> Void
    /// User tapped "No" — dismiss and stop recommending this app.
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            headerRow
            capabilitiesSection
            actionRow
        }
        .padding(DS.Spacing.xl)
        .frame(width: 420, alignment: .leading)
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

    // MARK: - Header (paired app icons + title)

    private var headerRow: some View {
        HStack(spacing: DS.Spacing.md) {
            pairedAppIcons
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect \(recommendation.name) to Micky")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                if recommendation.status == "initializing" {
                    Text("Finishing an earlier connection…")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The Micky icon and the connector's icon shown side by side, echoing the
    /// reference popup's two-logo header.
    private var pairedAppIcons: some View {
        HStack(spacing: -8) {
            iconTile(systemName: "m.circle.fill", foreground: DS.Colors.accentText, background: DS.Colors.surface3)
            iconTile(systemName: recommendation.iconSystemName, foreground: recommendation.brandColor, background: DS.Colors.surface3)
        }
    }

    private func iconTile(systemName: String, foreground: Color, background: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(foreground)
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    // MARK: - Capabilities (tagline + sample-action chips)

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(recommendation.tagline)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            ConnectorChipFlowLayout(horizontalSpacing: DS.Spacing.sm, verticalSpacing: DS.Spacing.sm) {
                ForEach(recommendation.chips, id: \.self) { chipText in
                    capabilityChip(chipText)
                }
            }
        }
    }

    private func capabilityChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .lineLimit(1)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                Capsule().fill(DS.Colors.surface3)
            )
            .overlay(
                Capsule().strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    // MARK: - Actions (No / Not now / Yes)

    private var actionRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(action: onDecline) {
                Label("No", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(DSTertiaryButtonStyle())

            Button(action: onNotNow) {
                Label("Not now", systemImage: "clock")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))

            Spacer(minLength: 0)

            Button(action: onConnect) {
                Label("Yes", systemImage: "link")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
        }
    }
}

/// Minimal flow layout that wraps its children onto new rows when they run out
/// of horizontal space — used for the capability chips. (macOS 13+ Layout API;
/// the app targets macOS 14.2+.)
struct ConnectorChipFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(CGFloat.zero) { runningHeight, row in
            runningHeight + row.height + (runningHeight > 0 ? verticalSpacing : 0)
        }
        let widestRow = rows.map(\.width).max() ?? 0
        return CGSize(width: min(widestRow, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var currentY = bounds.minY
        for row in rows {
            var currentX = bounds.minX
            for index in row.indices {
                let subviewSize = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: currentX, y: currentY),
                    proposal: ProposedViewSize(subviewSize)
                )
                currentX += subviewSize.width + horizontalSpacing
            }
            currentY += row.height + verticalSpacing
        }
    }

    /// One wrapped row: which subview indices it contains and its measured size.
    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        for index in subviews.indices {
            let subviewSize = subviews[index].sizeThatFits(.unspecified)
            let widthIfAdded = currentRow.width + subviewSize.width + (currentRow.indices.isEmpty ? 0 : horizontalSpacing)
            if !currentRow.indices.isEmpty && widthIfAdded > maxWidth {
                rows.append(currentRow)
                currentRow = Row()
                currentRow.indices = [index]
                currentRow.width = subviewSize.width
                currentRow.height = subviewSize.height
            } else {
                currentRow.indices.append(index)
                currentRow.width = widthIfAdded
                currentRow.height = max(currentRow.height, subviewSize.height)
            }
        }
        if !currentRow.indices.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}
