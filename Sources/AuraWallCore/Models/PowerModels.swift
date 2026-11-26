import Foundation

public struct PowerInputs: Sendable, Equatable, Hashable, Codable {
    public var displayAsleep: Bool
    public var screenLocked: Bool
    public var manualPause: Bool
    public var onBattery: Bool
    public var batteryOverrideActive: Bool
    public var pauseOnBatteryEnabled: Bool
    public var pauseOnFullscreenEnabled: Bool
    public var pauseOnLockSleepEnabled: Bool
    public var fullscreenDisplayIDs: Set<UInt32>

    public enum CodingKeys: String, CodingKey {
        case displayAsleep
        case screenLocked
        case manualPause
        case onBattery
        case batteryOverrideActive
        case pauseOnBatteryEnabled
        case pauseOnFullscreenEnabled
        case pauseOnLockSleepEnabled
        case fullscreenDisplayIDs
    }

    public init(
        displayAsleep: Bool = false,
        screenLocked: Bool = false,
        manualPause: Bool = false,
        onBattery: Bool = false,
        batteryOverrideActive: Bool = false,
        pauseOnBatteryEnabled: Bool = true,
        pauseOnFullscreenEnabled: Bool = true,
        pauseOnLockSleepEnabled: Bool = true,
        fullscreenDisplayIDs: Set<UInt32> = []
    ) {
        self.displayAsleep = displayAsleep
        self.screenLocked = screenLocked
        self.manualPause = manualPause
        self.onBattery = onBattery
        self.batteryOverrideActive = batteryOverrideActive
        self.pauseOnBatteryEnabled = pauseOnBatteryEnabled
        self.pauseOnFullscreenEnabled = pauseOnFullscreenEnabled
        self.pauseOnLockSleepEnabled = pauseOnLockSleepEnabled
        self.fullscreenDisplayIDs = fullscreenDisplayIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayAsleep = try container.decodeIfPresent(Bool.self, forKey: .displayAsleep) ?? false
        self.screenLocked = try container.decodeIfPresent(Bool.self, forKey: .screenLocked) ?? false
        self.manualPause = try container.decodeIfPresent(Bool.self, forKey: .manualPause) ?? false
        self.onBattery = try container.decodeIfPresent(Bool.self, forKey: .onBattery) ?? false
        self.batteryOverrideActive = try container.decodeIfPresent(Bool.self, forKey: .batteryOverrideActive) ?? false
        self.pauseOnBatteryEnabled = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBatteryEnabled) ?? true
        self.pauseOnFullscreenEnabled = try container.decodeIfPresent(Bool.self, forKey: .pauseOnFullscreenEnabled) ?? true
        self.pauseOnLockSleepEnabled = try container.decodeIfPresent(Bool.self, forKey: .pauseOnLockSleepEnabled) ?? true
        self.fullscreenDisplayIDs = try container.decodeIfPresent(Set<UInt32>.self, forKey: .fullscreenDisplayIDs) ?? []
    }

    public mutating func applying(settings: PowerSettings) {
        self.pauseOnBatteryEnabled = settings.pauseOnBattery
        self.pauseOnFullscreenEnabled = settings.pauseOnFullscreen
        self.pauseOnLockSleepEnabled = settings.pauseOnScreenLockOrSleep
    }
}

public enum PauseReason: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case displayAsleepOrLocked
    case manual
    case onBattery
    case fullscreenOccluded

    public var statusLabel: String {
        switch self {
        case .displayAsleepOrLocked: "Paused — Display Asleep / Locked"
        case .manual: "Paused — Manual"
        case .onBattery: "Paused — On Battery"
        case .fullscreenOccluded: "Paused — Fullscreen App"
        }
    }
}

public enum PowerDecision: Sendable, Equatable, Hashable, Codable {
    case play
    case pause(PauseReason)

    public var isPlaying: Bool {
        self == .play
    }

    public var pauseReason: PauseReason? {
        switch self {
        case .play: nil
        case .pause(let reason): reason
        }
    }

    public var statusLabel: String {
        switch self {
        case .play: "Playing"
        case .pause(let reason): reason.statusLabel
        }
    }

    public func menuBarStatusLabel(for activeMediaType: WallpaperMediaType?) -> String {
        guard let activeMediaType else {
            return "Ready"
        }
        switch activeMediaType {
        case .image:
            return "Static"
        case .video:
            return statusLabel
        }
    }
}
