//
//  IntegrationsService.swift
//  leanring-buddy
//
//  Thin async client for the proxy's connector-catalog routes that power the
//  Integrations tab. Mirrors AgentArtifactsService/ProactiveIntentsService's
//  fail-soft shape exactly: every call returns an empty array/nil instead of
//  throwing, so a down proxy (or a mid-flight network hiccup) can never crash
//  the tab or block the voice pipeline — it just means the tab shows a Retry
//  row instead of quietly hanging. Owned by CompanionManager, wrapped by
//  IntegrationsStore.
//
//  Three routes, three jobs:
//    GET  /connectors         — the curated seed + everything the user has
//                               actually connected (listConnectors)
//    GET  /connectors/search  — Composio's full 500+ app catalog, filtered by
//                               query (search)
//    POST /connect            — starts the OAuth flow for one toolkit slug
//                               and returns the browser redirect URL (connect)
//

import Foundation

@MainActor
final class IntegrationsService {
    /// Base URL of the local brain proxy, e.g. "http://127.0.0.1:8787".
    private let proxyBaseURL: String
    private let urlSession: URLSession

    init(proxyBaseURL: String, urlSession: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.urlSession = urlSession
    }

    // MARK: - GET /connectors

    /// Fetches the curated seed apps plus every app the user has actually
    /// connected. Returns an empty array on any failure — bad URL, network
    /// error, timeout, non-2xx, or malformed JSON — so the caller never has
    /// to special-case a failed fetch; IntegrationsStore treats an empty
    /// result as "proxy unreachable" and shows the Retry row.
    func listConnectors() async -> [Integration] {
        guard let requestURL = URL(string: "\(proxyBaseURL)/connectors") else { return [] }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        // Short timeout — this fires when the user opens the tab (or the app
        // comes to the foreground), not something worth making them wait on.
        request.timeoutInterval = 5

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }
            guard let envelope = try? JSONDecoder().decode(ConnectorsEnvelope.self, from: responseData) else {
                return []
            }
            // Tolerant mapping, same reasoning as AgentArtifactsService: an
            // entry missing a required field (slug/name/a recognized status)
            // can't be rendered as a row, so it's skipped individually rather
            // than dropping the whole catalog.
            return (envelope.connectors ?? []).compactMap { rawConnector in
                guard let slug = rawConnector.slug,
                      let name = rawConnector.name,
                      let rawStatus = rawConnector.status,
                      let status = IntegrationStatus(rawValue: rawStatus) else {
                    return nil
                }
                return Integration(
                    slug: slug,
                    name: name,
                    tagline: rawConnector.tagline ?? "",
                    chips: rawConnector.chips ?? [],
                    status: status
                )
            }
        } catch {
            print("⚠️ Integrations: /connectors fetch failed: \(error)")
            return []
        }
    }

    // MARK: - GET /connectors/search

    /// Searches Composio's full app catalog by query. Returns an empty array
    /// for a blank query (mirrors the proxy's own "empty q → empty results"
    /// behavior) and on any failure — including the request being cancelled
    /// by IntegrationsStore's debounce, which is expected and not logged.
    func search(_ query: String) async -> [IntegrationSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        guard var urlComponents = URLComponents(string: "\(proxyBaseURL)/connectors/search") else { return [] }
        urlComponents.queryItems = [
            URLQueryItem(name: "q", value: trimmedQuery),
            URLQueryItem(name: "limit", value: "20"),
        ]
        guard let requestURL = urlComponents.url else { return [] }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }
            guard let envelope = try? JSONDecoder().decode(SearchEnvelope.self, from: responseData) else {
                return []
            }
            return (envelope.results ?? []).compactMap { rawResult in
                guard let slug = rawResult.slug, let name = rawResult.name else { return nil }
                return IntegrationSearchResult(slug: slug, name: name, description: rawResult.description ?? "")
            }
        } catch is CancellationError {
            return []  // superseded by a newer keystroke's search — expected, stay quiet
        } catch let error as URLError where error.code == .cancelled {
            return []  // URLSession's cancellation flavor — also expected
        } catch {
            print("⚠️ Integrations: /connectors/search fetch failed: \(error)")
            return []
        }
    }

    // MARK: - POST /connect

    /// Starts the OAuth flow for one toolkit slug and returns the Composio
    /// redirect URL to open in the browser. Returns nil on error (400 invalid
    /// slug, 404 unknown app, 502 Composio error, or a network failure) — the
    /// caller can't distinguish these cases and shouldn't need to; either way
    /// there's nothing to open.
    func connect(slug: String) async -> URL? {
        guard let requestURL = URL(string: "\(proxyBaseURL)/connect") else { return nil }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["toolkit": slug])

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard (200...299).contains(httpResponse.statusCode) else {
                // Genuine failure — log the proxy's own error message when
                // present (400/404/502 all return {"error": ...}) so a bad
                // connect attempt is diagnosable from the console.
                let errorMessage = (try? JSONDecoder().decode(ConnectErrorEnvelope.self, from: responseData))?.error
                print("⚠️ Integrations: /connect failed for \(slug) (\(httpResponse.statusCode))\(errorMessage.map { ": \($0)" } ?? "")")
                return nil
            }
            guard let envelope = try? JSONDecoder().decode(ConnectEnvelope.self, from: responseData),
                  let redirectURLString = envelope.redirect_url,
                  let redirectURL = URL(string: redirectURLString) else {
                return nil
            }
            return redirectURL
        } catch {
            print("⚠️ Integrations: /connect request failed for \(slug): \(error)")
            return nil
        }
    }

    // MARK: - Decoding

    /// Matches the proxy's `{"connectors": [...], "user_id": "..."}` shape.
    private struct ConnectorsEnvelope: Decodable {
        let connectors: [RawConnector]?
    }

    private struct RawConnector: Decodable {
        let slug: String?
        let name: String?
        let tagline: String?
        let chips: [String]?
        let status: String?
    }

    /// Matches the proxy's `{"query": "...", "results": [...]}` shape.
    private struct SearchEnvelope: Decodable {
        let results: [RawSearchResult]?
    }

    private struct RawSearchResult: Decodable {
        let slug: String?
        let name: String?
        let description: String?
    }

    /// Matches the proxy's `{"toolkit": "...", "redirect_url": "..."}` shape.
    private struct ConnectEnvelope: Decodable {
        let redirect_url: String?
    }

    /// Matches the proxy's `{"error": "..."}` error shape (400/404/502).
    private struct ConnectErrorEnvelope: Decodable {
        let error: String?
    }
}
