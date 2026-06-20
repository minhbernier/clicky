//
//  AgentTaskPanelManager.swift
//  leanring-buddy
//
//  Manages the floating right-side task panel: a borderless, non-activating
//  NSPanel pinned to the right edge of the active screen that hosts
//  AgentTaskPanelView via NSHostingView. Mirrors the NSPanel pattern used by
//  MenuBarPanelManager so the two panels feel consistent.
//
//  Unlike the menu bar panel this one is not anchored to a status item — it
//  stays pinned to the right edge (per the HeyClicky-style layout). It auto-
//  shows when the first agent task appears and hides when all tasks are cleared
//  or the user closes it.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted to force the right-side task panel visible (e.g. when a new task
    /// is created after the user previously closed the panel).
    static let clickyShowAgentTaskPanel = Notification.Name("clickyShowAgentTaskPanel")
    /// Posted by the panel's close button to hide it until the next new task.
    static let clickyHideAgentTaskPanel = Notification.Name("clickyHideAgentTaskPanel")
}

/// NSPanel subclass that can become key even as a .nonactivatingPanel, so the
/// follow-up text field can receive keyboard focus.
private final class KeyableTaskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AgentTaskPanelManager: NSObject {
    private var panel: NSPanel?
    private let companionManager: CompanionManager
    private var cancellables = Set<AnyCancellable>()

    /// When the user explicitly closes the panel we keep it closed until they
    /// either start a brand-new task or the panel is force-shown. Without this,
    /// every task status change would immediately reopen the panel they dismissed.
    private var userClosedPanelManually = false
    private var lastObservedTaskCount = 0

    private let panelWidth: CGFloat = 320
    private let edgeMargin: CGFloat = 16

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        observeAgentTaskChanges()
        observeShowHideNotifications()
    }

    deinit {
        cancellables.removeAll()
    }

    // MARK: - Observation

    /// Auto-shows the panel when tasks exist and hides it when the list empties.
    /// A brand-new task (count increased) clears the manual-close flag so a fresh
    /// request always surfaces the panel.
    private func observeAgentTaskChanges() {
        companionManager.agentTaskStore.$agentTasks
            .receive(on: RunLoop.main)
            .sink { [weak self] agentTasks in
                guard let self else { return }
                let taskCount = agentTasks.count
                let aNewTaskWasAdded = taskCount > self.lastObservedTaskCount
                self.lastObservedTaskCount = taskCount

                if aNewTaskWasAdded {
                    self.userClosedPanelManually = false
                }

                if taskCount == 0 {
                    self.hidePanel()
                } else if !self.userClosedPanelManually {
                    self.showPanel()
                }
            }
            .store(in: &cancellables)
    }

    private func observeShowHideNotifications() {
        NotificationCenter.default.publisher(for: .clickyShowAgentTaskPanel)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.userClosedPanelManually = false
                self?.showPanel()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .clickyHideAgentTaskPanel)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.userClosedPanelManually = true
                self?.hidePanel()
            }
            .store(in: &cancellables)
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }
        positionPanelOnRightEdge()
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let agentTaskPanelView = AgentTaskPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: agentTaskPanelView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let taskPanel = KeyableTaskPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        taskPanel.isFloatingPanel = true
        taskPanel.level = .floating
        taskPanel.isOpaque = false
        taskPanel.backgroundColor = .clear
        taskPanel.hasShadow = false
        taskPanel.hidesOnDeactivate = false
        taskPanel.isExcludedFromWindowsMenu = true
        taskPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        taskPanel.isMovableByWindowBackground = false
        taskPanel.titleVisibility = .hidden
        taskPanel.titlebarAppearsTransparent = true
        taskPanel.contentView = hostingView

        panel = taskPanel
    }

    /// Pins the panel to the right edge of the active screen, vertically
    /// centered. Uses the screen under the mouse so the panel appears on the
    /// display the user is currently working on, falling back to the main screen.
    private func positionPanelOnRightEdge() {
        guard let panel else { return }

        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let activeScreen else { return }

        let visibleFrame = activeScreen.visibleFrame

        // Let the SwiftUI content decide its own height, capped to the screen.
        let fittingHeight = panel.contentView?.fittingSize.height ?? 480
        let panelHeight = min(fittingHeight, visibleFrame.height - edgeMargin * 2)

        let panelOriginX = visibleFrame.maxX - panelWidth - edgeMargin
        let panelOriginY = visibleFrame.minY + (visibleFrame.height - panelHeight) / 2.0

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
            display: true
        )
    }
}
