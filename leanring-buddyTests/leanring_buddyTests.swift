//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func handsFreeConversationEndPhrasesAreStrictAndPunctuationInsensitive() async throws {
        #expect(CompanionManager.isHandsFreeConversationEndTranscript("That's all, Micky."))
        #expect(CompanionManager.isHandsFreeConversationEndTranscript("Micky—that is all"))
        #expect(CompanionManager.isHandsFreeConversationEndTranscript("Stop listening, Micky!"))
        // STT often spells the wake-name "Mickey" — both must match.
        #expect(CompanionManager.isHandsFreeConversationEndTranscript("Goodbye Mickey"))
        #expect(CompanionManager.isHandsFreeConversationEndTranscript("That's all, Mickey."))
        #expect(!CompanionManager.isHandsFreeConversationEndTranscript("That's all I know, Micky."))
        #expect(!CompanionManager.isHandsFreeConversationEndTranscript("Thanks for listening, Micky."))
        #expect(!CompanionManager.isHandsFreeConversationEndTranscript("Stop listening to that song, Micky."))
    }

    @Test func handsFreeEndPhraseIsConsumedOnlyDuringAnActiveSession() async throws {
        let phrase = "That's all, Micky."
        #expect(!CompanionManager.shouldEndHandsFreeConversation(
            transcript: phrase,
            isEnabled: false,
            isSessionActive: true,
            isAutoListening: true
        ))
        #expect(!CompanionManager.shouldEndHandsFreeConversation(
            transcript: phrase,
            isEnabled: true,
            isSessionActive: false,
            isAutoListening: false
        ))
        #expect(CompanionManager.shouldEndHandsFreeConversation(
            transcript: phrase,
            isEnabled: true,
            isSessionActive: true,
            isAutoListening: false
        ))
        #expect(CompanionManager.shouldEndHandsFreeConversation(
            transcript: phrase,
            isEnabled: true,
            isSessionActive: false,
            isAutoListening: true
        ))
    }

}
