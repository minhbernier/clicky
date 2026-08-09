//
//  MorningBriefingManager.swift
//  leanring-buddy
//
//  Speaks a morning news briefing on the user's FIRST activity of the day after
//  an overnight-length idle gap. Fires at most once per calendar day, only
//  inside a morning window, and never mid-day after normal use — so it talks
//  when you wake your Mac, not every time you switch apps.
//
//  Trigger, mirroring ProactiveManager's observer style: it listens for
//  NSWorkspace.didActivateApplicationNotification (any frontmost-app change =
//  activity) and NSWorkspace.didWakeNotification (Mac woke from sleep). On each
//  such event it evaluates three gates — (a) the gap since the previous activity
//  is at least MICKY_MORNING_GAP hours (i.e. you were away/asleep), (b) the
//  local hour is inside [MICKY_MORNING_START, MICKY_MORNING_END), (c) it hasn't
//  already fired today — and if all hold, fetches /briefing/morning and speaks
//  it via the shared on-device/ElevenLabs TTS client. Every failure is silent.
//
//  Off-switch: UserDefaults "MickyMorningBriefingEnabled" (default true).
//

import AppKit
import Foundation

@MainActor
final class MorningBriefingManager: NSObject {
    static let enabledDefaultsKey = "MickyMorningBriefingEnabled"
    private static let lastFiredYMDKey = "MickyMorningBriefingLastFiredYMD"

    private let service: MorningBriefingService
    private let tts: any BuddyTextToSpeechClient

    /// Minimum idle gap (seconds) since the previous activity before a morning
    /// briefing may fire — "you were away/asleep." Env MICKY_MORNING_GAP (hours).
    private let gapThreshold: TimeInterval
    /// Local-hour morning window [start, end). Env MICKY_MORNING_START / _END.
    private let windowStartHour: Int
    private let windowEndHour: Int

    /// Timestamp of the previous observed activity. nil until the first event,
    /// so the very first activity of a launch can never fire (gap undefined).
    private var lastActivityDate: Date?

    /// The in-flight fetch+speak task, cancelled if superseded.
    private var currentTask: Task<Void, Never>?

    private let ymdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(proxyBaseURL: String, tts: any BuddyTextToSpeechClient) {
        self.service = MorningBriefingService(proxyBaseURL: proxyBaseURL)
        self.tts = tts

        let env = ProcessInfo.processInfo.environment
        let gapHours = Double(env["MICKY_MORNING_GAP"] ?? "") ?? 5.0
        self.gapThreshold = max(0, gapHours) * 3600
        self.windowStartHour = Int(env["MICKY_MORNING_START"] ?? "") ?? 5
        self.windowEndHour = Int(env["MICKY_MORNING_END"] ?? "") ?? 11
        super.init()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Start

    /// Registers the activity + wake observers. Safe to call once at launch;
    /// the feature self-gates on the enabled flag, the window, and the once-per-
    /// day stamp, so unlike ProactiveManager it does not need a user toggle to
    /// start observing. Seeds lastActivityDate = now so the first event can't
    /// fire on an undefined gap.
    func start() {
        lastActivityDate = Date()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activityObserved(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activityObserved(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - Trigger

    @objc private func activityObserved(_ notification: Notification) {
        let now = Date()
        defer { lastActivityDate = now }  // always advance the activity clock
        guard isEnabled else { return }
        guard shouldFire(now: now) else { return }
        markFired(now)
        fireBriefing()
    }

    private var isEnabled: Bool {
        // Default true: registered by start(), gated here so toggling the flag
        // takes effect without re-registering observers.
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    /// True iff (a) the gap since the previous activity is at least the
    /// threshold, (b) `now`'s local hour is in the morning window, and (c) it
    /// hasn't already fired today.
    func shouldFire(now: Date) -> Bool {
        guard let last = lastActivityDate else { return false }  // first ever
        guard now.timeIntervalSince(last) >= gapThreshold else { return false }
        let hour = Calendar.current.component(.hour, from: now)
        guard hour >= windowStartHour, hour < windowEndHour else { return false }
        return !hasFiredToday(now)
    }

    private func hasFiredToday(_ now: Date) -> Bool {
        UserDefaults.standard.string(forKey: Self.lastFiredYMDKey) == ymdFormatter.string(from: now)
    }

    private func markFired(_ now: Date) {
        UserDefaults.standard.set(ymdFormatter.string(from: now), forKey: Self.lastFiredYMDKey)
    }

    private func fireBriefing() {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            guard let text = await self.service.fetchMorningBriefing() else { return }
            guard !Task.isCancelled, self.isEnabled else { return }
            try? await self.tts.speakText(text)
        }
    }
}
