import AppKit
import AVFoundation
import CryptoKit
import Foundation
import os

public enum WallpaperEngineError: Error, LocalizedError, Sendable, Equatable {
    case imageEncodingFailed
    case emptyFrameGenerated

    public var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Failed to encode extracted still image."
        case .emptyFrameGenerated:
            return "Extracted first-frame image was empty."
        }
    }
}

public protocol DesktopImageApplying: Sendable {
    @MainActor
    func setDesktopImageURL(
        _ url: URL,
        for screen: NSScreen,
        options: [NSWorkspace.DesktopImageOptionKey: Any]
    ) throws
}

public struct LiveDesktopImageApplier: DesktopImageApplying {
    public init() {}

    @MainActor
    public func setDesktopImageURL(
        _ url: URL,
        for screen: NSScreen,
        options: [NSWorkspace.DesktopImageOptionKey: Any]
    ) throws {
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }
}

@MainActor
public final class WallpaperEngine {
    public typealias DesktopImageSetter = @MainActor (_ imageURL: URL, _ screen: NSScreen, _ options: [NSWorkspace.DesktopImageOptionKey: Any]) throws -> Void
    public typealias CurrentDesktopImageURLProvider = @MainActor (_ screen: NSScreen) -> URL?
    public typealias StillExtractor = @Sendable (_ videoURL: URL) async throws -> URL

    private struct DesiredDesktopImage: Equatable {
        let url: URL
        let scaling: WallpaperScalingMode
    }

    private final class SpaceObserverStore: @unchecked Sendable {
        private struct State: @unchecked Sendable {
            var center: NotificationCenter?
            var tokens: [NSObjectProtocol] = []
        }

        private let lock = OSAllocatedUnfairLock<State>(initialState: State())

        func replace(center: NotificationCenter, tokens: [NSObjectProtocol]) {
            let nextState = State(center: center, tokens: tokens)
            let old = lock.withLock { state -> State in
                let prev = state
                state = nextState
                return prev
            }
            if let oldCenter = old.center {
                for token in old.tokens {
                    oldCenter.removeObserver(token)
                }
            }
        }

        func invalidateAll() {
            let old = lock.withLock { state -> State in
                let prev = state
                state = State()
                return prev
            }
            if let oldCenter = old.center {
                for token in old.tokens {
                    oldCenter.removeObserver(token)
                }
            }
        }
    }

    public let displayManager: DisplayManager
    public var extractFirstFrameStill: Bool
    public let stillCacheDirectory: URL

    public private(set) var currentPowerInputs: PowerInputs = PowerInputs()
    public private(set) var activeWallpapers: [UInt32: WallpaperItem] = [:]
    public private(set) var currentDecisions: [UInt32: PowerDecision] = [:]
    public private(set) var lastErrorMessage: String?

    public var activeVideoDisplayIDs: Set<UInt32> {
        Set(videoWindows.keys)
    }

    public var activeImageDisplayIDs: Set<UInt32> {
        Set(imageWindows.keys)
    }

    private let desktopImageSetter: DesktopImageSetter
    private let currentDesktopImageURLProvider: CurrentDesktopImageURLProvider
    private let stillExtractor: StillExtractor
    private var videoWindows: [UInt32: DesktopVideoWindow] = [:]
    private var imageWindows: [UInt32: DesktopImageWindow] = [:]
    private var desiredDesktopImages: [UInt32: DesiredDesktopImage] = [:]
    private var stillTasks: [UInt32: Task<Void, Never>] = [:]
    private var stillGenerationByDisplay: [UInt32: UInt64] = [:]
    private var currentConfig: DisplayConfig = DisplayConfig()
    private var isRefreshingLayout: Bool = false
    private let spaceObserverStore = SpaceObserverStore()

    public convenience init() {
        self.init(
            displayManager: nil,
            extractFirstFrameStill: true,
            desktopImageSetter: nil,
            stillExtractor: nil,
            stillCacheDirectory: nil
        )
    }

    public init(
        displayManager: DisplayManager? = nil,
        extractFirstFrameStill: Bool = true,
        desktopImageSetter: DesktopImageSetter? = nil,
        stillExtractor: StillExtractor? = nil,
        stillCacheDirectory: URL? = nil,
        workspaceNotificationCenter: NotificationCenter? = nil,
        currentDesktopImageURLProvider: CurrentDesktopImageURLProvider? = nil
    ) {
        let resolvedStillDir: URL
        if let stillCacheDirectory {
            resolvedStillDir = stillCacheDirectory
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Caches", isDirectory: true)
            resolvedStillDir = cachesDir
                .appendingPathComponent("AuraWall", isDirectory: true)
                .appendingPathComponent("Stills", isDirectory: true)
        }

        self.displayManager = displayManager ?? DisplayManager()
        self.extractFirstFrameStill = extractFirstFrameStill
        self.stillCacheDirectory = resolvedStillDir

        if let desktopImageSetter {
            self.desktopImageSetter = desktopImageSetter
        } else {
            let liveApplier = LiveDesktopImageApplier()
            self.desktopImageSetter = { url, screen, options in
                try liveApplier.setDesktopImageURL(url, for: screen, options: options)
            }
        }

        self.currentDesktopImageURLProvider = currentDesktopImageURLProvider ?? { screen in
            NSWorkspace.shared.desktopImageURL(for: screen)
        }

        if let stillExtractor {
            self.stillExtractor = stillExtractor
        } else {
            self.stillExtractor = { videoURL in
                try await WallpaperEngine.extractFirstFrameStillImage(
                    from: videoURL,
                    into: resolvedStillDir
                )
            }
        }

        self.displayManager.onDisplaysChanged = { [weak self] _ in
            self?.refreshLayoutForConnectedDisplays()
        }
        self.displayManager.startMonitoring()

        let resolvedWorkspaceNC = workspaceNotificationCenter ?? NSWorkspace.shared.notificationCenter
        let spaceToken = resolvedWorkspaceNC.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncDesktopImagesForCurrentSpace()
            }
        }
        let wakeToken = resolvedWorkspaceNC.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncDesktopImagesForCurrentSpace()
            }
        }
        spaceObserverStore.replace(center: resolvedWorkspaceNC, tokens: [spaceToken, wakeToken])
    }

    deinit {
        spaceObserverStore.invalidateAll()
    }

    public func isPaused(for displayID: UInt32) -> Bool {
        if let window = videoWindows[displayID] {
            return !window.isPlaying
        }
        if let decision = currentDecisions[displayID] {
            return !decision.isPlaying
        }
        return false
    }

    public func apply(
        wallpaper: WallpaperItem,
        localURL: URL?,
        to displayID: UInt32?,
        mode: DisplayMode,
        scaling: WallpaperScalingMode
    ) {
        lastErrorMessage = nil

        let targetDisplays = resolveTargetDisplays(to: displayID, mode: mode)
        guard !targetDisplays.isEmpty else {
            if mode == .independent, let displayID {
                lastErrorMessage = "Display \(displayID) is not connected."
            }
            return
        }

        let resolvedURL = Self.resolveMediaURL(for: wallpaper, localURL: localURL)
        guard let resolvedURL else {
            lastErrorMessage = "No playable or displayable URL for wallpaper \(wallpaper.id)."
            tearDownDisplays(targetDisplays.map(\.id))
            return
        }

        if resolvedURL.isFileURL {
            guard Self.isNonEmptyReadableFile(at: resolvedURL) else {
                lastErrorMessage = "Media file missing or empty at \(resolvedURL.path)."
                tearDownDisplays(targetDisplays.map(\.id))
                return
            }
        } else if wallpaper.mediaType == .image {
            lastErrorMessage = "Static desktop image must be a local file URL."
            tearDownDisplays(targetDisplays.map(\.id))
            return
        }

        var effectiveWallpaper = wallpaper
        if resolvedURL.isFileURL {
            effectiveWallpaper.localPath = resolvedURL
        }

        updateConfigForAppliedWallpaper(
            effectiveWallpaper,
            targetDisplays: targetDisplays,
            requestedDisplayID: displayID,
            mode: mode,
            scaling: scaling
        )

        for display in targetDisplays {
            applyResolved(
                wallpaper: effectiveWallpaper,
                mediaURL: resolvedURL,
                to: display,
                scaling: scaling
            )
        }
    }

    public func apply(config: DisplayConfig) {
        lastErrorMessage = nil
        currentConfig = config
        displayManager.refreshDisplays()

        let resolved = DisplayManager.resolveAssignments(
            config: config,
            connectedDisplays: displayManager.displays
        )
        let activeIDs = Set(resolved.compactMap { $0.assignment.wallpaper != nil ? $0.display.id : nil })

        let existingDisplayIDs = Set(videoWindows.keys)
            .union(imageWindows.keys)
            .union(activeWallpapers.keys)
        for existingID in existingDisplayIDs where !activeIDs.contains(existingID) {
            tearDownDisplay(existingID)
        }

        for entry in resolved {
            guard let wallpaper = entry.assignment.wallpaper else {
                tearDownDisplay(entry.display.id)
                continue
            }
            guard let mediaURL = Self.resolveMediaURL(for: wallpaper, localURL: wallpaper.localPath) else {
                tearDownDisplay(entry.display.id)
                continue
            }
            if mediaURL.isFileURL && !Self.isNonEmptyReadableFile(at: mediaURL) {
                tearDownDisplay(entry.display.id)
                continue
            }
            if !mediaURL.isFileURL && wallpaper.mediaType == .image {
                tearDownDisplay(entry.display.id)
                continue
            }

            applyResolved(
                wallpaper: wallpaper,
                mediaURL: mediaURL,
                to: entry.display,
                scaling: entry.assignment.scalingMode
            )
        }
    }

    public func updatePowerInputs(_ inputs: PowerInputs) {
        currentPowerInputs = inputs
        evaluateAndApplyPowerPolicyForAllActiveVideos()
    }

    public func pauseAll() {
        var updated = currentPowerInputs
        updated.manualPause = true
        currentPowerInputs = updated
        evaluateAndApplyPowerPolicyForAllActiveVideos()
    }

    public func resumeAll() {
        var updated = currentPowerInputs
        updated.manualPause = false
        currentPowerInputs = updated
        evaluateAndApplyPowerPolicyForAllActiveVideos()
    }

    public func syncDesktopImagesForCurrentSpace() {
        for (displayID, desired) in desiredDesktopImages {
            guard let screen = displayManager.screen(for: displayID) else { continue }
            let currentURL = currentDesktopImageURLProvider(screen)
            if currentURL?.standardizedFileURL != desired.url.standardizedFileURL {
                try? desktopImageSetter(desired.url, screen, Self.desktopImageOptions(for: desired.scaling))
            }
        }
    }

    public func teardownAllVideoWindows() {
        for displayID in Array(stillTasks.keys) {
            cancelStillExtraction(for: displayID)
        }
        for (_, window) in videoWindows {
            window.teardown(fadeDuration: 0.0)
        }
        videoWindows.removeAll()
        currentDecisions.removeAll()
        for (displayID, wallpaper) in activeWallpapers where wallpaper.mediaType == .video {
            activeWallpapers.removeValue(forKey: displayID)
            desiredDesktopImages.removeValue(forKey: displayID)
        }
        clearAllVideosFromCurrentConfig()
    }

    public func teardownAllImageWindows() {
        for (_, window) in imageWindows {
            window.teardown(fadeDuration: 0.0)
        }
        imageWindows.removeAll()
        for (displayID, wallpaper) in activeWallpapers where wallpaper.mediaType == .image {
            activeWallpapers.removeValue(forKey: displayID)
            desiredDesktopImages.removeValue(forKey: displayID)
        }
    }

    public func teardownAllWindows() {
        teardownAllVideoWindows()
        teardownAllImageWindows()
        desiredDesktopImages.removeAll()
    }

    public func refreshLayoutForConnectedDisplays() {
        guard !isRefreshingLayout else { return }
        isRefreshingLayout = true
        defer { isRefreshingLayout = false }

        displayManager.refreshDisplays()
        let connected = displayManager.displays
        let connectedByID = Dictionary(connected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for existingID in Array(activeWallpapers.keys) where connectedByID[existingID] == nil {
            tearDownDisplay(existingID)
        }

        for existingID in Array(videoWindows.keys) {
            if let display = connectedByID[existingID] {
                videoWindows[existingID]?.updateFrame(display.frame)
            } else {
                tearDownDisplay(existingID)
            }
        }

        for existingID in Array(imageWindows.keys) {
            if let display = connectedByID[existingID] {
                imageWindows[existingID]?.updateFrame(display.frame)
            } else {
                tearDownDisplay(existingID)
            }
        }

        let resolved = DisplayManager.resolveAssignments(config: currentConfig, connectedDisplays: connected)
        for entry in resolved {
            guard let wallpaper = entry.assignment.wallpaper else { continue }
            if videoWindows[entry.display.id] == nil &&
               imageWindows[entry.display.id] == nil &&
               activeWallpapers[entry.display.id] == nil {
                guard let mediaURL = Self.resolveMediaURL(for: wallpaper, localURL: wallpaper.localPath) else {
                    continue
                }
                if mediaURL.isFileURL && !Self.isNonEmptyReadableFile(at: mediaURL) {
                    continue
                }
                if !mediaURL.isFileURL && wallpaper.mediaType == .image {
                    continue
                }
                applyResolved(
                    wallpaper: wallpaper,
                    mediaURL: mediaURL,
                    to: entry.display,
                    scaling: entry.assignment.scalingMode
                )
            }
        }
    }

    internal func videoWindow(for displayID: UInt32) -> DesktopVideoWindow? {
        videoWindows[displayID]
    }

    internal func imageWindow(for displayID: UInt32) -> DesktopImageWindow? {
        imageWindows[displayID]
    }

    // MARK: - Private Helpers

    private func resolveTargetDisplays(to displayID: UInt32?, mode: DisplayMode) -> [DisplayInfo] {
        displayManager.refreshDisplays()
        let connected = displayManager.displays
        guard !connected.isEmpty else { return [] }

        switch mode {
        case .mirrorAll:
            return connected
        case .independent:
            if let displayID {
                guard let match = connected.first(where: { $0.id == displayID }) else {
                    return []
                }
                return [match]
            }
            if let primary = connected.first(where: \.isMain) ?? connected.first {
                return [primary]
            }
            return []
        }
    }

    private func updateConfigForAppliedWallpaper(
        _ wallpaper: WallpaperItem,
        targetDisplays: [DisplayInfo],
        requestedDisplayID: UInt32?,
        mode: DisplayMode,
        scaling: WallpaperScalingMode
    ) {
        currentConfig.mode = mode
        switch mode {
        case .mirrorAll:
            currentConfig.assignments[DisplayConfig.mirrorAssignmentKey] = DisplayAssignment(
                displayID: 0,
                displayName: "Mirror",
                wallpaper: wallpaper,
                scalingMode: scaling
            )
        case .independent:
            for display in targetDisplays {
                let id = requestedDisplayID ?? display.id
                currentConfig.assignments[DisplayConfig.key(for: id)] = DisplayAssignment(
                    displayID: id,
                    displayName: display.name,
                    wallpaper: wallpaper,
                    scalingMode: scaling
                )
            }
        }
    }

    private func applyResolved(
        wallpaper: WallpaperItem,
        mediaURL: URL,
        to display: DisplayInfo,
        scaling: WallpaperScalingMode
    ) {
        cancelStillExtraction(for: display.id)

        switch wallpaper.mediaType {
        case .image:
            if let existingWindow = videoWindows.removeValue(forKey: display.id) {
                existingWindow.teardown(fadeDuration: 0.0)
            }
            if let existingImageWindow = imageWindows.removeValue(forKey: display.id) {
                existingImageWindow.teardown(fadeDuration: 0.0)
            }
            desiredDesktopImages.removeValue(forKey: display.id)
            if activeWallpapers[display.id]?.mediaType == .video {
                activeWallpapers.removeValue(forKey: display.id)
            }
            currentDecisions.removeValue(forKey: display.id)

            guard let screen = displayManager.screen(for: display.id) else { return }
            do {
                let options = Self.desktopImageOptions(for: scaling)
                try desktopImageSetter(mediaURL, screen, options)
                activeWallpapers[display.id] = wallpaper
                desiredDesktopImages[display.id] = DesiredDesktopImage(url: mediaURL, scaling: scaling)
                if let imageWindow = DesktopImageWindow(
                    displayID: display.id,
                    frame: display.frame,
                    imageURL: mediaURL,
                    scalingMode: scaling
                ) {
                    imageWindow.show()
                    imageWindows[display.id] = imageWindow
                }
            } catch {
                desiredDesktopImages.removeValue(forKey: display.id)
                lastErrorMessage = error.localizedDescription
            }

        case .video:
            if let existingImageWindow = imageWindows.removeValue(forKey: display.id) {
                existingImageWindow.teardown(fadeDuration: 0.0)
            }
            desiredDesktopImages.removeValue(forKey: display.id)
            if let existingWindow = videoWindows.removeValue(forKey: display.id) {
                existingWindow.teardown(fadeDuration: 0.0)
            }
            activeWallpapers[display.id] = wallpaper

            let window = DesktopVideoWindow(
                displayID: display.id,
                frame: display.frame,
                videoURL: mediaURL,
                scalingMode: scaling
            )
            window.onFailure = { [weak self, weak window] error in
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window else { return }
                    self.lastErrorMessage = error?.localizedDescription ?? "Video playback failed on display \(display.id)."
                    if self.videoWindows[display.id] === window {
                        self.tearDownDisplay(display.id)
                        self.clearVideoFromCurrentConfig(for: display.id)
                    }
                }
            }
            videoWindows[display.id] = window

            let decision = PowerPolicyEvaluator.evaluate(inputs: currentPowerInputs, forDisplay: display.id)
            currentDecisions[display.id] = decision
            if decision.isPlaying {
                window.play()
            } else {
                window.pause()
            }

            if extractFirstFrameStill {
                scheduleStillExtraction(for: display.id, videoURL: mediaURL, scaling: scaling)
            }
        }
    }

    private func scheduleStillExtraction(for displayID: UInt32, videoURL: URL, scaling: WallpaperScalingMode) {
        let generation = stillGenerationByDisplay[displayID, default: 0] &+ 1
        stillGenerationByDisplay[displayID] = generation

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stillURL = try await self.stillExtractor(videoURL)
                guard !Task.isCancelled,
                      self.stillGenerationByDisplay[displayID] == generation,
                      let screen = self.displayManager.screen(for: displayID) else {
                    return
                }
                let options = Self.desktopImageOptions(for: scaling)
                try self.desktopImageSetter(stillURL, screen, options)
                self.desiredDesktopImages[displayID] = DesiredDesktopImage(url: stillURL, scaling: scaling)
            } catch is CancellationError {
                return
            } catch {
                if self.stillGenerationByDisplay[displayID] == generation {
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
        stillTasks[displayID] = task
    }

    private func cancelStillExtraction(for displayID: UInt32) {
        stillGenerationByDisplay[displayID, default: 0] &+= 1
        stillTasks.removeValue(forKey: displayID)?.cancel()
    }

    private func tearDownDisplays(_ displayIDs: [UInt32]) {
        for displayID in displayIDs {
            tearDownDisplay(displayID)
        }
    }

    private func tearDownDisplay(_ displayID: UInt32) {
        cancelStillExtraction(for: displayID)
        if let window = videoWindows.removeValue(forKey: displayID) {
            window.teardown(fadeDuration: 0.0)
        }
        if let imageWindow = imageWindows.removeValue(forKey: displayID) {
            imageWindow.teardown(fadeDuration: 0.0)
        }
        desiredDesktopImages.removeValue(forKey: displayID)
        currentDecisions.removeValue(forKey: displayID)
        activeWallpapers.removeValue(forKey: displayID)
    }

    private func clearAllVideosFromCurrentConfig() {
        switch currentConfig.mode {
        case .independent:
            for (key, assignment) in currentConfig.assignments where assignment.wallpaper?.mediaType == .video {
                currentConfig.assignments.removeValue(forKey: key)
            }
        case .mirrorAll:
            var clearedMirrorOrPrimary = false
            for (key, assignment) in currentConfig.assignments where assignment.wallpaper?.mediaType == .video {
                if key == DisplayConfig.mirrorAssignmentKey || key == DisplayConfig.primaryAssignmentKey {
                    currentConfig.assignments[key]?.wallpaper = nil
                    clearedMirrorOrPrimary = true
                } else {
                    currentConfig.assignments[key]?.wallpaper = nil
                }
            }
            if !clearedMirrorOrPrimary,
               currentConfig.assignments[DisplayConfig.mirrorAssignmentKey] == nil,
               currentConfig.assignments[DisplayConfig.primaryAssignmentKey] == nil,
               currentConfig.assignments.values.contains(where: { $0.wallpaper != nil }) {
                // Keep mirror resolution returning nil if a non-video stale key existed alongside a cleared fallback
            }
        }
    }

    private func clearVideoFromCurrentConfig(for displayID: UInt32) {
        switch currentConfig.mode {
        case .independent:
            let key = DisplayConfig.key(for: displayID)
            if currentConfig.assignments[key]?.wallpaper?.mediaType == .video {
                currentConfig.assignments.removeValue(forKey: key)
            }
        case .mirrorAll:
            if currentConfig.assignments[DisplayConfig.mirrorAssignmentKey]?.wallpaper?.mediaType == .video {
                currentConfig.assignments[DisplayConfig.mirrorAssignmentKey]?.wallpaper = nil
            } else if currentConfig.assignments[DisplayConfig.primaryAssignmentKey]?.wallpaper?.mediaType == .video {
                currentConfig.assignments[DisplayConfig.primaryAssignmentKey]?.wallpaper = nil
            } else {
                let fallbackKey = currentConfig.assignments.sorted(by: { $0.key < $1.key }).first?.key
                if let fallbackKey, currentConfig.assignments[fallbackKey]?.wallpaper?.mediaType == .video {
                    currentConfig.assignments[fallbackKey]?.wallpaper = nil
                }
            }
        }
    }

    private func evaluateAndApplyPowerPolicyForAllActiveVideos() {
        for (displayID, window) in videoWindows {
            let decision = PowerPolicyEvaluator.evaluate(inputs: currentPowerInputs, forDisplay: displayID)
            currentDecisions[displayID] = decision
            if decision.isPlaying {
                window.play()
            } else {
                window.pause()
            }
        }
    }

    public static func desktopImageOptions(for scaling: WallpaperScalingMode) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        switch scaling {
        case .fill:
            return [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true
            ]
        case .fit:
            return [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: false,
                .fillColor: NSColor.black
            ]
        }
    }

    private static func resolveMediaURL(for wallpaper: WallpaperItem, localURL: URL?) -> URL? {
        switch wallpaper.mediaType {
        case .video:
            return localURL ?? wallpaper.localPath ?? wallpaper.fullAssetURL ?? wallpaper.previewVideoURL
        case .image:
            return localURL ?? wallpaper.localPath ?? wallpaper.fullAssetURL
        }
    }

    private static func isNonEmptyReadableFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    nonisolated public static func extractFirstFrameStillImage(
        from videoURL: URL,
        into directory: URL
    ) async throws -> URL {
        try Task.checkCancellation()

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 2160)

        let result = try await generator.image(at: .zero)
        try Task.checkCancellation()

        let cgImage = result.image
        guard cgImage.width > 0, cgImage.height > 0 else {
            throw WallpaperEngineError.emptyFrameGenerated
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw WallpaperEngineError.imageEncodingFailed
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let digest = SHA256.hash(data: Data(videoURL.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let outURL = directory.appendingPathComponent("\(hex).jpg", isDirectory: false)
        try jpegData.write(to: outURL, options: .atomic)
        return outURL
    }
}
