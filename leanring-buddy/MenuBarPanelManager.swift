//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var panelDidMoveObserver: NSObjectProtocol?

    /// True while we set the panel frame ourselves, so the didMove handler can
    /// tell a programmatic reposition apart from a real user drag and avoid
    /// overwriting the saved origin with the anchored one.
    private var isApplyingProgrammaticFrame = false

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    // UserDefaults keys for remembering where the user dragged the panel.
    private let savedPanelOriginXKey = "menuBarPanelSavedOriginX"
    private let savedPanelOriginYKey = "menuBarPanelSavedOriginY"

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = panelDidMoveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeMickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Builds a distinct menu bar icon for Micky so it isn't confused with the
    /// real HeyClicky (whose icon is the triangle cursor). Uses the "m.circle"
    /// SF Symbol — a clear "M" mark — rendered as a template image so it adapts
    /// to light/dark menu bars. Falls back to drawing an "M" if the symbol is
    /// somehow unavailable.
    private func makeMickyMenuBarIcon() -> NSImage {
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if let symbolImage = NSImage(systemSymbolName: "m.circle", accessibilityDescription: "Micky")?
            .withSymbolConfiguration(symbolConfiguration) {
            return symbolImage
        }

        // Fallback: draw a bold "M" glyph centered in the icon.
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let glyph = NSAttributedString(string: "M", attributes: attributes)
        let glyphSize = glyph.size()
        glyph.draw(at: NSPoint(x: (iconSize - glyphSize.width) / 2, y: (iconSize - glyphSize.height) / 2))
        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanel()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Let the user drag the panel by its background to reposition it. The
        // SwiftUI controls still receive clicks; only drags on empty background
        // move the window. The new position is remembered (see panelDidMove).
        menuBarPanel.isMovableByWindowBackground = true
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel

        // Persist the panel's origin whenever the user drags it so it reopens
        // where they left it. Programmatic repositioning is ignored via the flag.
        panelDidMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: menuBarPanel,
            queue: .main
        ) { [weak self] _ in
            guard let self, let movedPanel = self.panel, !self.isApplyingProgrammaticFrame else { return }
            self.savePanelOrigin(movedPanel.frame.origin)
        }
    }

    /// Positions the panel before showing it. If the user previously dragged it
    /// somewhere (and that spot is still on a connected screen), reopen it there;
    /// otherwise fall back to anchoring it under the status item like a normal
    /// menu-bar dropdown.
    private func positionPanel() {
        guard let panel else { return }

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        let panelOrigin: NSPoint
        if let savedOrigin = savedPanelOriginIfStillOnScreen(panelHeight: actualPanelHeight) {
            panelOrigin = savedOrigin
        } else {
            panelOrigin = anchoredOriginBelowStatusItem(panelHeight: actualPanelHeight)
        }

        // Mark this as a programmatic move so the didMove observer doesn't treat
        // it as a user drag and overwrite the saved origin.
        isApplyingProgrammaticFrame = true
        panel.setFrame(
            NSRect(x: panelOrigin.x, y: panelOrigin.y, width: panelWidth, height: actualPanelHeight),
            display: true
        )
        // Clear the flag on the next runloop tick, after the synchronous didMove
        // notification from setFrame has already been delivered and ignored.
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingProgrammaticFrame = false
        }
    }

    /// The default anchored origin: horizontally centered beneath the status item.
    private func anchoredOriginBelowStatusItem(panelHeight: CGFloat) -> NSPoint {
        guard let buttonWindow = statusItem?.button?.window else {
            // No status item window yet — fall back to the main screen's top-right.
            let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: visibleFrame.maxX - panelWidth - 8, y: visibleFrame.maxY - panelHeight - 8)
        }
        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - panelHeight - gapBelowMenuBar
        return NSPoint(x: panelOriginX, y: panelOriginY)
    }

    /// Returns the saved drag position only if it still lands on a connected
    /// screen (so unplugging a monitor doesn't strand the panel off-screen).
    private func savedPanelOriginIfStillOnScreen(panelHeight: CGFloat) -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: savedPanelOriginXKey) != nil,
              defaults.object(forKey: savedPanelOriginYKey) != nil else {
            return nil
        }
        let savedOrigin = NSPoint(
            x: defaults.double(forKey: savedPanelOriginXKey),
            y: defaults.double(forKey: savedPanelOriginYKey)
        )
        let panelRect = NSRect(x: savedOrigin.x, y: savedOrigin.y, width: panelWidth, height: panelHeight)
        // Require a meaningful overlap with some screen's visible area.
        let isMostlyOnScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersection(panelRect).height > 40
        }
        return isMostlyOnScreen ? savedOrigin : nil
    }

    private func savePanelOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: savedPanelOriginXKey)
        UserDefaults.standard.set(origin.y, forKey: savedPanelOriginYKey)
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
