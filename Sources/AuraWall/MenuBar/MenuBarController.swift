import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let coordinator: AppCoordinator
    private let onOpenMainWindow: () -> Void
    private let onQuit: () -> Void

    private var statusItem: NSStatusItem?
    private let popover: NSPopover

    init(
        coordinator: AppCoordinator,
        onOpenMainWindow: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.onOpenMainWindow = onOpenMainWindow
        self.onQuit = onQuit

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 336, height: 470)
        self.popover = popover

        super.init()

        let hostingController = NSHostingController(
            rootView: MenuBarPopoverView(
                coordinator: coordinator,
                onOpenMainWindow: { [weak self] in
                    self?.closePopover()
                    onOpenMainWindow()
                },
                onQuit: { [weak self] in
                    self?.closePopover()
                    onQuit()
                }
            )
        )
        popover.contentViewController = hostingController

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let symbolImage = NSImage(
                systemSymbolName: "sparkles.tv",
                accessibilityDescription: "AuraWall"
            ) ?? NSImage(
                systemSymbolName: "desktopcomputer",
                accessibilityDescription: "AuraWall"
            )
            symbolImage?.isTemplate = true
            button.image = symbolImage
            button.imagePosition = .imageOnly
            button.toolTip = "AuraWall — Works in background"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        self.statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: false)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func teardown() {
        closePopover()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }
}
