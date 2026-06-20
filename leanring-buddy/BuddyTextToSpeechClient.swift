//
//  BuddyTextToSpeechClient.swift
//  leanring-buddy
//
//  Shared protocol surface and factory for text-to-speech backends, mirroring
//  BuddyTranscriptionProvider's pluggable-provider pattern. Lets CompanionManager
//  hold any TTS client (cloud ElevenLabs or on-device system speech) behind one
//  interface and pick the active one from Info.plist.
//

import Foundation

@MainActor
protocol BuddyTextToSpeechClient {
    /// Sends `text` to the backend and begins playback. Returns once playback
    /// has started — audio continues in the background — so callers can update
    /// UI state immediately and poll `isPlaying` for completion.
    func speakText(_ text: String) async throws

    /// Whether spoken audio is currently playing back.
    var isPlaying: Bool { get }

    /// Stops any in-progress playback immediately.
    func stopPlayback()
}

@MainActor
enum BuddyTextToSpeechClientFactory {
    private enum PreferredProvider: String {
        case elevenLabs = "elevenlabs"
        case systemSpeech = "system"
        case openAI = "openai"
    }

    /// OpenAI TTS defaults, overridable via Info.plist (`OpenAITTSVoice`,
    /// `OpenAITTSModel`). Voices: alloy, ash, ballad, coral, echo, fable, nova,
    /// onyx, sage, shimmer.
    private static let defaultOpenAITTSVoice = "alloy"
    private static let defaultOpenAITTSModel = "gpt-4o-mini-tts"

    /// Resolves the active TTS client from the `VoiceTTSProvider` Info.plist key.
    /// When the key is absent or unrecognized, defaults to ElevenLabs so the
    /// app's shipped cloud behavior is unchanged.
    static func makeDefaultClient(elevenLabsProxyURL: String) -> any BuddyTextToSpeechClient {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTTSProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        if preferredProvider == .systemSpeech {
            print("🔊 TTS: using on-device system speech (AVSpeechSynthesizer)")
            return SystemSpeechTTSClient()
        }

        if preferredProvider == .openAI {
            // OpenAI TTS calls api.openai.com directly with an API key. If the key
            // is missing, fall back to on-device system speech rather than
            // ElevenLabs (which the local brain proxy can't serve), so the app
            // still talks.
            if let openAIAPIKey = AppBundleConfiguration.stringValue(forKey: "OpenAIAPIKey") {
                let voice = AppBundleConfiguration.stringValue(forKey: "OpenAITTSVoice") ?? defaultOpenAITTSVoice
                let model = AppBundleConfiguration.stringValue(forKey: "OpenAITTSModel") ?? defaultOpenAITTSModel
                print("🔊 TTS: using OpenAI (voice=\(voice), model=\(model))")
                return OpenAITextToSpeechClient(apiKey: openAIAPIKey, voice: voice, model: model)
            }
            print("⚠️ TTS: VoiceTTSProvider=openai but OpenAIAPIKey is missing — falling back to on-device system speech")
            return SystemSpeechTTSClient()
        }

        print("🔊 TTS: using ElevenLabs")
        return ElevenLabsTTSClient(proxyURL: elevenLabsProxyURL)
    }
}
