import CoreGraphics
import Foundation
import os
import Testing
@testable import AuraWallCore

@Suite("PowerMonitor and DisplayManager Tests")
struct PowerMonitorAndDisplayManagerTests {
    private static func makeCGWindow(
        layer: Int = 0,
        alpha: Double = 1.0,
        isOnscreen: Bool = true,
        ownerPID: Int32 = 12345,
        ownerName: String = "Safari",
        bounds: CGRect
    ) -> [String: Any] {
        [
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowIsOnscreen as String: isOnscreen,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowOwnerName as String: ownerName,
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary
        ]
    }

    // MARK: - FullscreenDetector & Coordinate Geometry

    @Test("FullscreenDetector detects >=98% overlap in Quartz coordinates and skips <98%")
    func fullscreenOverlapThreshold() {
        let displays: [(id: UInt32, bounds: CGRect)] = [
            (id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            (id: 2, bounds: CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        ]

        // 97.9% coverage on display 1 -> NOT occluded
        let belowThreshold = Self.makeCGWindow(bounds: CGRect(x: 0, y: 21, width: 1000, height: 979))
        #expect(FullscreenDetector.occludedDisplayIDs(windowList: [belowThreshold], displays: displays, ownPID: 999) == [])

        // 98.0% coverage on display 1 -> occluded
        let atThreshold = Self.makeCGWindow(bounds: CGRect(x: 0, y: 20, width: 1000, height: 980))
        #expect(FullscreenDetector.occludedDisplayIDs(windowList: [atThreshold], displays: displays, ownPID: 999) == [1])

        // Full coverage on secondary display at negative Y Quartz coordinate
        let secondaryDisplays: [(id: UInt32, bounds: CGRect)] = [
            (id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            (id: 2, bounds: CGRect(x: 0, y: -1440, width: 2560, height: 1440))
        ]
        let upperFullscreen = Self.makeCGWindow(bounds: CGRect(x: 0, y: -1440, width: 2560, height: 1440))
        #expect(PowerMonitor.occludedDisplayIDs(windowList: [upperFullscreen], displays: secondaryDisplays, ownPID: 999) == [2])
    }

    @Test("FullscreenDetector filters out non-zero layers, invisible/offscreen windows, own PID, and system UI")
    func fullscreenFilteringRules() {
        let displays: [(id: UInt32, bounds: CGRect)] = [
            (id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        let fullRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let ownPID: Int32 = 4242

        let ignoredWindows: [[String: Any]] = [
            Self.makeCGWindow(layer: 1, ownerPID: 100, ownerName: "App1", bounds: fullRect),
            Self.makeCGWindow(layer: -1, ownerPID: 100, ownerName: "App2", bounds: fullRect),
            Self.makeCGWindow(layer: 0, alpha: 0.0, ownerPID: 100, ownerName: "App3", bounds: fullRect),
            Self.makeCGWindow(layer: 0, alpha: 1.0, isOnscreen: false, ownerPID: 100, ownerName: "App4", bounds: fullRect),
            Self.makeCGWindow(layer: 0, ownerPID: ownPID, ownerName: "AuraWall", bounds: fullRect),
            Self.makeCGWindow(layer: 0, ownerPID: 101, ownerName: "Dock", bounds: fullRect),
            Self.makeCGWindow(layer: 0, ownerPID: 102, ownerName: "Window Server", bounds: fullRect),
            Self.makeCGWindow(layer: 0, ownerPID: 103, ownerName: "WindowServer", bounds: fullRect),
            Self.makeCGWindow(layer: 0, ownerPID: 104, ownerName: "SystemUIServer", bounds: fullRect),
            Self.makeCGWindow(layer: 0, ownerPID: 105, ownerName: "Control Center", bounds: fullRect),
            Self.makeCGWindow(layer: 0, ownerPID: 106, ownerName: "Notification Center", bounds: fullRect)
        ]

        #expect(FullscreenDetector.occludedDisplayIDs(windowList: ignoredWindows, displays: displays, ownPID: ownPID).isEmpty)

        // Works without kCGWindowName present
        let validNoNameWindow = Self.makeCGWindow(ownerPID: 555, ownerName: "VLC", bounds: fullRect)
        #expect(validNoNameWindow["kCGWindowName"] == nil)
        #expect(FullscreenDetector.occludedDisplayIDs(windowList: [validNoNameWindow], displays: displays, ownPID: ownPID) == [1])
    }

    // MARK: - PowerMonitor State & Lifecycle

    @MainActor
    @Test("PowerMonitor deduplicates emissions, tracks battery/fullscreen, and resets override on AC restore")
    func powerMonitorStateTransitionsAndOverrideReset() {
        let onBatteryState = OSAllocatedUnfairLock<Bool>(initialState: false)
        let showFullscreenState = OSAllocatedUnfairLock<Bool>(initialState: false)
        let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let monitor = PowerMonitor(
            initialSettings: PowerSettings(pauseOnBattery: true, pauseOnFullscreen: true, pauseOnScreenLockOrSleep: true),
            occlusionPollingInterval: 0,
            batteryStateProvider: { onBatteryState.withLock { $0 } },
            windowListProvider: {
                showFullscreenState.withLock { $0 }
                    ? [Self.makeCGWindow(ownerPID: 7777, ownerName: "IINA", bounds: displayBounds)]
                    : []
            },
            displaysProvider: { [(id: UInt32(1), bounds: displayBounds)] }
        )

        var emitted: [PowerInputs] = []
        monitor.onInputsChanged = { emitted.append($0) }

        // No change -> no emission
        monitor.refreshNow()
        #expect(emitted.isEmpty)

        // Switch to battery
        onBatteryState.withLock { $0 = true }
        monitor.refreshNow()
        #expect(emitted.count == 1)
        #expect(monitor.inputs.onBattery == true)
        #expect(monitor.inputs.batteryOverrideActive == false)

        // Duplicate refresh -> no extra emission
        monitor.refreshNow()
        #expect(emitted.count == 1)

        // Activate battery override
        monitor.setBatteryOverride(true)
        #expect(emitted.count == 2)
        #expect(monitor.inputs.batteryOverrideActive == true)

        // Restore AC power -> batteryOverrideActive resets to false automatically
        onBatteryState.withLock { $0 = false }
        monitor.refreshNow()
        #expect(emitted.count == 3)
        #expect(monitor.inputs.onBattery == false)
        #expect(monitor.inputs.batteryOverrideActive == false)

        // Fullscreen occlusion update
        showFullscreenState.withLock { $0 = true }
        monitor.refreshNow()
        #expect(emitted.count == 4)
        #expect(monitor.inputs.fullscreenDisplayIDs == [1])

        // Manual pause & settings update
        monitor.setManualPause(true)
        #expect(monitor.inputs.manualPause == true)
        monitor.applySettings(PowerSettings(pauseOnBattery: false, pauseOnFullscreen: false, pauseOnScreenLockOrSleep: false))
        #expect(monitor.inputs.pauseOnBatteryEnabled == false)
        #expect(monitor.inputs.pauseOnFullscreenEnabled == false)
        #expect(monitor.inputs.pauseOnLockSleepEnabled == false)
    }

    @MainActor
    @Test("PowerMonitor start/stop lifecycle and host battery read do not crash")
    func powerMonitorStartStopLifecycle() {
        _ = PowerMonitor.isOnBatteryPower()
        let monitor = PowerMonitor(
            occlusionPollingInterval: 0,
            batteryStateProvider: { false },
            windowListProvider: { [] },
            displaysProvider: { [] }
        )
        monitor.start()
        #expect(monitor.isMonitoring == true)
        monitor.stop()
        #expect(monitor.isMonitoring == false)
        monitor.stop()
        #expect(monitor.isMonitoring == false)
    }

    // MARK: - DisplayManager

    @MainActor
    @Test("DisplayManager handles empty screens safely and resolves mirror/independent configs")
    func displayManagerEmptyScreensAndAssignmentResolution() {
        let emptyManager = DisplayManager(screensProvider: { [] })
        #expect(emptyManager.displays.isEmpty)
        #expect(emptyManager.screen(for: 1) == nil)
        #expect(emptyManager.displayInfo(for: 1) == nil)
        emptyManager.startMonitoring()
        emptyManager.refreshDisplays()
        emptyManager.stopMonitoring()

        let d1 = DisplayInfo(id: 101, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
        let d2 = DisplayInfo(id: 202, name: "External 4K", frame: CGRect(x: 1512, y: 0, width: 3840, height: 2160), isMain: false)
        let w1 = WallpaperItem(id: "w1", title: "W1", source: .starter, mediaType: .video)
        let w2 = WallpaperItem(id: "w2", title: "W2", source: .wallhaven, mediaType: .image)
        let mirrorW = WallpaperItem(id: "wm", title: "Mirror", source: .starter, mediaType: .video)

        // Independent with both connected
        var config = DisplayConfig(
            mode: .independent,
            assignments: [
                DisplayConfig.key(for: 101): DisplayAssignment(displayID: 101, displayName: "Built-in", wallpaper: w1, scalingMode: .fill),
                DisplayConfig.key(for: 202): DisplayAssignment(displayID: 202, displayName: "External 4K", wallpaper: w2, scalingMode: .fit),
                DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: mirrorW, scalingMode: .fill)
            ]
        )

        let bothResolved = DisplayManager.resolveAssignments(config: config, connectedDisplays: [d1, d2])
        #expect(bothResolved.count == 2)
        #expect(bothResolved[0].assignment.wallpaper?.id == "w1")
        #expect(bothResolved[1].assignment.wallpaper?.id == "w2")
        #expect(bothResolved[1].assignment.scalingMode == .fit)

        // Unplug display 202 -> resolved drops 202 while config.assignments preserves 202
        let unpluggedResolved = DisplayManager.resolveAssignments(config: config, connectedDisplays: [d1])
        #expect(unpluggedResolved.count == 1)
        #expect(unpluggedResolved[0].display.id == 101)
        #expect(config.assignments[DisplayConfig.key(for: 202)]?.wallpaper?.id == "w2")

        // Mirror mode resolves mirror wallpaper for all connected displays
        config.mode = .mirrorAll
        let mirrorResolved = DisplayManager.resolveAssignments(config: config, connectedDisplays: [d1, d2])
        #expect(mirrorResolved.count == 2)
        #expect(mirrorResolved.allSatisfy { $0.assignment.wallpaper?.id == "wm" })

        // Replug in independent mode -> restores display 202 assignment automatically
        config.mode = .independent
        let repluggedResolved = DisplayManager.resolveAssignments(config: config, connectedDisplays: [d1, d2])
        #expect(repluggedResolved.count == 2)
        #expect(repluggedResolved[1].assignment.wallpaper?.id == "w2")
    }
}
