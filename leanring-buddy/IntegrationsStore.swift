//
//  IntegrationsStore.swift
//  leanring-buddy
//
//  Centralized observable state for the Integrations tab. Owned by
//  CompanionManager (like AgentTaskStore) so the catalog/search state
//  survives every open/close of the menu bar panel rather than resetting
//  each time the tab is selected. Fetches the catalog through
//  IntegrationsService and partitions it into three sections the tab
//  renders directly: Connected (active), Connecting… (initializing), and
//  Featured (disconnected seed apps) — plus a separate, debounced search
//  path over Composio's full app catalog.
//
//  Nothing here ever talks to the proxy until the user opens the tab once
//  (see onTabAppear). After that, the app coming to the foreground also
//  triggers a refresh, so reconnecting apps in the browser and switching
//  back to Micky picks up the new state without the user having to do
//  anything.
//

import AppKit
import Combine
import Foundation

@MainActor
final class IntegrationsStore: ObservableObject {

    /// Coarse fetch state for the top-level catalog (Connected/Connecting…/
    /// Featured). Search has its own implicit state — an empty
    /// `searchResults` while a query is active just means "no matches" or
    /// "still typing," not a failure worth a separate Retry affordance.
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    @Published private(set) var connected: [Integration] = []
    @Published private(set) var initializing: [Integration] = []
    @Published private(set) var available: [Integration] = []
    @Published private(set) var searchResults: [IntegrationSearchResult] = []
    @Published private(set) var loadState: LoadState = .idle

    /// Bound directly to the tab's search TextField. Every change reschedules
    /// the debounced search below via `didSet` — this is the one property on
    /// this store that isn't `private(set)`.
    @Published var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            runSearch()
        }
    }

    private let service: IntegrationsService

    /// True once the Integrations tab has appeared at least once. Gates the
    /// app-became-active refresh below so a foreground event before the user
    /// ever opens the tab stays a no-op — nothing about this feature may run
    /// before the user opts in by opening it.
    private var hasAppearedOnce = false

    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// In-flight connect attempts keyed by toolkit slug, mirroring
    /// CompanionManager's artifactFetchTasksByAgentTaskID pattern: tapping
    /// Connect on the same app twice cancels the stale attempt instead of
    /// letting two OAuth round-trips race, while two *different* apps can
    /// still be connected concurrently without stepping on each other.
    private var connectTasksBySlug: [String: Task<Void, Never>] = [:]

    private var didBecomeActiveObserver: NSObjectProtocol?

    init(service: IntegrationsService) {
        self.service = service

        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.hasAppearedOnce else { return }
            self.refresh()
        }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        refreshTask?.cancel()
        searchTask?.cancel()
        for (_, task) in connectTasksBySlug { task.cancel() }
    }

    // MARK: - Tab lifecycle

    /// Called from the Integrations tab's `.onAppear`. The first call arms
    /// the app-became-active refresh above; every call (first or not) kicks
    /// off a fresh fetch, since reopening the tab is a natural moment to pick
    /// up anything that changed since (e.g. a connect finishing in the
    /// browser while the panel was closed).
    func onTabAppear() {
        hasAppearedOnce = true
        refresh()
    }

    // MARK: - Fetch + partition

    /// Fetches the full catalog and partitions it into connected/
    /// initializing/available, cancelling any fetch already in flight so a
    /// slow older request can't land after (and stomp) a newer one.
    func refresh() {
        refreshTask?.cancel()
        loadState = .loading
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let integrations = await self.service.listConnectors()
            guard !Task.isCancelled else { return }
            guard !integrations.isEmpty else {
                // IntegrationsService.listConnectors() only ever returns []
                // on failure — the curated seed guarantees a non-empty
                // catalog whenever the proxy actually answered — so an empty
                // result here means "unreachable," not "genuinely no apps."
                self.loadState = .failed
                return
            }
            self.connected = integrations.filter { $0.status == .active }
            self.initializing = integrations.filter { $0.status == .initializing }
            self.available = integrations.filter { $0.status == .disconnected }
            self.loadState = .loaded
        }
    }

    // MARK: - Search

    /// Best-known status for a slug across every section this store tracks.
    /// Search results don't carry their own status (Composio's full catalog
    /// isn't curated with per-user connection state the way GET /connectors
    /// is), so a search hit that's already connected — or mid-connecting —
    /// looks up its real status here instead of always offering a redundant
    /// Connect button. Returns nil for a slug this store has never seen,
    /// which the row treats the same as `.disconnected`.
    func knownStatus(forSlug slug: String) -> IntegrationStatus? {
        if connected.contains(where: { $0.slug == slug }) { return .active }
        if initializing.contains(where: { $0.slug == slug }) { return .initializing }
        if available.contains(where: { $0.slug == slug }) { return .disconnected }
        return nil
    }

    /// Debounces `searchQuery` changes (~300ms) before hitting the network,
    /// so a fast typist doesn't fire a request per keystroke, and cancels
    /// whatever search is already in flight so stale results can never land
    /// after a newer query's. Below the 2-character floor, results are
    /// cleared immediately with no network call at all.
    private func runSearch() {
        searchTask?.cancel()
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            searchResults = []
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let results = await self.service.search(trimmedQuery)
            // The query may have changed (or this task may have been
            // superseded) while the request was in flight — only the task
            // that's still current is allowed to publish.
            guard !Task.isCancelled else { return }
            self.searchResults = results
        }
    }

    // MARK: - Connect

    /// "Connect" tapped on a non-active app row: starts the OAuth flow, opens
    /// the browser to complete it, and optimistically marks the app as
    /// initializing rather than waiting for a follow-up refresh — so the tab
    /// reflects the user's action immediately instead of looking like nothing
    /// happened. Schedules a refresh a few seconds later to pick up the
    /// proxy's real status once the OAuth round-trip has had a chance to land.
    func beginConnect(slug: String) {
        connectTasksBySlug[slug]?.cancel()
        connectTasksBySlug[slug] = Task { [weak self] in
            guard let self else { return }
            // Deliberately not cleared via `defer` on completion: if the user
            // re-taps Connect on the same slug before this task finishes, the
            // line above already overwrote this dictionary entry with the new
            // task. This task's `defer` firing afterward would otherwise nil
            // out — and orphan — that newer task's entry, breaking its own
            // cancel-on-re-tap. A finished task left in the dictionary is
            // harmless: the next connect attempt for this slug (or this
            // store's deinit) is the only thing that ever reads it again.
            guard let redirectURL = await self.service.connect(slug: slug) else { return }
            guard !Task.isCancelled else { return }

            NSWorkspace.shared.open(redirectURL)
            self.markInitializingOptimistically(slug: slug)

            // Give the OAuth round-trip (browser redirect + proxy callback)
            // a moment to settle before re-fetching — refreshing immediately
            // would almost always still show "disconnected".
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self.refresh()
        }
    }

    /// Moves a slug into `initializing` immediately after Connect is tapped,
    /// pulling its display copy from wherever it's currently known (the
    /// Featured list, or — for a catalog-search hit with no tagline/chips of
    /// its own — the search result) so the Connecting… section never shows a
    /// blank row while the real refresh is still in flight.
    private func markInitializingOptimistically(slug: String) {
        guard knownStatus(forSlug: slug) != .active, knownStatus(forSlug: slug) != .initializing else { return }

        if let index = available.firstIndex(where: { $0.slug == slug }) {
            let featuredIntegration = available.remove(at: index)
            initializing.append(
                Integration(
                    slug: featuredIntegration.slug,
                    name: featuredIntegration.name,
                    tagline: featuredIntegration.tagline,
                    chips: featuredIntegration.chips,
                    status: .initializing
                )
            )
        } else if let searchResult = searchResults.first(where: { $0.slug == slug }) {
            initializing.append(
                Integration(
                    slug: searchResult.slug,
                    name: searchResult.name,
                    tagline: searchResult.description,
                    chips: [],
                    status: .initializing
                )
            )
        }
    }
}
