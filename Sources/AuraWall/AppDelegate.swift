import AppKit
import Darwin
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    var openMainWindowAction: (() -> Void)?

    private var menuBarController: MenuBarController?
    private var sigtermSource: DispatchSourceSignal?
    private weak var mainWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installSigtermHandler()

        menuBarController = MenuBarController(
            coordinator: coordinator,
            onOpenMainWindow: { [weak self] in
                self?.reopenMainWindow()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        Task { @MainActor [weak self] in
            await self?.coordinator.bootstrap()
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            reopenMainWindow()
        } else {
            NSApp.setActivationPolicy(.regular)
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        sigtermSource?.cancel()
        sigtermSource = nil

        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()

        menuBarController?.teardown()
        menuBarController = nil

        coordinator.shutdown()
    }

    func registerMainWindow(_ window: NSWindow) {
        if mainWindow === window {
            return
        }
        mainWindow = window

        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()

        coordinator.isMainWindowVisible = window.isVisible && !window.isMiniaturized

        let center = NotificationCenter.default
        windowObservers.append(
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMainWindowClosed()
                }
            }
        )

        windowObservers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.coordinator.isMainWindowVisible = true
                }
            }
        )

        windowObservers.append(
            center.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.coordinator.isMainWindowVisible = false
                }
            }
        )

        windowObservers.append(
            center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.coordinator.isMainWindowVisible = true
                }
            }
        )
    }

    func reopenMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let mainWindow {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
        coordinator.isMainWindowVisible = true
    }

    private func handleMainWindowClosed() {
        coordinator.isMainWindowVisible = false
        if coordinator.settings.launchInBackgroundOnClose {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          !self.coordinator.isMainWindowVisible,
                          self.coordinator.settings.launchInBackgroundOnClose else {
                        return
                    }
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    private func installSigtermHandler() {
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
        source.resume()
        sigtermSource = source
    }
}
