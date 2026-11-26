import Foundation

public enum DisplayMode: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case mirrorAll
    case independent

    public var displayName: String {
        switch self {
        case .mirrorAll: "Mirror All Displays"
        case .independent: "Independent Per Display"
        }
    }
}

public enum WallpaperScalingMode: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case fill
    case fit

    public var displayName: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        }
    }
}

public struct DisplayAssignment: Codable, Equatable, Hashable, Sendable {
    public var displayID: UInt32
    public var displayName: String
    public var wallpaper: WallpaperItem?
    public var scalingMode: WallpaperScalingMode

    public enum CodingKeys: String, CodingKey {
        case displayID
        case displayName
        case wallpaper
        case scalingMode
    }

    public init(
        displayID: UInt32,
        displayName: String,
        wallpaper: WallpaperItem? = nil,
        scalingMode: WallpaperScalingMode = .fill
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.wallpaper = wallpaper
        self.scalingMode = scalingMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayID = try container.decode(UInt32.self, forKey: .displayID)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.wallpaper = try container.decodeIfPresent(WallpaperItem.self, forKey: .wallpaper)
        self.scalingMode = try container.decodeIfPresent(WallpaperScalingMode.self, forKey: .scalingMode) ?? .fill
    }
}

public struct DisplayConfig: Codable, Equatable, Hashable, Sendable {
    public static let mirrorAssignmentKey = "mirror"
    public static let primaryAssignmentKey = "primary"

    public var mode: DisplayMode
    public var assignments: [String: DisplayAssignment]

    public enum CodingKeys: String, CodingKey {
        case mode
        case assignments
    }

    public init(
        mode: DisplayMode = .mirrorAll,
        assignments: [String: DisplayAssignment] = [:]
    ) {
        self.mode = mode
        self.assignments = assignments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(DisplayMode.self, forKey: .mode) ?? .mirrorAll
        self.assignments = try container.decodeIfPresent([String: DisplayAssignment].self, forKey: .assignments) ?? [:]
    }

    public static func key(for displayID: UInt32) -> String {
        String(displayID)
    }

    public func assignment(for displayID: UInt32) -> DisplayAssignment? {
        switch mode {
        case .mirrorAll:
            return resolvedMirrorAssignment()
        case .independent:
            return assignments[Self.key(for: displayID)]
        }
    }

    public func activeWallpapers() -> [WallpaperItem] {
        switch mode {
        case .mirrorAll:
            return resolvedMirrorAssignment()?.wallpaper.map { [$0] } ?? []
        case .independent:
            return assignments
                .filter { $0.key != Self.mirrorAssignmentKey && $0.key != Self.primaryAssignmentKey }
                .sorted(by: { $0.key < $1.key })
                .compactMap(\.value.wallpaper)
        }
    }

    private func resolvedMirrorAssignment() -> DisplayAssignment? {
        assignments[Self.mirrorAssignmentKey]
            ?? assignments[Self.primaryAssignmentKey]
            ?? assignments.sorted(by: { $0.key < $1.key }).first?.value
    }
}

public struct PowerSettings: Codable, Equatable, Hashable, Sendable {
    public var pauseOnBattery: Bool
    public var pauseOnFullscreen: Bool
    public var pauseOnScreenLockOrSleep: Bool

    public enum CodingKeys: String, CodingKey {
        case pauseOnBattery
        case pauseOnFullscreen
        case pauseOnScreenLockOrSleep
    }

    public init(
        pauseOnBattery: Bool = true,
        pauseOnFullscreen: Bool = true,
        pauseOnScreenLockOrSleep: Bool = true
    ) {
        self.pauseOnBattery = pauseOnBattery
        self.pauseOnFullscreen = pauseOnFullscreen
        self.pauseOnScreenLockOrSleep = pauseOnScreenLockOrSleep
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? true
        self.pauseOnFullscreen = try container.decodeIfPresent(Bool.self, forKey: .pauseOnFullscreen) ?? true
        self.pauseOnScreenLockOrSleep = try container.decodeIfPresent(Bool.self, forKey: .pauseOnScreenLockOrSleep) ?? true
    }
}

public struct AppSettings: Codable, Equatable, Hashable, Sendable {
    public var customFeedURL: String?
    public var extractFirstFrameStill: Bool
    public var launchInBackgroundOnClose: Bool
    public var power: PowerSettings
    public var preferredResolution: String?

    public enum CodingKeys: String, CodingKey {
        case customFeedURL
        case extractFirstFrameStill
        case launchInBackgroundOnClose
        case power
        case preferredResolution
    }

    public init(
        customFeedURL: String? = nil,
        extractFirstFrameStill: Bool = true,
        launchInBackgroundOnClose: Bool = true,
        power: PowerSettings = PowerSettings(),
        preferredResolution: String? = nil
    ) {
        self.customFeedURL = customFeedURL
        self.extractFirstFrameStill = extractFirstFrameStill
        self.launchInBackgroundOnClose = launchInBackgroundOnClose
        self.power = power
        self.preferredResolution = preferredResolution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.customFeedURL = try container.decodeIfPresent(String.self, forKey: .customFeedURL)
        self.extractFirstFrameStill = try container.decodeIfPresent(Bool.self, forKey: .extractFirstFrameStill) ?? true
        self.launchInBackgroundOnClose = try container.decodeIfPresent(Bool.self, forKey: .launchInBackgroundOnClose) ?? true
        self.power = try container.decodeIfPresent(PowerSettings.self, forKey: .power) ?? PowerSettings()
        self.preferredResolution = try container.decodeIfPresent(String.self, forKey: .preferredResolution)
    }

    public var validatedCustomFeedURL: URL? {
        guard let raw = customFeedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            return nil
        }
        return url
    }
}

public struct ApiSecrets: Codable, Equatable, Hashable, Sendable, CustomDebugStringConvertible {
    public var pexelsAPIKey: String?
    public var pixabayAPIKey: String?
    public var wallhavenAPIKey: String?

    public enum CodingKeys: String, CodingKey {
        case pexelsAPIKey
        case pixabayAPIKey
        case wallhavenAPIKey
    }

    public init(
        pexelsAPIKey: String? = nil,
        pixabayAPIKey: String? = nil,
        wallhavenAPIKey: String? = nil
    ) {
        self.pexelsAPIKey = pexelsAPIKey
        self.pixabayAPIKey = pixabayAPIKey
        self.wallhavenAPIKey = wallhavenAPIKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pexelsAPIKey = try container.decodeIfPresent(String.self, forKey: .pexelsAPIKey)
        self.pixabayAPIKey = try container.decodeIfPresent(String.self, forKey: .pixabayAPIKey)
        self.wallhavenAPIKey = try container.decodeIfPresent(String.self, forKey: .wallhavenAPIKey)
    }

    public var normalizedPexelsKey: String? { Self.normalize(pexelsAPIKey) }
    public var normalizedPixabayKey: String? { Self.normalize(pixabayAPIKey) }
    public var normalizedWallhavenKey: String? { Self.normalize(wallhavenAPIKey) }

    public var isEmpty: Bool {
        normalizedPexelsKey == nil && normalizedPixabayKey == nil && normalizedWallhavenKey == nil
    }

    public func normalized() -> ApiSecrets {
        ApiSecrets(
            pexelsAPIKey: normalizedPexelsKey,
            pixabayAPIKey: normalizedPixabayKey,
            wallhavenAPIKey: normalizedWallhavenKey
        )
    }

    public var debugDescription: String {
        "ApiSecrets(pexels: \(normalizedPexelsKey == nil ? "nil" : "<redacted>"), pixabay: \(normalizedPixabayKey == nil ? "nil" : "<redacted>"), wallhaven: \(normalizedWallhavenKey == nil ? "nil" : "<redacted>"))"
    }

    private static func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
