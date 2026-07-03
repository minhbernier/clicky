//
//  ProactiveSuggestion.swift
//  leanring-buddy
//
//  Model for the proactive-suggestion HUD — a small bubble Micky surfaces when
//  the brain proxy's own throttle/cooldown/daily-cap logic decides the user
//  might want a nudge for whatever app they've been sitting in. Constructed
//  only when the proxy's /proactive-intents route actually returns a non-null
//  `suggestion` — see ProactiveIntentsService for the request/response shape
//  and ProactiveManager for the dwell timer that triggers the request.
//

import Foundation

/// One suggestion the proxy decided to surface right now, e.g. "Want me to
/// draft a reply to that email?" There is at most one of these live at a
/// time — a fresh suggestion replaces whatever bubble is already showing.
struct ProactiveSuggestion: Identifiable, Equatable {
    let id = UUID()
    /// The suggestion text shown in the bubble and, if the user taps
    /// "Act on it", sent verbatim as a follow-up to the main chat.
    let text: String
    /// The app the proxy generated this suggestion for. Not rendered in the
    /// bubble today — kept for logging/debugging and future use.
    let app: String
    /// A URL the proxy associated with the suggestion, if any. Not acted on
    /// by the v1 bubble (no "open" action), but decoded for future use.
    let url: String
}
