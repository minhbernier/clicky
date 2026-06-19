//
//  SystemSpeechTTSClient.swift
//  leanring-buddy
//
//  On-device text-to-speech backed by macOS-native AVSpeechSynthesizer. No
//  network, no API key — spoken replies work fully offline. Conforms to
//  BuddyTextToSpeechClient so it's a drop-in alternative to ElevenLabs.
//

import AVFoundation
import Foundation

@MainActor
final class SystemSpeechTTSClient: NSObject, BuddyTextToSpeechClient {
    // Held for the client's lifetime so speech isn't cut off by deallocation,
    // the same way ElevenLabsTTSClient keeps its AVAudioPlayer alive.
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// Continuation for the in-progress `speakText` call. Resolved when the
    /// synthesizer reports that speech has started (or was cancelled before it
    /// could start). Nil whenever no `speakText` call is awaiting.
    private var pendingPlaybackStartContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Speaks `text` on-device and returns once playback has started. Audio then
    /// continues in the background, matching ElevenLabsTTSClient's contract
    /// (return-on-start), so CompanionManager's voice-state handling and the
    /// `isPlaying` polling for transient-cursor hide work identically.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Stop anything already speaking so utterances don't queue up behind
        // each other when the user talks again mid-reply.
        stopPlayback()

        try Task.checkCancellation()

        let speechUtterance = AVSpeechUtterance(string: trimmedText)
        if let preferredVoice = Self.preferredEnglishVoice() {
            speechUtterance.voice = preferredVoice
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingPlaybackStartContinuation = continuation
            speechSynthesizer.speak(speechUtterance)
        }

        print("🔊 System speech TTS: speaking \(trimmedText.count) characters on-device")
    }

    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    func stopPlayback() {
        // Resolve any awaiting continuation before stopping so a `speakText`
        // call that hasn't yet received `didStart` doesn't hang forever.
        resumePendingPlaybackStartContinuation()

        guard speechSynthesizer.isSpeaking else { return }
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    /// Resumes the pending continuation at most once. Nil-ing it first makes the
    /// resume idempotent, guarding against both `didStart` and `stopPlayback`
    /// (or a `didCancel`) trying to resume the same continuation.
    private func resumePendingPlaybackStartContinuation() {
        guard let continuation = pendingPlaybackStartContinuation else { return }
        pendingPlaybackStartContinuation = nil
        continuation.resume()
    }

    private static func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        // 1) Explicit override: set `SystemTTSVoiceIdentifier` in Info.plist to a
        //    voice identifier from AVSpeechSynthesisVoice.speechVoices().
        if let overrideIdentifier = Bundle.main.object(forInfoDictionaryKey: "SystemTTSVoiceIdentifier") as? String,
           let overrideVoice = AVSpeechSynthesisVoice(identifier: overrideIdentifier) {
            return overrideVoice
        }

        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            // Drop the novelty/robotic voices (Zarvox, Bells, Bubbles, ...).
            .filter { !$0.identifier.hasPrefix("com.apple.speech.synthesis.voice.") }

        // 2) Pick the most natural voice available, ranked by:
        //    audio quality (premium > enhanced > default), then a curated list of
        //    known-good natural voice names, then US English. Downloading a
        //    Premium or Siri voice in System Settings is picked up automatically.
        let preferredNaturalNames = ["Siri", "Ava", "Zoe", "Allison", "Samantha", "Nicky", "Tom", "Aaron", "Evan", "Joelle"]
        func naturalNameRank(_ voice: AVSpeechSynthesisVoice) -> Int {
            if let index = preferredNaturalNames.firstIndex(where: { voice.name.localizedCaseInsensitiveContains($0) }) {
                return preferredNaturalNames.count - index
            }
            return 0
        }

        let bestVoice = englishVoices.max { lhs, rhs in
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue < rhs.quality.rawValue
            }
            if naturalNameRank(lhs) != naturalNameRank(rhs) {
                return naturalNameRank(lhs) < naturalNameRank(rhs)
            }
            // Prefer US English on ties.
            return (lhs.language == "en-US" ? 1 : 0) < (rhs.language == "en-US" ? 1 : 0)
        }

        return bestVoice ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension SystemSpeechTTSClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        // Playback has begun — let the awaiting speakText call return.
        Task { @MainActor in
            self.resumePendingPlaybackStartContinuation()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // If we were cancelled before speech started, the continuation still
        // needs to be resolved so speakText doesn't hang.
        Task { @MainActor in
            self.resumePendingPlaybackStartContinuation()
        }
    }
}
