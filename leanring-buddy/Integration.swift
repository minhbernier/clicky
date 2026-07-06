//
//  Integration.swift
//  leanring-buddy
//
//  Data models for the Integrations tab's searchable app catalog — Gmail,
//  Slack, Notion, and 500+ others the user can browse and connect via
//  Composio through the local brain proxy (see CompanionManager.workerBaseURL).
//
//  Two shapes power two different routes:
//   - `Integration` is the curated/connected catalog from GET /connectors —
//     the small, hand-picked set of apps Micky actively recommends plus
//     whatever the user has actually connected. It carries enough copy
//     (tagline, sample-action chips) to render a rich row.
//   - `IntegrationSearchResult` is one hit from GET /connectors/search, which
//     searches Composio's full 500+ app catalog. Deliberately thinner — that
//     catalog hasn't been curated with taglines/chips/status, just a name and
//     a one-line description.
//

import Foundation

/// Live connection status for one app in the curated/connected catalog.
/// Decoded straight from the proxy's `status` string, which is also the
/// vocabulary IntegrationsStore uses to partition the catalog into the
/// Connected / Connecting… / Featured sections shown in the tab.
enum IntegrationStatus: String {
    case active
    case initializing
    case disconnected
}

/// One app in the curated seed + connected catalog, as returned by
/// GET /connectors. Also the shape IntegrationsStore.beginConnect(slug:)
/// synthesizes optimistically (status flipped to .initializing) the moment
/// the user taps Connect, before the proxy's own state has had a chance to
/// catch up.
struct Integration: Identifiable, Equatable {
    /// Composio toolkit slug, e.g. "gmail". Also the stable identity.
    let slug: String
    let name: String
    /// One-line description of what Micky can do with this app once connected.
    let tagline: String
    /// Sample capability chips, e.g. "Read unread email", "Draft a reply".
    let chips: [String]
    let status: IntegrationStatus

    var id: String { slug }
}

/// One hit from Composio's full app catalog, as returned by
/// GET /connectors/search. Deliberately thinner than `Integration` — search
/// results haven't been curated with taglines/chips/status, just enough to
/// show a row and let the user tap Connect.
struct IntegrationSearchResult: Identifiable {
    let slug: String
    let name: String
    let description: String

    var id: String { slug }
}
