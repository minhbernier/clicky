//
//  OpenAITextToSpeechClient.swift
//  leanring-buddy
//
//  Text-to-speech backed by OpenAI's /v1/audio/speech endpoint. Calls OpenAI
//  directly with an API key (mirroring OpenAIAudioTranscriptionProvider), so it
//  works independently of the brain proxy. Returns once playback has started,
//  matching the BuddyTextToSpeechClient contract used by ElevenLabsTTSClient and
//  SystemSpeechTTSClient.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAITextToSpeechClient: BuddyTextToSpeechClient {
    private static let speechURL = URL(string: "https://api.openai.com/v1/audio/speech")!

    private let apiKey: String
    /// One of OpenAI's TTS voices: alloy, ash, ballad, coral, echo, fable, nova,
    /// onyx, sage, shimmer.
    private let voice: String
    /// The OpenAI TTS model, e.g. "gpt-4o-mini-tts", "tts-1", or "tts-1-hd".
    private let model: String
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the audio
    /// finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(apiKey: String, voice: String, model: String) {
        self.apiKey = apiKey
        self.voice = voice
        self.model = model

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to OpenAI TTS and plays the resulting MP3 audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        var request = URLRequest(url: Self.speechURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3",
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAITTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // OpenAI returns a JSON error body on failure (e.g. bad key, bad voice).
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAITTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI TTS error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 OpenAI TTS: playing \(data.count / 1024)KB audio (voice=\(voice), model=\(model))")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
