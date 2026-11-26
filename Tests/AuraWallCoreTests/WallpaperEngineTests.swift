import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import Testing
@testable import AuraWallCore

@Suite("WallpaperEngine Tests")
struct WallpaperEngineTests {
    private struct AppliedDesktopCall: Sendable {
        let imageURL: URL
        let displayID: UInt32
        let allowClipping: Bool?
        let hasFillColor: Bool
    }

    private struct MockDesktopSetterError: Error, LocalizedError {
        var errorDescription: String? { "Mock desktop setter failure" }
    }

    private final class MockScreen: NSScreen {
        private let stateLock: OSAllocatedUnfairLock<(id: UInt32, frame: NSRect, name: String)>

        var mockID: UInt32 {
            stateLock.withLock { $0.id }
        }

        var mockFrame: NSRect {
            get { stateLock.withLock { $0.frame } }
            set { stateLock.withLock { $0.frame = newValue } }
        }

        init(id: UInt32, frame: NSRect, name: String) {
            self.stateLock = OSAllocatedUnfairLock(initialState: (id: id, frame: frame, name: name))
            super.init()
        }

        override var frame: NSRect {
            stateLock.withLock { $0.frame }
        }

        override var localizedName: String {
            stateLock.withLock { $0.name }
        }

        override var backingScaleFactor: CGFloat { 2.0 }

        override var deviceDescription: [NSDeviceDescriptionKey: Any] {
            let id = stateLock.withLock { $0.id }
            return [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: id)]
        }
    }

    @MainActor
    private final class ScreenListHolder {
        var screens: [NSScreen]
        init(_ screens: [NSScreen]) {
            self.screens = screens
        }
    }

    @MainActor
    private func pumpMainRunLoopSlice() {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraWallEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createValidJPEG(in dir: URL, name: String = "sample.jpg") throws -> URL {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw WallpaperEngineError.imageEncodingFailed
        }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw WallpaperEngineError.imageEncodingFailed
        }
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func createValidMP4(in dir: URL, name: String = "sample.mp4") async throws -> URL {
        let outURL = dir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBufferOut)
        if let pixelBuffer = pixelBufferOut {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixelBuffer, withPresentationTime: .zero)
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: 1, timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return outURL
    }

    @MainActor
    private func makeIsolatedEngine(
        tempDir: URL,
        extractFirstFrameStill: Bool = true,
        stillExtractor: WallpaperEngine.StillExtractor? = nil
    ) -> (engine: WallpaperEngine, desktopCalls: OSAllocatedUnfairLock<[AppliedDesktopCall]>) {
        let calls = OSAllocatedUnfairLock<[AppliedDesktopCall]>(initialState: [])
        let engine = WallpaperEngine(
            displayManager: DisplayManager(),
            extractFirstFrameStill: extractFirstFrameStill,
            desktopImageSetter: { url, screen, options in
                let displayID = DisplayManager.displayID(for: screen) ?? 0
                let allowClipping = options[.allowClipping] as? Bool
                let hasFillColor = options[.fillColor] != nil
                calls.withLock {
                    $0.append(AppliedDesktopCall(
                        imageURL: url,
                        displayID: displayID,
                        allowClipping: allowClipping,
                        hasFillColor: hasFillColor
                    ))
                }
            },
            stillExtractor: stillExtractor,
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true)
        )
        return (engine, calls)
    }

    @MainActor
    @Test("Video apply -> power pause/resume -> static image tears down video windows and passes scaling options")
    func videoPowerTransitionsAndStaticTeardown() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = try await createValidMP4(in: tempDir)
        let jpgURL = try createValidJPEG(in: tempDir)
        let extractedStillURL = try createValidJPEG(in: tempDir, name: "still.jpg")

        let (engine, calls) = makeIsolatedEngine(
            tempDir: tempDir,
            extractFirstFrameStill: true,
            stillExtractor: { _ in extractedStillURL }
        )

        guard let primaryID = engine.displayManager.displays.first?.id else {
            // Headless environment without screens: still verify no crash
            engine.teardownAllVideoWindows()
            return
        }

        let videoItem = WallpaperItem(id: "vid-1", title: "Video", source: .starter, mediaType: .video, localPath: mp4URL)
        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)

        #expect(engine.activeVideoDisplayIDs.contains(primaryID))
        #expect(engine.isPaused(for: primaryID) == false)
        #expect(engine.activeWallpapers[primaryID]?.id == "vid-1")
        #expect(engine.currentDecisions[primaryID] == .play)

        // Pause on battery
        engine.updatePowerInputs(PowerInputs(onBattery: true))
        #expect(engine.isPaused(for: primaryID) == true)
        #expect(engine.currentDecisions[primaryID] == .pause(.onBattery))

        // Resume on AC
        engine.updatePowerInputs(PowerInputs(onBattery: false))
        #expect(engine.isPaused(for: primaryID) == false)
        #expect(engine.currentDecisions[primaryID] == .play)

        // Manual pauseAll / resumeAll
        engine.pauseAll()
        #expect(engine.isPaused(for: primaryID) == true)
        #expect(engine.currentDecisions[primaryID] == .pause(.manual))

        engine.resumeAll()
        #expect(engine.isPaused(for: primaryID) == false)

        // Wait for still extraction task to run (bounded poll avoids flakiness under parallel load)
        for _ in 0..<50 {
            if calls.withLock({ $0.contains(where: { $0.imageURL == extractedStillURL && $0.allowClipping == true }) }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.withLock { $0.contains(where: { $0.imageURL == extractedStillURL && $0.allowClipping == true }) })

        // Switch to static image with .fit -> tears down video window immediately
        let imageItem = WallpaperItem(id: "img-1", title: "Static", source: .wallhaven, mediaType: .image, localPath: jpgURL)
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: nil, mode: .mirrorAll, scaling: .fit)

        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers[primaryID]?.id == "img-1")
        #expect(engine.currentDecisions[primaryID] == nil)

        let lastCall = calls.withLock { $0.last }
        #expect(lastCall?.imageURL == jpgURL)
        #expect(lastCall?.allowClipping == false)
        #expect(lastCall?.hasFillColor == true)

        engine.teardownAllVideoWindows()
    }

    @MainActor
    @Test("Rapid switch from video to static image cancels stale still extraction")
    func staleStillExtractionCancellationRaceGuard() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = try await createValidMP4(in: tempDir)
        let jpgURL = try createValidJPEG(in: tempDir, name: "target-static.jpg")
        let staleStillURL = try createValidJPEG(in: tempDir, name: "stale-still.jpg")

        let (engine, calls) = makeIsolatedEngine(
            tempDir: tempDir,
            extractFirstFrameStill: true,
            stillExtractor: { _ in
                try await Task.sleep(for: .milliseconds(80))
                return staleStillURL
            }
        )

        guard !engine.displayManager.displays.isEmpty else {
            return
        }

        let videoItem = WallpaperItem(id: "slow-vid", title: "Slow Video", source: .starter, mediaType: .video, localPath: mp4URL)
        let imageItem = WallpaperItem(id: "fast-img", title: "Fast Static", source: .wallhaven, mediaType: .image, localPath: jpgURL)

        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: nil, mode: .mirrorAll, scaling: .fill)

        // Wait past the slow extractor duration
        try await Task.sleep(for: .milliseconds(150))

        let recordedURLs = calls.withLock { $0.map(\.imageURL) }
        #expect(recordedURLs.contains(jpgURL))
        #expect(!recordedURLs.contains(staleStillURL))

        engine.teardownAllVideoWindows()
    }

    @MainActor
    @Test("Invalid URLs, 0-byte MP4, disconnected display, empty screens, and repeated teardown are safe")
    func defensiveEdgeCases() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let emptyMP4 = tempDir.appendingPathComponent("empty.mp4")
        try Data().write(to: emptyMP4)

        let (engine, calls) = makeIsolatedEngine(tempDir: tempDir, extractFirstFrameStill: false)

        // Nil URLs
        let nilItem = WallpaperItem(id: "nil", title: "Nil", source: .starter, mediaType: .video)
        engine.apply(wallpaper: nilItem, localURL: nil, to: nil, mode: .mirrorAll, scaling: .fill)
        #expect(engine.activeVideoDisplayIDs.isEmpty)

        // Missing file
        let missingURL = tempDir.appendingPathComponent("does-not-exist.jpg")
        let missingItem = WallpaperItem(id: "missing", title: "Missing", source: .wallhaven, mediaType: .image, localPath: missingURL)
        engine.apply(wallpaper: missingItem, localURL: missingURL, to: nil, mode: .mirrorAll, scaling: .fill)
        #expect(calls.withLock { $0.isEmpty })

        // 0-byte corrupt MP4
        let corruptItem = WallpaperItem(id: "corrupt", title: "Corrupt", source: .localImport, mediaType: .video, localPath: emptyMP4)
        engine.apply(wallpaper: corruptItem, localURL: emptyMP4, to: nil, mode: .mirrorAll, scaling: .fill)
        #expect(engine.activeVideoDisplayIDs.isEmpty)

        // Disconnected display ID
        let jpgURL = try createValidJPEG(in: tempDir)
        let validImage = WallpaperItem(id: "valid-img", title: "Valid", source: .wallhaven, mediaType: .image, localPath: jpgURL)
        engine.apply(wallpaper: validImage, localURL: jpgURL, to: 999_999, mode: .independent, scaling: .fill)
        #expect(calls.withLock { $0.isEmpty })

        // Repeated teardown
        engine.teardownAllVideoWindows()
        engine.teardownAllVideoWindows()

        // Empty screens DisplayManager
        let headlessEngine = WallpaperEngine(
            displayManager: DisplayManager(screensProvider: { [] }),
            extractFirstFrameStill: false,
            desktopImageSetter: { _, _, _ in },
            stillExtractor: nil,
            stillCacheDirectory: tempDir.appendingPathComponent("HeadlessStills", isDirectory: true)
        )
        headlessEngine.apply(wallpaper: validImage, localURL: jpgURL, to: nil, mode: .mirrorAll, scaling: .fill)
        #expect(headlessEngine.activeVideoDisplayIDs.isEmpty)
        headlessEngine.teardownAllVideoWindows()
    }

    @Test("Real AVAssetImageGenerator still extraction writes JPEG into Stills directory")
    func realFirstFrameStillExtraction() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = try await createValidMP4(in: tempDir)
        let stillsDir = tempDir.appendingPathComponent("Stills", isDirectory: true)

        let stillURL = try await WallpaperEngine.extractFirstFrameStillImage(from: mp4URL, into: stillsDir)
        #expect(stillURL.deletingLastPathComponent().standardizedFileURL == stillsDir.standardizedFileURL)
        let data = try Data(contentsOf: stillURL)
        #expect(!data.isEmpty)
    }

    @MainActor
    @Test("DesktopVideoWindow configures desktop window level, frame, scaling, and idempotent teardown")
    func desktopVideoWindowLifecycleAndProperties() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = try await createValidMP4(in: tempDir)
        let window = DesktopVideoWindow(
            displayID: 1,
            frame: NSRect(x: 0, y: 0, width: 640, height: 360),
            videoURL: mp4URL,
            scalingMode: .fill
        )

        #expect(window.windowLevelRawValue == Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        #expect(window.scalingMode == .fill)
        #expect(window.isTornDown == false)

        window.play(fadeDuration: 0)
        #expect(window.isPlaying == true)

        window.updateFrame(NSRect(x: 0, y: 0, width: 800, height: 450))
        #expect(window.windowFrame.size == NSSize(width: 800, height: 450))

        window.updateScaling(.fit)
        #expect(window.scalingMode == .fit)

        window.pause()
        #expect(window.isPlaying == false)

        window.teardown(fadeDuration: 0)
        #expect(window.isTornDown == true)
        #expect(window.isPlaying == false)

        // Idempotent second teardown and post-teardown no-ops
        window.teardown(fadeDuration: 0)
        window.play(fadeDuration: 0)
        #expect(window.isPlaying == false)
    }

    @MainActor
    @Test("WallpaperEngine.apply(config:) applies connected assignments and tears down removed displays")
    func applyDisplayConfigLifecycle() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = try await createValidMP4(in: tempDir)
        let jpgURL = try createValidJPEG(in: tempDir)
        let (engine, calls) = makeIsolatedEngine(tempDir: tempDir, extractFirstFrameStill: false)

        guard let primaryID = engine.displayManager.displays.first?.id else {
            return
        }

        let videoItem = WallpaperItem(id: "cfg-vid", title: "Config Video", source: .starter, mediaType: .video, localPath: mp4URL)
        let imageItem = WallpaperItem(id: "cfg-img", title: "Config Image", source: .wallhaven, mediaType: .image, localPath: jpgURL)

        let videoConfig = DisplayConfig(
            mode: .independent,
            assignments: [
                DisplayConfig.key(for: primaryID): DisplayAssignment(
                    displayID: primaryID,
                    displayName: "Primary",
                    wallpaper: videoItem,
                    scalingMode: .fill
                )
            ]
        )
        engine.apply(config: videoConfig)
        #expect(engine.activeVideoDisplayIDs == [primaryID])

        let imageConfig = DisplayConfig(
            mode: .mirrorAll,
            assignments: [
                DisplayConfig.mirrorAssignmentKey: DisplayAssignment(
                    displayID: 0,
                    displayName: "Mirror",
                    wallpaper: imageItem,
                    scalingMode: .fit
                )
            ]
        )
        engine.apply(config: imageConfig)
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(calls.withLock { $0.last?.imageURL == jpgURL })

        engine.teardownAllVideoWindows()
    }

    @MainActor
    @Test("Non-empty corrupt video async onFailure cleans up state and cancels pending still extraction")
    func nonEmptyCorruptVideoOnFailureCleansUpAndCancelsStillExtraction() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptMP4 = tempDir.appendingPathComponent("nonempty_corrupt.mp4")
        let corruptBytes = Data("NOT_A_VALID_MP4_HEADER_BYTES_FOR_ASYNC_FAILURE_TEST".utf8)
        try corruptBytes.write(to: corruptMP4, options: .atomic)

        let extractedStillURL = try createValidJPEG(in: tempDir, name: "should-never-apply.jpg")
        let screen = MockScreen(id: 101, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "Mock-101")
        let calls = OSAllocatedUnfairLock<[AppliedDesktopCall]>(initialState: [])

        let engine = WallpaperEngine(
            displayManager: DisplayManager(screensProvider: { [screen] }),
            extractFirstFrameStill: true,
            desktopImageSetter: { url, targetScreen, options in
                let displayID = DisplayManager.displayID(for: targetScreen) ?? 0
                let allowClipping = options[.allowClipping] as? Bool
                let hasFillColor = options[.fillColor] != nil
                calls.withLock {
                    $0.append(AppliedDesktopCall(
                        imageURL: url,
                        displayID: displayID,
                        allowClipping: allowClipping,
                        hasFillColor: hasFillColor
                    ))
                }
            },
            stillExtractor: { _ in
                try await Task.sleep(for: .milliseconds(300))
                return extractedStillURL
            },
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true)
        )

        let badVideo = WallpaperItem(
            id: "bad-vid",
            title: "Corrupt Non-Empty Video",
            source: .localImport,
            mediaType: .video,
            localPath: corruptMP4
        )
        engine.apply(wallpaper: badVideo, localURL: corruptMP4, to: screen.mockID, mode: .independent, scaling: .fill)
        #expect(engine.activeVideoDisplayIDs == [screen.mockID])

        // Pump MainRunLoop until onFailure fires and past the 300ms stillExtractor delay (~700ms+)
        let start = Date()
        while Date().timeIntervalSince(start) < 1.5 {
            pumpMainRunLoopSlice()
            try await Task.sleep(for: .milliseconds(20))
            if engine.activeVideoDisplayIDs.isEmpty && Date().timeIntervalSince(start) >= 0.7 {
                break
            }
        }

        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers[screen.mockID] == nil)
        #expect(engine.currentDecisions[screen.mockID] == nil)
        #expect(engine.lastErrorMessage != nil)
        #expect(calls.withLock { $0.count } == 0)

        engine.teardownAllVideoWindows()
    }

    @MainActor
    @Test("Throwing desktopImageSetter on .image preserves clean activeWallpapers state")
    func throwingDesktopImageSetterDoesNotMutateActiveWallpapers() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpgURL = try createValidJPEG(in: tempDir)
        let mp4URL = try await createValidMP4(in: tempDir)
        let screen = MockScreen(id: 202, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "Mock-202")
        let shouldThrow = OSAllocatedUnfairLock<Bool>(initialState: true)

        let engine = WallpaperEngine(
            displayManager: DisplayManager(screensProvider: { [screen] }),
            extractFirstFrameStill: false,
            desktopImageSetter: { _, _, _ in
                if shouldThrow.withLock({ $0 }) {
                    throw MockDesktopSetterError()
                }
            },
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true)
        )

        let imageItem = WallpaperItem(
            id: "throw-img",
            title: "Throw Image",
            source: .wallhaven,
            mediaType: .image,
            localPath: jpgURL
        )

        // Fresh display: throwing setter must not record failed image in activeWallpapers
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: screen.mockID, mode: .independent, scaling: .fill)
        #expect(engine.lastErrorMessage != nil)
        #expect(engine.activeWallpapers[screen.mockID] == nil)

        // Switching from active video to throwing image tears down the video and clears activeWallpapers
        let videoItem = WallpaperItem(
            id: "prior-vid",
            title: "Prior Video",
            source: .starter,
            mediaType: .video,
            localPath: mp4URL
        )
        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: screen.mockID, mode: .independent, scaling: .fill)
        #expect(engine.activeVideoDisplayIDs == [screen.mockID])
        #expect(engine.activeWallpapers[screen.mockID]?.id == "prior-vid")

        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: screen.mockID, mode: .independent, scaling: .fit)
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.currentDecisions[screen.mockID] == nil)
        #expect(engine.lastErrorMessage != nil)
        #expect(engine.activeWallpapers[screen.mockID] == nil)

        engine.teardownAllVideoWindows()
    }

    @MainActor
    @Test("refreshLayoutForConnectedDisplays updates resized frames, tears down disconnected displays, and restores on reconnect")
    func refreshLayoutForConnectedDisplaysHotplugAndResize() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = try await createValidMP4(in: tempDir)
        let screen1 = MockScreen(id: 301, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "Display-1")
        let screen2 = MockScreen(id: 302, frame: NSRect(x: 1280, y: 0, width: 1920, height: 1080), name: "Display-2")
        let screenHolder = ScreenListHolder([screen1, screen2])

        let displayManager = DisplayManager(screensProvider: { screenHolder.screens })
        let engine = WallpaperEngine(
            displayManager: displayManager,
            extractFirstFrameStill: false,
            desktopImageSetter: { _, _, _ in },
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true)
        )

        let videoItem = WallpaperItem(
            id: "hotplug-vid",
            title: "Hotplug Video",
            source: .starter,
            mediaType: .video,
            localPath: mp4URL
        )
        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)

        #expect(engine.activeVideoDisplayIDs == [301, 302])
        #expect(engine.videoWindow(for: 301)?.windowFrame == NSRect(x: 0, y: 0, width: 1280, height: 720))
        #expect(engine.videoWindow(for: 302)?.windowFrame == NSRect(x: 1280, y: 0, width: 1920, height: 1080))

        // Resize display 1 and disconnect display 2
        screen1.mockFrame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        screenHolder.screens = [screen1]
        engine.refreshLayoutForConnectedDisplays()

        #expect(engine.activeVideoDisplayIDs == [301])
        #expect(engine.videoWindow(for: 301)?.windowFrame == NSRect(x: 0, y: 0, width: 1600, height: 900))
        #expect(engine.videoWindow(for: 302) == nil)
        #expect(engine.activeWallpapers[302] == nil)
        #expect(engine.currentDecisions[302] == nil)

        // Reconnect display 2 with a new frame
        screen2.mockFrame = NSRect(x: 1600, y: 0, width: 2560, height: 1440)
        screenHolder.screens = [screen1, screen2]
        engine.refreshLayoutForConnectedDisplays()

        #expect(engine.activeVideoDisplayIDs == [301, 302])
        #expect(engine.videoWindow(for: 302)?.windowFrame == NSRect(x: 1600, y: 0, width: 2560, height: 1440))
        #expect(engine.activeWallpapers[302]?.id == "hotplug-vid")

        // Verify teardownAllVideoWindows clears video entries from activeWallpapers consistently
        engine.teardownAllVideoWindows()
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers.isEmpty)
        #expect(engine.currentDecisions.isEmpty)
    }

    @MainActor
    @Test("DesktopImageWindow configures desktop level, frame, scaling, idempotent teardown, and rejects corrupt files")
    func desktopImageWindowLifecycleAndCorruptFile() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let badImageURL = tempDir.appendingPathComponent("corrupt.jpg")
        try Data("not-an-image".utf8).write(to: badImageURL, options: .atomic)
        #expect(
            DesktopImageWindow(
                displayID: 1,
                frame: NSRect(x: 0, y: 0, width: 640, height: 360),
                imageURL: badImageURL,
                scalingMode: .fill
            ) == nil
        )

        let jpgURL = try createValidJPEG(in: tempDir)
        let window = try #require(
            DesktopImageWindow(
                displayID: 1,
                frame: NSRect(x: 0, y: 0, width: 640, height: 360),
                imageURL: jpgURL,
                scalingMode: .fill
            )
        )

        #expect(window.windowLevelRawValue == Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        #expect(window.scalingMode == .fill)
        #expect(window.isTornDown == false)

        window.show(fadeDuration: 0)
        #expect(window.isVisible == true)

        window.updateFrame(NSRect(x: 0, y: 0, width: 800, height: 450))
        #expect(window.windowFrame.size == NSSize(width: 800, height: 450))

        window.updateScaling(.fit)
        #expect(window.scalingMode == .fit)

        window.teardown(fadeDuration: 0)
        #expect(window.isTornDown == true)
        #expect(window.isVisible == false)

        // Idempotent second teardown and post-teardown no-ops
        window.teardown(fadeDuration: 0)
        window.show(fadeDuration: 0)
        #expect(window.isVisible == false)
    }

    @MainActor
    @Test("Static image wallpaper uses all-spaces DesktopImageWindow, resizes on hotplug, and tears down cleanly")
    func staticImageAllSpacesWindowHotplugAndTeardown() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpgURL = try createValidJPEG(in: tempDir)
        let mp4URL = try await createValidMP4(in: tempDir)
        let screen1 = MockScreen(id: 401, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "Display-1")
        let screen2 = MockScreen(id: 402, frame: NSRect(x: 1280, y: 0, width: 1920, height: 1080), name: "Display-2")
        let screenHolder = ScreenListHolder([screen1, screen2])

        let engine = WallpaperEngine(
            displayManager: DisplayManager(screensProvider: { screenHolder.screens }),
            extractFirstFrameStill: false,
            desktopImageSetter: { _, _, _ in },
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true),
            workspaceNotificationCenter: NotificationCenter(),
            currentDesktopImageURLProvider: { _ in nil }
        )

        let imageItem = WallpaperItem(
            id: "all-spaces-img",
            title: "All Spaces Static",
            source: .wallhaven,
            mediaType: .image,
            localPath: jpgURL
        )
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: nil, mode: .mirrorAll, scaling: .fill)

        #expect(engine.activeImageDisplayIDs == [401, 402])
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.imageWindow(for: 401)?.windowFrame == NSRect(x: 0, y: 0, width: 1280, height: 720))
        #expect(engine.imageWindow(for: 402)?.windowFrame == NSRect(x: 1280, y: 0, width: 1920, height: 1080))

        // Resize display 1 and disconnect display 2
        screen1.mockFrame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        screenHolder.screens = [screen1]
        engine.refreshLayoutForConnectedDisplays()

        #expect(engine.activeImageDisplayIDs == [401])
        #expect(engine.imageWindow(for: 401)?.windowFrame == NSRect(x: 0, y: 0, width: 1600, height: 900))
        #expect(engine.imageWindow(for: 402) == nil)

        // Switching to video tears down image window on that display
        let videoItem = WallpaperItem(
            id: "switch-vid",
            title: "Switch Video",
            source: .starter,
            mediaType: .video,
            localPath: mp4URL
        )
        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
        #expect(engine.activeImageDisplayIDs.isEmpty)
        #expect(engine.activeVideoDisplayIDs == [401])

        // Switch back to image and verify teardownAllWindows tears down image windows cleanly
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: nil, mode: .mirrorAll, scaling: .fit)
        #expect(engine.activeImageDisplayIDs == [401])
        engine.teardownAllWindows()
        #expect(engine.activeImageDisplayIDs.isEmpty)
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers.isEmpty)
    }

    @MainActor
    @Test("Space-change notification syncs native desktop image for unvisited Spaces and video first-frame stills")
    func activeSpaceDidChangeSyncsStaticAndVideoStillWallpapers() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpgURL = try createValidJPEG(in: tempDir, name: "desired.jpg")
        let oldSpaceURL = try createValidJPEG(in: tempDir, name: "old-space.jpg")
        let mp4URL = try await createValidMP4(in: tempDir)
        let extractedStillURL = try createValidJPEG(in: tempDir, name: "video-still.jpg")

        let screen = MockScreen(id: 501, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "Display-501")
        let workspaceNC = NotificationCenter()
        let currentSpaceImage = OSAllocatedUnfairLock<URL?>(initialState: oldSpaceURL)
        let calls = OSAllocatedUnfairLock<[AppliedDesktopCall]>(initialState: [])

        let engine = WallpaperEngine(
            displayManager: DisplayManager(screensProvider: { [screen] }),
            extractFirstFrameStill: true,
            desktopImageSetter: { url, targetScreen, options in
                let displayID = DisplayManager.displayID(for: targetScreen) ?? 0
                let allowClipping = options[.allowClipping] as? Bool
                let hasFillColor = options[.fillColor] != nil
                calls.withLock {
                    $0.append(AppliedDesktopCall(
                        imageURL: url,
                        displayID: displayID,
                        allowClipping: allowClipping,
                        hasFillColor: hasFillColor
                    ))
                }
            },
            stillExtractor: { _ in extractedStillURL },
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true),
            workspaceNotificationCenter: workspaceNC,
            currentDesktopImageURLProvider: { _ in currentSpaceImage.withLock { $0 } }
        )

        let imageItem = WallpaperItem(
            id: "space-sync-img",
            title: "Space Sync Static",
            source: .wallhaven,
            mediaType: .image,
            localPath: jpgURL
        )
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: screen.mockID, mode: .independent, scaling: .fill)
        #expect(calls.withLock { $0.count } == 1)

        // Simulate switching to Space 4 (currently showing oldSpaceURL) -> should sync jpgURL
        currentSpaceImage.withLock { $0 = oldSpaceURL }
        workspaceNC.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for _ in 0..<40 {
            if calls.withLock({ $0.count }) >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.withLock { $0.count } == 2)
        #expect(calls.withLock { $0.last?.imageURL } == jpgURL)

        // Simulate switching to a Space that already has jpgURL -> should NOT re-apply redundantly
        currentSpaceImage.withLock { $0 = jpgURL }
        workspaceNC.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(calls.withLock { $0.count } == 2)

        // Switch to a video with first-frame still extraction -> Space switch should sync extractedStillURL
        let videoItem = WallpaperItem(
            id: "space-sync-vid",
            title: "Space Sync Video",
            source: .starter,
            mediaType: .video,
            localPath: mp4URL
        )
        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: screen.mockID, mode: .independent, scaling: .fit)
        for _ in 0..<50 {
            if calls.withLock({ $0.contains(where: { $0.imageURL == extractedStillURL }) }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let countAfterStill = calls.withLock { $0.count }
        #expect(calls.withLock { $0.last?.imageURL } == extractedStillURL)

        currentSpaceImage.withLock { $0 = oldSpaceURL }
        workspaceNC.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for _ in 0..<40 {
            if calls.withLock({ $0.count }) > countAfterStill { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.withLock { $0.count } == countAfterStill + 1)
        #expect(calls.withLock { $0.last?.imageURL } == extractedStillURL)
        #expect(calls.withLock { $0.last?.allowClipping } == false)

        engine.teardownAllWindows()
    }
}
