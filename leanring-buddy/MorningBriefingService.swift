//
//  MorningBriefingService.swift
//  leanring-buddy
//
//  Thin async client for the proxy's /briefing/morning route — the backend
//  scrapes world/markets/AI headlines and returns a spoken-ready digest. Mirrors
//  ProactiveIntentsService's fail-soft shape: returns nil on any failure instead
//  of throwing, never blocks the main thread. Owned by MorningBriefingManager.
//

import Foundation

/// Thin async client for the proxy's `/briefing/morning` route. POSTs an empty
/// body and expects `{"text": ..., "sources": [...], "generated_at": ...}`.
/// Returns the `text` to be spoken, or nil on any failure. Never throws.
@MainActor
final class MorningBriefingService {
    /// Base URL of the local brain proxy, e.g. "http://127.0.0.1:8787".
    private let proxyBaseURL: String
    private let urlSession: URLSession

    init(proxyBaseURL: String, urlSession: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.urlSession = urlSession
    }

    /// Fetches this morning's briefing text. Returns nil on any failure (bad
    /// URL, network error, timeout, non-2xx, malformed JSON, or empty text) —
    /// the caller simply stays silent in that case. The scrape + summary can
    /// take several seconds, so the timeout is generous; this only ever runs
    /// from the background morning trigger, never in front of a waiting user.
    func fetchMorningBriefing() async -> String? {
        guard let requestURL = URL(string: "\(proxyBaseURL)/briefing/morning") else { return nil }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = Data("{}".utf8)

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            guard let envelope = try? JSONDecoder().decode(BriefingEnvelope.self, from: responseData) else {
                print("⚠️ Morning briefing: malformed response")
                return nil
            }
            let text = envelope.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            print("⚠️ Morning briefing fetch failed: \(error)")
            return nil
        }
    }

    // MARK: - Decoding

    /// Matches the proxy's `{"text": ..., "sources": [...], "generated_at": ...}`.
    private struct BriefingEnvelope: Decodable {
        let text: String
    }
}
