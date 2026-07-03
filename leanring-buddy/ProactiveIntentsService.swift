//
//  ProactiveIntentsService.swift
//  leanring-buddy
//
//  Thin async client for the proxy's /proactive-intents route — the backend
//  half of the proactive-suggestion HUD. That route is OFF by default and
//  enforces its own throttle/cooldown/daily caps server-side, so this client
//  is free to call it on every dwell tick without adding client-side rate
//  limiting of its own: a null `suggestion` just means "nothing to show right
//  now," not an error. Mirrors AgentArtifactsService's fail-soft shape: every
//  call returns nil instead of throwing, and nothing here may ever block the
//  main thread or disrupt the dwell timer that drives it (see ProactiveManager).
//

import Foundation

/// Thin async client for the proxy's `/proactive-intents` route. Owned by
/// ProactiveManager. POSTs `{app, url, title?}` and expects either
/// `{"suggestion": null, "reason": "..."}` or
/// `{"suggestion": {"text": ..., "app": ..., "url": ...}}`. Never throws.
@MainActor
final class ProactiveIntentsService {
    /// Base URL of the local brain proxy, e.g. "http://127.0.0.1:8787".
    private let proxyBaseURL: String
    private let urlSession: URLSession

    init(proxyBaseURL: String, urlSession: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.urlSession = urlSession
    }

    /// Asks the proxy whether it wants to surface a proactive suggestion for
    /// the given app context. Returns nil both when the server says there's
    /// nothing to suggest (the common case — the feature is off by default
    /// and rate-limited even when on) and on any failure (bad URL, network
    /// error, timeout, non-2xx, malformed JSON). Callers can't tell those two
    /// cases apart, which is intentional: either way the answer is "show
    /// nothing." Only genuine failures are logged (see the catch block and
    /// the malformed-JSON guard below) — the routine "nothing to suggest"
    /// response is expected on most calls and would spam the console if it
    /// warned every time, given this fires on every dwell tick.
    func suggestion(forApp app: String, url: String, title: String?) async -> ProactiveSuggestion? {
        guard let requestURL = URL(string: "\(proxyBaseURL)/proactive-intents") else { return nil }

        var requestBody: [String: Any] = ["app": app, "url": url]
        if let title, !title.isEmpty {
            requestBody["title"] = title
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Short timeout — this fires from a background dwell timer, never in
        // response to something the user is actively waiting on, so it must
        // never be allowed to hang around.
        request.timeoutInterval = 5
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            guard let envelope = try? JSONDecoder().decode(SuggestionEnvelope.self, from: responseData) else {
                print("⚠️ Proactive intents: malformed response")
                return nil
            }
            guard let rawSuggestion = envelope.suggestion else {
                // No suggestion this time — not a failure, just nothing to
                // show. `reason` (if present) explains why for debugging but
                // isn't surfaced to the UI.
                return nil
            }
            // Tolerant mapping, same reasoning as AgentArtifactsService: a
            // `suggestion` object missing any of these fields can't be
            // rendered, so treat it as "nothing to show" rather than
            // crashing the whole decode. Named to avoid shadowing this
            // function's own `app`/`url` request parameters above — these
            // come from the response body, not the request.
            guard let suggestionText = rawSuggestion.text,
                  let suggestionApp = rawSuggestion.app,
                  let suggestionURL = rawSuggestion.url else {
                return nil
            }
            return ProactiveSuggestion(text: suggestionText, app: suggestionApp, url: suggestionURL)
        } catch is CancellationError {
            return nil  // a superseded/disabled request — expected, stay quiet
        } catch let error as URLError where error.code == .cancelled {
            return nil  // URLSession's cancellation flavor — also expected
        } catch {
            // Genuine failure (timeout, connection refused, malformed response).
            // This polls on a dwell timer, so log sparingly, not every tick.
            print("⚠️ Proactive intents fetch failed: \(error)")
            return nil
        }
    }

    // MARK: - Decoding

    /// Matches the proxy's `{"suggestion": null | {...}, "reason": "..."}` shape.
    private struct SuggestionEnvelope: Decodable {
        let suggestion: RawSuggestion?
    }

    private struct RawSuggestion: Decodable {
        let text: String?
        let app: String?
        let url: String?
    }
}
