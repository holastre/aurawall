import Foundation
import Testing
@testable import AuraWallCore

@Suite("PowerPolicyEvaluator Tests")
struct PowerPolicyEvaluatorTests {
    @Test("Priority 1: Display asleep or screen locked overrides all lower rules")
    func sleepAndLockOverrideAll() {
        let flags: [(Bool, Bool)] = [(true, false), (false, true), (true, true)]
        for (asleep, locked) in flags {
            let inputs = PowerInputs(
                displayAsleep: asleep,
                screenLocked: locked,
                manualPause: true,
                onBattery: true,
                batteryOverrideActive: false,
                pauseOnBatteryEnabled: true,
                pauseOnFullscreenEnabled: true,
                pauseOnLockSleepEnabled: true,
                fullscreenDisplayIDs: [1, 2]
            )
            #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .pause(.displayAsleepOrLocked))
            #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 2) == .pause(.displayAsleepOrLocked))
            #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 99) == .pause(.displayAsleepOrLocked))
        }
    }

    @Test("Priority 2: Manual pause overrides battery, override, and fullscreen")
    func manualPauseOverridesLowerRules() {
        let inputs = PowerInputs(
            displayAsleep: false,
            screenLocked: false,
            manualPause: true,
            onBattery: true,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            pauseOnLockSleepEnabled: true,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .pause(.manual))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 2) == .pause(.manual))
    }

    @Test("Priority 3: On battery pauses when enabled and override is inactive")
    func onBatteryWithoutOverridePauses() {
        let inputs = PowerInputs(
            displayAsleep: false,
            screenLocked: false,
            manualPause: false,
            onBattery: true,
            batteryOverrideActive: false,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            pauseOnLockSleepEnabled: true,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .pause(.onBattery))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 2) == .pause(.onBattery))
    }

    @Test("Battery override allows playback on AC and falls through to fullscreen on battery")
    func batteryOverrideFallthrough() {
        let acInputs = PowerInputs(
            onBattery: false,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: acInputs, forDisplay: 1) == .play)

        let batteryFullscreenInputs = PowerInputs(
            onBattery: true,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: batteryFullscreenInputs, forDisplay: 1) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: batteryFullscreenInputs, forDisplay: 2) == .play)
    }

    @Test("Priority 4: Fullscreen occlusion is strictly per-display")
    func fullscreenOcclusionPerDisplay() {
        let inputs = PowerInputs(
            pauseOnFullscreenEnabled: true,
            fullscreenDisplayIDs: [10, 30]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 10) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 20) == .play)
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 30) == .pause(.fullscreenOccluded))
    }

    @Test("Disabled settings toggles bypass corresponding rules while manualPause stays active")
    func disabledTogglesBypassRules() {
        var inputs = PowerInputs(
            displayAsleep: true,
            screenLocked: true,
            manualPause: false,
            onBattery: true,
            batteryOverrideActive: false,
            pauseOnBatteryEnabled: false,
            pauseOnFullscreenEnabled: false,
            pauseOnLockSleepEnabled: false,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .play)

        inputs.manualPause = true
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .pause(.manual))
    }

    @Test("Boundary displayIDs 0 and UInt32.max match accurately")
    func boundaryDisplayIDs() {
        let inputs = PowerInputs(
            pauseOnFullscreenEnabled: true,
            fullscreenDisplayIDs: [0, UInt32.max]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 0) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: UInt32.max) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .play)
    }

    @Test("PowerInputs.applying(settings:) updates only setting toggles")
    func applyingSettingsPreservesRuntimeFlags() {
        var inputs = PowerInputs(
            displayAsleep: true,
            screenLocked: true,
            manualPause: true,
            onBattery: true,
            batteryOverrideActive: true,
            fullscreenDisplayIDs: [42]
        )
        inputs.applying(settings: PowerSettings(
            pauseOnBattery: false,
            pauseOnFullscreen: false,
            pauseOnScreenLockOrSleep: false
        ))

        #expect(inputs.pauseOnBatteryEnabled == false)
        #expect(inputs.pauseOnFullscreenEnabled == false)
        #expect(inputs.pauseOnLockSleepEnabled == false)
        #expect(inputs.displayAsleep == true)
        #expect(inputs.screenLocked == true)
        #expect(inputs.manualPause == true)
        #expect(inputs.onBattery == true)
        #expect(inputs.batteryOverrideActive == true)
        #expect(inputs.fullscreenDisplayIDs == [42])
    }

    @Test("aggregateDecision reports overall play/pause status across display sets")
    func aggregateDecisionBehavior() {
        // Empty displays with global condition
        let batteryInputs = PowerInputs(onBattery: true, pauseOnBatteryEnabled: true)
        #expect(PowerPolicyEvaluator.aggregateDecision(inputs: batteryInputs, displayIDs: []) == .pause(.onBattery))
        #expect(PowerPolicyEvaluator.aggregateDecision(inputs: PowerInputs(fullscreenDisplayIDs: [0]), displayIDs: []) == .play)

        // Mixed fullscreen displays: at least one display still playing -> .play
        let partialFullscreen = PowerInputs(fullscreenDisplayIDs: [1])
        #expect(PowerPolicyEvaluator.aggregateDecision(inputs: partialFullscreen, displayIDs: [1, 2]) == .play)
        #expect(PowerPolicyEvaluator.aggregateDecision(inputs: partialFullscreen, displayIDs: [1]) == .pause(.fullscreenOccluded))

        // All connected displays occluded -> .pause(.fullscreenOccluded)
        let allOccluded = PowerInputs(fullscreenDisplayIDs: [1, 2])
        #expect(PowerPolicyEvaluator.aggregateDecision(inputs: allOccluded, displayIDs: [1, 2]) == .pause(.fullscreenOccluded))
    }

    @Test("menuBarStatusLabel maps nil, .image, and .video across all PowerDecision states")
    func menuBarStatusLabelMapping() {
        #expect(PowerDecision.play.menuBarStatusLabel(for: nil) == "Ready")
        #expect(PowerDecision.pause(.onBattery).menuBarStatusLabel(for: nil) == "Ready")
        #expect(PowerDecision.play.menuBarStatusLabel(for: .image) == "Static")
        #expect(PowerDecision.pause(.manual).menuBarStatusLabel(for: .image) == "Static")

        #expect(PowerDecision.play.menuBarStatusLabel(for: .video) == "Playing")
        #expect(PowerDecision.pause(.onBattery).menuBarStatusLabel(for: .video) == "Paused — On Battery")
        #expect(PowerDecision.pause(.fullscreenOccluded).menuBarStatusLabel(for: .video) == "Paused — Fullscreen App")
        #expect(PowerDecision.pause(.manual).menuBarStatusLabel(for: .video) == "Paused — Manual")
        #expect(PowerDecision.pause(.displayAsleepOrLocked).menuBarStatusLabel(for: .video) == "Paused — Display Asleep / Locked")

        let batteryInputs = PowerInputs(onBattery: true, pauseOnBatteryEnabled: true)
        #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: batteryInputs, displayIDs: [1], activeMediaType: .video) == "Paused — On Battery")
        #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: batteryInputs, displayIDs: [1], activeMediaType: .image) == "Static")
        #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: batteryInputs, displayIDs: [1], activeMediaType: nil) == "Ready")
    }
}
