//
//  ParakeetTranscriptionProvider.swift
//  leanring-buddy
//
//  On-device transcription provider backed by NVIDIA Parakeet (TDT) running
//  locally on the Apple Neural Engine via the FluidAudio Swift package.
//
//  Unlike AssemblyAI and OpenAI, this provider never sends audio off the
//  device — speech is transcribed entirely on-device. The Claude "brain" call
//  still needs the network; this only makes the "ears" work offline.
//
//  It mirrors OpenAIAudioTranscriptionProvider's buffer-then-finalize shape:
//  PCM16 audio is accumulated while the push-to-talk key is held, then the
//  whole utterance is transcribed at once on key-up. The only difference is
//  that transcription happens locally instead of over HTTP.
//

import AVFoundation
import FluidAudio
import Foundation

struct ParakeetTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class ParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Parakeet (on-device)"

    // Parakeet only needs the microphone, which Clicky already requests. It
    // does NOT need the Apple Speech Recognition entitlement, so push-to-talk
    // works without the speech-recognition permission prompt.
    let requiresSpeechRecognitionPermission = false

    private let speechModelLoader = ParakeetSpeechModelLoader.shared

    init() {
        // Kick off the (potentially large) one-time model download and load in
        // the background as soon as the provider is created, so the user's
        // first push-to-talk doesn't have to pay the full download cost inline.
        speechModelLoader.beginPreloadingModelsIfNeeded()
    }

    var isConfigured: Bool {
        // The model self-downloads on first use, so the provider is usable in
        // every state except an outright load failure.
        switch speechModelLoader.modelAvailabilityStatus {
        case .failedToLoad:
            return false
        case .notStarted, .downloadingOrLoading, .ready:
            return true
        }
    }

    var unavailableExplanation: String? {
        switch speechModelLoader.modelAvailabilityStatus {
        case .notStarted, .ready:
            return nil
        case .downloadingOrLoading:
            return "The on-device Parakeet model is still downloading. Transcription will work once it finishes."
        case .failedToLoad(let failureReason):
            return "The on-device Parakeet model could not be loaded: \(failureReason)"
        }
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        return ParakeetTranscriptionSession(
            speechModelLoader: speechModelLoader,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class ParakeetTranscriptionSession: BuddyStreamingTranscriptionSession {
    // Parakeet transcribes the full utterance in one batch (not streaming), so
    // we use the same generous fallback delay OpenAI's batch provider uses.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    // Parakeet's CoreML encoder expects 16kHz mono audio, which is exactly what
    // BuddyPCM16AudioConverter produces.
    private static let targetSampleRate = 16_000

    private let speechModelLoader: ParakeetSpeechModelLoader
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.parakeet.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        speechModelLoader: ParakeetSpeechModelLoader,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.speechModelLoader = speechModelLoader
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let audioIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if audioIsEmpty {
            deliverFinalTranscript("")
            return
        }

        // Parakeet needs a minimum amount of audio (~0.3s) or its CoreML encoder
        // rejects the input with ASRError.invalidAudioData. Treat presses too
        // short to transcribe as an empty utterance instead of surfacing an error.
        let bufferedSampleCount = bufferedPCM16AudioData.count / MemoryLayout<Int16>.size
        let minimumRequiredSampleCount = ASRConstants.minimumRequiredSamples(
            forSampleRate: Self.targetSampleRate
        )
        if bufferedSampleCount < minimumRequiredSampleCount {
            deliverFinalTranscript("")
            return
        }

        do {
            // Awaiting here finishes immediately once the model is loaded. On a
            // cold first launch it waits for the background download/load that
            // the provider kicked off at init.
            let asrManager = try await speechModelLoader.loadedTranscriptionManager()
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            let transcriptText = try await transcribeLocally(
                using: asrManager,
                pcm16AudioData: bufferedPCM16AudioData
            )
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Parakeet Transcription] ❌ Local transcription failed (audio samples: \(bufferedSampleCount)): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func transcribeLocally(
        using asrManager: AsrManager,
        pcm16AudioData: Data
    ) async throws -> String {
        // Reuse the shared WAV builder so the on-device path produces audio in
        // the exact same format as the upload-based providers. FluidAudio reads
        // the file back through AVAudioFile and resamples as needed.
        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: pcm16AudioData,
            sampleRate: Self.targetSampleRate
        )

        let temporaryWAVFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-voice-input-\(UUID().uuidString).wav")
        try wavAudioData.write(to: temporaryWAVFileURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryWAVFileURL)
        }

        // Each utterance is transcribed from a fresh decoder state since we feed
        // the whole press at once rather than streaming overlapping chunks.
        var decoderState = TdtDecoderState.make(
            decoderLayers: await asrManager.decoderLayerCount
        )

        let transcriptionResult = try await asrManager.transcribe(
            temporaryWAVFileURL,
            decoderState: &decoderState
        )

        return transcriptionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        // Cancel the in-flight transcription Task directly. We must NOT call
        // cancel() here: its stateQueue.async closure strongly captures `self`,
        // which retains an object already at refcount zero while it is being
        // deallocated. That resurrection traps the Swift runtime with abort()
        // and crashes the whole app when a session deallocates after push-to-talk.
        // The Task already uses [weak self], so cancelling it is enough; the
        // buffered-state cleanup cancel() does is moot once the object is gone.
        transcriptionTask?.cancel()
    }
}

/// Loads the Parakeet CoreML models once and shares the resulting `AsrManager`
/// across every transcription session. The model bundle is large and slow to
/// download and compile, so reloading it per push-to-talk would be unusable.
///
/// `AsrManager` is an `actor`, so it is safe to hand the same instance to many
/// concurrent sessions. This loader only coordinates the one-time load and
/// exposes a synchronous status snapshot for the provider's `isConfigured` /
/// `unavailableExplanation` reads.
final class ParakeetSpeechModelLoader: @unchecked Sendable {
    static let shared = ParakeetSpeechModelLoader()

    enum ModelAvailabilityStatus {
        case notStarted
        case downloadingOrLoading
        case ready
        case failedToLoad(failureReason: String)
    }

    private let stateLock = NSLock()
    private var modelAvailabilityStatusStorage: ModelAvailabilityStatus = .notStarted
    private var loadedAsrManager: AsrManager?
    private var inFlightLoadTask: Task<AsrManager, Error>?

    private init() {}

    var modelAvailabilityStatus: ModelAvailabilityStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return modelAvailabilityStatusStorage
    }

    /// Starts the one-time download/load if it hasn't started yet. Safe to call
    /// repeatedly — only the first call kicks off real work.
    func beginPreloadingModelsIfNeeded() {
        _ = sharedLoadTask()
    }

    /// Returns the shared, fully-loaded `AsrManager`, awaiting the in-flight
    /// load (or starting one) if the model isn't ready yet.
    func loadedTranscriptionManager() async throws -> AsrManager {
        try await sharedLoadTask().value
    }

    private func sharedLoadTask() -> Task<AsrManager, Error> {
        stateLock.lock()

        if let inFlightLoadTask {
            stateLock.unlock()
            return inFlightLoadTask
        }

        if let loadedAsrManager {
            let alreadyLoadedManager = loadedAsrManager
            stateLock.unlock()
            return Task<AsrManager, Error> { alreadyLoadedManager }
        }

        modelAvailabilityStatusStorage = .downloadingOrLoading
        let loadTask = Task<AsrManager, Error> {
            do {
                let asrManager = try await Self.downloadAndLoadAsrManager()
                self.recordSuccessfullyLoaded(asrManager)
                return asrManager
            } catch {
                self.recordLoadFailure(error)
                throw error
            }
        }
        inFlightLoadTask = loadTask

        stateLock.unlock()
        return loadTask
    }

    private static func downloadAndLoadAsrManager() async throws -> AsrManager {
        // .v3 is FluidAudio's multilingual Parakeet TDT model. Downloads from
        // Hugging Face and compiles to CoreML on first run, then caches locally.
        let asrModels = try await AsrModels.downloadAndLoad(version: .v3)
        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(asrModels)
        print("🎙️ Parakeet: on-device model loaded and ready")
        return asrManager
    }

    private func recordSuccessfullyLoaded(_ asrManager: AsrManager) {
        stateLock.lock()
        defer { stateLock.unlock() }
        loadedAsrManager = asrManager
        modelAvailabilityStatusStorage = .ready
        // Drop the task reference now that the manager is cached; future calls
        // return the cached manager directly.
        inFlightLoadTask = nil
    }

    private func recordLoadFailure(_ error: Error) {
        stateLock.lock()
        defer { stateLock.unlock() }
        modelAvailabilityStatusStorage = .failedToLoad(failureReason: error.localizedDescription)
        // Clear the failed task so a later push-to-talk can retry the load.
        inFlightLoadTask = nil
    }
}
