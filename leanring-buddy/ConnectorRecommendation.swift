//
//  ConnectorRecommendation.swift
//  leanring-buddy
//
//  Model + networking for the connector-recommendation popup — Micky's version
//  of the HeyClicky "Connect Discord to …" card. When the user mentions an app
//  they haven't connected yet (e.g. "check my Discord profile"), the brain proxy
//  surfaces a recommendation and Micky offers to connect it via Composio.
//
//  The actual app tools (reading Discord, Gmail, etc.) run inside the proxy's
//  power/agent sessions through the user-scope Composio MCP. This layer is ONLY
//  the connect/recommend UX: it talks to the proxy's /connector-suggestion and
//  /connect routes, which front Composio's REST API.
//

import AppKit
import SwiftUI

/// One recommendable app as described by the proxy's connector catalog. Decoded
/// straight from the `/connector-suggestion` and `/connectors` JSON.
struct ConnectorRecommendation: Codable, Identifiable, Equatable {
    /// Composio toolkit slug, e.g. "discord". Also the stable identity.
    let slug: String
    /// Display name shown in the popup title, e.g. "Discord".
    let name: String
    /// Lead-in line above the sample actions, e.g. "Use Micky to:".
    let tagline: String
    /// The sample actions shown as chips, e.g. "Fetch my Discord profile information".
    let chips: [String]
    /// Live connection status: "active" | "initializing" | "disconnected".
    let status: String
    /// Convenience flag mirrored from the proxy (status == "active").
    let connected: Bool

    var id: String { slug }

    /// SF Symbol used as the app's icon in the popup. Micky has no bundled brand
    /// logos, so each connector maps to a representative system symbol — the same
    /// convention the menu-bar "Integrations" row already uses.
    var iconSystemName: String {
        switch slug {
        case "discord": return "bubble.left.and.bubble.right.fill"
        case "gmail": return "envelope.fill"
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "notion": return "note.text"
        case "slack": return "number.square.fill"
        default: return "app.connected.to.app.below.fill"
        }
    }

    /// Brand-ish accent for the app's icon tile so each connector reads distinctly.
    var brandColor: Color {
        switch slug {
        case "discord": return Color(red: 0.345, green: 0.396, blue: 0.949)   // Discord blurple
        case "gmail": return Color(red: 0.917, green: 0.262, blue: 0.207)      // Gmail red
        case "github": return Color(red: 0.90, green: 0.91, blue: 0.93)        // GitHub near-white
        case "notion": return Color(red: 0.90, green: 0.90, blue: 0.88)        // Notion off-white
        case "slack": return Color(red: 0.36, green: 0.20, blue: 0.55)         // Slack aubergine
        default: return DS.Colors.accent
        }
    }
}

/// Thin async client for the proxy's connector routes. Owned by CompanionManager.
/// Every call fails soft (returns nil / does nothing on error) because a
/// recommendation is never allowed to block or break the voice pipeline.
@MainActor
final class ConnectorRecommendationService {
    /// Base URL of the local brain proxy, e.g. "http://127.0.0.1:8787".
    private let proxyBaseURL: String
    private let urlSession: URLSession

    init(proxyBaseURL: String, urlSession: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.urlSession = urlSession
    }

    /// Ask the proxy whether this utterance should trigger a connector
    /// recommendation. Returns nil when there's nothing to suggest (the common
    /// case) or on any error.
    func recommendation(forUtterance utterance: String) async -> ConnectorRecommendation? {
        guard let requestURL = URL(string: "\(proxyBaseURL)/connector-suggestion") else { return nil }
        let requestBody = ["text": utterance]
        guard let responseData = await postJSON(to: requestURL, body: requestBody) else { return nil }

        struct SuggestionEnvelope: Codable { let suggestion: ConnectorRecommendation? }
        return try? JSONDecoder().decode(SuggestionEnvelope.self, from: responseData).suggestion
    }

    /// Begin an OAuth connection for the given toolkit and return the Composio
    /// redirect URL the user should open in their browser. Returns nil on error.
    func connectionURL(forToolkitSlug toolkitSlug: String) async -> URL? {
        guard let requestURL = URL(string: "\(proxyBaseURL)/connect") else { return nil }
        let requestBody = ["toolkit": toolkitSlug]
        guard let responseData = await postJSON(to: requestURL, body: requestBody) else { return nil }

        struct ConnectEnvelope: Codable { let redirect_url: String? }
        guard
            let redirectURLString = try? JSONDecoder().decode(ConnectEnvelope.self, from: responseData).redirect_url,
            let redirectURL = URL(string: redirectURLString)
        else { return nil }
        return redirectURL
    }

    /// Permanently stop recommending this toolkit for the life of the proxy
    /// process (the user tapped "No"). Fire-and-forget.
    func suppressRecommendations(forToolkitSlug toolkitSlug: String) async {
        guard let requestURL = URL(string: "\(proxyBaseURL)/connect") else { return }
        _ = await postJSON(to: requestURL, body: ["toolkit": toolkitSlug, "dismiss": true])
    }

    // MARK: - Networking helper

    /// POST a small JSON body and return the raw response data, or nil on any
    /// failure (bad URL, network error, non-2xx). Never throws.
    private func postJSON(to requestURL: URL, body: [String: Any]) async -> Data? {
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                return nil
            }
            return responseData
        } catch {
            return nil
        }
    }
}
