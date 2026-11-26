import AppKit
import Foundation
import Testing
import AuraWallCore

@Suite("Tier4 Scenario E2E Tests")
struct Tier4ScenarioE2ETests {

    @MainActor
    @Test("T4-01: First-launch starter catalog, fresh persistence, and engine apply/teardown")
    func firstLaunchStarterCatalogAndEngineLifecycle() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let secretStore = E2EHelpers.makeSecretStore(in: tempDir)

            let initialState = try await store.load()
            #expect(initialState == LibraryState())
            let initialSecrets = try await secretStore.load()
            #expect(initialSecrets.isEmpty)

            try await E2EHelpers.withMockBaseURL { baseURL in
                if !E2EEnvironment.noLive {
                    let liveService = E2EHelpers.makeCatalogService()
                    let liveStarterResult = await liveService.fetchCatalog(
                        query: E2EHelpers.makeQuery(mediaType: .video, sources: [.starter]),
                        secrets: initialSecrets,
                        customFeedURL: nil
                    )
                    let liveStarterProvider = try #require(
                        E2EHelpers.extractProviderResults(from: liveStarterResult).first(where: { $0.source == .starter })
                    )
                    #expect(liveStarterProvider.errorMessage == nil)
                    let liveStarterItems = E2EHelpers.extractItems(from: liveStarterResult)
                    #expect(liveStarterItems.count >= 10)
                    #expect(liveStarterItems.allSatisfy { $0.mediaType == .video && $0.fullAssetURL?.scheme?.lowercased() == "https" })
                }

                let mockService = E2EHelpers.makeMockCatalogService(baseURL: baseURL)
                let starterResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(mediaType: .video, sources: [.starter]),
                    secrets: initialSecrets,
                    customFeedURL: nil
                )
                let starterProvider = try #require(
                    E2EHelpers.extractProviderResults(from: starterResult).first(where: { $0.source == .starter })
                )
                #expect(starterProvider.errorMessage == nil)
                let starterItems = E2EHelpers.extractItems(from: starterResult)
                let firstVideo = try #require(starterItems.first(where: { $0.mediaType == .video && $0.fullAssetURL != nil }))

                let cache = E2EHelpers.makeCacheManager(in: tempDir)
                let cachedVideoURL = try await cache.download(firstVideo)
                #expect(FileManager.default.fileExists(atPath: cachedVideoURL.path))
                #expect(await cache.cachedFileURL(for: firstVideo) == cachedVideoURL)

                var assignedVideo = firstVideo
                assignedVideo.localPath = cachedVideoURL

                await store.updateDisplayConfig(
                    DisplayConfig(
                        mode: .mirrorAll,
                        assignments: [
                            DisplayConfig.mirrorAssignmentKey: DisplayAssignment(
                                displayID: 0,
                                displayName: "Mirror",
                                wallpaper: assignedVideo,
                                scalingMode: .fill
                            )
                        ]
                    )
                )
                try await store.save()

                let reloadedStore = E2EHelpers.makeLibraryStore(in: tempDir)
                let reloadedState = try await reloadedStore.load()
                let persistedActive = try #require(reloadedState.displayConfig.activeWallpapers().first)
                #expect(persistedActive.id == assignedVideo.id)
                #expect(await reloadedStore.activeWallpaperLocalURLs() == Set([PathCanonicalizer.canonicalFileURL(cachedVideoURL)]))

                let mockDisplays: [(id: UInt32, frame: NSRect, name: String)] = [
                    (id: 1, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "Primary")
                ]
                let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(
                    in: tempDir,
                    extractFirstFrameStill: true,
                    mockDisplays: mockDisplays
                )

                engine.apply(
                    wallpaper: persistedActive,
                    localURL: persistedActive.localPath,
                    to: nil,
                    mode: reloadedState.displayConfig.mode,
                    scaling: .fill
                )
                #expect(engine.lastErrorMessage == nil)
                #expect(engine.activeVideoDisplayIDs == [1])
                #expect(engine.activeWallpapers[1]?.id == assignedVideo.id)
                #expect(engine.currentDecisions[1] == .play)
                #expect(engine.isPaused(for: 1) == false)

                for _ in 0..<200 {
                    if !desktopCalls.value.isEmpty {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }

                #expect(desktopCalls.value.count == 1)
                let stillCall = try #require(desktopCalls.value.first)
                #expect(stillCall.displayID == 1)
                #expect(
                    PathCanonicalizer.canonicalFileURL(stillCall.imageURL.deletingLastPathComponent())
                        == PathCanonicalizer.canonicalFileURL(engine.stillCacheDirectory)
                )
                #expect(
                    PathCanonicalizer.canonicalFileURL(engine.stillCacheDirectory)
                        == PathCanonicalizer.canonicalFileURL(tempDir.appendingPathComponent("Stills", isDirectory: true))
                )
                #expect(FileManager.default.fileExists(atPath: stillCall.imageURL.path))

                engine.teardownAllVideoWindows()
                #expect(engine.activeVideoDisplayIDs.isEmpty)
                #expect(engine.activeWallpapers.isEmpty)
                #expect(engine.currentDecisions.isEmpty)
            }
        }
    }

    @MainActor
    @Test("T4-02: Multi-monitor independent assignment, hotplug simulation, and mirror toggle")
    func multiMonitorIndependentHotplugAndMirrorToggle() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let jpgURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)

            let videoItem = WallpaperItem(id: "mm-v1", title: "Studio Motion", source: .starter, mediaType: .video, localPath: mp4URL)
            let imageItem = WallpaperItem(id: "mm-i2", title: "Secondary Still", source: .wallhaven, mediaType: .image, localPath: jpgURL)

            let screen1 = E2EMockScreen(id: 101, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "Built-in")
            let screen2 = E2EMockScreen(id: 202, frame: NSRect(x: 1920, y: 0, width: 3840, height: 2160), name: "External 4K")
            let screensBox = LockedBox<[E2EMockScreen]>([screen1, screen2])

            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(
                in: tempDir,
                extractFirstFrameStill: false,
                screensProvider: { screensBox.value }
            )

            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            var config = DisplayConfig(
                mode: .independent,
                assignments: [
                    DisplayConfig.key(for: 101): DisplayAssignment(displayID: 101, displayName: "Built-in", wallpaper: videoItem, scalingMode: .fill),
                    DisplayConfig.key(for: 202): DisplayAssignment(displayID: 202, displayName: "External 4K", wallpaper: imageItem, scalingMode: .fit)
                ]
            )
            await store.updateDisplayConfig(config)
            try await store.save()

            engine.apply(config: config)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == [101])
            #expect(engine.activeWallpapers[101]?.id == "mm-v1")
            #expect(engine.activeWallpapers[202]?.id == "mm-i2")
            #expect(desktopCalls.value.count == 1)
            let firstStillCall = try #require(desktopCalls.value.first)
            #expect(firstStillCall.displayID == 202)
            #expect(firstStillCall.imageURL == jpgURL)
            #expect(firstStillCall.allowClipping == false)
            #expect(firstStillCall.hasFillColor == true)

            // Simulate unplugging display 202 while keeping saved assignment dictionary in LibraryStore
            screensBox.withValue { $0 = [screen1] }
            engine.refreshLayoutForConnectedDisplays()
            #expect(engine.activeWallpapers[202] == nil)
            #expect(engine.activeVideoDisplayIDs == [101])
            #expect(engine.activeWallpapers[101]?.id == "mm-v1")
            let retainedDuringUnplug = try await E2EHelpers.makeLibraryStore(in: tempDir).load()
            #expect(retainedDuringUnplug.displayConfig.assignments[DisplayConfig.key(for: 202)]?.wallpaper?.id == "mm-i2")

            // Toggle mirrorAll while only display 101 is connected
            config.mode = .mirrorAll
            config.assignments[DisplayConfig.mirrorAssignmentKey] = DisplayAssignment(
                displayID: 0,
                displayName: "Mirror",
                wallpaper: videoItem,
                scalingMode: .fill
            )
            await store.updateDisplayConfig(config)
            try await store.save()
            engine.apply(config: config)
            #expect(engine.activeVideoDisplayIDs == [101])
            #expect(engine.activeWallpapers[101]?.id == "mm-v1")

            // Replug external display 202 -> mirrorAll auto-applies across [101, 202]
            screensBox.withValue { $0 = [screen1, screen2] }
            engine.refreshLayoutForConnectedDisplays()
            #expect(engine.activeVideoDisplayIDs == [101, 202])
            #expect(engine.activeWallpapers[101]?.id == "mm-v1")
            #expect(engine.activeWallpapers[202]?.id == "mm-v1")

            // Reload LibraryStore and restore independent mode
            let reloadedStore = LibraryStore(baseDirectory: await store.baseDirectory)
            var reloadedState = try await reloadedStore.load()
            reloadedState.displayConfig.mode = .independent
            await reloadedStore.updateDisplayConfig(reloadedState.displayConfig)
            try await reloadedStore.save()

            let finalState = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
            #expect(finalState.displayConfig.mode == .independent)
            #expect(finalState.displayConfig.assignment(for: 101)?.wallpaper?.id == "mm-v1")
            #expect(finalState.displayConfig.assignment(for: 101)?.scalingMode == .fill)
            #expect(finalState.displayConfig.assignment(for: 202)?.wallpaper?.id == "mm-i2")
            #expect(finalState.displayConfig.assignment(for: 202)?.scalingMode == .fit)

            engine.apply(config: finalState.displayConfig)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == [101])
            #expect(engine.activeWallpapers[101]?.id == "mm-v1")
            #expect(engine.activeWallpapers[202]?.id == "mm-i2")
            #expect(desktopCalls.value.count == 2)
            let restoredCall = try #require(desktopCalls.value.last)
            #expect(restoredCall.displayID == 202)
            #expect(restoredCall.allowClipping == false)
            #expect(restoredCall.hasFillColor == true)

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
        }
    }

    @Test("T4-03: Catalog search -> streaming download -> favorite/recent -> restart persistence")
    func feedAndWallhavenSearchDownloadFavoriteRestartPersistence() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let mockService = E2EHelpers.makeMockCatalogService(baseURL: baseURL)

                let whResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(
                        text: "landscape",
                        mediaType: .image,
                        sources: [.wallhaven],
                        minResolution: "1920x1080",
                        aspectRatio: "16:9",
                        sorting: .top,
                        page: 1
                    ),
                    secrets: ApiSecrets(),
                    customFeedURL: nil
                )
                let whProvider = try #require(
                    E2EHelpers.extractProviderResults(from: whResult).first(where: { $0.source == .wallhaven })
                )
                #expect(whProvider.errorMessage == nil)
                let whItems = E2EHelpers.extractItems(from: whResult)
                #expect(!whItems.isEmpty)
                #expect(whItems.allSatisfy { $0.source == .wallhaven && $0.mediaType == .image && $0.tags.contains("sfw") })

                let customResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(text: "ocean", sources: [.customFeed]),
                    secrets: ApiSecrets(),
                    customFeedURL: baseURL.appendingPathComponent("custom/wrapped.json")
                )
                let customProvider = try #require(
                    E2EHelpers.extractProviderResults(from: customResult).first(where: { $0.source == .customFeed })
                )
                #expect(customProvider.errorMessage == nil)
                #expect(!E2EHelpers.extractItems(from: customResult).isEmpty)

                if !E2EEnvironment.noLive {
                    let liveService = E2EHelpers.makeCatalogService()
                    let liveWhResult = await liveService.fetchCatalog(
                        query: E2EHelpers.makeQuery(
                            text: "landscape",
                            mediaType: .image,
                            sources: [.wallhaven],
                            minResolution: "1920x1080",
                            aspectRatio: "16:9",
                            sorting: .top,
                            page: 1
                        ),
                        secrets: ApiSecrets(),
                        customFeedURL: nil
                    )
                    let liveWhProvider = try #require(
                        E2EHelpers.extractProviderResults(from: liveWhResult).first(where: { $0.source == .wallhaven })
                    )
                    #expect(liveWhProvider.errorMessage == nil)
                    let liveWhItems = E2EHelpers.extractItems(from: liveWhResult)
                    #expect(!liveWhItems.isEmpty)
                    #expect(liveWhItems.allSatisfy {
                        $0.source == .wallhaven
                            && $0.mediaType == .image
                            && $0.fullAssetURL?.scheme?.lowercased() == "https"
                            && $0.tags.contains("sfw")
                    })
                }

                let chosen = try #require(whItems.first(where: { $0.fullAssetURL != nil }))

                let cache = E2EHelpers.makeCacheManager(in: tempDir)
                let progress = LockedBox<[Double]>([])
                let downloadedURL = try await cache.download(chosen) { pct in
                    progress.withValue { $0.append(pct) }
                }
                let recordedProgress = progress.value
                #expect(recordedProgress.count >= 2)
                #expect((recordedProgress.first ?? -1.0) >= 0.0)
                #expect(recordedProgress.last == 1.0)
                #expect(zip(recordedProgress, recordedProgress.dropFirst()).allSatisfy { $0 <= $1 })
                #expect(await cache.totalCacheSizeBytes() > 0)
                #expect(NSImage(contentsOf: downloadedURL) != nil)

                let store = E2EHelpers.makeLibraryStore(in: tempDir)
                var savedItem = chosen
                savedItem.localPath = downloadedURL
                #expect(await store.toggleFavorite(savedItem) == true)
                await store.recordRecent(savedItem)
                await store.updateDisplayConfig(
                    DisplayConfig(
                        mode: .mirrorAll,
                        assignments: [
                            DisplayConfig.mirrorAssignmentKey: DisplayAssignment(
                                displayID: 0,
                                displayName: "Mirror",
                                wallpaper: savedItem,
                                scalingMode: .fill
                            )
                        ]
                    )
                )
                try await store.save()

                // Simulate app restart with fresh instances
                let restartedStore = E2EHelpers.makeLibraryStore(in: tempDir)
                let restartedState = try await restartedStore.load()
                let restartedCache = E2EHelpers.makeCacheManager(in: tempDir)

                #expect(restartedState.favorites.contains(where: {
                    $0.id == chosen.id && $0.source == .wallhaven && $0.localPath == downloadedURL
                }))
                #expect(restartedState.recents.contains(where: {
                    $0.id == chosen.id && $0.source == .wallhaven && $0.localPath == downloadedURL
                }))
                #expect(await restartedCache.cachedFileURL(for: chosen) == downloadedURL)
                #expect(await restartedStore.activeWallpaperLocalURLs() == Set([PathCanonicalizer.canonicalFileURL(downloadedURL)]))
            }
        }
    }

    @MainActor
    @Test("T4-04: Battery commute -> session override -> fullscreen occlusion -> lock -> AC resume")
    func batteryCommuteOverrideFullscreenLockAndACResume() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let d1Bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let d2Bounds = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

            let mockDisplays: [(id: UInt32, frame: NSRect, name: String)] = [
                (id: 1, frame: d1Bounds, name: "Built-in"),
                (id: 2, frame: d2Bounds, name: "External")
            ]
            let (engine, _) = E2EHelpers.makeObservedWallpaperEngine(
                in: tempDir,
                extractFirstFrameStill: false,
                mockDisplays: mockDisplays
            )

            let onBatteryBox = LockedBox(false)
            let fullscreenDisplay1Box = LockedBox(false)
            let monitor = PowerMonitor(
                initialSettings: PowerSettings(pauseOnBattery: true, pauseOnFullscreen: true, pauseOnScreenLockOrSleep: true),
                occlusionPollingInterval: 0,
                batteryStateProvider: { onBatteryBox.value },
                windowListProvider: {
                    guard fullscreenDisplay1Box.value else { return [] }
                    return [
                        [
                            kCGWindowLayer as String: 0,
                            kCGWindowAlpha as String: 1.0,
                            kCGWindowIsOnscreen as String: true,
                            kCGWindowOwnerPID as String: Int32(99_999),
                            kCGWindowOwnerName as String: "FullscreenPlayer",
                            kCGWindowBounds as String: d1Bounds
                        ]
                    ]
                },
                displaysProvider: {
                    [(id: UInt32(1), bounds: d1Bounds), (id: UInt32(2), bounds: d2Bounds)]
                }
            )
            monitor.onInputsChanged = { inputs in
                engine.updatePowerInputs(inputs)
            }

            let video = WallpaperItem(id: "commute-v", title: "Commute Aerial", source: .starter, mediaType: .video, localPath: mp4URL)
            engine.apply(wallpaper: video, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            engine.updatePowerInputs(monitor.inputs)

            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == [1, 2])
            #expect(engine.activeWallpapers[1]?.id == "commute-v")
            #expect(engine.activeWallpapers[2]?.id == "commute-v")

            // 1. On AC power -> Playing on both displays
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Playing")
            #expect(engine.currentDecisions[1] == .play)
            #expect(engine.currentDecisions[2] == .play)
            #expect(engine.isPaused(for: 1) == false)
            #expect(engine.isPaused(for: 2) == false)

            // 2. Unplug power -> On Battery pauses both displays
            onBatteryBox.withValue { $0 = true }
            monitor.refreshNow()
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Paused — On Battery")
            #expect(engine.currentDecisions[1] == .pause(.onBattery))
            #expect(engine.currentDecisions[2] == .pause(.onBattery))
            #expect(engine.isPaused(for: 1) == true)
            #expect(engine.isPaused(for: 2) == true)

            // 3. User activates session battery override -> Playing on both displays
            monitor.setBatteryOverride(true)
            #expect(monitor.inputs.batteryOverrideActive == true)
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Playing")
            #expect(engine.currentDecisions[1] == .play)
            #expect(engine.currentDecisions[2] == .play)
            #expect(engine.isPaused(for: 1) == false)
            #expect(engine.isPaused(for: 2) == false)

            // 4. Fullscreen app on display 1 -> display 1 pauses (.fullscreenOccluded), display 2 plays (.play)
            fullscreenDisplay1Box.withValue { $0 = true }
            monitor.refreshNow()
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1], activeMediaType: .video) == "Paused — Fullscreen App")
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Playing")
            #expect(engine.currentDecisions[1] == .pause(.fullscreenOccluded))
            #expect(engine.currentDecisions[2] == .play)
            #expect(engine.isPaused(for: 1) == true)
            #expect(engine.isPaused(for: 2) == false)

            // 5. Screen locked -> overrides everything on both displays
            var lockedInputs = monitor.inputs
            lockedInputs.screenLocked = true
            engine.updatePowerInputs(lockedInputs)
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: lockedInputs, displayIDs: [1, 2], activeMediaType: .video) == "Paused — Display Asleep / Locked")
            #expect(engine.currentDecisions[1] == .pause(.displayAsleepOrLocked))
            #expect(engine.currentDecisions[2] == .pause(.displayAsleepOrLocked))
            #expect(engine.isPaused(for: 1) == true)
            #expect(engine.isPaused(for: 2) == true)

            // 6. Unlock + exit fullscreen + AC power restored -> batteryOverrideActive auto-clears and both displays play
            fullscreenDisplay1Box.withValue { $0 = false }
            onBatteryBox.withValue { $0 = false }
            monitor.refreshNow()
            #expect(monitor.inputs.onBattery == false)
            #expect(monitor.inputs.batteryOverrideActive == false)
            #expect(monitor.inputs.fullscreenDisplayIDs.isEmpty)
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Playing")
            #expect(engine.currentDecisions[1] == .play)
            #expect(engine.currentDecisions[2] == .play)
            #expect(engine.isPaused(for: 1) == false)
            #expect(engine.isPaused(for: 2) == false)

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
        }
    }

    @MainActor
    @Test("T4-05: Cache bloat cleanup preserves active desktop wallpaper and local imports")
    func cacheBloatCleanupPreservingActiveAndImported() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let videoURL = try await E2EHelpers.firstVideoURL(from: baseURL)
                let imageURL = try await E2EHelpers.firstImageURL(from: baseURL)

                let cache = E2EHelpers.makeCacheManager(in: tempDir)
                let activeItem = WallpaperItem(id: "keep-active", title: "Active Desktop", source: .customFeed, mediaType: .video, fullAssetURL: videoURL)
                let oldOne = WallpaperItem(id: "old-one", title: "Old 1", source: .customFeed, mediaType: .video, fullAssetURL: videoURL)
                let oldTwo = WallpaperItem(id: "old-two", title: "Old 2", source: .customFeed, mediaType: .image, fullAssetURL: imageURL)

                let activeCachedURL = try await cache.download(activeItem)
                let oldOneURL = try await cache.download(oldOne)
                let oldTwoURL = try await cache.download(oldTwo)

                let rawMovURL = try E2EHelpers.resolveMediaFixture(extension: "mov", in: tempDir)
                let importsDir = tempDir.appendingPathComponent("imports", isDirectory: true)
                let thumbsDir = tempDir.appendingPathComponent("thumbs", isDirectory: true)
                let localImport = try await LocalMediaImporter.importFile(
                    from: rawMovURL,
                    importsDir: importsDir,
                    thumbsDir: thumbsDir
                )
                #expect(localImport.source == .localImport)
                #expect(localImport.mediaType == .video)
                let importedMovURL = try #require(localImport.localPath)
                let importedThumbURL = try #require(localImport.previewImageURL)
                #expect(FileManager.default.fileExists(atPath: importedMovURL.path))
                #expect(FileManager.default.fileExists(atPath: importedThumbURL.path))

                var activeWithPath = activeItem
                activeWithPath.localPath = activeCachedURL

                let mockDisplays: [(id: UInt32, frame: NSRect, name: String)] = [
                    (id: 1, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "Primary")
                ]
                let (engine, _) = E2EHelpers.makeObservedWallpaperEngine(
                    in: tempDir,
                    extractFirstFrameStill: false,
                    mockDisplays: mockDisplays
                )
                engine.apply(wallpaper: activeWithPath, localURL: activeCachedURL, to: nil, mode: .mirrorAll, scaling: .fill)
                #expect(engine.lastErrorMessage == nil)
                #expect(engine.activeVideoDisplayIDs == [1])
                #expect(engine.activeWallpapers[1]?.id == activeItem.id)

                let store = E2EHelpers.makeLibraryStore(in: tempDir)
                await store.addLocalImport(localImport)
                await store.updateDisplayConfig(
                    DisplayConfig(
                        mode: .mirrorAll,
                        assignments: [
                            DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: activeWithPath)
                        ]
                    )
                )
                try await store.save()

                let activeSize = Int64(try Data(contentsOf: activeCachedURL).count)
                let oldSize = Int64(try Data(contentsOf: oldOneURL).count + Data(contentsOf: oldTwoURL).count)
                #expect(await cache.totalCacheSizeBytes() == activeSize + oldSize)

                let activeURLs = await store.activeWallpaperLocalURLs()
                let freed = try await cache.clearCache(preserving: activeURLs)

                #expect(freed == oldSize)
                #expect(await cache.totalCacheSizeBytes() == activeSize)
                #expect(await cache.cachedFileURL(for: activeItem) == activeCachedURL)
                #expect(await cache.cachedFileURL(for: oldOne) == nil)
                #expect(await cache.cachedFileURL(for: oldTwo) == nil)
                #expect(FileManager.default.fileExists(atPath: activeCachedURL.path))
                #expect(!FileManager.default.fileExists(atPath: oldOneURL.path))
                #expect(!FileManager.default.fileExists(atPath: oldTwoURL.path))
                #expect(FileManager.default.fileExists(atPath: importedMovURL.path))
                #expect(FileManager.default.fileExists(atPath: importedThumbURL.path))

                engine.teardownAllVideoWindows()
                #expect(engine.activeVideoDisplayIDs.isEmpty)
                #expect(engine.activeWallpapers.isEmpty)
            }
        }
    }

    @Test("T4-06: Multi-provider aggregation isolates invalid API keys, rate limits, and failing custom feed")
    func multiProviderAggregationWithInvalidKeysAndCustomFeed() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let secretStore = E2EHelpers.makeSecretStore(in: tempDir)
                try await secretStore.save(
                    ApiSecrets(
                        pexelsAPIKey: "invalid_key_123",
                        pixabayAPIKey: "invalid_key_123",
                        wallhavenAPIKey: "invalid_key_123"
                    )
                )
                #expect(try E2EHelpers.posixPermissions(of: await secretStore.fileURL) == 0o600)
                let invalidSecrets = try await secretStore.load()

                let mockService = E2EHelpers.makeMockCatalogService(baseURL: baseURL)

                // (a) Invalid keys + HTTP 500 custom feed: Starter succeeds, all other 4 isolate errors
                let failingResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.starter, .customFeed, .wallhaven, .pexels, .pixabay]),
                    secrets: invalidSecrets,
                    customFeedURL: baseURL.appendingPathComponent("custom/error500.html")
                )
                let failingItems = E2EHelpers.extractItems(from: failingResult)
                let failingProviders = E2EHelpers.extractProviderResults(from: failingResult)
                #expect(failingItems.contains(where: { $0.source == .starter }))
                #expect(failingProviders.first(where: { $0.source == .starter })?.errorMessage == nil)
                for failingSource in [WallpaperSource.customFeed, .wallhaven, .pexels, .pixabay] {
                    let res = try #require(failingProviders.first(where: { $0.source == failingSource }))
                    #expect(res.errorMessage != nil)
                    #expect(res.items.isEmpty)
                }

                // (b) Rate limit (429) on Wallhaven/Pexels/Pixabay + malformed custom feed: Starter succeeds, 429s isolated
                try await secretStore.save(
                    ApiSecrets(
                        pexelsAPIKey: "valid_key",
                        pixabayAPIKey: "valid_key",
                        wallhavenAPIKey: nil
                    )
                )
                #expect(try E2EHelpers.posixPermissions(of: await secretStore.fileURL) == 0o600)
                let validSecrets = try await secretStore.load()

                let rateLimitResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(text: "ratelimit", sources: [.starter, .customFeed, .wallhaven, .pexels, .pixabay]),
                    secrets: validSecrets,
                    customFeedURL: baseURL.appendingPathComponent("custom/malformed.json")
                )
                let rlProviders = E2EHelpers.extractProviderResults(from: rateLimitResult)
                let rlStarter = try #require(rlProviders.first(where: { $0.source == .starter }))
                #expect(rlStarter.errorMessage == nil)
                for rlSource in [WallpaperSource.wallhaven, .pexels, .pixabay] {
                    let res = try #require(rlProviders.first(where: { $0.source == rlSource }))
                    let err = try #require(res.errorMessage)
                    #expect(err.localizedCaseInsensitiveContains("rate limit"))
                    #expect(res.items.isEmpty)
                }
                let rlCustom = try #require(rlProviders.first(where: { $0.source == .customFeed }))
                #expect(rlCustom.errorMessage != nil)
                #expect(rlCustom.items.isEmpty)

                // (c) Healthy recovery with valid keys + wrapped custom feed: all 5 providers succeed
                let recoveredResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.starter, .customFeed, .wallhaven, .pexels, .pixabay]),
                    secrets: validSecrets,
                    customFeedURL: baseURL.appendingPathComponent("custom/wrapped.json")
                )
                let recoveredProviders = E2EHelpers.extractProviderResults(from: recoveredResult)
                for source in [WallpaperSource.starter, .customFeed, .wallhaven, .pexels, .pixabay] {
                    let res = try #require(recoveredProviders.first(where: { $0.source == source }))
                    #expect(res.errorMessage == nil)
                    #expect(!res.items.isEmpty)
                }

                // Live mode parity check (without sending bogus keys to real Pexels/Pixabay)
                if !E2EEnvironment.noLive {
                    let liveService = E2EHelpers.makeCatalogService()
                    let liveResult = await liveService.fetchCatalog(
                        query: E2EHelpers.makeQuery(sources: [.starter, .wallhaven, .customFeed]),
                        secrets: ApiSecrets(),
                        customFeedURL: baseURL.appendingPathComponent("custom/error500.html")
                    )
                    let liveProviders = E2EHelpers.extractProviderResults(from: liveResult)
                    let liveStarter = try #require(liveProviders.first(where: { $0.source == .starter }))
                    let liveWallhaven = try #require(liveProviders.first(where: { $0.source == .wallhaven }))
                    let liveCustom = try #require(liveProviders.first(where: { $0.source == .customFeed }))
                    #expect(liveStarter.errorMessage == nil)
                    #expect(!liveStarter.items.isEmpty)
                    #expect(liveWallhaven.errorMessage == nil)
                    #expect(!liveWallhaven.items.isEmpty)
                    #expect(liveCustom.errorMessage != nil)
                }
            }
        }
    }
}
