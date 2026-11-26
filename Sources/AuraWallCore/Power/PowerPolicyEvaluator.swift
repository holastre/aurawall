import Foundation

public enum PowerPolicyEvaluator: Sendable {
    public static func evaluate(inputs: PowerInputs, forDisplay displayID: UInt32) -> PowerDecision {
        if inputs.pauseOnLockSleepEnabled && (inputs.displayAsleep || inputs.screenLocked) {
            return .pause(.displayAsleepOrLocked)
        }
        if inputs.manualPause {
            return .pause(.manual)
        }
        if inputs.pauseOnBatteryEnabled && inputs.onBattery && !inputs.batteryOverrideActive {
            return .pause(.onBattery)
        }
        if inputs.pauseOnFullscreenEnabled && inputs.fullscreenDisplayIDs.contains(displayID) {
            return .pause(.fullscreenOccluded)
        }
        return .play
    }

    public static func aggregateDecision(inputs: PowerInputs, displayIDs: [UInt32]) -> PowerDecision {
        if displayIDs.isEmpty {
            if inputs.pauseOnLockSleepEnabled && (inputs.displayAsleep || inputs.screenLocked) {
                return .pause(.displayAsleepOrLocked)
            }
            if inputs.manualPause {
                return .pause(.manual)
            }
            if inputs.pauseOnBatteryEnabled && inputs.onBattery && !inputs.batteryOverrideActive {
                return .pause(.onBattery)
            }
            return .play
        }

        let decisions = displayIDs.map { evaluate(inputs: inputs, forDisplay: $0) }
        if decisions.contains(.play) {
            return .play
        }
        return decisions.first ?? .play
    }

    public static func aggregateDecision(
        inputs: PowerInputs,
        activeVideoDisplayIDs: Set<UInt32>,
        fallbackDisplayIDs: [UInt32]
    ) -> PowerDecision {
        let targetIDs = activeVideoDisplayIDs.isEmpty
            ? fallbackDisplayIDs
            : Array(activeVideoDisplayIDs).sorted()
        return aggregateDecision(inputs: inputs, displayIDs: targetIDs)
    }

    public static func menuBarStatusLabel(
        inputs: PowerInputs,
        displayIDs: [UInt32],
        activeMediaType: WallpaperMediaType?
    ) -> String {
        aggregateDecision(inputs: inputs, displayIDs: displayIDs)
            .menuBarStatusLabel(for: activeMediaType)
    }

    public static func menuBarStatusLabel(
        inputs: PowerInputs,
        activeVideoDisplayIDs: Set<UInt32>,
        fallbackDisplayIDs: [UInt32] = [],
        primaryMediaType: WallpaperMediaType?
    ) -> String {
        let effectiveMediaType: WallpaperMediaType? = activeVideoDisplayIDs.isEmpty
            ? primaryMediaType
            : .video
        return aggregateDecision(
            inputs: inputs,
            activeVideoDisplayIDs: activeVideoDisplayIDs,
            fallbackDisplayIDs: fallbackDisplayIDs
        )
        .menuBarStatusLabel(for: effectiveMediaType)
    }
}
