import AppKit
import Foundation
import Testing
import AuraWallCore

@Suite("Tier3 Combination E2E Tests")
struct Tier3CombinationE2ETests {

    @Test("T3-01 (F2, F3): Custom feed fetch -> streaming download -> favorite & recent -> persist -> reload")
    func customFeedDownloadFavoritePersistReload() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let feedURL = baseURL.appendingPathComponent("custom/wrapped.json")
                let service = E2EHelpers.makeCatalogService()
                let catalog = await service.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.customFeed]),
                    secrets: ApiSecrets(),
                    customFeedURL: feedURL
                )
                let providerResult = try #require(
                    E2EHelpers.extractProviderResults(from: catalog).first(where: { $0.source == .customFeed })
                )
                #expect(providerResult.errorMessage == nil)

                let fetchedItems = E2EHelpers.extractItems(from: catalog)
                let targetItem = try #require(fetchedItems.first(where: { $0.fullAssetURL != nil }))

                let cache = E2EHelpers.makeCacheManager(in: tempDir)
                let progress = LockedBox<[Double]>([])
                let cachedURL = try await cache.download(targetItem) { val in
                    progress.withValue { $0.append(val) }
                }
                #expect(progress.value.count >= 2)
                #expect(progress.value.first != nil)
                #expect(progress.value.last == 1.0)
                #expect(FileManager.default.fileExists(atPath: cachedURL.path))
                #expect(await cache.totalCacheSizeBytes() > 0)

                var persistedItem = targetItem
                persistedItem.localPath = cachedURL

                let store = E2EHelpers.makeLibraryStore(in: tempDir)
                #expect(await store.activeWallpaperLocalURLs().isEmpty)
                #expect(await store.toggleFavorite(persistedItem) == true)
                await store.recordRecent(persistedItem)
                await store.updateDisplayConfig(
                    DisplayConfig(
                        mode: .mirrorAll,
                        assignments: [
                            DisplayConfig.mirrorAssignmentKey: DisplayAssignment(
                                displayID: 0,
                                displayName: "Mirror",
                                wallpaper: persistedItem,
                                scalingMode: .fill
                            )
                        ]
                    )
                )
                try await store.save()

                let reloadedStore = LibraryStore(baseDirectory: await store.baseDirectory)
                let loadedState = try await reloadedStore.load()
                #expect(loadedState.favorites.contains(where: {
                    $0.id == persistedItem.id && $0.source == .customFeed && $0.localPath == cachedURL
                }))
                #expect(loadedState.recents.contains(where: {
                    $0.id == persistedItem.id && $0.source == .customFeed && $0.localPath == cachedURL
                }))
                #expect(await reloadedStore.activeWallpaperLocalURLs() == Set([PathCanonicalizer.canonicalFileURL(cachedURL)]))
                #expect(await cache.cachedFileURL(for: targetItem) == cachedURL)
            }
        }
    }

    @MainActor
    @Test("T3-02 (F3, F4, F5): Download -> apply video -> battery pause & AC resume -> safe clear cache")
    func downloadApplyBatteryPauseSafeClearCache() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let videoURL = try await E2EHelpers.firstVideoURL(from: baseURL)
                let imageURL = try await E2EHelpers.firstImageURL(from: baseURL)

                let cache = E2EHelpers.makeCacheManager(in: tempDir)
                let itemAlpha = WallpaperItem(id: "t3-alpha", title: "Active Video", source: .customFeed, mediaType: .video, fullAssetURL: videoURL)
                let itemBravo = WallpaperItem(id: "t3-bravo", title: "Unused Image", source: .customFeed, mediaType: .image, fullAssetURL: imageURL)

                let cachedAlpha = try await cache.download(itemAlpha)
                let cachedBravo = try await cache.download(itemBravo)

                let alphaAttrs = try FileManager.default.attributesOfItem(atPath: cachedAlpha.path)
                let bravoAttrs = try FileManager.default.attributesOfItem(atPath: cachedBravo.path)
                let alphaBytes = (alphaAttrs[.size] as? NSNumber)?.int64Value ?? 0
                let bravoBytes = (bravoAttrs[.size] as? NSNumber)?.int64Value ?? 0
                #expect(alphaBytes > 0)
                #expect(bravoBytes > 0)
                #expect(await cache.totalCacheSizeBytes() == alphaBytes + bravoBytes)

                var activeAlpha = itemAlpha
                activeAlpha.localPath = cachedAlpha

                let powerSettings = PowerSettings(pauseOnBattery: true, pauseOnFullscreen: true, pauseOnScreenLockOrSleep: true)
                let store = E2EHelpers.makeLibraryStore(in: tempDir)
                await store.updateSettings(AppSettings(power: powerSettings))
                await store.updateDisplayConfig(
                    DisplayConfig(
                        mode: .mirrorAll,
                        assignments: [
                            DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: activeAlpha, scalingMode: .fill)
                        ]
                    )
                )
                try await store.save()

                let reloadedStore = LibraryStore(baseDirectory: await store.baseDirectory)
                let reloadedState = try await reloadedStore.load()
                #expect(reloadedState.settings.power == powerSettings)

                let mockDisplays: [(id: UInt32, frame: NSRect, name: String)] = [
                    (id: 1, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "Primary")
                ]
                let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(
                    in: tempDir,
                    extractFirstFrameStill: false,
                    mockDisplays: mockDisplays
                )

                engine.apply(wallpaper: activeAlpha, localURL: cachedAlpha, to: nil, mode: .mirrorAll, scaling: .fill)
                #expect(engine.lastErrorMessage == nil)
                #expect(engine.activeVideoDisplayIDs == [1])
                #expect(engine.activeWallpapers[1]?.id == activeAlpha.id)
                #expect(engine.currentDecisions[1] == .play)
                #expect(engine.isPaused(for: 1) == false)
                #expect(desktopCalls.value.isEmpty)

                var batteryInputs = PowerInputs(onBattery: true)
                batteryInputs.applying(settings: reloadedState.settings.power)
                #expect(PowerPolicyEvaluator.evaluate(inputs: batteryInputs, forDisplay: 1) == .pause(.onBattery))
                engine.updatePowerInputs(batteryInputs)
                #expect(engine.currentPowerInputs.onBattery == true)
                #expect(engine.currentDecisions[1] == .pause(.onBattery))
                #expect(engine.isPaused(for: 1) == true)

                var acInputs = PowerInputs(onBattery: false)
                acInputs.applying(settings: reloadedState.settings.power)
                engine.updatePowerInputs(acInputs)
                #expect(engine.currentPowerInputs.onBattery == false)
                #expect(engine.currentDecisions[1] == .play)
                #expect(engine.isPaused(for: 1) == false)

                let activeURLs = await reloadedStore.activeWallpaperLocalURLs()
                #expect(activeURLs == Set([PathCanonicalizer.canonicalFileURL(cachedAlpha)]))
                let freed = try await cache.clearCache(preserving: activeURLs)
                #expect(freed == bravoBytes)
                #expect(await cache.totalCacheSizeBytes() == alphaBytes)
                #expect(FileManager.default.fileExists(atPath: cachedAlpha.path))
                #expect(!FileManager.default.fileExists(atPath: cachedBravo.path))

                engine.teardownAllVideoWindows()
                #expect(engine.activeVideoDisplayIDs.isEmpty)
                #expect(engine.activeWallpapers.isEmpty)
                #expect(engine.currentDecisions.isEmpty)
            }
        }
    }

    @MainActor
    @Test("T3-03 (F3, F6, F4): LocalMediaImporter video & image -> apply -> switch static -> GPU teardown")
    func localImportVideoApplySwitchStaticTeardown() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let jpgURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)
            let importsDir = tempDir.appendingPathComponent("imports", isDirectory: true)
            let thumbsDir = tempDir.appendingPathComponent("thumbs", isDirectory: true)

            let localVideo = try await LocalMediaImporter.importFile(from: mp4URL, importsDir: importsDir, thumbsDir: thumbsDir)
            let localImage = try await LocalMediaImporter.importFile(from: jpgURL, importsDir: importsDir, thumbsDir: thumbsDir)

            let canonicalImportsDir = PathCanonicalizer.canonicalFileURL(importsDir)
            let canonicalThumbsDir = PathCanonicalizer.canonicalFileURL(thumbsDir)

            #expect(localVideo.source == .localImport)
            #expect(localVideo.mediaType == .video)
            let importedVideoPath = try #require(localVideo.localPath)
            #expect(PathCanonicalizer.canonicalFileURL(importedVideoPath.deletingLastPathComponent()) == canonicalImportsDir)
            #expect(FileManager.default.fileExists(atPath: importedVideoPath.path))
            #expect((localVideo.width ?? 0) > 0 && (localVideo.height ?? 0) > 0)
            let videoThumbPath = try #require(localVideo.previewImageURL)
            #expect(PathCanonicalizer.canonicalFileURL(videoThumbPath.deletingLastPathComponent()) == canonicalThumbsDir)
            #expect(FileManager.default.fileExists(atPath: videoThumbPath.path))

            #expect(localImage.source == .localImport)
            #expect(localImage.mediaType == .image)
            let importedImagePath = try #require(localImage.localPath)
            #expect(PathCanonicalizer.canonicalFileURL(importedImagePath.deletingLastPathComponent()) == canonicalImportsDir)
            #expect(FileManager.default.fileExists(atPath: importedImagePath.path))
            #expect((localImage.width ?? 0) > 0 && (localImage.height ?? 0) > 0)

            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            await store.addLocalImport(localVideo)
            await store.addLocalImport(localImage)
            try await store.save()

            let reloaded = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
            #expect(reloaded.localImports.count == 2)
            #expect(reloaded.localImports.contains(where: { $0.id == localVideo.id && $0.localPath == importedVideoPath }))
            #expect(reloaded.localImports.contains(where: { $0.id == localImage.id && $0.localPath == importedImagePath }))

            let mockDisplays: [(id: UInt32, frame: NSRect, name: String)] = [
                (id: 1, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "Primary")
            ]
            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(
                in: tempDir,
                extractFirstFrameStill: false,
                mockDisplays: mockDisplays
            )

            engine.apply(wallpaper: localVideo, localURL: importedVideoPath, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == [1])
            #expect(engine.activeWallpapers[1]?.id == localVideo.id)
            #expect(engine.currentDecisions[1] == .play)
            #expect(engine.isPaused(for: 1) == false)
            #expect(desktopCalls.value.isEmpty)

            engine.apply(wallpaper: localImage, localURL: importedImagePath, to: nil, mode: .mirrorAll, scaling: .fit)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
            #expect(engine.activeWallpapers[1]?.id == localImage.id)
            #expect(desktopCalls.value.count == 1)
            let desktopCall = try #require(desktopCalls.value.first)
            #expect(desktopCall.displayID == 1)
            #expect(desktopCall.imageURL == importedImagePath)
            #expect(desktopCall.allowClipping == false)
            #expect(desktopCall.hasFillColor == true)

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers[1]?.id == localImage.id)
        }
    }

    @Test("T3-04 (F2, F6): Settings custom feed + 0600 secrets -> multi-provider error isolation")
    func settingsCustomFeedAnd0600SecretsErrorIsolation() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let store = E2EHelpers.makeLibraryStore(in: tempDir)
                let secretStore = E2EHelpers.makeSecretStore(in: tempDir)

                let brokenFeed = baseURL.appendingPathComponent("custom/error500.html")
                await store.updateSettings(AppSettings(customFeedURL: brokenFeed.absoluteString))
                try await store.save()

                try await secretStore.save(
                    ApiSecrets(
                        pexelsAPIKey: "invalid_key_123",
                        pixabayAPIKey: "invalid_key_123",
                        wallhavenAPIKey: "invalid_key_123"
                    )
                )
                let secretPerms = try E2EHelpers.posixPermissions(of: await secretStore.fileURL)
                #expect(secretPerms == 0o600)

                let loadedState = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
                let loadedSecrets = try await SecretStore(fileURL: await secretStore.fileURL).load()
                #expect(loadedState.settings.customFeedURL == brokenFeed.absoluteString)
                #expect(loadedState.settings.validatedCustomFeedURL == brokenFeed)
                #expect(loadedSecrets.normalizedPexelsKey == "invalid_key_123")
                #expect(loadedSecrets.normalizedPixabayKey == "invalid_key_123")
                #expect(loadedSecrets.normalizedWallhavenKey == "invalid_key_123")

                // Concurrent 5-provider isolation against mock server (Starter healthy vs Custom 500 + Wallhaven 401 + Pexels 401 + Pixabay 400)
                let mockService = E2EHelpers.makeMockCatalogService(baseURL: baseURL)
                let isolatedResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.starter, .customFeed, .wallhaven, .pexels, .pixabay]),
                    secrets: loadedSecrets,
                    customFeedURL: loadedState.settings.validatedCustomFeedURL
                )
                let isolatedItems = E2EHelpers.extractItems(from: isolatedResult)
                let isolatedResults = E2EHelpers.extractProviderResults(from: isolatedResult)
                #expect(isolatedItems.contains(where: { $0.source == .starter }))
                #expect(isolatedResults.first(where: { $0.source == .starter })?.errorMessage == nil)
                for failingSource in [WallpaperSource.customFeed, .wallhaven, .pexels, .pixabay] {
                    let res = try #require(isolatedResults.first(where: { $0.source == failingSource }))
                    #expect(res.errorMessage != nil)
                    #expect(res.items.isEmpty)
                }

                // Also verify Wallhaven 500 HTML + malformed custom feed isolate cleanly
                let malformedResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(text: "error500", sources: [.customFeed, .wallhaven, .pexels, .pixabay]),
                    secrets: loadedSecrets,
                    customFeedURL: baseURL.appendingPathComponent("custom/malformed.json")
                )
                #expect(E2EHelpers.extractItems(from: malformedResult).isEmpty)
                for failingSource in [WallpaperSource.customFeed, .wallhaven, .pexels, .pixabay] {
                    #expect(E2EHelpers.extractProviderResults(from: malformedResult).first(where: { $0.source == failingSource })?.errorMessage != nil)
                }

                if !E2EEnvironment.noLive {
                    let liveService = E2EHelpers.makeCatalogService()
                    let liveResult = await liveService.fetchCatalog(
                        query: E2EHelpers.makeQuery(sources: [.starter, .customFeed]),
                        secrets: loadedSecrets,
                        customFeedURL: loadedState.settings.validatedCustomFeedURL
                    )
                    let liveItems = E2EHelpers.extractItems(from: liveResult)
                    let liveResults = E2EHelpers.extractProviderResults(from: liveResult)
                    #expect(liveItems.contains(where: { $0.source == .starter }))
                    #expect(liveResults.first(where: { $0.source == .starter })?.errorMessage == nil)
                    #expect(liveResults.first(where: { $0.source == .customFeed })?.errorMessage != nil)
                }

                // Recovery: update settings to wrapped custom feed + valid API keys, reload, and verify all 5 providers succeed
                let healthyFeed = baseURL.appendingPathComponent("custom/wrapped.json")
                await store.updateSettings(AppSettings(customFeedURL: healthyFeed.absoluteString))
                try await store.save()
                try await secretStore.save(ApiSecrets(pexelsAPIKey: "valid_key", pixabayAPIKey: "valid_key", wallhavenAPIKey: nil))
                #expect(try E2EHelpers.posixPermissions(of: await secretStore.fileURL) == 0o600)

                let reloadedHealthyState = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
                let reloadedHealthySecrets = try await SecretStore(fileURL: await secretStore.fileURL).load()
                let recoveredResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.starter, .customFeed, .wallhaven, .pexels, .pixabay]),
                    secrets: reloadedHealthySecrets,
                    customFeedURL: reloadedHealthyState.settings.validatedCustomFeedURL
                )
                let recoveredResults = E2EHelpers.extractProviderResults(from: recoveredResult)
                for source in [WallpaperSource.starter, .customFeed, .wallhaven, .pexels, .pixabay] {
                    let res = try #require(recoveredResults.first(where: { $0.source == source }))
                    #expect(res.errorMessage == nil)
                    #expect(!res.items.isEmpty)
                }
            }
        }
    }

    @MainActor
    @Test("T3-05 (F5, F6): Settings power toggles, PowerMonitor, and battery override drive menu bar status & engine pause")
    func settingsPowerTogglesAndMenuBarBatteryOverride() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let initialPower = PowerSettings(pauseOnBattery: true, pauseOnFullscreen: true, pauseOnScreenLockOrSleep: true)
            await store.updateSettings(AppSettings(power: initialPower))
            try await store.save()

            let reloaded = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
            #expect(reloaded.settings.power == initialPower)

            let onBatteryBox = LockedBox(true)
            let display1Bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let display2Bounds = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

            let mockDisplays: [(id: UInt32, frame: NSRect, name: String)] = [
                (id: 1, frame: display1Bounds, name: "Display 1"),
                (id: 2, frame: display2Bounds, name: "Display 2")
            ]
            let (engine, _) = E2EHelpers.makeObservedWallpaperEngine(
                in: tempDir,
                extractFirstFrameStill: false,
                mockDisplays: mockDisplays
            )

            let monitor = PowerMonitor(
                initialSettings: reloaded.settings.power,
                occlusionPollingInterval: 0,
                batteryStateProvider: { onBatteryBox.value },
                windowListProvider: {
                    [
                        [
                            kCGWindowLayer as String: 0,
                            kCGWindowAlpha as String: 1.0,
                            kCGWindowIsOnscreen as String: true,
                            kCGWindowOwnerPID as String: Int32(99_999),
                            kCGWindowOwnerName as String: "FullscreenVideoPlayer",
                            kCGWindowBounds as String: display1Bounds
                        ]
                    ]
                },
                displaysProvider: {
                    [(id: UInt32(1), bounds: display1Bounds), (id: UInt32(2), bounds: display2Bounds)]
                }
            )
            monitor.onInputsChanged = { inputs in
                engine.updatePowerInputs(inputs)
            }

            let videoItem = WallpaperItem(id: "t3-05-v", title: "Status Video", source: .starter, mediaType: .video, localPath: mp4URL)
            engine.apply(wallpaper: videoItem, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            engine.updatePowerInputs(monitor.inputs)
            #expect(engine.activeVideoDisplayIDs == [1, 2])

            // 1. On battery -> both displays paused, label "Paused — On Battery"
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Paused — On Battery")
            #expect(engine.isPaused(for: 1) == true)
            #expect(engine.isPaused(for: 2) == true)

            // 2. Battery override active with display 1 fullscreen occluded -> display 1 paused, display 2 playing
            monitor.setBatteryOverride(true)
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1], activeMediaType: .video) == "Paused — Fullscreen App")
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Playing")
            #expect(engine.isPaused(for: 1) == true)
            #expect(engine.isPaused(for: 2) == false)

            // 3. Manual pause overrides everything -> both paused, label "Paused — Manual"
            monitor.setManualPause(true)
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Paused — Manual")
            #expect(engine.isPaused(for: 1) == true)
            #expect(engine.isPaused(for: 2) == true)

            // 4. Persist disabled battery/fullscreen power toggles -> reload -> apply to monitor -> unpause manual
            let disabledPower = PowerSettings(pauseOnBattery: false, pauseOnFullscreen: false, pauseOnScreenLockOrSleep: true)
            await store.updateSettings(AppSettings(power: disabledPower))
            try await store.save()
            let reloadedDisabled = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
            monitor.applySettings(reloadedDisabled.settings.power)
            monitor.setManualPause(false)

            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .video) == "Playing")
            #expect(engine.isPaused(for: 1) == false)
            #expect(engine.isPaused(for: 2) == false)

            // 5. Static image & Ready (nil) menu bar status labels
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: .image) == "Static")
            #expect(PowerPolicyEvaluator.menuBarStatusLabel(inputs: monitor.inputs, displayIDs: [1, 2], activeMediaType: nil) == "Ready")

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
        }
    }

    @Test("T3-07 (F1, F2): Live Starter/Wallhaven smoke when enabled; offline mock Starter/Wallhaven/CustomFeed when AURAWALL_E2E_NO_LIVE=1")
    func starterAndWallhavenCatalogSmoke() async throws {
        if !E2EEnvironment.noLive {
            let service = E2EHelpers.makeCatalogService()
            let starterResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(mediaType: .video, sources: [.starter]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            let starterProvider = try #require(
                E2EHelpers.extractProviderResults(from: starterResult).first(where: { $0.source == .starter })
            )
            #expect(starterProvider.errorMessage == nil)
            let starterItems = E2EHelpers.extractItems(from: starterResult)
            #expect(!starterItems.isEmpty)
            #expect(starterItems.allSatisfy { $0.fullAssetURL?.scheme?.lowercased() == "https" })

            let wallhavenResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "landscape", mediaType: .image, sources: [.wallhaven], sorting: .top, page: 1),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            let whProvider = try #require(
                E2EHelpers.extractProviderResults(from: wallhavenResult).first(where: { $0.source == .wallhaven })
            )
            #expect(whProvider.errorMessage == nil)
            let whItems = E2EHelpers.extractItems(from: wallhavenResult)
            #expect(!whItems.isEmpty)
            #expect(whItems.allSatisfy { $0.fullAssetURL?.scheme?.lowercased() == "https" && $0.tags.contains("sfw") })
        } else {
            try await E2EHelpers.withMockBaseURL { baseURL in
                let mockService = CatalogService(providers: [
                    StarterVideoProvider(
                        resources16TarURL: baseURL.appendingPathComponent("aerials/resources-16.tar"),
                        aerials2xURL: baseURL.appendingPathComponent("aerials/2x/entries.json"),
                        probeURLsIn2xFallback: true
                    ),
                    WallhavenProvider(baseURL: baseURL.appendingPathComponent("wallhaven")),
                    CustomFeedProvider()
                ])

                let starterResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(mediaType: .video, sources: [.starter]),
                    secrets: ApiSecrets(),
                    customFeedURL: nil
                )
                let starterProvider = try #require(
                    E2EHelpers.extractProviderResults(from: starterResult).first(where: { $0.source == .starter })
                )
                #expect(starterProvider.errorMessage == nil)
                let starterItems = E2EHelpers.extractItems(from: starterResult)
                #expect(!starterItems.isEmpty)
                #expect(starterItems.allSatisfy { $0.source == .starter && $0.mediaType == .video && $0.fullAssetURL != nil })

                let wallhavenResult = await mockService.fetchCatalog(
                    query: E2EHelpers.makeQuery(text: "landscape", mediaType: .image, sources: [.wallhaven], sorting: .top, page: 1),
                    secrets: ApiSecrets(),
                    customFeedURL: nil
                )
                let whProvider = try #require(
                    E2EHelpers.extractProviderResults(from: wallhavenResult).first(where: { $0.source == .wallhaven })
                )
                #expect(whProvider.errorMessage == nil)
                let whItems = E2EHelpers.extractItems(from: wallhavenResult)
                #expect(!whItems.isEmpty)
                #expect(whItems.allSatisfy { $0.source == .wallhaven && $0.mediaType == .image && $0.tags.contains("sfw") })

                let wrappedItems = try await E2EHelpers.fetchCustomFeedItems(from: baseURL, path: "/custom/wrapped.json")
                let arrayItems = try await E2EHelpers.fetchCustomFeedItems(from: baseURL, path: "/custom/array.json")
                #expect(wrappedItems.contains(where: { $0.mediaType == .video }))
                #expect(wrappedItems.contains(where: { $0.mediaType == .image }))
                #expect(!arrayItems.isEmpty)
            }

            if let aerial = try E2EHelpers.loadFixtureJSONObjectIfPresent(named: "aerial_r16_entries.json") {
                #expect(((aerial["assets"] as? [[String: Any]])?.isEmpty ?? true) == false)
            }
            if let wallhaven = try E2EHelpers.loadFixtureJSONObjectIfPresent(named: "wallhaven_string_query.json") {
                #expect(((wallhaven["data"] as? [[String: Any]])?.isEmpty ?? true) == false)
            }
        }
    }

    @MainActor
    @Test("T3-08 (F1, F3, F4): Standalone SwiftE2E persistence, isolated first-frame still, and WallpaperEngine teardown")
    func standaloneSwiftE2EPersistenceAndEngineTeardown() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let item = WallpaperItem(id: "t3-08-v", title: "T3-08 Video", source: .starter, mediaType: .video, localPath: mp4URL)

            await store.updateDisplayConfig(
                DisplayConfig(
                    mode: .mirrorAll,
                    assignments: [
                        DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: item)
                    ]
                )
            )
            try await store.save()

            let reloadedStore = LibraryStore(baseDirectory: await store.baseDirectory)
            let reloaded = try await reloadedStore.load()
            let active = try #require(reloaded.displayConfig.activeWallpapers().first)
            #expect(await reloadedStore.activeWallpaperLocalURLs().contains(PathCanonicalizer.canonicalFileURL(mp4URL)))

            let mockDisplays: [(id: UInt32, frame: NSRect, name: String)] = [
                (id: 1, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "E2E-1")
            ]
            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(
                in: tempDir,
                extractFirstFrameStill: true,
                mockDisplays: mockDisplays
            )

            engine.apply(wallpaper: active, localURL: active.localPath, to: nil, mode: reloaded.displayConfig.mode, scaling: .fill)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == [1])
            #expect(engine.activeWallpapers[1]?.id == "t3-08-v")
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

    @MainActor
    @Test("T3-09 (F1, F5): PowerPolicyEvaluator priority matrix, FullscreenDetector, and PowerMonitor integration")
    func powerPolicyPriorityMatrix() {
        let matrix: [(PowerInputs, UInt32, PowerDecision)] = [
            (PowerInputs(displayAsleep: true, screenLocked: false, manualPause: true, onBattery: true, fullscreenDisplayIDs: [1]), 1, .pause(.displayAsleepOrLocked)),
            (PowerInputs(displayAsleep: false, screenLocked: true, manualPause: true, onBattery: true, fullscreenDisplayIDs: [1]), 1, .pause(.displayAsleepOrLocked)),
            (PowerInputs(displayAsleep: false, screenLocked: false, manualPause: true, onBattery: true, fullscreenDisplayIDs: [1]), 1, .pause(.manual)),
            (PowerInputs(displayAsleep: false, screenLocked: false, manualPause: false, onBattery: true, batteryOverrideActive: false, fullscreenDisplayIDs: [1]), 1, .pause(.onBattery)),
            (PowerInputs(displayAsleep: false, screenLocked: false, manualPause: false, onBattery: true, batteryOverrideActive: true, fullscreenDisplayIDs: [1]), 1, .pause(.fullscreenOccluded)),
            (PowerInputs(displayAsleep: false, screenLocked: false, manualPause: false, onBattery: true, batteryOverrideActive: true, fullscreenDisplayIDs: [1]), 2, .play),
            (PowerInputs(), 1, .play)
        ]

        for (inputs, displayID, expected) in matrix {
            #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: displayID) == expected)
        }

        let d1Bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let d2Bounds = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        @Sendable func makeTestWindows() -> [[String: Any]] {
            [
                // Fullscreen app covering 100% of display 1
                [
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    kCGWindowIsOnscreen as String: true,
                    kCGWindowOwnerPID as String: Int32(42_001),
                    kCGWindowOwnerName as String: "GameEngine",
                    kCGWindowBounds as String: d1Bounds
                ],
                // Ignored system owner covering display 2 -> should NOT occlude display 2
                [
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    kCGWindowIsOnscreen as String: true,
                    kCGWindowOwnerPID as String: Int32(42_002),
                    kCGWindowOwnerName as String: "Dock",
                    kCGWindowBounds as String: d2Bounds
                ],
                // Partial 50% window on display 2 -> below 0.98 coverage threshold
                [
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    kCGWindowIsOnscreen as String: true,
                    kCGWindowOwnerPID as String: Int32(42_003),
                    kCGWindowOwnerName as String: "Browser",
                    kCGWindowBounds as String: CGRect(x: 1920, y: 0, width: 1280, height: 1440)
                ]
            ]
        }

        let occluded = FullscreenDetector.occludedDisplayIDs(
            windowList: makeTestWindows(),
            displays: [(id: 1, bounds: d1Bounds), (id: 2, bounds: d2Bounds)]
        )
        #expect(occluded == [1])

        let batteryState = LockedBox(true)
        let monitor = PowerMonitor(
            initialSettings: PowerSettings(pauseOnBattery: true, pauseOnFullscreen: true, pauseOnScreenLockOrSleep: true),
            occlusionPollingInterval: 0,
            batteryStateProvider: { batteryState.value },
            windowListProvider: { makeTestWindows() },
            displaysProvider: { [(id: UInt32(1), bounds: d1Bounds), (id: UInt32(2), bounds: d2Bounds)] }
        )
        #expect(monitor.inputs.onBattery == true)
        #expect(monitor.inputs.fullscreenDisplayIDs == [1])
        #expect(PowerPolicyEvaluator.aggregateDecision(inputs: monitor.inputs, displayIDs: [1, 2]) == .pause(.onBattery))

        monitor.setBatteryOverride(true)
        #expect(PowerPolicyEvaluator.evaluate(inputs: monitor.inputs, forDisplay: 1) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: monitor.inputs, forDisplay: 2) == .play)
        #expect(PowerPolicyEvaluator.aggregateDecision(inputs: monitor.inputs, displayIDs: [1, 2]) == .play)

        batteryState.withValue { $0 = false }
        monitor.refreshNow()
        #expect(monitor.inputs.onBattery == false)
        #expect(monitor.inputs.batteryOverrideActive == false)

        monitor.applySettings(PowerSettings(pauseOnBattery: false, pauseOnFullscreen: false, pauseOnScreenLockOrSleep: true))
        #expect(PowerPolicyEvaluator.evaluate(inputs: monitor.inputs, forDisplay: 1) == .play)
    }

    @MainActor
    @Test("T3-10 (F2, F4, F5): Online UHD/SD video selection -> multi-display assignment -> per-display fullscreen pause")
    func onlineVideoSelectionMultiDisplayFullscreenPause() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let pexels = PexelsProvider(baseURL: baseURL.appendingPathComponent("pexels"))
                let service = CatalogService(providers: [pexels])
                let catalog = await service.fetchCatalog(
                    query: E2EHelpers.makeQuery(text: "waves", mediaType: .video, sources: [.pexels]),
                    secrets: ApiSecrets(pexelsAPIKey: "valid_key"),
                    customFeedURL: nil
                )
                let providerResult = try #require(
                    E2EHelpers.extractProviderResults(from: catalog).first(where: { $0.source == .pexels })
                )
                #expect(providerResult.errorMessage == nil)

                let videoItem = try #require(E2EHelpers.extractItems(from: catalog).first(where: { $0.mediaType == .video }))
                #expect(videoItem.width == 3840)
                #expect(videoItem.height == 2160)
                #expect(videoItem.fullAssetURL?.pathExtension.lowercased() == "mp4")
                #expect(videoItem.previewVideoURL?.pathExtension.lowercased() == "mp4")

                let cache = E2EHelpers.makeCacheManager(in: tempDir)
                let localVideo = try await cache.download(videoItem)
                #expect(FileManager.default.fileExists(atPath: localVideo.path))

                var assignedVideo = videoItem
                assignedVideo.localPath = localVideo

                let config = DisplayConfig(
                    mode: .independent,
                    assignments: [
                        "1": DisplayAssignment(displayID: 1, displayName: "Display 1", wallpaper: assignedVideo, scalingMode: .fill),
                        "2": DisplayAssignment(displayID: 2, displayName: "Display 2", wallpaper: assignedVideo, scalingMode: .fit)
                    ]
                )

                let mockDisplays: [(id: UInt32, frame: NSRect, name: String)] = [
                    (id: 1, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "Display 1"),
                    (id: 2, frame: NSRect(x: 1920, y: 0, width: 2560, height: 1440), name: "Display 2")
                ]
                let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(
                    in: tempDir,
                    extractFirstFrameStill: false,
                    mockDisplays: mockDisplays
                )

                engine.apply(config: config)
                #expect(engine.lastErrorMessage == nil)
                #expect(engine.activeVideoDisplayIDs == [1, 2])
                #expect(engine.activeWallpapers[1]?.id == videoItem.id)
                #expect(engine.activeWallpapers[2]?.id == videoItem.id)
                #expect(engine.currentDecisions[1] == .play)
                #expect(engine.currentDecisions[2] == .play)
                #expect(engine.isPaused(for: 1) == false)
                #expect(engine.isPaused(for: 2) == false)
                #expect(desktopCalls.value.isEmpty)

                let occludedInputs = PowerInputs(pauseOnFullscreenEnabled: true, fullscreenDisplayIDs: [1])
                engine.updatePowerInputs(occludedInputs)
                #expect(engine.currentDecisions[1] == .pause(.fullscreenOccluded))
                #expect(engine.isPaused(for: 1) == true)
                #expect(engine.currentDecisions[2] == .play)
                #expect(engine.isPaused(for: 2) == false)

                let clearedInputs = PowerInputs(pauseOnFullscreenEnabled: true, fullscreenDisplayIDs: [])
                engine.updatePowerInputs(clearedInputs)
                #expect(engine.currentDecisions[1] == .play)
                #expect(engine.isPaused(for: 1) == false)
                #expect(engine.currentDecisions[2] == .play)
                #expect(engine.isPaused(for: 2) == false)

                engine.teardownAllVideoWindows()
                #expect(engine.activeVideoDisplayIDs.isEmpty)
                #expect(engine.activeWallpapers.isEmpty)
                #expect(engine.currentDecisions.isEmpty)
            }
        }
    }
}
