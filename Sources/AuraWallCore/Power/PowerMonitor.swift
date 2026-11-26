import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import os

public enum FullscreenDetector: Sendable {
    public static let defaultCoverageThreshold: Double = 0.98

    public static let ignoredOwnerNames: Set<String> = [
        "Dock",
        "Window Server",
        "WindowServer",
        "SystemUIServer",
        "Control Center",
        "ControlCenter",
        "Notification Center",
        "NotificationCenter"
    ]

    nonisolated public static func occludedDisplayIDs(
        windowList: [[String: Any]],
        displays: [(id: UInt32, bounds: CGRect)],
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        coverageThreshold: Double = defaultCoverageThreshold
    ) -> Set<UInt32> {
        guard !displays.isEmpty, !windowList.isEmpty else {
            return []
        }

        let layerKey = kCGWindowLayer as String
        let alphaKey = kCGWindowAlpha as String
        let onscreenKey = kCGWindowIsOnscreen as String
        let ownerPIDKey = kCGWindowOwnerPID as String
        let ownerNameKey = kCGWindowOwnerName as String
        let boundsKey = kCGWindowBounds as String

        var occluded: Set<UInt32> = []

        for window in windowList {
            guard let layer = (window[layerKey] as? NSNumber)?.intValue, layer == 0 else {
                continue
            }
            if let alpha = (window[alphaKey] as? NSNumber)?.doubleValue, alpha <= 0.0 {
                continue
            }
            if let isOnscreen = (window[onscreenKey] as? NSNumber)?.boolValue, !isOnscreen {
                continue
            }
            if let pid = (window[ownerPIDKey] as? NSNumber)?.int32Value, pid == ownPID {
                continue
            }
            if let ownerName = window[ownerNameKey] as? String,
               ignoredOwnerNames.contains(ownerName.trimmingCharacters(in: .whitespacesAndNewlines)) {
                continue
            }

            let windowBounds: CGRect
            if let boundsDict = window[boundsKey] as? NSDictionary,
               let parsed = CGRect(dictionaryRepresentation: boundsDict) {
                windowBounds = parsed
            } else if let directRect = window[boundsKey] as? CGRect {
                windowBounds = directRect
            } else {
                continue
            }

            guard !windowBounds.isNull, !windowBounds.isEmpty, windowBounds.width > 0, windowBounds.height > 0 else {
                continue
            }

            for (displayID, displayBounds) in displays {
                let displayArea = Double(displayBounds.width * displayBounds.height)
                guard displayArea > 0 else { continue }

                let intersection = windowBounds.intersection(displayBounds)
                guard !intersection.isNull, !intersection.isEmpty else { continue }

                let intersectionArea = Double(intersection.width * intersection.height)
                if (intersectionArea / displayArea) >= coverageThreshold {
                    occluded.insert(displayID)
                }
            }
        }

        return occluded
    }
}

private final class PowerCallbackBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(handler: @escaping @Sendable () -> Void) {
        lock.withLock { $0 = handler }
    }

    func fire() {
        let handler = lock.withLock { $0 }
        handler?()
    }

    func invalidate() {
        lock.withLock { $0 = nil }
    }
}

private func iopsPowerSourceCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<PowerCallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.fire()
}

@MainActor
public final class PowerMonitor {
    public typealias BatteryStateProvider = @Sendable () -> Bool
    public typealias WindowListProvider = @Sendable () -> [[String: Any]]
    public typealias DisplaysProvider = @MainActor () -> [(id: UInt32, bounds: CGRect)]

    private struct UncheckedRunLoopSource: @unchecked Sendable {
        let source: CFRunLoopSource
    }

    private struct UncheckedRawPointer: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
    }

    private struct UncheckedObserverToken: @unchecked Sendable {
        let token: NSObjectProtocol
    }

    private struct UncheckedNotificationCenter: @unchecked Sendable {
        let center: NotificationCenter
    }

    private final class MonitorTeardownResources: @unchecked Sendable {
        private struct State {
            var isRunning = false
            var runLoopSource: UncheckedRunLoopSource?
            var callbackBox: PowerCallbackBox?
            var callbackBoxPointer: UncheckedRawPointer?
            var workspaceCenter: UncheckedNotificationCenter?
            var distributedCenter: UncheckedNotificationCenter?
            var defaultCenter: UncheckedNotificationCenter?
            var workspaceObservers: [UncheckedObserverToken] = []
            var distributedObservers: [UncheckedObserverToken] = []
            var defaultObservers: [UncheckedObserverToken] = []
            var pollingTask: Task<Void, Never>?
        }

        private let lock = OSAllocatedUnfairLock<State>(initialState: State())

        var isRunning: Bool {
            lock.withLock { $0.isRunning }
        }

        func install(
            runLoopSource: CFRunLoopSource?,
            callbackBox: PowerCallbackBox?,
            callbackBoxPointer: UnsafeMutableRawPointer?,
            workspaceCenter: NotificationCenter,
            distributedCenter: NotificationCenter,
            defaultCenter: NotificationCenter,
            workspaceObservers: [NSObjectProtocol],
            distributedObservers: [NSObjectProtocol],
            defaultObservers: [NSObjectProtocol],
            pollingTask: Task<Void, Never>?
        ) {
            let wrappedSource = runLoopSource.map { UncheckedRunLoopSource(source: $0) }
            let wrappedPtr = callbackBoxPointer.map { UncheckedRawPointer(pointer: $0) }
            let wrappedWSCenter = UncheckedNotificationCenter(center: workspaceCenter)
            let wrappedDistCenter = UncheckedNotificationCenter(center: distributedCenter)
            let wrappedDefCenter = UncheckedNotificationCenter(center: defaultCenter)
            let wrappedWS = workspaceObservers.map { UncheckedObserverToken(token: $0) }
            let wrappedDist = distributedObservers.map { UncheckedObserverToken(token: $0) }
            let wrappedDef = defaultObservers.map { UncheckedObserverToken(token: $0) }

            lock.withLock { state in
                state.isRunning = true
                state.runLoopSource = wrappedSource
                state.callbackBox = callbackBox
                state.callbackBoxPointer = wrappedPtr
                state.workspaceCenter = wrappedWSCenter
                state.distributedCenter = wrappedDistCenter
                state.defaultCenter = wrappedDefCenter
                state.workspaceObservers = wrappedWS
                state.distributedObservers = wrappedDist
                state.defaultObservers = wrappedDef
                state.pollingTask = pollingTask
            }
        }

        func cleanup() {
            let captured = lock.withLock { state -> (
                UncheckedRunLoopSource?,
                PowerCallbackBox?,
                UncheckedRawPointer?,
                UncheckedNotificationCenter?,
                UncheckedNotificationCenter?,
                UncheckedNotificationCenter?,
                [UncheckedObserverToken],
                [UncheckedObserverToken],
                [UncheckedObserverToken],
                Task<Void, Never>?
            ) in
                let result = (
                    state.runLoopSource,
                    state.callbackBox,
                    state.callbackBoxPointer,
                    state.workspaceCenter,
                    state.distributedCenter,
                    state.defaultCenter,
                    state.workspaceObservers,
                    state.distributedObservers,
                    state.defaultObservers,
                    state.pollingTask
                )
                state.isRunning = false
                state.runLoopSource = nil
                state.callbackBox = nil
                state.callbackBoxPointer = nil
                state.workspaceCenter = nil
                state.distributedCenter = nil
                state.defaultCenter = nil
                state.workspaceObservers = []
                state.distributedObservers = []
                state.defaultObservers = []
                state.pollingTask = nil
                return result
            }

            captured.9?.cancel()
            captured.1?.invalidate()

            if let sourceWrapper = captured.0 {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), sourceWrapper.source, .commonModes)
                CFRunLoopSourceInvalidate(sourceWrapper.source)
            }

            if let rawPtrWrapper = captured.2 {
                DispatchQueue.main.async {
                    Unmanaged<PowerCallbackBox>.fromOpaque(rawPtrWrapper.pointer).release()
                }
            }

            let wsCenter = captured.3
            let distCenter = captured.4
            let defCenter = captured.5
            let wsObservers = captured.6
            let distObservers = captured.7
            let defObservers = captured.8

            if !wsObservers.isEmpty || !distObservers.isEmpty || !defObservers.isEmpty {
                let removeAll = { @Sendable in
                    if let wsCenter {
                        for observer in wsObservers {
                            wsCenter.center.removeObserver(observer.token)
                        }
                    }
                    if let distCenter {
                        for observer in distObservers {
                            distCenter.center.removeObserver(observer.token)
                        }
                    }
                    if let defCenter {
                        for observer in defObservers {
                            defCenter.center.removeObserver(observer.token)
                        }
                    }
                }

                if Thread.isMainThread {
                    removeAll()
                } else {
                    DispatchQueue.main.async(execute: removeAll)
                }
            }
        }
    }

    public private(set) var inputs: PowerInputs
    public var onInputsChanged: ((PowerInputs) -> Void)?

    private let occlusionPollingInterval: TimeInterval
    private let batteryStateProvider: BatteryStateProvider
    private let windowListProvider: WindowListProvider
    private let displaysProvider: DisplaysProvider
    private let workspaceNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: NotificationCenter
    private let defaultNotificationCenter: NotificationCenter
    private let teardownResources = MonitorTeardownResources()

    public init(
        initialSettings: PowerSettings = PowerSettings(),
        occlusionPollingInterval: TimeInterval = 2.0,
        batteryStateProvider: BatteryStateProvider? = nil,
        windowListProvider: WindowListProvider? = nil,
        displaysProvider: DisplaysProvider? = nil,
        workspaceNotificationCenter: NotificationCenter? = nil,
        distributedNotificationCenter: NotificationCenter? = nil,
        defaultNotificationCenter: NotificationCenter? = nil
    ) {
        var initial = PowerInputs()
        initial.applying(settings: initialSettings)
        self.inputs = initial
        self.occlusionPollingInterval = occlusionPollingInterval
        self.batteryStateProvider = batteryStateProvider ?? { PowerMonitor.isOnBatteryPower() }
        self.windowListProvider = windowListProvider ?? {
            guard let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] else {
                return []
            }
            return info
        }
        self.displaysProvider = displaysProvider ?? {
            NSScreen.screens.compactMap { screen in
                guard let id = DisplayManager.displayID(for: screen) else {
                    return nil
                }
                return (id: id, bounds: CGDisplayBounds(id))
            }
        }
        self.workspaceNotificationCenter = workspaceNotificationCenter ?? NSWorkspace.shared.notificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter ?? DistributedNotificationCenter.default()
        self.defaultNotificationCenter = defaultNotificationCenter ?? NotificationCenter.default
        refreshState(notifyIfChanged: false)
    }

    deinit {
        teardownResources.cleanup()
    }

    public var isMonitoring: Bool {
        teardownResources.isRunning
    }

    public func start() {
        stop()

        let box = PowerCallbackBox { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshBatteryState()
            }
        }
        let retainedPtr = Unmanaged.passRetained(box).toOpaque()
        var runLoopSource: CFRunLoopSource?
        if let unmanagedSource = IOPSNotificationCreateRunLoopSource(iopsPowerSourceCallback, retainedPtr) {
            let source = unmanagedSource.takeRetainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        } else {
            Unmanaged<PowerCallbackBox>.fromOpaque(retainedPtr).release()
        }

        let wsCenter = workspaceNotificationCenter
        var wsObservers: [NSObjectProtocol] = []
        wsObservers.append(wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplayAsleep(true) }
        })
        wsObservers.append(wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplayAsleep(true) }
        })
        wsObservers.append(wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
        wsObservers.append(wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
        wsObservers.append(wsCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScreenLocked(true) }
        })
        wsObservers.append(wsCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUnlock() }
        })
        wsObservers.append(wsCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOcclusionState() }
        })
        wsObservers.append(wsCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOcclusionState() }
        })

        let distCenter = distributedNotificationCenter
        var distObservers: [NSObjectProtocol] = []
        distObservers.append(distCenter.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScreenLocked(true) }
        })
        distObservers.append(distCenter.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUnlock() }
        })

        let defCenter = defaultNotificationCenter
        let defObservers: [NSObjectProtocol] = [
            defCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshOcclusionState() }
            }
        ]

        let interval = occlusionPollingInterval
        let pollingTask: Task<Void, Never>?
        if interval > 0 {
            pollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled, let self else { break }
                    if !self.inputs.displayAsleep && !self.inputs.screenLocked {
                        self.refreshOcclusionState()
                    }
                }
            }
        } else {
            pollingTask = nil
        }

        teardownResources.install(
            runLoopSource: runLoopSource,
            callbackBox: runLoopSource != nil ? box : nil,
            callbackBoxPointer: runLoopSource != nil ? retainedPtr : nil,
            workspaceCenter: wsCenter,
            distributedCenter: distCenter,
            defaultCenter: defCenter,
            workspaceObservers: wsObservers,
            distributedObservers: distObservers,
            defaultObservers: defObservers,
            pollingTask: pollingTask
        )

        refreshNow()
    }

    public func stop() {
        teardownResources.cleanup()
    }

    public func refreshNow() {
        refreshState(notifyIfChanged: true)
    }

    public func setManualPause(_ paused: Bool) {
        var updated = inputs
        updated.manualPause = paused
        commitInputs(updated, notifyIfChanged: true)
    }

    public func setBatteryOverride(_ active: Bool) {
        var updated = inputs
        updated.batteryOverrideActive = active
        commitInputs(updated, notifyIfChanged: true)
    }

    public func applySettings(_ settings: PowerSettings) {
        var updated = inputs
        updated.applying(settings: settings)
        commitInputs(updated, notifyIfChanged: true)
    }

    nonisolated public static func isOnBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }

        if let providingType = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? {
            if providingType == kIOPMBatteryPowerKey {
                return true
            }
            if providingType == kIOPMACPowerKey {
                return false
            }
        }

        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = description[kIOPSPowerSourceStateKey as String] as? String,
               state == (kIOPSBatteryPowerValue as String) {
                return true
            }
        }
        return false
    }

    nonisolated public static func occludedDisplayIDs(
        windowList: [[String: Any]],
        displays: [(id: UInt32, bounds: CGRect)],
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        coverageThreshold: Double = FullscreenDetector.defaultCoverageThreshold
    ) -> Set<UInt32> {
        FullscreenDetector.occludedDisplayIDs(
            windowList: windowList,
            displays: displays,
            ownPID: ownPID,
            coverageThreshold: coverageThreshold
        )
    }

    private func populateLiveHardwareState(into updated: inout PowerInputs) {
        let newOnBattery = batteryStateProvider()
        if updated.onBattery && !newOnBattery {
            updated.batteryOverrideActive = false
        }
        updated.onBattery = newOnBattery

        let displays = displaysProvider()
        let windows = windowListProvider()
        updated.fullscreenDisplayIDs = FullscreenDetector.occludedDisplayIDs(
            windowList: windows,
            displays: displays
        )
    }

    private func refreshState(notifyIfChanged: Bool) {
        var updated = inputs
        populateLiveHardwareState(into: &updated)
        commitInputs(updated, notifyIfChanged: notifyIfChanged)
    }

    private func handleWake() {
        var updated = inputs
        updated.displayAsleep = false
        populateLiveHardwareState(into: &updated)
        commitInputs(updated, notifyIfChanged: true)
    }

    private func handleUnlock() {
        var updated = inputs
        updated.screenLocked = false
        populateLiveHardwareState(into: &updated)
        commitInputs(updated, notifyIfChanged: true)
    }

    private func refreshBatteryState() {
        var updated = inputs
        let newOnBattery = batteryStateProvider()
        if updated.onBattery && !newOnBattery {
            updated.batteryOverrideActive = false
        }
        updated.onBattery = newOnBattery
        commitInputs(updated, notifyIfChanged: true)
    }

    private func refreshOcclusionState() {
        var updated = inputs
        let displays = displaysProvider()
        let windows = windowListProvider()
        updated.fullscreenDisplayIDs = FullscreenDetector.occludedDisplayIDs(
            windowList: windows,
            displays: displays
        )
        commitInputs(updated, notifyIfChanged: true)
    }

    private func setDisplayAsleep(_ asleep: Bool) {
        var updated = inputs
        updated.displayAsleep = asleep
        commitInputs(updated, notifyIfChanged: true)
    }

    private func setScreenLocked(_ locked: Bool) {
        var updated = inputs
        updated.screenLocked = locked
        commitInputs(updated, notifyIfChanged: true)
    }

    private func commitInputs(_ updated: PowerInputs, notifyIfChanged: Bool) {
        guard updated != inputs else { return }
        inputs = updated
        if notifyIfChanged {
            onInputsChanged?(updated)
        }
    }
}
