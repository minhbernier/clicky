//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// Centralized store of agent tasks shown in the right-side task panel and
    /// the Agents tab. Lives here so task state is shared across all panels.
    let agentTaskStore = AgentTaskStore()

    /// True while a voice follow-up dictation session (started from a tab button,
    /// not the hardware shortcut) is recording. Drives the Voice button's UI.
    /// Also true while hands-free conversation mode has auto-reopened the mic
    /// for the user's next spoken turn — see isHandsFreeAutoListening below for
    /// how that specific case is distinguished from a manual tab-button start.
    @Published private(set) var isRecordingVoiceFollowUp = false

    /// True only when the CURRENT isRecordingVoiceFollowUp session was opened
    /// automatically by hands-free conversation mode's re-arm (as opposed to a
    /// manual tap on a task card's Voice button). Lets setHandsFreeEnabled(false)
    /// tell the difference: disabling hands-free mid-listen should stop an
    /// auto-opened mic immediately, but must never stop a session the user
    /// started manually. Always toggles together with isRecordingVoiceFollowUp
    /// via endVoiceListeningSession(), so it never goes stale.
    private var isHandsFreeAutoListening = false

    /// The agent task whose turn is currently in flight, if any. Used so a turn
    /// that gets superseded (cancelled) by a newer, unrelated request can settle
    /// its card out of the spinning .running state instead of stranding it.
    private var currentInFlightAgentTaskID: UUID?

    /// A typed follow-up the user sent while a turn was still in flight. Text
    /// follow-ups queue behind the current turn — the agent finishes what it's
    /// saying first — instead of cutting it off. (Voice interrupts; text waits.)
    private struct QueuedFollowUpMessage {
        let text: String
        let agentTaskID: UUID?
        /// True when the user's message was already shown in its task transcript
        /// at enqueue time, so the send path doesn't record it a second time.
        let isAlreadyRecordedInTranscript: Bool
    }

    /// Typed follow-ups waiting their turn, oldest first. Drained one at a time
    /// whenever the response pipeline goes idle.
    private var queuedFollowUpMessages: [QueuedFollowUpMessage] = []

    /// True while the response pipeline is actively working — recording or
    /// processing a voice request, generating a reply, or speaking one aloud.
    /// Typed follow-ups queue behind this instead of interrupting it. A cancelled
    /// (superseded) response task does not count as busy, so a barge-in that
    /// cancels without starting a new turn can't strand the queue.
    private var isResponsePipelineBusy: Bool {
        if let currentResponseTask, !currentResponseTask.isCancelled {
            return true
        }
        return isRecordingVoiceFollowUp || voiceState != .idle || textToSpeechClient.isPlaying
    }

    /// Forwards the agent task store's changes to this manager's observers.
    /// SwiftUI views (the menu bar Agents tab and the right-side task panel)
    /// observe CompanionManager, but the tasks live in the nested
    /// `agentTaskStore` ObservableObject — without re-broadcasting its changes
    /// here, those views would not re-render when a task's status or transcript
    /// updates.
    private var agentTaskStoreChangeCancellable: AnyCancellable?

    /// Forwards the Integrations store's changes the same way
    /// agentTaskStoreChangeCancellable does above — IntegrationsTabView
    /// observes it directly as its own @ObservedObject, but this keeps
    /// CompanionManager itself a complete source of truth for anything else
    /// that reads `integrationsStore` off of it.
    private var integrationsStoreChangeCancellable: AnyCancellable?

    init() {
        agentTaskStoreChangeCancellable = agentTaskStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        integrationsStoreChangeCancellable = integrationsStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the brain proxy. Points at the local clicky-max-proxy
    /// (~/Developer/clicky-max-proxy) so /chat runs on a Claude Max subscription
    /// with no API key. LOCAL-ONLY: do not ship or PR this — the upstream value
    /// is the Cloudflare Worker URL.
    private static let workerBaseURL = "http://127.0.0.1:8787"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    /// Talks to the proxy's connector routes to recommend and connect apps (via
    /// Composio). Surfaces the "Connect Discord to Micky" style popup.
    private lazy var connectorRecommendationService: ConnectorRecommendationService = {
        return ConnectorRecommendationService(proxyBaseURL: Self.workerBaseURL)
    }()

    /// Fetches artifacts (a diff, a screenshot, a saved doc) the proxy recorded
    /// for an agent task's latest turn, so the task card can render them as
    /// clickable chips. See AgentArtifactsService for details.
    private lazy var agentArtifactsService: AgentArtifactsService = {
        return AgentArtifactsService(proxyBaseURL: Self.workerBaseURL)
    }()

    /// Centralized store for the Integrations tab: the connected/
    /// initializing/available catalog partitioning, debounced app search, and
    /// the connect→browser→refresh flow. Lives here (like agentTaskStore
    /// above) so the tab's state survives every open/close of the panel, not
    /// just while the tab happens to be selected. Nothing here talks to the
    /// proxy until the tab is opened once — see IntegrationsStore.onTabAppear.
    let integrationsStore: IntegrationsStore = IntegrationsStore(
        service: IntegrationsService(proxyBaseURL: CompanionManager.workerBaseURL)
    )

    /// Drives the proactive-suggestion HUD: a dwell timer that watches the
    /// frontmost app and, once enabled, asks the proxy's /proactive-intents
    /// route whether to surface a small suggestion bubble. Off by default and
    /// never auto-started — see isProactiveEnabled / setProactiveEnabled.
    private lazy var proactiveManager: ProactiveManager = {
        return ProactiveManager(
            proxyBaseURL: Self.workerBaseURL,
            sendToMainChat: { [weak self] text in
                // nil agentTaskID routes to the main chat path (see
                // sendFollowUpText) rather than any specific agent task — an
                // "Act on it" nudge isn't scoped to an existing task thread.
                self?.sendFollowUpText(text, toAgentTaskID: nil)
            }
        )
    }()

    /// In-flight artifact fetches keyed by agent task id. Two turns of the same
    /// task can settle close together (e.g. a confirmation reply immediately
    /// followed by the completion reply), each kicking off its own fetch; without
    /// tracking these, the two requests could land out of order and let a stale
    /// response overwrite a newer one. `fetchArtifactsAndAttach` cancels whatever
    /// is already tracked for a task id before starting a new fetch for it.
    private var artifactFetchTasksByAgentTaskID: [UUID: Task<Void, Never>] = [:]

    /// The connector recommendation to surface right now, if any.
    /// ConnectorRecommendationManager observes this to show/hide the popup.
    @Published private(set) var pendingConnectorRecommendation: ConnectorRecommendation?

    /// Toolkits already shown this app session ("Not now" or already surfaced) so
    /// we don't re-pop the same card on every later utterance. A permanent "No"
    /// is recorded server-side; this set is just the in-app nag-suppression.
    private var connectorSlugsAlreadySurfacedThisSession: Set<String> = []

    /// The active text-to-speech client. Defaults to ElevenLabs (cloud); can be
    /// switched to on-device system speech via the `VoiceTTSProvider` Info.plist key.
    private lazy var textToSpeechClient: any BuddyTextToSpeechClient = {
        return BuddyTextToSpeechClientFactory.makeDefaultClient(
            elevenLabsProxyURL: "\(Self.workerBaseURL)/tts"
        )
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    /// Delayed re-arm of the mic for hands-free conversation mode, scheduled
    /// from the reply-settle block in sendTranscriptToClaudeWithScreenshot.
    /// Cancellable so a new turn, a manual voice/push-to-talk start, or the
    /// user disabling hands-free can all stop it before it ever opens the mic.
    /// See scheduleHandsFreeRearmIfNeeded() for every guard checked before it fires.
    private var handsFreeRearmTask: Task<Void, Never>?

    /// Voice-activity monitor for an in-progress hands-free auto-listen turn.
    /// The dictation pipeline itself is hold-to-talk with no end-of-speech
    /// detection — nothing else ever calls stop for an auto-opened mic — so
    /// this polls currentAudioPowerLevel (~every 100ms, Task.sleep-based, not
    /// a busy-wait) to detect when the user has finished talking and finalize
    /// the turn. Only ever started for an auto-listen (isHandsFreeAutoListen
    /// == true); manual push-to-talk and the Voice button rely on their own
    /// explicit stop and never have a monitor task running. See
    /// startHandsFreeListenMonitor() for the full detection + timeout logic.
    /// Cancelled and nil'd at every teardown point — endVoiceListeningSession(),
    /// setHandsFreeEnabled(false), cancelInFlightResponseForBargeIn(), stop(),
    /// and the top of scheduleHandsFreeRearmIfNeeded() — mirroring how
    /// handsFreeRearmTask above is managed.
    private var handsFreeListenMonitorTask: Task<Void, Never>?

    /// Count of consecutive hands-free auto-listen turns that ended with no
    /// real speech: either total silence (the monitor's no-speech/max-listen
    /// backstop) or a transcript too short to plausibly be real ("you",
    /// "thank you" — common STT hallucinations on near-silent audio). Without
    /// this, a silent/hallucinated turn would still submit, get a reply, and
    /// re-arm the mic — looping forever on background noise. Consulted by
    /// scheduleHandsFreeRearmIfNeeded, which suspends auto re-arming once this
    /// reaches handsFreeMaxConsecutiveSilentTurns. Reset to 0 by any real
    /// hands-free turn that submits, or by any manual push-to-talk /
    /// Voice-button turn — see resetHandsFreeSilentTurnCounter().
    private var handsFreeConsecutiveSilentTurns = 0

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User-selectable accent color for the blue cursor companion. `.blue` maps
    /// to the original overlay color so the default look is unchanged. Persisted
    /// so the choice survives restarts; the overlay reads `cursorColor` directly.
    enum CursorColorChoice: String, CaseIterable, Identifiable {
        case blue
        case red
        case yellow
        case green

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .blue: return DS.Colors.overlayCursorBlue
            case .red: return DS.Colors.destructiveText
            case .yellow: return DS.Colors.warning
            case .green: return DS.Colors.success
            }
        }
    }

    @Published var cursorColorChoice: CursorColorChoice =
        CursorColorChoice(rawValue: UserDefaults.standard.string(forKey: "cursorColorChoice") ?? "") ?? .blue

    /// The resolved cursor color the overlay renders with.
    var cursorColor: Color { cursorColorChoice.color }

    func setCursorColorChoice(_ choice: CursorColorChoice) {
        cursorColorChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "cursorColorChoice")
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// User preference for whether Micky should occasionally surface a
    /// proactive suggestion based on which app has been focused for a while.
    /// OFF by default (opt-in, unlike the cursor toggle) — persisted so the
    /// choice survives app restarts. `UserDefaults.bool(forKey:)` already
    /// returns false when the key has never been set, so no extra
    /// "was this ever set" check is needed here (contrast isClickyCursorEnabled
    /// above, which defaults to true and does need one).
    @Published var isProactiveEnabled: Bool = UserDefaults.standard.bool(forKey: "isProactiveEnabled")

    /// Mirrors setClickyCursorEnabled's shape exactly: update the published
    /// flag, persist it, then start/stop the underlying subsystem — here,
    /// ProactiveManager's dwell timer and any bubble it has on screen.
    /// ProactiveManager.start()/stop() also persist this same UserDefaults key
    /// themselves (so the class is correct even if ever driven directly), so
    /// this write is a harmless, idempotent duplicate.
    func setProactiveEnabled(_ enabled: Bool) {
        isProactiveEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isProactiveEnabled")
        if enabled {
            proactiveManager.start()
        } else {
            proactiveManager.stop()
        }
    }

    /// User preference for whether Micky should automatically reopen the mic
    /// for the user's next spoken turn right after finishing a reply, so a
    /// conversation can flow without holding push-to-talk for every turn. OFF
    /// by default (opt-in) — persisted so the choice survives app restarts.
    /// `UserDefaults.bool(forKey:)` already returns false when the key has
    /// never been set, so no extra "was this ever set" check is needed here
    /// (same reasoning as isProactiveEnabled above).
    ///
    /// IMPORTANT — this is continuous TURN-TAKING, not full duplex. The mic is
    /// only ever reopened once TTS playback has completely finished (see the
    /// settle block in sendTranscriptToClaudeWithScreenshot and
    /// scheduleHandsFreeRearmIfNeeded below); Micky never listens while it is
    /// speaking, so it can never hear its own voice.
    @Published var isHandsFreeEnabled: Bool = UserDefaults.standard.bool(forKey: "isHandsFreeConversationEnabled")

    /// Whether the current hands-free conversation should keep re-opening the
    /// mic. This is intentionally separate from the persisted feature toggle:
    /// saying an explicit end phrase stops the current conversation without
    /// turning the feature off. The next manual voice turn starts a fresh
    /// conversation automatically.
    @Published private(set) var isHandsFreeSessionActive = false

    /// Mirrors setClickyCursorEnabled's shape exactly: update the published
    /// flag, then persist it. Disabling mid-conversation additionally cancels
    /// any pending re-arm (so it can never fire after this) and, if hands-free
    /// had already opened the mic for this turn and is sitting there listening,
    /// stops that listening immediately — the user just asked to stop the
    /// automatic behavior, so it shouldn't keep going for the turn already in
    /// progress. A manually-started voice follow-up (tab button) is left alone,
    /// since isHandsFreeAutoListening is only true for hands-free's own re-arm.
    ///
    /// Stopping an open auto-listen here DISCARDS whatever was captured so far
    /// (cancelCurrentDictation) rather than finalizing+submitting it — the user
    /// is turning the feature off, not asking for one more reply, so disabling
    /// must not trigger a surprise extra turn. This is deliberately different
    /// from toggleVoiceFollowUp's own manual toggle-off, which still finalizes
    /// + submits via stopPushToTalkFromKeyboardShortcut() because there the user
    /// explicitly asked to end that turn, not discard it.
    func setHandsFreeEnabled(_ enabled: Bool) {
        isHandsFreeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isHandsFreeConversationEnabled")
        if enabled {
            // Enabling makes hands-free available, but a manual voice turn is
            // what starts a conversation. This prevents a stale reply or task
            // from opening the mic merely because the preference was toggled.
            isHandsFreeSessionActive = false
            return
        }

        isHandsFreeSessionActive = false
        handsFreeRearmTask?.cancel()
        handsFreeRearmTask = nil
        handsFreeListenMonitorTask?.cancel()
        handsFreeListenMonitorTask = nil

        if isHandsFreeAutoListening {
            buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
            endVoiceListeningSession()
        }
    }

    /// Whether the upstream Farza intro video + theme music play during
    /// onboarding. This fork (Micky) disables them by default so onboarding is
    /// effectively skipped — the cursor just appears. Set the Info.plist key
    /// "FarzaOnboardingEnabled" to YES to restore the original experience.
    var isFarzaOnboardingEnabled: Bool {
        guard let rawValue = AppBundleConfiguration.stringValue(forKey: "FarzaOnboardingEnabled")?.lowercased() else {
            return false
        }
        return rawValue == "yes" || rawValue == "true" || rawValue == "1"
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        // Ask for everything we need up front, the moment the app opens, instead
        // of waiting for the user's first push-to-talk to surface the prompts.
        requestAllNeededPermissionsOnLaunch()
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Resume the proactive-suggestion dwell timer if the user had it on
        // in a previous session. This is not an auto-enable — it only fires
        // when the persisted flag is already true from an explicit toggle.
        if isProactiveEnabled {
            proactiveManager.start()
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        // Disabled for the Micky fork — the upstream theme music only plays when
        // the Farza onboarding experience is explicitly re-enabled.
        guard isFarzaOnboardingEnabled else { return }
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        handsFreeRearmTask?.cancel()
        handsFreeRearmTask = nil
        handsFreeListenMonitorTask?.cancel()
        handsFreeListenMonitorTask = nil
        isHandsFreeSessionActive = false
        isHandsFreeAutoListening = false
        isRecordingVoiceFollowUp = false

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        proactiveManager.stop()
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Fires the system permission prompts for everything the companion needs —
    /// Microphone, Accessibility, and Screen Recording — right at launch, so the
    /// user is asked up front instead of on their first push-to-talk. Each
    /// request no-ops when that permission is already granted; the per-launch
    /// guards in WindowPositionManager fall back to opening System Settings on
    /// later attempts once macOS has shown its one-time prompt.
    private func requestAllNeededPermissionsOnLaunch() {
        // Only ever fire the microphone prompt when the user has truly never been
        // asked — never re-prompt once a decision exists.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            promptForMicrophoneIfNotDetermined()
        }
        // Accessibility's AXIsProcessTrusted() is reliable, so a false reading
        // won't nag — request only when genuinely not trusted.
        if !WindowPositionManager.hasAccessibilityPermission() {
            WindowPositionManager.requestAccessibilityPermission()
        }
        // Screen Recording's preflight check frequently returns a false negative
        // at launch even after the user granted it, which made Micky re-prompt on
        // every open. Use the tolerant check (honors the last confirmed-granted
        // state) so we only prompt when it was never actually granted.
        if !WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() {
            WindowPositionManager.requestScreenRecordingPermission()
        }
    }

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding or .processing while the AI
                // response pipeline is running — it manages those states
                // directly until TTS finishes. Gating on currentResponseTask
                // (not just voiceState) means a barge-in or stuck state can't
                // wedge the pipeline by silently dropping every later update.
                if self.currentResponseTask != nil
                    && (self.voiceState == .responding || self.voiceState == .processing) {
                    return
                }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // A button-initiated voice follow-up (or a hands-free
                    // auto-listen) that ended without producing a transcript
                    // (empty utterance, denied permission, or aborted start)
                    // never runs its submit closure, so reset the recording
                    // flags here so the Voice button doesn't stay stuck on its
                    // red "stop" state, and fade any transiently-shown overlay.
                    if self.isRecordingVoiceFollowUp {
                        self.endVoiceListeningSession()
                        self.scheduleTransientHideIfNeeded()
                    }
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                    // If a typed follow-up was queued while voice was recording
                    // but that recording produced no turn (empty utterance), the
                    // pipeline is idle now — drain the queue so the message isn't
                    // stranded. No-ops while anything is still in flight.
                    self.processNextQueuedFollowUpIfPipelineIdle()
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance,
            // resetting supervisory state so the cancelled turn can't wedge the
            // pipeline at .responding.
            cancelInFlightResponseForBargeIn()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        if Self.shouldEndHandsFreeConversation(
                            transcript: finalTranscript,
                            isEnabled: self.isHandsFreeEnabled,
                            isSessionActive: self.isHandsFreeSessionActive,
                            isAutoListening: false
                        ) {
                            self.endHandsFreeConversation()
                            return
                        }
                        if self.isHandsFreeEnabled {
                            self.isHandsFreeSessionActive = true
                        }
                        // A real, manually-spoken turn — clears any streak of
                        // silent/trivial hands-free auto-listen turns that
                        // may have built up (see handsFreeConsecutiveSilentTurns),
                        // proving the user is actually there.
                        self.resetHandsFreeSilentTurnCounter()
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        // Hardware push-to-talk is always a fresh request — let the
                        // send path classify it. (Voice follow-ups to a specific
                        // task come through toggleVoiceFollowUp's own closure, which
                        // passes that task id directly.)
                        self.sendTranscriptToClaudeWithScreenshot(
                            transcript: finalTranscript,
                            associatedAgentTaskID: nil
                        )
                    }
                )
            }
        case .released:
            // A button-initiated voice follow-up uses the same dictation machinery
            // as the hardware shortcut, so a stray hardware release while a follow-up
            // is recording would otherwise force-finalize it. Ignore the release in
            // that case — the follow-up is toggled off from its own button.
            guard !isRecordingVoiceFollowUp else { return }
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Cancels the in-flight response turn so a voice request can barge in, and
    /// resets the supervisory state the cancelled turn can no longer reset on its
    /// own. A cancelled turn skips its settle block, so without this the pipeline
    /// would stay stuck at `.responding` (or `.processing`) — which makes
    /// `bindVoiceStateObservation`'s `.responding` guard drop every later state
    /// update and can strand a queued typed follow-up. Queued follow-ups are left
    /// intact so they run after the new turn settles.
    ///
    /// Also cancels any pending hands-free re-arm: this function runs whenever
    /// a hardware push-to-talk press or a voice follow-up start "takes the
    /// mic" (see handleShortcutTransition and beginVoiceListening), and none
    /// of those should ever race against a delayed hands-free re-arm trying to
    /// open the mic on top of them.
    private func cancelInFlightResponseForBargeIn() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        currentInFlightAgentTaskID = nil
        textToSpeechClient.stopPlayback()
        voiceState = .idle
        handsFreeRearmTask?.cancel()
        handsFreeRearmTask = nil
        // A barge-in supersedes whatever hands-free auto-listen turn might
        // still be getting monitored for end-of-speech — that turn no longer
        // owns the mic (or is about to be replaced), so its monitor must die
        // with it. See handsFreeListenMonitorTask's declaration for every
        // other teardown point.
        handsFreeListenMonitorTask?.cancel()
        handsFreeListenMonitorTask = nil
    }

    // MARK: - Connector recommendations

    /// Ask the proxy whether this utterance should trigger a "Connect … to Micky"
    /// popup, and if so publish it (the panel manager observes
    /// pendingConnectorRecommendation). Fire-and-forget: any failure is silent so
    /// the voice pipeline is never affected. Each app is surfaced at most once per
    /// app session to avoid nagging.
    private func maybeRecommendConnector(forUtterance utterance: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let recommendation = await self.connectorRecommendationService.recommendation(forUtterance: utterance) else { return }
            if self.connectorSlugsAlreadySurfacedThisSession.contains(recommendation.slug) { return }
            // Don't replace a popup the user hasn't answered yet.
            if self.pendingConnectorRecommendation != nil { return }
            self.connectorSlugsAlreadySurfacedThisSession.insert(recommendation.slug)
            self.pendingConnectorRecommendation = recommendation
        }
    }

    /// "Yes" — start the OAuth flow and open Composio's connect link in the
    /// browser. Dismisses the popup immediately for responsiveness.
    func acceptConnectorRecommendation(_ recommendation: ConnectorRecommendation) {
        pendingConnectorRecommendation = nil
        Task { [weak self] in
            guard let self else { return }
            if let connectionURL = await self.connectorRecommendationService.connectionURL(forToolkitSlug: recommendation.slug) {
                NSWorkspace.shared.open(connectionURL)
            }
        }
    }

    /// "Not now" — just dismiss. It may resurface in a future app session.
    func snoozeConnectorRecommendation(_ recommendation: ConnectorRecommendation) {
        pendingConnectorRecommendation = nil
    }

    /// "No" — dismiss and tell the proxy to stop recommending this app.
    func declineConnectorRecommendation(_ recommendation: ConnectorRecommendation) {
        pendingConnectorRecommendation = nil
        Task { [weak self] in
            await self?.connectorRecommendationService.suppressRecommendations(forToolkitSlug: recommendation.slug)
        }
    }

    // MARK: - Agent Task Artifacts

    /// Fetches whatever artifacts the proxy has recorded for `agentTaskID` and
    /// attaches them to its card. Called from every place a turn settles for
    /// that task (normal completion, needs-confirmation, and the cancellation
    /// settle path for a superseded turn), since each of those is a point where
    /// the proxy may have recorded new files.
    ///
    /// Cancels any fetch already in flight for the same task id before starting
    /// a new one, so two overlapping fetches can't land out of order and leave
    /// stale data attached (last-writer-wins with the older response overwriting
    /// the newer one). Fire-and-forget: never blocks the voice pipeline, and a
    /// failed or cancelled fetch just means no artifacts row appears — the card
    /// itself already settled.
    private func fetchArtifactsAndAttach(toAgentTaskID agentTaskID: UUID) {
        artifactFetchTasksByAgentTaskID[agentTaskID]?.cancel()
        let agentID = agentTaskID.uuidString
        artifactFetchTasksByAgentTaskID[agentTaskID] = Task { [weak self] in
            guard let self else { return }
            defer {
                // Only clear this task's own dictionary slot on a normal finish.
                // `.cancel()` above is the only place that cancels one of these
                // tasks, so landing here cancelled means a newer fetch for this
                // same agentTaskID already overwrote the dictionary entry —
                // clearing it here would erase that newer task's entry instead
                // of this (superseded) one's.
                if !Task.isCancelled {
                    self.artifactFetchTasksByAgentTaskID[agentTaskID] = nil
                }
            }
            let fetchedArtifacts = await self.agentArtifactsService.artifacts(forAgentID: agentID)
            guard !Task.isCancelled, !fetchedArtifacts.isEmpty else { return }
            self.agentTaskStore.setArtifacts(fetchedArtifacts, forTaskWithID: agentTaskID)
        }
    }

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via the active TTS client. The cursor stays
    /// in the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(
        transcript: String,
        associatedAgentTaskID: UUID? = nil,
        isAlreadyRecordedInTranscript: Bool = false
    ) {
        // Supersede any in-flight turn. No supervisory reset is needed here —
        // this method's own task sets voiceState = .processing immediately below,
        // so it can't leave the pipeline wedged the way a record-first barge-in can.
        currentResponseTask?.cancel()
        textToSpeechClient.stopPlayback()

        // Non-blocking: if this utterance mentions an app the user hasn't connected
        // yet, surface the "Connect … to Micky" popup. Runs alongside the response
        // and never affects the voice pipeline.
        maybeRecommendConnector(forUtterance: transcript)

        // Resolve which agent task (if any) this turn belongs to:
        //  - an explicit follow-up target wins,
        //  - otherwise a request that reads like a multi-step/power job spawns a
        //    new task card,
        //  - plain screen questions get no card.
        var didCreateNewAgentTask = false
        let effectiveAgentTaskID: UUID? = {
            if let associatedAgentTaskID {
                // A queued follow-up was already shown in the transcript when the
                // user sent it, so don't record it a second time here.
                if !isAlreadyRecordedInTranscript {
                    agentTaskStore.appendUserMessage(transcript, toTaskWithID: associatedAgentTaskID)
                }
                agentTaskStore.updateStatus(.running, forTaskWithID: associatedAgentTaskID)
                return associatedAgentTaskID
            }
            if AgentTaskClassifier.looksLikeAgentTask(transcript) {
                didCreateNewAgentTask = true
                return agentTaskStore.createAgentTask(
                    title: AgentTaskClassifier.makeTitle(from: transcript),
                    initialUserMessage: transcript
                )
            }
            return nil
        }()

        currentInFlightAgentTaskID = effectiveAgentTaskID

        // Per-agent routing metadata: agent turns go to their OWN isolated proxy
        // session (own memory), keyed by the task id, focused on the original task.
        let agentRoutingID = effectiveAgentTaskID?.uuidString
        let agentRoutingTask = effectiveAgentTaskID.flatMap { agentTaskStore.agentTask(withID: $0) }
        let agentRoutingName = agentRoutingTask?.title
        let agentRoutingOriginalTask = agentRoutingTask?.transcript.first(where: { $0.role == .user })?.text ?? transcript

        // For a brand-new agent, generate a contextual gerund name asynchronously.
        // The instant placeholder (makeTitle) shows immediately, then upgrades when
        // the model label returns — never blocks the turn.
        if didCreateNewAgentTask, let newAgentTaskID = effectiveAgentTaskID {
            Task { [weak self] in
                guard let self else { return }
                if let generatedTitle = await self.claudeAPI.generateAgentTitle(text: transcript) {
                    self.agentTaskStore.setTitle(generatedTitle, forTaskWithID: newAgentTaskID)
                }
            }
        }

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Agent turns use the proxy's per-agent isolated session (its own
                // memory), so we send the agent id + focused metadata and NO global
                // history. The main chat keeps the shared conversationHistory.
                let isAgentTurn = agentRoutingID != nil
                let historyForAPI: [(userPlaceholder: String, assistantResponse: String)] = isAgentTurn
                    ? []
                    : conversationHistory.map { entry in
                        (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                    }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    agentID: agentRoutingID,
                    agentName: agentRoutingName,
                    agentTask: agentRoutingOriginalTask,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to the MAIN chat's conversation history. Agent
                // turns are excluded — their context lives in the proxy's per-agent
                // session and the task transcript — so agents and the main chat
                // don't bleed into each other.
                if !isAgentTurn {
                    conversationHistory.append((
                        userTranscript: transcript,
                        assistantResponse: spokenText
                    ))

                    // Keep only the last 10 exchanges to avoid unbounded context growth
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }

                    print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                }

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Record the agent's reply on its task card and update its status.
                // If the reply reads like a "describe the action, then ask the
                // user to say yes" confirmation prompt (the proxy's power gate),
                // mark it Needs confirmation so the card reflects that it's waiting.
                if let effectiveAgentTaskID {
                    agentTaskStore.appendAssistantMessage(spokenText, toTaskWithID: effectiveAgentTaskID)
                    let resolvedStatus: AgentTaskStatus = Self.responseAsksForConfirmation(spokenText)
                        ? .needsConfirmation
                        : .done
                    agentTaskStore.updateStatus(resolvedStatus, forTaskWithID: effectiveAgentTaskID)

                    // Once a turn settles — either fully Done, or waiting on the
                    // user for confirmation (the proxy already ran the described
                    // action and may have recorded artifacts for it before pausing
                    // on the power gate) — fetch whatever artifacts the proxy has
                    // recorded for this agent id in the background and attach
                    // them to the card.
                    if resolvedStatus == .done || resolvedStatus == .needsConfirmation {
                        fetchArtifactsAndAttach(toAgentTaskID: effectiveAgentTaskID)
                    }
                }

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await textToSpeechClient.speakText(spokenText)
                        // speakText returns once playback has started — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }

                // Keep this turn marked in-flight until the spoken reply finishes
                // playing, so a typed follow-up the user queued waits for the agent
                // to stop talking before it runs. A voice interrupt cancels this
                // task (and stops playback), which breaks out of this wait so the
                // new request can barge in immediately.
                while textToSpeechClient.isPlaying && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            } catch is CancellationError {
                // User spoke again — this turn was superseded. If it belonged to a
                // task that is NOT the one now in flight, don't leave that card
                // spinning forever; settle it back to done (its prior reply stands)
                // and still fetch — the cancelled turn may have run far enough on
                // the proxy side to have recorded artifacts before this app-side
                // cancellation happened.
                if let effectiveAgentTaskID,
                   effectiveAgentTaskID != currentInFlightAgentTaskID,
                   agentTaskStore.agentTask(withID: effectiveAgentTaskID)?.status == .running {
                    agentTaskStore.updateStatus(.done, forTaskWithID: effectiveAgentTaskID)
                    fetchArtifactsAndAttach(toAgentTaskID: effectiveAgentTaskID)
                }
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                if let effectiveAgentTaskID {
                    agentTaskStore.updateStatus(.error, forTaskWithID: effectiveAgentTaskID)
                }
                speakCreditsErrorFallback()
            }

            // The turn has settled. Reaching here un-cancelled means it ran to
            // completion and still owns the pipeline — a voice barge-in would have
            // cancelled it — so clear the in-flight markers and start the next
            // queued typed follow-up, if any.
            if !Task.isCancelled {
                voiceState = .idle
                currentResponseTask = nil
                currentInFlightAgentTaskID = nil
                scheduleTransientHideIfNeeded()
                processNextQueuedFollowUpIfPipelineIdle()

                // Hands-free conversation mode: if enabled, and nothing else
                // just picked the pipeline back up (a drained queued follow-up
                // above would already have set currentResponseTask again),
                // schedule a delayed re-arm of the mic for the user's next
                // spoken turn. See scheduleHandsFreeRearmIfNeeded for the full
                // set of guards — this is turn-taking, never duplex, so the
                // mic is never opened while TTS is playing.
                scheduleHandsFreeRearmIfNeeded()
            }
        }
    }

    /// Schedules a delayed re-arm of the mic for hands-free conversation mode.
    /// Called only from the reply-settle block above, i.e. only once a turn
    /// has fully finished (including its TTS playback — the settle block is
    /// reached after `sendTranscriptToClaudeWithScreenshot`'s `while
    /// textToSpeechClient.isPlaying` wait completes).
    ///
    /// SAFETY: this feature is continuous TURN-TAKING, not full duplex. The
    /// mic must NEVER open while Micky is speaking, or it will hear its own
    /// voice. Guards are applied twice — once here, synchronously, before
    /// scheduling anything, and again inside the delayed task right before it
    /// actually opens the mic — because the world can change during the delay
    /// (the user can disable hands-free, press push-to-talk, tap a task's
    /// Voice button, or a brand-new turn can start). If anything is
    /// uncertain, this errs toward NOT auto-opening the mic.
    ///
    /// Always cancels whatever was previously in `handsFreeRearmTask` first,
    /// so only ever one re-arm is pending at a time, and any of the other
    /// cancellation points (setHandsFreeEnabled(false),
    /// cancelInFlightResponseForBargeIn, or stop()) can reliably kill it.
    private func scheduleHandsFreeRearmIfNeeded() {
        handsFreeRearmTask?.cancel()
        handsFreeRearmTask = nil
        // Any monitor watching a previous auto-listen turn has already done
        // its job by the time we get here (that turn already settled) —
        // mirror handsFreeRearmTask's own cancel-first-thing pattern so a
        // stale monitor can never poll past its turn's lifetime.
        handsFreeListenMonitorTask?.cancel()
        handsFreeListenMonitorTask = nil

        guard isHandsFreeEnabled else { return }
        guard isHandsFreeSessionActive else { return }
        // A queued typed follow-up drained above already started a new turn —
        // don't stack a re-arm on top of it.
        guard currentResponseTask == nil else { return }
        // Nothing else should already have the mic.
        guard !isRecordingVoiceFollowUp, !buddyDictationManager.isDictationInProgress else { return }
        // Never schedule while audio is still playing — belt-and-suspenders on
        // top of the settle block only running after playback ends.
        guard !textToSpeechClient.isPlaying else { return }
        // Loop / silence-hallucination protection: once several consecutive
        // auto-listen turns in a row have produced no real speech (STT
        // hallucinating short junk on background noise, or genuine silence
        // timing out), stop re-opening the mic on our own. This does NOT
        // disable the isHandsFreeEnabled toggle — it just halts the automatic
        // loop until the user proves they're actually there with a manual
        // push-to-talk or Voice-button turn, which resets the streak (see
        // resetHandsFreeSilentTurnCounter). Without this a quiet or noisy
        // room would submit junk, get a reply, re-arm, and repeat forever.
        guard handsFreeConsecutiveSilentTurns < Self.handsFreeMaxConsecutiveSilentTurns else {
            print("🎙️ Hands-free: \(handsFreeConsecutiveSilentTurns) consecutive silent turns — suspending auto re-arm until a manual turn")
            return
        }

        handsFreeRearmTask = Task { @MainActor [weak self] in
            // Let the tail of the spoken reply finish decaying acoustically
            // before the mic opens, so it can't catch the last words of
            // Micky's own voice. A single fixed-length sleep — not a
            // busy-wait / tight polling loop.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }

            // Re-check every guard right before opening the mic. Anything
            // could have changed during the 500ms delay — the user could have
            // toggled hands-free off, pressed push-to-talk, tapped a task's
            // Voice button, or a brand-new response/TTS turn could already be
            // in flight. NEVER open the mic while TTS is playing, and if
            // there's any doubt at all, skip the re-arm rather than risk
            // capturing Micky's own voice or stepping on something else.
            guard self.isHandsFreeEnabled else { return }
            guard self.isHandsFreeSessionActive else { return }
            guard self.currentResponseTask == nil else { return }
            guard !self.isRecordingVoiceFollowUp, !self.buddyDictationManager.isDictationInProgress else { return }
            guard !self.textToSpeechClient.isPlaying else { return }

            self.handsFreeRearmTask = nil
            // Re-open the mic for the user's next turn via the SAME primitive
            // toggleVoiceFollowUp uses — nil agentTaskID routes the resulting
            // transcript to the main chat, since a hands-free re-arm isn't
            // scoped to any particular agent task card.
            self.beginVoiceListening(forAgentTaskID: nil, isHandsFreeAutoListen: true)
        }
    }

    // MARK: - Agent Task Follow-Ups

    /// Sends a typed follow-up message to an existing agent task through the same
    /// /chat path the voice pipeline uses (with a fresh screenshot for context).
    /// Used by the right-side panel's "follow up with agent…" field and the
    /// Agents tab's Text button.
    func sendFollowUpText(_ text: String, toAgentTaskID agentTaskID: UUID?) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        lastTranscript = trimmedText
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedText)

        // If the agent is still answering — generating a reply or speaking one
        // aloud — don't cut it off. Queue this typed message behind the current
        // turn; it runs automatically when the pipeline goes idle. (Voice
        // interrupts; text waits its turn.)
        if isResponsePipelineBusy {
            // Show the queued message on its task transcript right away so the
            // user sees it was received (the input field clears on send), and
            // mark it already-recorded so the send path won't duplicate it.
            var isAlreadyRecordedInTranscript = false
            if let agentTaskID {
                agentTaskStore.appendUserMessage(trimmedText, toTaskWithID: agentTaskID)
                isAlreadyRecordedInTranscript = true
            }
            queuedFollowUpMessages.append(
                QueuedFollowUpMessage(
                    text: trimmedText,
                    agentTaskID: agentTaskID,
                    isAlreadyRecordedInTranscript: isAlreadyRecordedInTranscript
                )
            )
            return
        }

        sendTranscriptToClaudeWithScreenshot(
            transcript: trimmedText,
            associatedAgentTaskID: agentTaskID
        )
    }

    /// Starts the next queued typed follow-up, but only when the response
    /// pipeline is fully idle — no turn in flight, nothing recording, no audio
    /// still playing. If anything is still active, the message stays queued and
    /// whatever is running will drain it when it settles. Safe to call from any
    /// settle point; it no-ops when the queue is empty or the pipeline is busy.
    private func processNextQueuedFollowUpIfPipelineIdle() {
        guard !isResponsePipelineBusy else { return }
        guard !queuedFollowUpMessages.isEmpty else { return }
        let nextQueuedFollowUpMessage = queuedFollowUpMessages.removeFirst()
        sendTranscriptToClaudeWithScreenshot(
            transcript: nextQueuedFollowUpMessage.text,
            associatedAgentTaskID: nextQueuedFollowUpMessage.agentTaskID,
            isAlreadyRecordedInTranscript: nextQueuedFollowUpMessage.isAlreadyRecordedInTranscript
        )
    }

    /// Starts (or stops) a voice follow-up dictation session bound to a specific
    /// agent task, driven by the Agents tab's Voice button rather than the
    /// hardware push-to-talk shortcut. The resulting transcript is attached to
    /// the given task when it finalizes.
    ///
    /// This is the manual entry point — the toggle only ever stops or starts a
    /// user-initiated session. The actual "start listening" mechanics live in
    /// beginVoiceListening(forAgentTaskID:) below, shared with hands-free
    /// conversation mode's automatic re-arm so the barge-in/dictation logic
    /// exists in exactly one place.
    func toggleVoiceFollowUp(forAgentTaskID agentTaskID: UUID?) {
        // If a follow-up dictation is already running, stop it (toggle off).
        if isRecordingVoiceFollowUp {
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            endVoiceListeningSession()
            return
        }

        beginVoiceListening(forAgentTaskID: agentTaskID)
    }

    /// Clears both the recording flag and the hands-free-auto-listen flag
    /// together — they always change in lockstep, so every place that used to
    /// reset isRecordingVoiceFollowUp alone now goes through here instead, to
    /// keep isHandsFreeAutoListening from ever going stale. Also tears down
    /// the hands-free listen monitor task (see handsFreeListenMonitorTask) —
    /// it only ever makes sense while a hands-free auto-listen session is
    /// open, so it always ends here too, whichever path ends the session.
    private func endVoiceListeningSession() {
        isRecordingVoiceFollowUp = false
        isHandsFreeAutoListening = false
        handsFreeListenMonitorTask?.cancel()
        handsFreeListenMonitorTask = nil
    }

    // MARK: - Hands-Free Auto-Listen (Voice Activity Detection)
    //
    // The dictation pipeline (BuddyDictationManager) is hold-to-talk — audio
    // keeps recording until something explicitly calls stop. That's fine for
    // the hardware shortcut and the manual Voice button, where the user
    // themselves controls start/stop. But hands-free's auto re-arm opens the
    // mic programmatically with nothing holding a key down, and nothing was
    // ever calling stop for it — so an auto-opened mic stayed hot forever,
    // the user's follow-up was captured but never finalized/submitted, and
    // the conversation died after exactly one turn. Everything below gives an
    // auto-listen turn its own end-of-speech detection so it behaves like a
    // real conversational turn instead of a stuck recorder.

    /// Speech-detection threshold for currentAudioPowerLevel (0...1 range,
    /// see BuddyDictationManager.currentAudioPowerLevel). BuddyDictationManager's
    /// own silence floor (its private recordedAudioPowerHistoryBaselineLevel)
    /// is 0.02; this is roughly 2.5x that, so ordinary room tone/hiss can't
    /// falsely register as "the user started talking." NEEDS LIVE TUNING
    /// against a real microphone/room.
    private static let handsFreeSpeechDetectionLevel: CGFloat = 0.05

    /// Once speech has been detected, a sample at or below this level counts
    /// toward the trailing silence window that ends the turn — close to
    /// BuddyDictationManager's own silence floor (0.02). Anything strictly
    /// between this and handsFreeSpeechDetectionLevel is treated as ambiguous
    /// (quiet talking, not silence): it pauses the silence countdown without
    /// resetting it. NEEDS LIVE TUNING.
    private static let handsFreeSilenceLevel: CGFloat = 0.03

    /// How many consecutive above-threshold polls (at the ~100ms interval
    /// below) are required before a burst counts as "the user started
    /// talking" — guards against a single noise spike.
    private static let handsFreeSpeechConfirmationSampleCount = 2

    /// How long the level must stay at/below handsFreeSilenceLevel, after
    /// speech has started, before the turn is auto-finalized (finalize +
    /// submit via stopPushToTalkFromKeyboardShortcut()).
    private static let handsFreeTrailingSilenceDurationSeconds: TimeInterval = 1.5

    /// If no speech is heard at all within this long, give up on the turn —
    /// treated as silence, so it's discarded (cancelCurrentDictation), not
    /// submitted.
    private static let handsFreeNoSpeechTimeoutSeconds: TimeInterval = 8.0

    /// Absolute ceiling on a single auto-listen turn regardless of whether
    /// speech was heard — a backstop against a stuck-open mic.
    private static let handsFreeMaxListenDurationSeconds: TimeInterval = 20.0

    /// Poll interval for the monitor below. Task.sleep-based — not a busy-wait.
    private static let handsFreeMonitorPollIntervalNanoseconds: UInt64 = 100_000_000

    /// A hands-free transcript with fewer words than this is treated as STT
    /// hallucination on near-silent audio ("you", "thank you") rather than a
    /// real utterance — see the submit closure in beginVoiceListening below.
    private static let handsFreeMinimumSpokenWordCount = 2

    /// Same idea in raw non-space character terms, so a single short "word"
    /// STT split into pieces (or vice versa) is still caught.
    private static let handsFreeMinimumSpokenNonSpaceCharacterCount = 3

    /// Once this many consecutive hands-free turns in a row produce no real
    /// speech, scheduleHandsFreeRearmIfNeeded stops re-opening the mic on its
    /// own (without touching the isHandsFreeEnabled toggle) until the user
    /// does a manual push-to-talk / Voice-button turn.
    private static let handsFreeMaxConsecutiveSilentTurns = 3

    /// Starts the voice-activity monitor for an in-progress hands-free
    /// auto-listen turn — see the MARK section above for why this exists at
    /// all. Polls buddyDictationManager.currentAudioPowerLevel on the main
    /// actor roughly every 100ms (Task.sleep, not a tight loop) and:
    ///   - waits for the level to clear handsFreeSpeechDetectionLevel for
    ///     handsFreeSpeechConfirmationSampleCount consecutive polls before
    ///     considering the turn to have started ("heardSpeech"),
    ///   - once heardSpeech is true, finalizes+submits the turn
    ///     (stopPushToTalkFromKeyboardShortcut) once the level has stayed at
    ///     or below handsFreeSilenceLevel continuously for
    ///     handsFreeTrailingSilenceDurationSeconds,
    ///   - and otherwise gives up and discards the turn
    ///     (cancelCurrentDictation(preserveDraftText: false), counted as a
    ///     silent turn) if no speech is ever heard within
    ///     handsFreeNoSpeechTimeoutSeconds, or unconditionally once
    ///     handsFreeMaxListenDurationSeconds elapses regardless of speech.
    ///
    /// Only ever called from beginVoiceListening's isHandsFreeAutoListen
    /// branch. Exits immediately, on every poll, if hands-free was disabled,
    /// this is no longer the active auto-listen session, a new response task
    /// started, or the task itself was cancelled — see every cancellation
    /// site listed on handsFreeListenMonitorTask's declaration.
    private func startHandsFreeListenMonitor() {
        handsFreeListenMonitorTask?.cancel()
        // Explicit @MainActor: the monitor reads/writes main-actor state
        // (isHandsFreeEnabled, currentResponseTask, buddyDictationManager) across
        // its await points, so it must resume on the main actor every poll.
        handsFreeListenMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var hasObservedDictationInProgress = false
            var heardSpeech = false
            var consecutiveAboveThresholdSamples = 0
            var silenceStartedAt: Date?
            let listenStartedAt = Date()

            while !Task.isCancelled {
                guard self.isHandsFreeEnabled,
                      self.isHandsFreeSessionActive,
                      self.isHandsFreeAutoListening,
                      self.currentResponseTask == nil else {
                    return
                }

                let dictationInProgress = self.buddyDictationManager.isDictationInProgress
                if dictationInProgress {
                    hasObservedDictationInProgress = true

                    let level = self.buddyDictationManager.currentAudioPowerLevel
                    if level > Self.handsFreeSpeechDetectionLevel {
                        consecutiveAboveThresholdSamples += 1
                        silenceStartedAt = nil
                        if !heardSpeech && consecutiveAboveThresholdSamples >= Self.handsFreeSpeechConfirmationSampleCount {
                            heardSpeech = true
                            print("🎙️ Hands-free listen monitor: speech detected, watching for end-of-speech")
                        }
                    } else {
                        consecutiveAboveThresholdSamples = 0
                        if heardSpeech && level <= Self.handsFreeSilenceLevel {
                            let silenceStart = silenceStartedAt ?? Date()
                            silenceStartedAt = silenceStart
                            if Date().timeIntervalSince(silenceStart) >= Self.handsFreeTrailingSilenceDurationSeconds {
                                print("🎙️ Hands-free listen monitor: end-of-speech detected, finalizing turn")
                                self.buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
                                return
                            }
                        }
                        // Else: level is in the ambiguous band between
                        // handsFreeSilenceLevel and handsFreeSpeechDetectionLevel
                        // (or speech hasn't started yet) — leave any running
                        // silence timer paused rather than resetting it.
                    }
                } else if hasObservedDictationInProgress {
                    // Dictation was running and has since ended through some
                    // other path (an internal STT error/fallback, or a
                    // teardown that for some reason didn't cancel this task
                    // directly) — nothing left for this monitor to do.
                    return
                }

                let elapsedListenSeconds = Date().timeIntervalSince(listenStartedAt)
                if !heardSpeech && elapsedListenSeconds >= Self.handsFreeNoSpeechTimeoutSeconds {
                    print("🎙️ Hands-free listen monitor: no speech within \(Int(Self.handsFreeNoSpeechTimeoutSeconds))s — discarding silent turn")
                    self.buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
                    self.endVoiceListeningSession()
                    self.scheduleTransientHideIfNeeded()
                    self.registerHandsFreeSilentTurn()
                    self.scheduleHandsFreeRearmIfNeeded()
                    return
                }
                if elapsedListenSeconds >= Self.handsFreeMaxListenDurationSeconds {
                    print("🎙️ Hands-free listen monitor: max listen duration reached — ending turn")
                    if heardSpeech {
                        self.buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
                    } else {
                        self.buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
                        self.endVoiceListeningSession()
                        self.scheduleTransientHideIfNeeded()
                        self.registerHandsFreeSilentTurn()
                        self.scheduleHandsFreeRearmIfNeeded()
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: Self.handsFreeMonitorPollIntervalNanoseconds)
            }
        }
    }

    /// Records that a hands-free auto-listen turn ended without a real,
    /// submittable utterance — either startHandsFreeListenMonitor's
    /// no-speech/max-listen backstop discarded a silent turn, or the submit
    /// closure in beginVoiceListening caught a trivially short transcript.
    /// scheduleHandsFreeRearmIfNeeded consults this count and suspends
    /// auto-rearming once it reaches handsFreeMaxConsecutiveSilentTurns, so a
    /// noisy room can't loop the mic open forever.
    private func registerHandsFreeSilentTurn() {
        handsFreeConsecutiveSilentTurns += 1
        print("🎙️ Hands-free: silent/trivial turn #\(handsFreeConsecutiveSilentTurns) in a row")
    }

    /// Clears the silent-turn streak. Called whenever a real utterance is
    /// submitted — a genuine hands-free turn, or any manual push-to-talk /
    /// Voice-button turn — since either proves the user is actually there.
    private func resetHandsFreeSilentTurnCounter() {
        handsFreeConsecutiveSilentTurns = 0
    }

    /// True if `transcript`, once trimmed, is too short to plausibly be a
    /// real spoken turn — fewer than handsFreeMinimumSpokenWordCount words,
    /// or fewer than handsFreeMinimumSpokenNonSpaceCharacterCount non-space
    /// characters. Speech-to-text reliably hallucinates short junk like "you"
    /// or "thank you" on near-silent audio; this heuristic keeps a hands-free
    /// auto-listen from submitting that noise as a real message (see the
    /// submit closure in beginVoiceListening below).
    private static func isTriviallyShortHandsFreeTranscript(_ transcript: String) -> Bool {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonSpaceCharacterCount = trimmedTranscript.filter { !$0.isWhitespace }.count
        guard nonSpaceCharacterCount >= Self.handsFreeMinimumSpokenNonSpaceCharacterCount else { return true }
        let wordCount = trimmedTranscript.split(whereSeparator: { $0.isWhitespace }).count
        return wordCount < Self.handsFreeMinimumSpokenWordCount
    }

    /// Exact, assistant-addressed phrases that end the current hands-free
    /// conversation. Matching is deliberately strict so ordinary sentences
    /// containing "stop", "done", or "thanks" never shut the mic loop down.
    /// Punctuation and apostrophe style are ignored by normalization.
    static func isHandsFreeConversationEndTranscript(_ transcript: String) -> Bool {
        let apostropheNormalized = transcript
            .lowercased()
            // STT transcribes the wake-name as "Mickey" (the common English
            // spelling) about as often as "Micky" — fold both to one form so
            // every end phrase matches regardless of which the recognizer picked.
            .replacingOccurrences(of: "mickey", with: "micky")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
        let wordsOnly = apostropheNormalized.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        let normalized = String(wordsOnly)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return [
            "thats all micky",
            "that is all micky",
            "micky thats all",
            "micky that is all",
            "end conversation micky",
            "stop listening micky",
            "goodbye micky",
        ].contains(normalized)
    }

    /// Session policy around the phrase matcher. The phrase is consumed only
    /// when hands-free is enabled and a conversation is already active (or the
    /// transcript came from the auto-opened microphone). A first, unrelated
    /// push-to-talk saying "goodbye Micky" therefore still reaches the model.
    static func shouldEndHandsFreeConversation(
        transcript: String,
        isEnabled: Bool,
        isSessionActive: Bool,
        isAutoListening: Bool
    ) -> Bool {
        guard isEnabled, isSessionActive || isAutoListening else { return false }
        return isHandsFreeConversationEndTranscript(transcript)
    }

    /// Stop only the current automatic conversation loop. The persisted
    /// hands-free preference remains enabled, so a later manual push-to-talk
    /// turn can begin a new conversation without visiting Settings.
    private func endHandsFreeConversation() {
        isHandsFreeSessionActive = false
        handsFreeRearmTask?.cancel()
        handsFreeRearmTask = nil
        handsFreeListenMonitorTask?.cancel()
        handsFreeListenMonitorTask = nil
        if isHandsFreeAutoListening && buddyDictationManager.isDictationInProgress {
            buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
            endVoiceListeningSession()
        }
        print("🎙️ Hands-free: conversation ended by voice phrase")
        scheduleTransientHideIfNeeded()
    }

    /// Starts listening for one spoken turn: barge-in (cancels whatever the
    /// agent is currently saying/generating), flags `isRecordingVoiceFollowUp`,
    /// brings up the cursor overlay if it's hidden, and starts a push-to-talk
    /// dictation session through the SAME machinery the hardware shortcut uses.
    /// On a final transcript, sends it through the normal response path
    /// attached to `agentTaskID` (nil routes to the main chat, with no
    /// specific task card).
    ///
    /// This is the single primitive both toggleVoiceFollowUp (the Agents tab's
    /// manual Voice button) and hands-free conversation mode's automatic
    /// re-arm (scheduleHandsFreeRearmIfNeeded above) use to open the mic for a
    /// turn — do NOT duplicate this barge-in/dictation logic anywhere else.
    ///
    /// - Parameter isHandsFreeAutoListen: true only when this call is the
    ///   hands-free re-arm opening the mic automatically, as opposed to the
    ///   user tapping a Voice button. Recorded on isHandsFreeAutoListening so
    ///   setHandsFreeEnabled(false) can tell an auto-opened mic apart from a
    ///   manually-started one and only stop the former.
    private func beginVoiceListening(forAgentTaskID agentTaskID: UUID?, isHandsFreeAutoListen: Bool = false) {
        // Don't start if another dictation (e.g. the hardware shortcut) is busy.
        guard !buddyDictationManager.isDictationInProgress else { return }

        // Barge-in: interrupting with voice cancels whatever the agent is
        // currently saying or generating, and resets supervisory state so the
        // cancelled turn can't wedge the pipeline at .responding. This spoken
        // request takes over right away; any typed follow-ups the user queued stay
        // queued and run after this voice turn. (Mirrors the hardware push-to-talk
        // path, which also interrupts on press.) For a hands-free re-arm there is
        // nothing in flight to cancel at this point — the settle block only
        // schedules the re-arm once the pipeline is already idle — so this is a
        // harmless no-op in that case. This also tears down any monitor task
        // left over from a superseded auto-listen turn (see
        // handsFreeListenMonitorTask).
        cancelInFlightResponseForBargeIn()

        isRecordingVoiceFollowUp = true
        isHandsFreeAutoListening = isHandsFreeAutoListen

        // Only a hands-free auto-listen needs its own end-of-speech detection
        // — the hardware shortcut and the manual Voice button are both held
        // open by an explicit user action and stopped by an explicit
        // release/tap, so neither of them needs this. See
        // startHandsFreeListenMonitor's doc comment (and the MARK section
        // above it) for why an auto-opened mic would otherwise never close.
        if isHandsFreeAutoListen {
            startHandsFreeListenMonitor()
        }

        // Bring the cursor overlay up transiently so the waveform is visible,
        // matching the hardware push-to-talk experience.
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        Task { [weak self] in
            guard let self else { return }
            await self.buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts are hidden (waveform-only UI).
                },
                submitDraftText: { [weak self] finalTranscript in
                    guard let self else { return }
                    self.endVoiceListeningSession()
                    self.lastTranscript = finalTranscript

                    if Self.shouldEndHandsFreeConversation(
                        transcript: finalTranscript,
                        isEnabled: self.isHandsFreeEnabled,
                        isSessionActive: self.isHandsFreeSessionActive,
                        isAutoListening: isHandsFreeAutoListen
                    ) {
                        self.endHandsFreeConversation()
                        return
                    }

                    // Loop / silence-hallucination protection: STT reliably
                    // hallucinates short junk ("you", "thank you") on near-
                    // silent audio, which would otherwise submit, get a
                    // reply, and re-arm the mic — looping forever on
                    // background noise. Only hands-free's own auto-listen
                    // turns are filtered like this; a manual Voice-button
                    // turn (or the hardware push-to-talk shortcut, handled
                    // separately in handleShortcutTransition) is never
                    // dropped, since the user explicitly chose to speak.
                    if isHandsFreeAutoListen && Self.isTriviallyShortHandsFreeTranscript(finalTranscript) {
                        print("🎙️ Hands-free: dropping trivial transcript \"\(finalTranscript)\" as likely silence/hallucination")
                        self.registerHandsFreeSilentTurn()
                        self.scheduleHandsFreeRearmIfNeeded()
                        return
                    }

                    // A real utterance — resets the silent-turn streak,
                    // whether this was a hands-free turn or a manual one.
                    if self.isHandsFreeEnabled {
                        self.isHandsFreeSessionActive = true
                    }
                    self.resetHandsFreeSilentTurnCounter()

                    ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                    // Attach the follow-up to the task captured at button-tap
                    // time (nil for hands-free re-arm / main chat).
                    self.sendTranscriptToClaudeWithScreenshot(
                        transcript: finalTranscript,
                        associatedAgentTaskID: agentTaskID
                    )
                }
            )

            // If the session never actually began (permission denied, recognition
            // error, cancelled, or superseded), the submit closure won't run — roll
            // back the optimistic flags so the Voice button isn't stuck recording.
            if !self.buddyDictationManager.isDictationInProgress && self.isRecordingVoiceFollowUp {
                self.endVoiceListeningSession()
                self.scheduleTransientHideIfNeeded()
                // The voice follow-up never produced a turn, so the pipeline may
                // be idle now — drain any typed follow-up queued behind it.
                self.processNextQueuedFollowUpIfPipelineIdle()
            }
        }
    }

    /// Heuristic: does this reply read like the power gate's "describe the action,
    /// then ask the user to say yes" confirmation prompt? The proxy instructs the
    /// model to do exactly this before any mutating action, so a reply that both
    /// asks a question and invites a yes/confirmation is treated as pending.
    static func responseAsksForConfirmation(_ responseText: String) -> Bool {
        let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A confirmation prompt ends by asking the user to approve, so it must end
        // with a question mark and the cue must be near the end — this avoids
        // mislabeling normal explanatory replies that merely contain a cue word
        // somewhere (e.g. a "want me to go deeper?" seed-planting closer).
        guard trimmedResponse.hasSuffix("?") else { return false }
        let closingFragment = String(trimmedResponse.suffix(90))
        // The proxy's power gate instructs the model to ask the user to "say yes",
        // so prioritize that and a few strong, action-oriented confirmation cues.
        // Deliberately omit broad cues like "want me to", "confirm", and "go ahead"
        // that fire on ordinary conversational follow-up questions.
        let confirmationCues = [
            "say yes", "should i", "shall i", "do you want me to", "ok to ", "okay to ",
            "can i ", "may i ",
        ]
        return confirmationCues.contains(where: { closingFragment.contains($0) })
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while textToSpeechClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        // Disabled for the Micky fork — the upstream intro video only plays when
        // the Farza onboarding experience is explicitly re-enabled.
        guard isFarzaOnboardingEnabled else { return }
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
