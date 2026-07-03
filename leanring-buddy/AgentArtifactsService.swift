//
//  AgentArtifactsService.swift
//  leanring-buddy
//
//  Thin async client for the proxy's per-agent artifacts route. After an agent
//  turn completes, the proxy may have produced file artifacts (a diff, a
//  screenshot, a saved doc, etc.) and tracks them keyed by agent id — the same
//  id the app already sends as `agent_id` on /chat (the AgentTask's UUID
//  string). This service fetches those artifacts so the task card can render
//  them as clickable chips. Fails soft on every path — a flaky fetch can never
//  disrupt the voice pipeline or leave a task card in a broken state.
//

import Foundation

/// Thin async client for the proxy's `/agents/{id}/artifacts` route. Owned by
/// CompanionManager. Mirrors ConnectorRecommendationService's fail-soft shape:
/// every call returns an empty result instead of throwing.
@MainActor
final class AgentArtifactsService {
    /// Base URL of the local brain proxy, e.g. "http://127.0.0.1:8787".
    private let proxyBaseURL: String
    private let urlSession: URLSession

    init(proxyBaseURL: String, urlSession: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.urlSession = urlSession
    }

    /// Fetches the artifacts the proxy recorded for this agent id. Returns an
    /// empty array on any failure — bad URL, network error, timeout, non-2xx,
    /// or malformed JSON — so the caller never has to special-case a failed
    /// fetch; it just means no artifacts row appears on the card.
    func artifacts(forAgentID agentID: String) async -> [AgentTaskArtifact] {
        guard let requestURL = URL(string: "\(proxyBaseURL)/agents/\(agentID)/artifacts") else {
            return []
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        // Short timeout — this is a best-effort UI enrichment fired after the
        // turn already settled, not something the user is waiting on.
        request.timeoutInterval = 5

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }
            guard let envelope = try? JSONDecoder().decode(ArtifactsEnvelope.self, from: responseData) else {
                return []
            }

            // Tolerant mapping: an entry missing (or null for) `path` or `title`
            // can't be rendered as a chip (no identity, no label), so it's
            // skipped rather than dropping every other artifact in the
            // response. See ArtifactsEnvelope below for what this tolerance
            // does and doesn't cover. A missing `exists` is treated as true —
            // the proxy only just recorded the file.
            return (envelope.artifacts ?? []).compactMap { rawArtifact in
                guard let path = rawArtifact.path, let title = rawArtifact.title else { return nil }
                return AgentTaskArtifact(path: path, title: title, exists: rawArtifact.exists ?? true)
            }
        } catch {
            print("⚠️ Agent artifacts fetch failed: \(error)")
            return []
        }
    }

    // MARK: - Decoding

    /// Matches the proxy's `{"id": "...", "artifacts": [...]}` response shape.
    /// Decoding is still all-or-nothing: `JSONDecoder` only tolerates a field
    /// being *missing or null* (that's what Optional buys you here — e.g. an
    /// absent `artifacts` array, or one entry missing `path`/`title`), not a
    /// field present with the *wrong type* (e.g. `path` sent as a number).
    /// A single type-mismatched field anywhere in the payload still fails this
    /// whole decode, and `artifacts(forAgentID:)` returns [] for the entire
    /// fetch. The optionality here only sets up the *entry-level* tolerance
    /// that function applies afterward: an entry that decoded successfully
    /// but is missing `path` or `title` is dropped individually instead of
    /// discarding every other artifact in the response.
    private struct ArtifactsEnvelope: Decodable {
        let artifacts: [RawArtifact]?
    }

    private struct RawArtifact: Decodable {
        let path: String?
        let title: String?
        let exists: Bool?
    }
}
