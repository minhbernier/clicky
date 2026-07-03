//
//  ProactiveManager.swift
//  leanring-buddy
//
//  Drives the proactive-suggestion HUD end to end: watches which app has been
//  frontmost, waits for a dwell period of continuous focus, asks the proxy's
//  /proactive-intents route whether it wants to say something, and — if so —
//  presents the same kind of floating, non-activating NSPanel bubble that
//  ConnectorRecommendationManager uses for its "Connect X to Micky" popup.
//
//  OFF BY DEFAULT. Nothing in this class runs — no observer is registered, no
//  timer is scheduled, no network call is made — unless the user explicitly
//  flips the "Proactive suggestions" toggle in CompanionPanelView, which calls
//  start(). The server side is also off by default and owns its own
//  throttle/cooldown/daily caps, so this class does not attempt any additional
//  client-side rate limiting beyond the dwell gate itself.
//
//  Dwell logic: rather than polling the frontmost app on a fast repeating
//  timer, this listens for NSWorkspace.didActivateApplicationNotification
//  (fired immediately whenever the frontmost app changes) and, on each *real*
//  change (different bundle identifier — duplicate activation notifications
//  for the same app are ignored), cancels and reschedules a single one-shot
//  dwellInterval-second timer. If nothing interrupts it, that timer firing
//  means the same app has been frontmost, continuously, for the whole
//  interval — exactly the "dwell" condition. After a fire, the timer is
//  rescheduled for another interval (rather than stopping) so a suggestion
//  can still surface later in a long session on the same app; the server's
//  own cooldown/caps are what actually decide whether that later check
//  produces anything.
//

import AppKit
import SwiftUI

@MainActor
final class ProactiveManager: NSObject {
    /// UserDefaults key backing `isEnabled`. Shared with CompanionManager's
    /// published `isProactiveEnabled` mirror — both read/write the same key,
    /// but only start()/stop() below actually drive the timer.
    static let userDefaultsKey = "isProactiveEnabled"

    private let intentsService: ProactiveIntentsService

    /// Delivers a suggestion's text as a follow-up when the user taps
    /// "Act on it". Injected by CompanionManager as
    /// `{ self.sendFollowUpText($0, toAgentTaskID: nil) }` — a nil
    /// agentTaskID routes to the main chat path rather than any specific
    /// agent task, since a proactive nudge isn't scoped to an existing task.
    private let sendToMainChat: (String) -> Void

    /// How long the same frontmost app must stay focused, uninterrupted,
    /// before triggering a check. Reset whenever the frontmost app changes.
    private let dwellInterval: TimeInterval

    /// Backed by UserDefaults (key: "isProactiveEnabled"), default FALSE.
    /// This is the source of truth start()/stop() use to decide whether the
    /// dwell timer should be running; it is never flipped to true except by
    /// an explicit call to start() (which only happens from the user's own
    /// toggle, or on app launch resuming a previously-enabled session).
    private(set) var isEnabled: Bool

    /// The single-shot dwell timer. Non-nil only while running.
    private var dwellTimer: Timer?

    /// Bundle identifier of the app the dwell timer is currently timing, so a
    /// genuine change in frontmost app (vs. a spurious duplicate activation
    /// notification for the same app) can be detected and the clock reset.
    private var dwellingBundleIdentifier: String?

    /// The in-flight /proactive-intents request, if any. Cancelled before
    /// starting a new one so an old, slow response can't land after a newer
    /// dwell fire and show stale info.
    private var currentIntentTask: Task<Void, Never>?

    private var panel: NSPanel?
    private let panelWidth: CGFloat = 360
    private let topMargin: CGFloat = 24

    init(
        proxyBaseURL: String,
        sendToMainChat: @escaping (String) -> Void,
        dwellInterval: TimeInterval = 20
    ) {
        self.intentsService = ProactiveIntentsService(proxyBaseURL: proxyBaseURL)
        self.sendToMainChat = sendToMainChat
        self.dwellInterval = dwellInterval
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
        super.init()
    }

    deinit {
        dwellTimer?.invalidate()
        // Defensive: in practice this manager is a lazy var CompanionManager
        // holds for the app's entire lifetime, so this rarely runs — but the
        // old-style addObserver(self:...) API keeps a strong reference to
        // self until removed, so this guards against a leaked observer if
        // that ever changes.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Start / Stop

    /// Enables the feature (persists it) and starts the dwell timer if it
    /// isn't already running. Safe to call repeatedly.
    func start() {
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)

        guard dwellTimer == nil else { return }

        // Seed with whatever is frontmost right now so the first dwell
        // period starts counting from "now," not from some future switch.
        dwellingBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        scheduleDwellTimer()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    /// Disables the feature (persists it), stops the dwell timer, cancels any
    /// in-flight request, and hides any bubble currently on screen.
    func stop() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.userDefaultsKey)

        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwellingBundleIdentifier = nil
        currentIntentTask?.cancel()
        currentIntentTask = nil
        hideBubble()
    }

    // MARK: - Dwell tracking

    /// Fires on every frontmost-app change, including ones unrelated to a
    /// dwell in progress. Only a genuine change (different bundle
    /// identifier) resets the clock — this guards against macOS sometimes
    /// re-posting activation for the app that's already frontmost.
    @objc private func frontmostAppDidChange(_ notification: Notification) {
        guard isEnabled else { return }
        let newBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard newBundleIdentifier != dwellingBundleIdentifier else { return }
        dwellingBundleIdentifier = newBundleIdentifier
        dwellTimer?.invalidate()
        scheduleDwellTimer()
    }

    private func scheduleDwellTimer() {
        // Invalidate any existing timer before replacing it. Without this, a fire
        // whose @MainActor Task is still queued when an app switch reschedules
        // could orphan the freshly-scheduled timer (unreachable via self.dwellTimer,
        // so stop() can't invalidate it) and leave it running independently.
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: dwellInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dwellFired()
            }
        }
    }

    /// Called once the dwell interval has elapsed without an intervening app
    /// switch. Re-verifies the frontmost app still matches what we've been
    /// timing (in case an activation notification was somehow missed) before
    /// asking the proxy for a suggestion, then reschedules for another
    /// interval so a long session on the same app can still surface a later
    /// suggestion — the server's own cooldown/caps decide if that happens.
    private func dwellFired() {
        guard isEnabled else { return }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let appName = frontmostApp.localizedName else {
            scheduleDwellTimer()
            return
        }
        guard frontmostApp.bundleIdentifier == dwellingBundleIdentifier else {
            // Missed activation notification — resync instead of firing on
            // stale info, and start a fresh dwell period for the app that's
            // actually frontmost now.
            dwellingBundleIdentifier = frontmostApp.bundleIdentifier
            scheduleDwellTimer()
            return
        }

        checkForSuggestion(appName: appName)
        scheduleDwellTimer()
    }

    /// Asks the proxy for a suggestion for the given app. v1 sends the app
    /// name only — no URL or window title. A window title would need the
    /// Accessibility API, which risks either a blocking round-trip to another
    /// app's process or (if permission were ever revoked) a permission
    /// prompt; neither is acceptable for a background sampling call, so it's
    /// deliberately omitted rather than attempted. `url` is sent as an empty
    /// string per the endpoint's contract; `title` is omitted entirely.
    private func checkForSuggestion(appName: String) {
        currentIntentTask?.cancel()
        currentIntentTask = Task { [weak self] in
            guard let self else { return }
            guard let suggestion = await self.intentsService.suggestion(forApp: appName, url: "", title: nil) else {
                return
            }
            guard !Task.isCancelled, self.isEnabled else { return }
            self.showBubble(for: suggestion)
        }
    }

    // MARK: - Panel lifecycle
    // Mirrors ConnectorRecommendationManager's NSPanel pattern exactly: a
    // borderless, non-activating panel floated near top-center, recreated
    // each time so it always sizes to the current card.

    private func showBubble(for suggestion: ProactiveSuggestion) {
        let suggestionView = ProactiveSuggestionView(
            suggestion: suggestion,
            onDismiss: { [weak self] in
                self?.hideBubble()
            },
            onActOnIt: { [weak self] in
                guard let self else { return }
                self.sendToMainChat(suggestion.text)
                self.hideBubble()
            }
        )

        let hostingView = NSHostingView(rootView: suggestionView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        // Only one bubble at a time — a new suggestion replaces the old.
        hideBubble()

        let suggestionPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        suggestionPanel.isFloatingPanel = true
        suggestionPanel.level = .floating
        suggestionPanel.isOpaque = false
        suggestionPanel.backgroundColor = .clear
        suggestionPanel.hasShadow = false
        suggestionPanel.hidesOnDeactivate = false
        suggestionPanel.isExcludedFromWindowsMenu = true
        suggestionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        suggestionPanel.isMovableByWindowBackground = false
        suggestionPanel.titleVisibility = .hidden
        suggestionPanel.titlebarAppearsTransparent = true
        suggestionPanel.contentView = hostingView

        panel = suggestionPanel
        positionPanelTopCenter()
        suggestionPanel.orderFrontRegardless()
    }

    private func hideBubble() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Pin the bubble to the top-center of the screen under the mouse (where
    /// the user is working), falling back to the main screen.
    private func positionPanelTopCenter() {
        guard let panel else { return }

        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let activeScreen else { return }

        let visibleFrame = activeScreen.visibleFrame
        let fittingHeight = panel.contentView?.fittingSize.height ?? 120

        let panelOriginX = visibleFrame.minX + (visibleFrame.width - panelWidth) / 2.0
        let panelOriginY = visibleFrame.maxY - fittingHeight - topMargin

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: fittingHeight),
            display: true
        )
    }
}
