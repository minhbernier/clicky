//
//  ConnectorRecommendationManager.swift
//  leanring-buddy
//
//  Presents the connector-recommendation popup as a floating, non-activating
//  NSPanel near the top-center of the active screen — Micky's equivalent of the
//  HeyClicky "Connect Discord to …" banner. Observes
//  CompanionManager.pendingConnectorRecommendation and shows/hides the card as
//  recommendations arrive and are answered. Mirrors AgentTaskPanelManager's
//  NSPanel pattern so the floating surfaces feel consistent.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ConnectorRecommendationManager: NSObject {
    private var panel: NSPanel?
    private let companionManager: CompanionManager
    private var cancellables = Set<AnyCancellable>()

    private let panelWidth: CGFloat = 420
    private let topMargin: CGFloat = 24

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        observePendingRecommendation()
    }

    deinit {
        cancellables.removeAll()
    }

    // MARK: - Observation

    /// Show the popup whenever a recommendation is pending; tear it down when it
    /// is cleared (the user answered, or it was superseded).
    private func observePendingRecommendation() {
        companionManager.$pendingConnectorRecommendation
            .receive(on: RunLoop.main)
            .sink { [weak self] recommendation in
                guard let self else { return }
                if let recommendation {
                    self.showPanel(for: recommendation)
                } else {
                    self.hidePanel()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Panel lifecycle

    private func showPanel(for recommendation: ConnectorRecommendation) {
        let recommendationView = ConnectorRecommendationView(
            recommendation: recommendation,
            onConnect: { [weak self] in
                self?.companionManager.acceptConnectorRecommendation(recommendation)
            },
            onNotNow: { [weak self] in
                self?.companionManager.snoozeConnectorRecommendation(recommendation)
            },
            onDecline: { [weak self] in
                self?.companionManager.declineConnectorRecommendation(recommendation)
            }
        )

        let hostingView = NSHostingView(rootView: recommendationView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        // Recreate the panel each time so it always sizes to the current card.
        hidePanel()

        let recommendationPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        recommendationPanel.isFloatingPanel = true
        recommendationPanel.level = .floating
        recommendationPanel.isOpaque = false
        recommendationPanel.backgroundColor = .clear
        recommendationPanel.hasShadow = false
        recommendationPanel.hidesOnDeactivate = false
        recommendationPanel.isExcludedFromWindowsMenu = true
        recommendationPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        recommendationPanel.isMovableByWindowBackground = false
        recommendationPanel.titleVisibility = .hidden
        recommendationPanel.titlebarAppearsTransparent = true
        recommendationPanel.contentView = hostingView

        panel = recommendationPanel
        positionPanelTopCenter()
        recommendationPanel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Pin the popup to the top-center of the screen under the mouse (where the
    /// user is working), falling back to the main screen.
    private func positionPanelTopCenter() {
        guard let panel else { return }

        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let activeScreen else { return }

        let visibleFrame = activeScreen.visibleFrame
        let fittingHeight = panel.contentView?.fittingSize.height ?? 240

        let panelOriginX = visibleFrame.minX + (visibleFrame.width - panelWidth) / 2.0
        let panelOriginY = visibleFrame.maxY - fittingHeight - topMargin

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: fittingHeight),
            display: true
        )
    }
}
