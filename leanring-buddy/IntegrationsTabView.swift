//
//  IntegrationsTabView.swift
//  leanring-buddy
//
//  The Integrations tab: a searchable catalog of apps Micky can connect to
//  via Composio through the local brain proxy. Three sections stacked
//  top-to-bottom — Connected, Connecting…, and either live search results or
//  a Featured list of the curated seed apps — mirroring how the Agents tab
//  in CompanionPanelView lays out its own search field + scrollable list.
//  Owns none of its own state; everything comes from the IntegrationsStore
//  passed in (see CompanionManager.integrationsStore), so the tab's search
//  query and catalog partitioning survive every open/close of the panel.
//

import SwiftUI

struct IntegrationsTabView: View {
    @ObservedObject var store: IntegrationsStore

    /// Search takes over the bottom section (replacing Featured) once the
    /// query clears IntegrationsStore's 2-character floor — matching the
    /// floor the store itself uses to decide when to hit the network.
    private var isSearching: Bool {
        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch store.loadState {
                    case .idle, .loading:
                        loadingRow
                    case .failed:
                        retryRow
                    case .loaded:
                        loadedContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 320)
        }
        // First appearance kicks off the initial fetch and arms the
        // app-became-active refresh (see IntegrationsStore.onTabAppear) —
        // nothing about this tab runs before the user opens it once.
        .onAppear { store.onTabAppear() }
    }

    // MARK: - Search Field

    /// DS-styled search input, same visual language as CompanionPanelView's
    /// agentSearchField: magnifyingglass leading icon, plain text field, and
    /// a clear button that only appears once there's something to clear.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            TextField("Search apps…", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)

            if !store.searchQuery.isEmpty {
                Button(action: { store.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Loaded Content

    @ViewBuilder
    private var loadedContent: some View {
        if isSearching {
            searchResultsSection
        } else if store.connected.isEmpty && store.initializing.isEmpty && store.available.isEmpty {
            // Only reachable if the proxy answered with a genuinely empty
            // catalog — the curated seed makes this practically impossible,
            // but a blank scroll view with no explanation would look broken.
            Text("No integrations available")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            if !store.connected.isEmpty { connectedSection }
            if !store.initializing.isEmpty { connectingSection }
            featuredSection
        }
    }

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("CONNECTED")
            VStack(spacing: 6) {
                ForEach(store.connected) { integration in
                    IntegrationRowView(
                        name: integration.name,
                        subtitle: rowSubtitle(for: integration),
                        status: integration.status,
                        onConnect: nil
                    )
                }
            }
        }
    }

    private var connectingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("CONNECTING…")
            VStack(spacing: 6) {
                ForEach(store.initializing) { integration in
                    IntegrationRowView(
                        name: integration.name,
                        subtitle: rowSubtitle(for: integration),
                        status: integration.status,
                        onConnect: nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var featuredSection: some View {
        if !store.available.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("FEATURED")
                VStack(spacing: 6) {
                    ForEach(store.available) { integration in
                        IntegrationRowView(
                            name: integration.name,
                            subtitle: rowSubtitle(for: integration),
                            status: integration.status,
                            onConnect: { store.beginConnect(slug: integration.slug) }
                        )
                    }
                }
            }
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("RESULTS")
            if store.searchResults.isEmpty {
                Text("No matching apps")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.searchResults) { result in
                        IntegrationRowView(
                            name: result.name,
                            subtitle: result.description,
                            // Search results don't carry their own status —
                            // resolve it from the store so an already-connected
                            // (or mid-connecting) app doesn't offer a redundant
                            // Connect button just because it also turned up here.
                            status: store.knownStatus(forSlug: result.slug),
                            onConnect: { store.beginConnect(slug: result.slug) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Loading / Retry

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 24)
    }

    /// Shown when IntegrationsService.listConnectors() came back empty (the
    /// service's fail-soft contract means that only happens when the proxy
    /// couldn't be reached at all). Retry re-runs the exact same fetch.
    private var retryRow: some View {
        VStack(spacing: 8) {
            Text("Couldn't reach Micky's proxy")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Button(action: { store.refresh() }) {
                Text("Retry")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textTertiary)
    }

    /// Rows show the tagline when the catalog has one; otherwise fall back to
    /// the first sample-action chip so a row is never left with no subtitle
    /// at all.
    private func rowSubtitle(for integration: Integration) -> String {
        integration.tagline.isEmpty ? (integration.chips.first ?? "") : integration.tagline
    }
}

// MARK: - Integration Row

/// One row in any Integrations tab section: app name + subtitle on the left,
/// a trailing status badge or Connect button on the right. Shared by the
/// Connected/Connecting…/Featured sections and by search results — the only
/// thing that varies per call site is which status is known and whether a
/// Connect action is offered.
private struct IntegrationRowView: View {
    let name: String
    let subtitle: String
    /// nil is treated the same as `.disconnected` — a Connect button is
    /// offered whenever `onConnect` is non-nil, regardless of which of the
    /// two this is. Search results that this store has never seen resolve to
    /// nil via IntegrationsStore.knownStatus(forSlug:).
    let status: IntegrationStatus?
    let onConnect: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            trailingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch status {
        case .active:
            statusBadge(text: "Connected", color: DS.Colors.success, showSpinner: false)
        case .initializing:
            statusBadge(text: "Connecting…", color: DS.Colors.warning, showSpinner: true)
        case .disconnected, .none:
            if let onConnect {
                connectButton(action: onConnect)
            }
        }
    }

    /// Same pill shape as the permission rows' "Granted" indicator elsewhere
    /// in CompanionPanelView (dot/checkmark + label), reused here so status
    /// reads consistently across the whole panel.
    private func statusBadge(text: String, color: Color, showSpinner: Bool) -> some View {
        HStack(spacing: 4) {
            if showSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
        }
    }

    private func connectButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Connect")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
