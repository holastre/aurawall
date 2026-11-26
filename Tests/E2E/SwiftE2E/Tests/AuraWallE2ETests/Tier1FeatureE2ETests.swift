import AppKit
import AVFoundation
import Foundation
import Testing
import AuraWallCore

@Suite("Tier1 Feature E2E Tests")
struct Tier1FeatureE2ETests {

    // MARK: - F2: Online Wallpaper Sources & SecretStore

    @Test("T1-F2-01: Starter live catalog when enabled; offline custom feed, 0600 secrets, and provider fixtures when AURAWALL_E2E_NO_LIVE=1")
    func starterCatalogAndAerials() async throws {
        let service = E2EHelpers.makeCatalogService()

        if !E2EEnvironment.noLive {
            let result = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(mediaType: .video, sources: [.starter]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )

            let items = E2EHelpers.extractItems(from: result)
            let starterResults = E2EHelpers.extractProviderResults(from: result)
                .filter { $0.source == .starter }

            #expect(!starterResults.isEmpty)
            #expect(starterResults.allSatisfy { $0.errorMessage == nil })
            #expect(!items.isEmpty)
            #expect(items.allSatisfy { $0.source == .starter })
            #expect(items.allSatisfy { $0.mediaType == .video })
            #expect(items.allSatisfy { !$0.title.isEmpty })
            #expect(items.allSatisfy { $0.fullAssetURL?.scheme?.lowercased() == "https" })
        } else {
            // Zero external network calls: exercise local mock custom feed + error isolation + 0600 SecretStore
            try await E2EHelpers.withMockBaseURL { baseURL in
                let wrappedResult = await service.fetchCatalog(
                    query: E2EHelpers.makeQuery(mediaType: .video, sources: [.customFeed]),
                    secrets: ApiSecrets(),
                    customFeedURL: baseURL.appendingPathComponent("custom/wrapped.json")
                )
                let wrappedItems = E2EHelpers.extractItems(from: wrappedResult)
                let wrappedProvider = E2EHelpers.extractProviderResults(from: wrappedResult)
                    .first(where: { $0.source == .customFeed })
                #expect(wrappedProvider?.errorMessage == nil)
                #expect(!wrappedItems.isEmpty)
                #expect(wrappedItems.allSatisfy { $0.source == .customFeed })
                #expect(wrappedItems.contains(where: { $0.mediaType == .video && !$0.title.isEmpty }))

                let arrayResult = await service.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.customFeed]),
                    secrets: ApiSecrets(),
                    customFeedURL: baseURL.appendingPathComponent("custom/array.json")
                )
                let arrayProvider = E2EHelpers.extractProviderResults(from: arrayResult)
                    .first(where: { $0.source == .customFeed })
                #expect(arrayProvider?.errorMessage == nil)
                #expect(!E2EHelpers.extractItems(from: arrayResult).isEmpty)

                for badPath in ["custom/error500.html", "custom/malformed.json"] {
                    let badResult = await service.fetchCatalog(
                        query: E2EHelpers.makeQuery(sources: [.customFeed]),
                        secrets: ApiSecrets(),
                        customFeedURL: baseURL.appendingPathComponent(badPath)
                    )
                    let badProvider = E2EHelpers.extractProviderResults(from: badResult)
                        .first(where: { $0.source == .customFeed })
                    #expect(badProvider?.errorMessage != nil)
                    #expect(E2EHelpers.extractItems(from: badResult).isEmpty)
                }

                if E2EEnvironment.mockBaseURLFromEnv != nil {
                    let (tarData, tarResponse) = try await URLSession.shared.data(
                        from: baseURL.appendingPathComponent("aerials/resources-16.tar")
                    )
                    let httpTar = try #require(tarResponse as? HTTPURLResponse)
                    #expect(httpTar.statusCode == 200)
                    #expect(!tarData.isEmpty)
                }
            }

            try await E2EHelpers.withIsolatedWorkspace { tempDir in
                let secretStore = E2EHelpers.makeSecretStore(in: tempDir)
                try await secretStore.save(ApiSecrets(pexelsAPIKey: "offline-px", pixabayAPIKey: "offline-pb"))
                #expect(try E2EHelpers.posixPermissions(of: await secretStore.fileURL) == 0o600)
            }

            // Validate offline Wallhaven / Pexels / Pixabay / Aerials fixtures if present
            if let aerial2x = try E2EHelpers.loadFixtureJSONObjectIfPresent(named: "aerial_2x_entries.json") {
                #expect(((aerial2x["assets"] as? [[String: Any]])?.isEmpty ?? true) == false)
            }
            if let wallhaven = try E2EHelpers.loadFixtureJSONObjectIfPresent(named: "wallhaven_string_query.json") {
                #expect(((wallhaven["data"] as? [[String: Any]])?.isEmpty ?? true) == false)
            }
            if let pexels = try E2EHelpers.loadFixtureJSONObjectIfPresent(named: "pexels_videos_search.json") {
                #expect(((pexels["videos"] as? [[String: Any]])?.isEmpty ?? true) == false)
            }
            if let pixabay = try E2EHelpers.loadFixtureJSONObjectIfPresent(named: "pixabay_videos.json") {
                #expect(((pixabay["hits"] as? [[String: Any]])?.isEmpty ?? true) == false)
            }
        }

        // Validate Aerial r16 fixture JSON if Track A fixtures exist on disk
        if let object = try E2EHelpers.loadFixtureJSONObjectIfPresent(named: "aerial_r16_entries.json") {
            let assets = object["assets"] as? [[String: Any]]
            let categories = object["categories"] as? [[String: Any]]
            #expect((assets?.isEmpty ?? true) == false)
            #expect((categories?.isEmpty ?? true) == false)
        }
    }

    @Test("T1-F2-02: WallhavenProvider SFW search via CatalogService against mock server and live API when enabled")
    func wallhavenProviderSearch() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            let provider = WallhavenProvider(baseURL: baseURL.appendingPathComponent("wallhaven"))
            let service = CatalogService(providers: [provider])
            let result = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "landscape", mediaType: .image, sources: [.wallhaven]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )

            let providerResult = try #require(
                E2EHelpers.extractProviderResults(from: result).first(where: { $0.source == .wallhaven })
            )
            #expect(providerResult.errorMessage == nil)
            #expect(providerResult.hasNextPage == true)
            #expect(result.items.count >= 2)
            #expect(result.items.allSatisfy { $0.source == .wallhaven && $0.mediaType == .image })
            #expect(result.items.allSatisfy { $0.tags.contains("sfw") })
            #expect(result.items.allSatisfy { $0.fullAssetURL != nil && $0.previewImageURL != nil })
        }

        if !E2EEnvironment.noLive {
            let liveService = CatalogService(providers: [WallhavenProvider()])
            let liveResult = await liveService.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "landscape", mediaType: .image, sources: [.wallhaven]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            let liveProvider = try #require(
                E2EHelpers.extractProviderResults(from: liveResult).first(where: { $0.source == .wallhaven })
            )
            #expect(liveProvider.errorMessage == nil)
            #expect(!liveResult.items.isEmpty)
            #expect(liveResult.items.allSatisfy { $0.source == .wallhaven && $0.mediaType == .image })
            #expect(liveResult.items.allSatisfy { $0.tags.contains("sfw") })
            #expect(liveResult.items.allSatisfy { $0.fullAssetURL?.scheme?.lowercased() == "https" })
        }
    }

    @Test("T1-F2-03: PexelsProvider video and photo search via CatalogService selects landscape UHD and SD streams")
    func pexelsProviderVideoAndPhotoSearch() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            let provider = PexelsProvider(baseURL: baseURL.appendingPathComponent("pexels"))
            let service = CatalogService(providers: [provider])
            let secrets = ApiSecrets(pexelsAPIKey: "valid_pexels_test_key")

            let result = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "waves", mediaType: .all, sources: [.pexels]),
                secrets: secrets,
                customFeedURL: nil
            )
            let providerResult = try #require(
                E2EHelpers.extractProviderResults(from: result).first(where: { $0.source == .pexels })
            )
            #expect(providerResult.errorMessage == nil)
            #expect(providerResult.hasNextPage == true)
            #expect(result.items.allSatisfy { $0.source == .pexels })

            let video = try #require(result.items.first(where: { $0.mediaType == .video }))
            #expect(video.width == 3840)
            #expect(video.height == 2160)
            #expect(video.fullAssetURL != nil)
            #expect(video.previewVideoURL != nil)
            #expect(video.previewImageURL != nil)

            let photos = result.items.filter { $0.mediaType == .image }
            #expect(photos.count >= 2)
            #expect(photos.allSatisfy { $0.fullAssetURL != nil && $0.previewImageURL != nil })
        }
    }

    @Test("T1-F2-04: PixabayProvider video and photo search via CatalogService includes medium fallback")
    func pixabayProviderVideoAndPhotoSearch() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            let provider = PixabayProvider(baseURL: baseURL.appendingPathComponent("pixabay"))
            let service = CatalogService(providers: [provider])
            let secrets = ApiSecrets(pixabayAPIKey: "valid_pixabay_key")

            let result = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "ocean", mediaType: .all, sources: [.pixabay]),
                secrets: secrets,
                customFeedURL: nil
            )
            let providerResult = try #require(
                E2EHelpers.extractProviderResults(from: result).first(where: { $0.source == .pixabay })
            )
            #expect(providerResult.errorMessage == nil)
            #expect(result.items.allSatisfy { $0.source == .pixabay })

            let videos = result.items.filter { $0.mediaType == .video }
            #expect(videos.count >= 2)
            let primaryVideo = try #require(videos.first(where: { $0.id == "pixabay-video-12573" }))
            #expect(primaryVideo.width == 3840)
            #expect(primaryVideo.height == 2160)
            let fallbackVideo = try #require(videos.first(where: { $0.id == "pixabay-video-24891" }))
            #expect(fallbackVideo.width == 1920)
            #expect(fallbackVideo.height == 1080)

            let photos = result.items.filter { $0.mediaType == .image }
            #expect(photos.count >= 2)
            #expect(photos.allSatisfy { $0.fullAssetURL != nil && $0.previewImageURL != nil })
        }
    }

    @Test("T1-F2-05: Custom JSON feed wrapped and bare array formats decode via CatalogService")
    func customFeedWrappedAndArray() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            let service = E2EHelpers.makeCatalogService()

            let wrappedURL = baseURL.appendingPathComponent("custom/wrapped.json")
            let wrappedResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(sources: [.customFeed]),
                secrets: ApiSecrets(),
                customFeedURL: wrappedURL
            )
            let wrappedItems = E2EHelpers.extractItems(from: wrappedResult)
            let wrappedProvider = E2EHelpers.extractProviderResults(from: wrappedResult)
                .first(where: { $0.source == .customFeed })
            #expect(wrappedProvider?.errorMessage == nil)
            #expect(!wrappedItems.isEmpty)
            #expect(wrappedItems.allSatisfy { $0.source == .customFeed })
            #expect(wrappedItems.contains(where: { $0.mediaType == .video }))
            #expect(wrappedItems.contains(where: { $0.mediaType == .image }))

            let arrayURL = baseURL.appendingPathComponent("custom/array.json")
            let arrayResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(sources: [.customFeed]),
                secrets: ApiSecrets(),
                customFeedURL: arrayURL
            )
            let arrayItems = E2EHelpers.extractItems(from: arrayResult)
            let arrayProvider = E2EHelpers.extractProviderResults(from: arrayResult)
                .first(where: { $0.source == .customFeed })
            #expect(arrayProvider?.errorMessage == nil)
            #expect(!arrayItems.isEmpty)
            #expect(arrayItems.allSatisfy { $0.source == .customFeed })
        }
    }

    @Test("T1-F2-06: SecretStore saves secrets with strict 0600 permissions and reloads identically")
    func secretStoreStrict0600() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeSecretStore(in: tempDir)
            let expected = ApiSecrets(
                pexelsAPIKey: "pexels-e2e-key-001",
                pixabayAPIKey: "pixabay-e2e-key-002",
                wallhavenAPIKey: "wallhaven-e2e-key-003"
            )
            try await store.save(expected)

            let fileURL = await store.fileURL
            let perms = try E2EHelpers.posixPermissions(of: fileURL)
            #expect(perms == 0o600)

            let reloadedStore = SecretStore(fileURL: fileURL)
            let loaded = try await reloadedStore.load()
            #expect(loaded == expected)
        }
    }

    // MARK: - F3: Core Models, Persistence & Media Cache

    @Test("T1-F3-01: WallpaperItem Codable and Hashable round-trip across all sources")
    func wallpaperItemCodableAndHashable() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_764_000_000)
        var items: [WallpaperItem] = []

        for (index, source) in WallpaperSource.allCases.enumerated() {
            let mediaType: WallpaperMediaType = (index % 2 == 0) ? .video : .image
            let item = WallpaperItem(
                id: "item-\(source.rawValue)-\(index)",
                title: "Wallpaper \(source.displayName)",
                category: "Scenery",
                source: source,
                mediaType: mediaType,
                width: 3840,
                height: 2160,
                fileSize: 12_345_678,
                duration: mediaType == .video ? 30.0 : nil,
                previewImageURL: URL(string: "https://example.com/thumb-\(index).jpg"),
                previewVideoURL: mediaType == .video ? URL(string: "https://example.com/sd-\(index).mp4") : nil,
                fullAssetURL: URL(string: "https://example.com/full-\(index).\(mediaType == .video ? "mp4" : "jpg")"),
                localPath: source == .localImport ? URL(fileURLWithPath: "/tmp/local-\(index).jpg") : nil,
                tags: ["tagA", "tagB"],
                dominantColors: ["#112233", "#AABBCC"],
                createdAt: fixedDate
            )
            items.append(item)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(items)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([WallpaperItem].self, from: data)

        #expect(decoded == items)
        let set = Set(decoded + items)
        #expect(set.count == items.count)
    }

    @Test("T1-F3-02: DisplayConfig and AppSettings Codable round-trip")
    func displayConfigAndAppSettingsRoundTrip() throws {
        let item = WallpaperItem(
            id: "w-1",
            title: "Forest Canopy",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160
        )
        let mirrorConfig = DisplayConfig(
            mode: .mirrorAll,
            assignments: [
                DisplayConfig.mirrorAssignmentKey: DisplayAssignment(
                    displayID: 0,
                    displayName: "Mirror",
                    wallpaper: item,
                    scalingMode: .fill
                )
            ]
        )
        let independentConfig = DisplayConfig(
            mode: .independent,
            assignments: [
                "101": DisplayAssignment(displayID: 101, displayName: "Built-in", wallpaper: item, scalingMode: .fit),
                "202": DisplayAssignment(displayID: 202, displayName: "Studio", wallpaper: item, scalingMode: .fill)
            ]
        )
        let settings = AppSettings(
            customFeedURL: "https://example.com/feed.json",
            extractFirstFrameStill: false,
            launchInBackgroundOnClose: true,
            power: PowerSettings(pauseOnBattery: true, pauseOnFullscreen: false, pauseOnScreenLockOrSleep: true),
            preferredResolution: "4K"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decodedMirror = try decoder.decode(DisplayConfig.self, from: try encoder.encode(mirrorConfig))
        let decodedIndep = try decoder.decode(DisplayConfig.self, from: try encoder.encode(independentConfig))
        let decodedSettings = try decoder.decode(AppSettings.self, from: try encoder.encode(settings))

        #expect(decodedMirror == mirrorConfig)
        #expect(decodedIndep == independentConfig)
        #expect(decodedSettings == settings)
    }

    @Test("T1-F3-03: LibraryStore atomic state.json persistence across reload")
    func libraryStoreAtomicPersistence() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let fav = WallpaperItem(id: "fav-1", title: "Fav", source: .wallhaven, mediaType: .image)
            let rec = WallpaperItem(id: "rec-1", title: "Rec", source: .starter, mediaType: .video)
            let impURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)
            let imp = WallpaperItem(id: "imp-1", title: "Imp", source: .localImport, mediaType: .image, localPath: impURL)

            _ = await store.toggleFavorite(fav)
            await store.recordRecent(rec)
            await store.addLocalImport(imp)
            await store.updateDisplayConfig(
                DisplayConfig(
                    mode: .independent,
                    assignments: [
                        "1": DisplayAssignment(displayID: 1, displayName: "Main", wallpaper: imp, scalingMode: .fit)
                    ]
                )
            )
            await store.updateSettings(
                AppSettings(
                    customFeedURL: "https://example.com/custom.json",
                    extractFirstFrameStill: true,
                    launchInBackgroundOnClose: false,
                    power: PowerSettings(pauseOnBattery: false, pauseOnFullscreen: true, pauseOnScreenLockOrSleep: true),
                    preferredResolution: "1440p"
                )
            )
            try await store.save()

            let stateFileURL = await store.stateFileURL
            #expect(FileManager.default.fileExists(atPath: stateFileURL.path))
            let expectedState = await store.state

            let reloadedStore = LibraryStore(baseDirectory: await store.baseDirectory)
            let loadedState = try await reloadedStore.load()
            #expect(loadedState == expectedState)
        }
    }

    @Test("T1-F3-04: MediaCacheManager streaming download reports monotonic progress and caches file")
    func mediaCacheStreamingDownloadAndProgress() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let videoURL = try await E2EHelpers.firstVideoURL(from: baseURL)
                let cache = E2EHelpers.makeCacheManager(in: tempDir)
                let item = WallpaperItem(
                    id: "stream-video-1",
                    title: "Streaming Video",
                    source: .customFeed,
                    mediaType: .video,
                    fullAssetURL: videoURL
                )

                let progressLog = LockedBox<[Double]>([])
                let downloadedURL = try await cache.download(item) { progress in
                    progressLog.withValue { $0.append(progress) }
                }

                #expect(FileManager.default.fileExists(atPath: downloadedURL.path))
                let data = try Data(contentsOf: downloadedURL)
                #expect(!data.isEmpty)

                let cachedLookup = await cache.cachedFileURL(for: item)
                #expect(cachedLookup == downloadedURL)

                let values = progressLog.value
                #expect(!values.isEmpty)
                #expect(values.last == 1.0)
                #expect(values.allSatisfy { !$0.isNaN && $0 >= 0.0 && $0 <= 1.0 })
                for idx in 1..<values.count {
                    #expect(values[idx] >= values[idx - 1])
                }

                // Verify mock server HTTP Range 206 Partial Content support
                var rangeReq = URLRequest(url: videoURL)
                rangeReq.setValue("bytes=0-511", forHTTPHeaderField: "Range")
                let (rangeData, rangeResp) = try await URLSession.shared.data(for: rangeReq)
                let httpRange = try #require(rangeResp as? HTTPURLResponse)
                #expect(httpRange.statusCode == 206)
                #expect(rangeData.count == 512)
                let contentRange = httpRange.value(forHTTPHeaderField: "Content-Range") ?? ""
                #expect(contentRange.hasPrefix("bytes 0-511/"))
            }
        }
    }

    @Test("T1-F3-05: MediaCacheManager totalCacheSizeBytes and clearCache preserve active file")
    func mediaCacheSizeAndSafeClear() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let videoURL = try await E2EHelpers.firstVideoURL(from: baseURL)
                let imageURL = try await E2EHelpers.firstImageURL(from: baseURL)
                let cache = E2EHelpers.makeCacheManager(in: tempDir)

                let itemAlpha = WallpaperItem(
                    id: "alpha-keep",
                    title: "Alpha",
                    source: .customFeed,
                    mediaType: .video,
                    fullAssetURL: videoURL
                )
                let itemBravo = WallpaperItem(
                    id: "bravo-evict",
                    title: "Bravo",
                    source: .customFeed,
                    mediaType: .image,
                    fullAssetURL: imageURL
                )

                let urlAlpha = try await cache.download(itemAlpha)
                let urlBravo = try await cache.download(itemBravo)

                let sizeAlpha = Int64(try Data(contentsOf: urlAlpha).count)
                let sizeBravo = Int64(try Data(contentsOf: urlBravo).count)
                #expect(sizeAlpha > 0)
                #expect(sizeBravo > 0)

                let totalBefore = await cache.totalCacheSizeBytes()
                #expect(totalBefore == sizeAlpha + sizeBravo)

                let freed = try await cache.clearCache(preserving: [urlAlpha])
                #expect(freed == sizeBravo)
                #expect(FileManager.default.fileExists(atPath: urlAlpha.path))
                #expect(!FileManager.default.fileExists(atPath: urlBravo.path))
                #expect(await cache.totalCacheSizeBytes() == sizeAlpha)
            }
        }
    }

    @Test("T1-F3-06: LibraryStore.activeWallpaperLocalURLs returns assigned local URL")
    func libraryStoreActiveWallpaperLocalURLs() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let localCopy = tempDir.appendingPathComponent("assigned_wall.mp4")
            try Data(contentsOf: mp4URL).write(to: localCopy)

            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let assignedItem = WallpaperItem(
                id: "assigned-1",
                title: "Assigned",
                source: .starter,
                mediaType: .video,
                localPath: localCopy
            )
            await store.updateDisplayConfig(
                DisplayConfig(
                    mode: .independent,
                    assignments: [
                        "1": DisplayAssignment(displayID: 1, displayName: "Primary", wallpaper: assignedItem)
                    ]
                )
            )
            try await store.save()

            let reloaded = LibraryStore(baseDirectory: await store.baseDirectory)
            _ = try await reloaded.load()
            let activeURLs = await reloaded.activeWallpaperLocalURLs()
            let canonicalExpected = localCopy.resolvingSymlinksInPath().standardizedFileURL
            #expect(activeURLs.contains(canonicalExpected))
        }
    }

    // MARK: - F4: Live Desktop Wallpaper Engine & Multi-Display

    @MainActor
    @Test("T1-F4-01: WallpaperEngine applies live video and tears down cleanly")
    func wallpaperEngineApplyLiveVideo() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let (engine, _) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: false)
            let expectedDisplayIDs = Set(engine.displayManager.displays.map(\.id))
            #expect(!expectedDisplayIDs.isEmpty)

            let item = WallpaperItem(
                id: "engine-v1",
                title: "Live Video",
                source: .starter,
                mediaType: .video,
                localPath: mp4URL
            )

            engine.apply(wallpaper: item, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == expectedDisplayIDs)
            for id in expectedDisplayIDs {
                #expect(engine.activeWallpapers[id]?.id == "engine-v1")
                #expect(engine.activeWallpapers[id]?.mediaType == .video)
                #expect(engine.activeWallpapers[id]?.localPath == mp4URL)
                #expect(engine.currentDecisions[id] == .play)
                #expect(engine.isPaused(for: id) == false)
            }

            await Task.yield()
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == expectedDisplayIDs)

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
            #expect(engine.lastErrorMessage == nil)
        }
    }

    @MainActor
    @Test("T1-F4-02: WallpaperEngine switches from live video to static image and tears down")
    func wallpaperEngineSwitchVideoToStaticTeardown() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let jpgURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)
            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: false)
            let expectedDisplayIDs = Set(engine.displayManager.displays.map(\.id))
            #expect(!expectedDisplayIDs.isEmpty)

            let videoItem = WallpaperItem(id: "eng-vid", title: "Video", source: .starter, mediaType: .video, localPath: mp4URL)
            let imageItem = WallpaperItem(id: "eng-img", title: "Static", source: .wallhaven, mediaType: .image, localPath: jpgURL)

            engine.apply(wallpaper: videoItem, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == expectedDisplayIDs)
            #expect(expectedDisplayIDs.allSatisfy { engine.activeWallpapers[$0]?.id == "eng-vid" })
            #expect(desktopCalls.value.isEmpty)

            await Task.yield()
            engine.apply(wallpaper: imageItem, localURL: jpgURL, to: nil, mode: .mirrorAll, scaling: .fit)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
            for id in expectedDisplayIDs {
                #expect(engine.activeWallpapers[id]?.id == "eng-img")
                #expect(engine.activeWallpapers[id]?.mediaType == .image)
                #expect(engine.activeWallpapers[id]?.localPath == jpgURL)
            }
            let recorded = desktopCalls.value
            #expect(recorded.count == expectedDisplayIDs.count)
            #expect(Set(recorded.map(\.displayID)) == expectedDisplayIDs)
            #expect(recorded.allSatisfy { $0.imageURL == jpgURL && $0.allowClipping == false && $0.hasFillColor == true })

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(expectedDisplayIDs.allSatisfy { engine.activeWallpapers[$0]?.id == "eng-img" })
        }
    }

    @MainActor
    @Test("T1-F4-03: WallpaperEngine pauseAll, resumeAll, and updatePowerInputs complete cleanly")
    func wallpaperEnginePauseResumeAndPowerInputs() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let (engine, _) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: false)
            let expectedDisplayIDs = Set(engine.displayManager.displays.map(\.id))
            #expect(!expectedDisplayIDs.isEmpty)

            let videoItem = WallpaperItem(id: "eng-pwr", title: "Power Video", source: .starter, mediaType: .video, localPath: mp4URL)

            engine.apply(wallpaper: videoItem, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == expectedDisplayIDs)
            #expect(expectedDisplayIDs.allSatisfy { engine.currentDecisions[$0] == .play && engine.isPaused(for: $0) == false })

            engine.pauseAll()
            #expect(engine.currentPowerInputs.manualPause == true)
            #expect(expectedDisplayIDs.allSatisfy { engine.currentDecisions[$0] == .pause(.manual) && engine.isPaused(for: $0) == true })

            engine.resumeAll()
            #expect(engine.currentPowerInputs.manualPause == false)
            #expect(expectedDisplayIDs.allSatisfy { engine.currentDecisions[$0] == .play && engine.isPaused(for: $0) == false })

            engine.updatePowerInputs(PowerInputs(onBattery: true))
            #expect(engine.currentPowerInputs.onBattery == true)
            #expect(expectedDisplayIDs.allSatisfy { engine.currentDecisions[$0] == .pause(.onBattery) && engine.isPaused(for: $0) == true })

            engine.updatePowerInputs(PowerInputs(onBattery: false))
            #expect(engine.currentPowerInputs.onBattery == false)
            #expect(expectedDisplayIDs.allSatisfy { engine.currentDecisions[$0] == .play && engine.isPaused(for: $0) == false })

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
        }
    }

    @Test("T1-F4-04: Multi-display DisplayConfig independent assignments and mirror toggle")
    func multiDisplayConfigAssignmentsAndMirrorToggle() {
        let v1 = WallpaperItem(id: "d1-vid", title: "Display 1", source: .starter, mediaType: .video)
        let i2 = WallpaperItem(id: "d2-img", title: "Display 2", source: .wallhaven, mediaType: .image)

        var config = DisplayConfig(
            mode: .independent,
            assignments: [
                DisplayConfig.key(for: 1): DisplayAssignment(displayID: 1, displayName: "Built-in", wallpaper: v1, scalingMode: .fill),
                DisplayConfig.key(for: 2): DisplayAssignment(displayID: 2, displayName: "External", wallpaper: i2, scalingMode: .fit)
            ]
        )

        #expect(config.assignment(for: 1)?.wallpaper?.id == "d1-vid")
        #expect(config.assignment(for: 1)?.scalingMode == .fill)
        #expect(config.assignment(for: 2)?.wallpaper?.id == "d2-img")
        #expect(config.assignment(for: 2)?.scalingMode == .fit)
        #expect(Set(config.activeWallpapers().map(\.id)) == ["d1-vid", "d2-img"])

        config.mode = .mirrorAll
        config.assignments[DisplayConfig.mirrorAssignmentKey] = DisplayAssignment(
            displayID: 0,
            displayName: "Mirror",
            wallpaper: v1,
            scalingMode: .fill
        )
        #expect(config.assignment(for: 1)?.wallpaper?.id == "d1-vid")
        #expect(config.assignment(for: 2)?.wallpaper?.id == "d1-vid")

        config.mode = .independent
        #expect(config.assignment(for: 2)?.wallpaper?.id == "d2-img")
    }

    @MainActor
    @Test("T1-F4-05: First-frame still extraction and media fixture validity")
    func firstFrameStillAndMediaFixtureValidity() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let jpgURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)

            let asset = AVURLAsset(url: mp4URL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at: .zero)
            #expect(frame.image.width > 0)
            #expect(frame.image.height > 0)

            let image = NSImage(contentsOf: jpgURL)
            #expect(image != nil)
            #expect((image?.size.width ?? 0) > 0)

            let directStillsDir = tempDir.appendingPathComponent("DirectStills", isDirectory: true)
            let directStillURL = try await WallpaperEngine.extractFirstFrameStillImage(
                from: mp4URL,
                into: directStillsDir
            )
            #expect(directStillURL.deletingLastPathComponent().standardizedFileURL == directStillsDir.standardizedFileURL)
            #expect(FileManager.default.fileExists(atPath: directStillURL.path))
            #expect(((try? Data(contentsOf: directStillURL).isEmpty) ?? true) == false)
            let directImage = NSImage(contentsOf: directStillURL)
            #expect(directImage != nil)
            #expect((directImage?.size.width ?? 0) > 0)

            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: true)
            let expectedDisplayIDs = Set(engine.displayManager.displays.map(\.id))
            #expect(!expectedDisplayIDs.isEmpty)

            let item = WallpaperItem(id: "still-v", title: "Still Extraction", source: .starter, mediaType: .video, localPath: mp4URL)
            engine.apply(wallpaper: item, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == expectedDisplayIDs)

            for _ in 0..<200 {
                if desktopCalls.value.count >= expectedDisplayIDs.count {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let stillCalls = desktopCalls.value
            #expect(stillCalls.count == expectedDisplayIDs.count)
            #expect(Set(stillCalls.map(\.displayID)) == expectedDisplayIDs)
            for call in stillCalls {
                #expect(call.allowClipping == true)
                #expect(call.imageURL.deletingLastPathComponent().standardizedFileURL == engine.stillCacheDirectory.standardizedFileURL)
                #expect(FileManager.default.fileExists(atPath: call.imageURL.path))
                #expect(((try? Data(contentsOf: call.imageURL).isEmpty) ?? true) == false)
            }
            #expect(engine.lastErrorMessage == nil)

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
        }
    }

    // MARK: - F5: Smart Power Saving

    @Test("T1-F5-01: Power priority 1 - display sleep or screen lock overrides all other flags")
    func powerPrioritySleepLockHighest() {
        let asleepInputs = PowerInputs(
            displayAsleep: true,
            screenLocked: false,
            manualPause: true,
            onBattery: true,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            pauseOnLockSleepEnabled: true,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: asleepInputs, forDisplay: 1) == .pause(.displayAsleepOrLocked))

        let lockedInputs = PowerInputs(
            displayAsleep: false,
            screenLocked: true,
            manualPause: true,
            onBattery: true,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            pauseOnLockSleepEnabled: true,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: lockedInputs, forDisplay: 1) == .pause(.displayAsleepOrLocked))
    }

    @Test("T1-F5-02: Power priority 2 - manual pause takes precedence over battery and fullscreen")
    func powerPriorityManualOverBatteryAndFullscreen() {
        let inputs = PowerInputs(
            displayAsleep: false,
            screenLocked: false,
            manualPause: true,
            onBattery: true,
            batteryOverrideActive: false,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            pauseOnLockSleepEnabled: true,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .pause(.manual))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 2) == .pause(.manual))
    }

    @Test("T1-F5-03: Power priority 3 - onBattery takes precedence over fullscreen occlusion")
    func powerPriorityBatteryOverFullscreen() {
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

    @Test("T1-F5-04: Power priority 4 - per-display fullscreen occlusion pauses only occluded display")
    func powerPriorityPerDisplayFullscreenOcclusion() {
        let inputs = PowerInputs(
            displayAsleep: false,
            screenLocked: false,
            manualPause: false,
            onBattery: false,
            batteryOverrideActive: false,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            pauseOnLockSleepEnabled: true,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 2) == .play)
    }

    @Test("T1-F5-05: Nominal PowerInputs returns .play")
    func powerAllClearReturnsPlay() {
        let inputs = PowerInputs()
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .play)
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 2) == .play)
    }

    // MARK: - F6: UI Settings, Menu Bar Status & Local Imports

    @Test("T1-F6-02: Background mode setting launchInBackgroundOnClose persists across reloads")
    func backgroundModeSettingPersistence() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            await store.updateSettings(AppSettings(launchInBackgroundOnClose: true))
            try await store.save()

            let reloaded1 = LibraryStore(baseDirectory: await store.baseDirectory)
            let state1 = try await reloaded1.load()
            #expect(state1.settings.launchInBackgroundOnClose == true)

            await reloaded1.updateSettings(AppSettings(launchInBackgroundOnClose: false))
            try await reloaded1.save()

            let reloaded2 = LibraryStore(baseDirectory: await store.baseDirectory)
            let state2 = try await reloaded2.load()
            #expect(state2.settings.launchInBackgroundOnClose == false)
        }
    }

    @Test("T1-F6-03: Menu bar status labels map deterministically from PowerDecision and mediaType")
    func menuBarStatusMapping() {
        let playing = PowerPolicyEvaluator.aggregateDecision(inputs: PowerInputs(), displayIDs: [1])
        let battery = PowerPolicyEvaluator.aggregateDecision(
            inputs: PowerInputs(onBattery: true, pauseOnBatteryEnabled: true),
            displayIDs: [1]
        )
        let fullscreen = PowerPolicyEvaluator.aggregateDecision(
            inputs: PowerInputs(pauseOnFullscreenEnabled: true, fullscreenDisplayIDs: [1]),
            displayIDs: [1]
        )
        let manual = PowerPolicyEvaluator.aggregateDecision(
            inputs: PowerInputs(manualPause: true),
            displayIDs: [1]
        )
        let locked = PowerPolicyEvaluator.aggregateDecision(
            inputs: PowerInputs(screenLocked: true, pauseOnLockSleepEnabled: true),
            displayIDs: [1]
        )

        #expect(playing.menuBarStatusLabel(for: nil) == "Ready")
        #expect(battery.menuBarStatusLabel(for: nil) == "Ready")
        #expect(playing.menuBarStatusLabel(for: .image) == "Static")
        #expect(battery.menuBarStatusLabel(for: .image) == "Static")
        #expect(playing.menuBarStatusLabel(for: .video) == "Playing")
        #expect(battery.menuBarStatusLabel(for: .video) == "Paused — On Battery")
        #expect(fullscreen.menuBarStatusLabel(for: .video) == "Paused — Fullscreen App")
        #expect(manual.menuBarStatusLabel(for: .video) == "Paused — Manual")
        #expect(locked.menuBarStatusLabel(for: .video) == "Paused — Display Asleep / Locked")

        #expect(
            PowerPolicyEvaluator.menuBarStatusLabel(
                inputs: PowerInputs(onBattery: true, pauseOnBatteryEnabled: true),
                displayIDs: [1, 2],
                activeMediaType: .video
            ) == "Paused — On Battery"
        )
        #expect(E2EHelpers.menuBarStatusLabel(for: playing, activeMediaType: .video) == "Playing")
    }

    @Test("T1-F6-04: Supported local import formats (.mp4, .mov, .jpg, .png, .heic) persist in LibraryStore")
    func supportedLocalImportFormats() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let specs: [(String, WallpaperMediaType)] = [
                ("mp4", .video),
                ("mov", .video),
                ("jpg", .image),
                ("png", .image),
                ("heic", .image)
            ]

            for (ext, mediaType) in specs {
                let fileURL = try E2EHelpers.resolveMediaFixture(extension: ext, in: tempDir)
                let item = WallpaperItem(
                    id: "local-\(ext)",
                    title: "Local \(ext.uppercased())",
                    source: .localImport,
                    mediaType: mediaType,
                    localPath: fileURL
                )
                await store.addLocalImport(item)
            }
            try await store.save()

            let reloaded = LibraryStore(baseDirectory: await store.baseDirectory)
            let state = try await reloaded.load()
            #expect(state.localImports.count == 5)
            for (ext, mediaType) in specs {
                let found = state.localImports.first(where: { $0.id == "local-\(ext)" })
                #expect(found?.source == .localImport)
                #expect(found?.mediaType == mediaType)
                #expect(found?.localPath != nil)
            }
        }
    }

    @Test("T1-F6-05: Favorites and recents quick-strip state toggles and persists cleanly")
    func favoritesAndRecentsQuickStripState() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let itemA = WallpaperItem(id: "qs-a", title: "Quick A", source: .starter, mediaType: .video)
            let itemB = WallpaperItem(id: "qs-b", title: "Quick B", source: .wallhaven, mediaType: .image)

            #expect(await store.toggleFavorite(itemA) == true)
            #expect(await store.toggleFavorite(itemB) == true)
            #expect(await store.toggleFavorite(itemA) == false)

            await store.recordRecent(itemA)
            await store.recordRecent(itemB)
            await store.recordRecent(itemA)
            try await store.save()

            let reloaded = LibraryStore(baseDirectory: await store.baseDirectory)
            let state = try await reloaded.load()
            #expect(state.favorites.map(\.id) == ["qs-b"])
            #expect(state.recents.map(\.id) == ["qs-a", "qs-b"])
        }
    }
}
