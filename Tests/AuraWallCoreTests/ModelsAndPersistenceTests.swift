import Foundation
import Testing
@testable import AuraWallCore

@Suite("Models and Persistence Tests")
struct ModelsAndPersistenceTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraWallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - WallpaperItem Tests

    @Test("WallpaperItem full Codable round-trip preserves all fields")
    func wallpaperItemFullCodableRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_764_000_000)
        let original = WallpaperItem(
            id: "starter:aerial-01",
            title: "California Coastline",
            category: "Nature",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 124_500_000,
            duration: 42.5,
            previewImageURL: URL(string: "https://example.com/thumb.jpg"),
            previewVideoURL: URL(string: "https://example.com/preview.mp4"),
            fullAssetURL: URL(string: "https://example.com/full.mov"),
            localPath: URL(fileURLWithPath: "/tmp/aurawall-sample.mov"),
            tags: ["ocean", "aerial", "4k"],
            dominantColors: ["#112233", "#445566"],
            createdAt: fixedDate
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WallpaperItem.self, from: data)

        #expect(decoded == original)
    }

    @Test("WallpaperItem decodes minimal JSON with resilient defaults")
    func wallpaperItemMinimalJSONDefaults() throws {
        let json = """
        {
          "id": "wallhaven:94x38z",
          "title": "Minimal Horizon",
          "source": "wallhaven",
          "mediaType": "image"
        }
        """
        let decoded = try JSONDecoder().decode(WallpaperItem.self, from: Data(json.utf8))

        #expect(decoded.id == "wallhaven:94x38z")
        #expect(decoded.title == "Minimal Horizon")
        #expect(decoded.source == .wallhaven)
        #expect(decoded.mediaType == .image)
        #expect(decoded.category == "General")
        #expect(decoded.tags.isEmpty)
        #expect(decoded.dominantColors.isEmpty)
        #expect(decoded.localPath == nil)
        #expect(decoded.width == nil)
        #expect(decoded.height == nil)
    }

    @Test("WallpaperItem computed helpers respect priority and media type")
    func wallpaperItemComputedHelpers() {
        let videoWithLocal = WallpaperItem(
            id: "v1",
            title: "Video",
            source: .pexels,
            mediaType: .video,
            width: 3840,
            height: 2160,
            previewImageURL: nil,
            previewVideoURL: URL(string: "https://example.com/sd.mp4"),
            fullAssetURL: URL(string: "https://example.com/hd.mp4"),
            localPath: URL(fileURLWithPath: "/tmp/local.mp4")
        )
        #expect(videoWithLocal.resolutionLabel == "3840×2160")
        #expect(videoWithLocal.aspectRatio == 3840.0 / 2160.0)
        #expect(videoWithLocal.preferredPlaybackURL == URL(fileURLWithPath: "/tmp/local.mp4"))
        #expect(videoWithLocal.preferredThumbnailURL == nil)

        let imageFallback = WallpaperItem(
            id: "i1",
            title: "Image",
            source: .wallhaven,
            mediaType: .image,
            width: 0,
            height: 1080,
            fullAssetURL: URL(string: "https://example.com/full.jpg")
        )
        #expect(imageFallback.resolutionLabel == nil)
        #expect(imageFallback.aspectRatio == nil)
        #expect(imageFallback.preferredPlaybackURL == URL(string: "https://example.com/full.jpg"))
        #expect(imageFallback.preferredThumbnailURL == URL(string: "https://example.com/full.jpg"))
    }

    @Test("WallpaperSource metadata covers all sources and API key requirements")
    func wallpaperSourceMetadata() {
        #expect(WallpaperSource.allCases.count == 6)
        #expect(WallpaperSource.pexels.requiresAPIKey == true)
        #expect(WallpaperSource.pixabay.requiresAPIKey == true)
        #expect(WallpaperSource.starter.requiresAPIKey == false)
        #expect(WallpaperSource.wallhaven.requiresAPIKey == false)
        #expect(WallpaperSource.customFeed.requiresAPIKey == false)
        #expect(WallpaperSource.localImport.requiresAPIKey == false)
    }

    // MARK: - DisplayConfig, Settings & ApiSecrets Tests

    @Test("DisplayConfig mirror and independent lookups behave accurately")
    func displayConfigMirrorAndIndependentLookup() {
        let mirrorItem = WallpaperItem(id: "m1", title: "Mirror", source: .starter, mediaType: .video)
        let d1Item = WallpaperItem(id: "d1", title: "Display 1", source: .wallhaven, mediaType: .image)
        let d2Item = WallpaperItem(id: "d2", title: "Display 2", source: .pexels, mediaType: .video)

        let mirrorConfig = DisplayConfig(
            mode: .mirrorAll,
            assignments: [
                DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: mirrorItem),
                "101": DisplayAssignment(displayID: 101, displayName: "Built-in", wallpaper: d1Item)
            ]
        )
        #expect(mirrorConfig.assignment(for: 101)?.wallpaper?.id == "m1")
        #expect(mirrorConfig.assignment(for: 999)?.wallpaper?.id == "m1")
        #expect(mirrorConfig.activeWallpapers().map(\.id) == ["m1"])

        let independentConfig = DisplayConfig(
            mode: .independent,
            assignments: [
                DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Stale Mirror", wallpaper: mirrorItem),
                DisplayConfig.primaryAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Stale Primary", wallpaper: mirrorItem),
                "101": DisplayAssignment(displayID: 101, displayName: "Built-in", wallpaper: d1Item),
                "202": DisplayAssignment(displayID: 202, displayName: "External", wallpaper: d2Item, scalingMode: .fit)
            ]
        )
        #expect(independentConfig.assignment(for: 101)?.wallpaper?.id == "d1")
        #expect(independentConfig.assignment(for: 202)?.scalingMode == .fit)
        #expect(independentConfig.assignment(for: 303) == nil)
        #expect(independentConfig.activeWallpapers().map(\.id) == ["d1", "d2"])
    }

    @Test("DisplayConfig mirrorAll is deterministic without mirror key and consistent when mirror wallpaper is nil")
    func displayConfigMirrorAllDeterminismAndNilConsistency() {
        let d1Item = WallpaperItem(id: "d1", title: "Display 1", source: .wallhaven, mediaType: .image)
        let d2Item = WallpaperItem(id: "d2", title: "Display 2", source: .pexels, mediaType: .video)

        // Case 1: .mirrorAll with only per-display keys ("101", "202") and no "mirror"/"primary" key
        let perDisplayOnlyConfig = DisplayConfig(
            mode: .mirrorAll,
            assignments: [
                "202": DisplayAssignment(displayID: 202, displayName: "External", wallpaper: d2Item),
                "101": DisplayAssignment(displayID: 101, displayName: "Built-in", wallpaper: d1Item)
            ]
        )
        let assigned101 = perDisplayOnlyConfig.assignment(for: 101)?.wallpaper
        let assigned202 = perDisplayOnlyConfig.assignment(for: 202)?.wallpaper
        let assignedUnknown = perDisplayOnlyConfig.assignment(for: 999)?.wallpaper
        let active = perDisplayOnlyConfig.activeWallpapers()

        #expect(assigned101?.id == "d1")
        #expect(assigned202?.id == "d1")
        #expect(assignedUnknown?.id == "d1")
        #expect(active.map(\.id) == ["d1"])

        // Case 2: .mirrorAll with explicit "mirror" key having wallpaper == nil while per-display keys remain
        let nilMirrorConfig = DisplayConfig(
            mode: .mirrorAll,
            assignments: [
                DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: nil),
                "101": DisplayAssignment(displayID: 101, displayName: "Built-in", wallpaper: d1Item),
                "202": DisplayAssignment(displayID: 202, displayName: "External", wallpaper: d2Item)
            ]
        )
        #expect(nilMirrorConfig.assignment(for: 101)?.wallpaper == nil)
        #expect(nilMirrorConfig.assignment(for: 202)?.wallpaper == nil)
        #expect(nilMirrorConfig.activeWallpapers().isEmpty)
    }

    @Test("DisplayAssignment, DisplayConfig, PowerSettings, and AppSettings decode partial JSON with defaults")
    func partialJSONDefaults() throws {
        let emptyObj = Data("{}".utf8)
        let appSettings = try JSONDecoder().decode(AppSettings.self, from: emptyObj)
        #expect(appSettings.extractFirstFrameStill == true)
        #expect(appSettings.launchInBackgroundOnClose == true)
        #expect(appSettings.power == PowerSettings())
        #expect(appSettings.customFeedURL == nil)

        let power = try JSONDecoder().decode(PowerSettings.self, from: emptyObj)
        #expect(power.pauseOnBattery == true)
        #expect(power.pauseOnFullscreen == true)
        #expect(power.pauseOnScreenLockOrSleep == true)

        let displayConfig = try JSONDecoder().decode(DisplayConfig.self, from: emptyObj)
        #expect(displayConfig.mode == .mirrorAll)
        #expect(displayConfig.assignments.isEmpty)

        let assignmentJSON = Data(#"{"displayID": 42, "displayName": "Studio Display"}"#.utf8)
        let assignment = try JSONDecoder().decode(DisplayAssignment.self, from: assignmentJSON)
        #expect(assignment.displayID == 42)
        #expect(assignment.displayName == "Studio Display")
        #expect(assignment.scalingMode == .fill)
        #expect(assignment.wallpaper == nil)
    }

    @Test("AppSettings validatedCustomFeedURL allows only valid HTTP(S) URLs")
    func appSettingsValidatedCustomFeedURL() {
        #expect(AppSettings(customFeedURL: nil).validatedCustomFeedURL == nil)
        #expect(AppSettings(customFeedURL: "").validatedCustomFeedURL == nil)
        #expect(AppSettings(customFeedURL: "   \n ").validatedCustomFeedURL == nil)
        #expect(AppSettings(customFeedURL: "ftp://bad.example/feed.json").validatedCustomFeedURL == nil)
        #expect(AppSettings(customFeedURL: "file:///tmp/feed.json").validatedCustomFeedURL == nil)
        #expect(AppSettings(customFeedURL: "not a url").validatedCustomFeedURL == nil)

        let valid = AppSettings(customFeedURL: "  https://example.com/wallpapers.json  ").validatedCustomFeedURL
        #expect(valid == URL(string: "https://example.com/wallpapers.json"))
    }

    @Test("ApiSecrets normalizes whitespace and redacts debugDescription")
    func apiSecretsNormalizationAndRedaction() throws {
        let secrets = ApiSecrets(
            pexelsAPIKey: "  pexels-secret-value  ",
            pixabayAPIKey: "   ",
            wallhavenAPIKey: "wh-secret-value"
        )
        #expect(secrets.normalizedPexelsKey == "pexels-secret-value")
        #expect(secrets.normalizedPixabayKey == nil)
        #expect(secrets.normalizedWallhavenKey == "wh-secret-value")
        #expect(secrets.isEmpty == false)
        #expect(!secrets.debugDescription.contains("pexels-secret-value"))
        #expect(!secrets.debugDescription.contains("wh-secret-value"))

        let empty = ApiSecrets(pexelsAPIKey: "  ", pixabayAPIKey: nil, wallhavenAPIKey: "\n")
        #expect(empty.isEmpty == true)

        let data = try JSONEncoder().encode(secrets)
        let decoded = try JSONDecoder().decode(ApiSecrets.self, from: data)
        #expect(decoded == secrets)
    }

    // MARK: - PowerModels Tests

    @Test("PowerModels Codable round-trip and applying PowerSettings")
    func powerModelsCodableAndSettings() throws {
        var inputs = PowerInputs(
            displayAsleep: false,
            screenLocked: true,
            manualPause: false,
            onBattery: true,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            pauseOnLockSleepEnabled: true,
            fullscreenDisplayIDs: [1, 2]
        )

        let data = try JSONEncoder().encode(inputs)
        let decoded = try JSONDecoder().decode(PowerInputs.self, from: data)
        #expect(decoded == inputs)

        inputs.applying(settings: PowerSettings(
            pauseOnBattery: false,
            pauseOnFullscreen: true,
            pauseOnScreenLockOrSleep: false
        ))
        #expect(inputs.pauseOnBatteryEnabled == false)
        #expect(inputs.pauseOnFullscreenEnabled == true)
        #expect(inputs.pauseOnLockSleepEnabled == false)

        let play = PowerDecision.play
        #expect(play.isPlaying == true)
        #expect(play.pauseReason == nil)
        #expect(play.statusLabel == "Playing")

        let paused = PowerDecision.pause(.fullscreenOccluded)
        #expect(paused.isPlaying == false)
        #expect(paused.pauseReason == .fullscreenOccluded)
        #expect(paused.statusLabel == "Paused — Fullscreen App")
    }

    // MARK: - LibraryStore Persistence Tests

    @Test("LibraryStore missing state.json returns defaults without creating file")
    func libraryStoreEmptyLoadReturnsDefaults() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LibraryStore(baseDirectory: tempDir)
        let state = try await store.load()
        #expect(state == LibraryState())
        #expect(await store.lastLoadWarning == nil)
        #expect(!FileManager.default.fileExists(atPath: await store.stateFileURL.path))
    }

    @Test("LibraryStore persists full state atomically across instances")
    func libraryStorePersistenceRoundTrip() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LibraryStore(baseDirectory: tempDir.appendingPathComponent("nested", isDirectory: true))
        let item1 = WallpaperItem(
            id: "101",
            title: "Ocean Waves",
            source: .pexels,
            mediaType: .video,
            fullAssetURL: URL(string: "https://example.com/waves.mp4"),
            localPath: URL(fileURLWithPath: "/tmp/waves.mp4"),
            createdAt: Date(timeIntervalSince1970: 1_764_000_000)
        )
        let localItem = WallpaperItem(
            id: "local-1",
            title: "My Import",
            source: .localImport,
            mediaType: .image,
            localPath: tempDir.appendingPathComponent("custom.png")
        )

        let favorited = await store.toggleFavorite(item1)
        #expect(favorited == true)
        await store.recordRecent(item1)
        await store.addLocalImport(localItem)
        await store.updateDisplayConfig(
            DisplayConfig(
                mode: .mirrorAll,
                assignments: [
                    DisplayConfig.mirrorAssignmentKey: DisplayAssignment(
                        displayID: 0,
                        displayName: "Mirror",
                        wallpaper: item1,
                        scalingMode: .fit
                    )
                ]
            )
        )
        await store.updateSettings(
            AppSettings(
                customFeedURL: "https://example.com/feed.json",
                extractFirstFrameStill: false,
                launchInBackgroundOnClose: true,
                power: PowerSettings(pauseOnBattery: false, pauseOnFullscreen: true, pauseOnScreenLockOrSleep: true),
                preferredResolution: "4K"
            )
        )
        try await store.save()

        let expectedState = await store.state

        let reloadedStore = LibraryStore(baseDirectory: tempDir.appendingPathComponent("nested", isDirectory: true))
        let loadedState = try await reloadedStore.load()
        #expect(loadedState == expectedState)
    }

    @Test("LibraryStore deduplicates by composite (source, id) and ignores localPath differences")
    func libraryStoreCompositeIdentityAndDeduplication() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LibraryStore(baseDirectory: tempDir)
        let pexelsRemote = WallpaperItem(id: "123", title: "Pexels Video", source: .pexels, mediaType: .video)
        let pexelsCached = WallpaperItem(
            id: "123",
            title: "Pexels Video",
            source: .pexels,
            mediaType: .video,
            localPath: tempDir.appendingPathComponent("cached.mp4")
        )
        let pixabaySameID = WallpaperItem(id: "123", title: "Pixabay Video", source: .pixabay, mediaType: .video)

        #expect(await store.toggleFavorite(pexelsRemote) == true)
        #expect(await store.toggleFavorite(pixabaySameID) == true)
        #expect(await store.state.favorites.count == 2)
        #expect(await store.isFavorite(pexelsCached) == true)

        // Removing with updated localPath still matches (pexels, 123) and leaves (pixabay, 123) intact
        #expect(await store.toggleFavorite(pexelsCached) == false)
        #expect(await store.state.favorites.count == 1)
        #expect(await store.state.favorites.first?.source == .pixabay)

        // Recents ordering & limit
        for i in 1...5 {
            await store.recordRecent(
                WallpaperItem(id: "r\(i)", title: "Recent \(i)", source: .wallhaven, mediaType: .image),
                limit: 3
            )
        }
        #expect(await store.state.recents.map(\.id) == ["r5", "r4", "r3"])

        // Local import dedup by canonical localPath (/var vs /private/var)
        let fileURL = tempDir.appendingPathComponent("import.mp4")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("abc".utf8))
        let privatePrefixed = URL(fileURLWithPath: fileURL.path.hasPrefix("/private") ? fileURL.path : "/private" + fileURL.path)

        await store.addLocalImport(WallpaperItem(id: "loc-a", title: "A", source: .localImport, mediaType: .video, localPath: fileURL))
        await store.addLocalImport(WallpaperItem(id: "loc-b", title: "B", source: .localImport, mediaType: .video, localPath: privatePrefixed))
        #expect(await store.state.localImports.count == 1)
        #expect(await store.state.localImports.first?.id == "loc-b")

        await store.removeLocalImport(WallpaperItem(id: "loc-x", title: "X", source: .localImport, mediaType: .video, localPath: fileURL))
        #expect(await store.state.localImports.isEmpty)
    }

    @Test("LibraryStore quarantines corrupt state.json on recovery and throws when recovery disabled")
    func libraryStoreCorruptRecovery() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LibraryStore(baseDirectory: tempDir)
        let stateURL = await store.stateFileURL
        try Data("{not valid json".utf8).write(to: stateURL)

        await #expect(throws: (any Error).self) {
            _ = try await store.load(recoverFromCorruption: false)
        }
        #expect(FileManager.default.fileExists(atPath: stateURL.path))

        let recovered = try await store.load(recoverFromCorruption: true)
        #expect(recovered == LibraryState())
        #expect(await store.lastLoadWarning != nil)
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))

        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        #expect(files.contains(where: { $0.lastPathComponent.hasPrefix("state.corrupt-") }))
    }

    @Test("LibraryStore activeWallpaperLocalURLs resolves mirror/independent and canonicalizes paths")
    func libraryStoreActiveWallpaperLocalURLs() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let activeFile = tempDir.appendingPathComponent("active.mp4")
        let staleMirrorFile = tempDir.appendingPathComponent("stale_mirror.mp4")
        let unrelatedFile = tempDir.appendingPathComponent("unrelated.mp4")
        FileManager.default.createFile(atPath: activeFile.path, contents: Data("1".utf8))
        FileManager.default.createFile(atPath: staleMirrorFile.path, contents: Data("2".utf8))
        FileManager.default.createFile(atPath: unrelatedFile.path, contents: Data("3".utf8))

        let privateActive = URL(
            fileURLWithPath: activeFile.path.hasPrefix("/private") ? activeFile.path : "/private" + activeFile.path
        )

        let store = LibraryStore(baseDirectory: tempDir)
        let activeItem = WallpaperItem(id: "a1", title: "Active", source: .starter, mediaType: .video, localPath: privateActive)
        let mirrorItem = WallpaperItem(id: "m1", title: "Mirror", source: .starter, mediaType: .video, localPath: staleMirrorFile)
        let unrelatedItem = WallpaperItem(id: "u1", title: "Unrelated", source: .wallhaven, mediaType: .image, localPath: unrelatedFile)

        _ = await store.toggleFavorite(unrelatedItem)
        await store.recordRecent(unrelatedItem)

        // Independent mode ignores stale "mirror" entry
        await store.updateDisplayConfig(
            DisplayConfig(
                mode: .independent,
                assignments: [
                    DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: mirrorItem),
                    "1": DisplayAssignment(displayID: 1, displayName: "Main", wallpaper: activeItem)
                ]
            )
        )

        let activeURLs = await store.activeWallpaperLocalURLs()
        #expect(activeURLs == [PathCanonicalizer.canonicalFileURL(activeFile)])

        // Mirror mode selects "mirror" over display-specific entries
        await store.updateDisplayConfig(
            DisplayConfig(
                mode: .mirrorAll,
                assignments: [
                    DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: mirrorItem),
                    "1": DisplayAssignment(displayID: 1, displayName: "Main", wallpaper: activeItem)
                ]
            )
        )
        let mirrorURLs = await store.activeWallpaperLocalURLs()
        #expect(mirrorURLs == [PathCanonicalizer.canonicalFileURL(staleMirrorFile)])

        // Mirror mode without "mirror"/"primary" deterministically uses lowest sorted key and matches assignment(for:)
        let sortedConfig = DisplayConfig(
            mode: .mirrorAll,
            assignments: [
                "2": DisplayAssignment(displayID: 2, displayName: "Secondary", wallpaper: mirrorItem),
                "1": DisplayAssignment(displayID: 1, displayName: "Main", wallpaper: activeItem)
            ]
        )
        await store.updateDisplayConfig(sortedConfig)
        #expect(sortedConfig.assignment(for: 1)?.wallpaper?.id == "a1")
        #expect(sortedConfig.assignment(for: 2)?.wallpaper?.id == "a1")
        #expect(await store.activeWallpaperLocalURLs() == [PathCanonicalizer.canonicalFileURL(activeFile)])

        // Mirror mode with explicit "mirror" key having wallpaper == nil yields empty activeWallpaperLocalURLs()
        let nilMirrorConfig = DisplayConfig(
            mode: .mirrorAll,
            assignments: [
                DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: nil),
                "1": DisplayAssignment(displayID: 1, displayName: "Main", wallpaper: activeItem)
            ]
        )
        await store.updateDisplayConfig(nilMirrorConfig)
        #expect(nilMirrorConfig.assignment(for: 1)?.wallpaper == nil)
        #expect((await store.activeWallpaperLocalURLs()).isEmpty)
    }

    // MARK: - SecretStore Tests

    @Test("SecretStore enforces strict 0600 permissions and atomic lifecycle")
    func secretStoreEnforces0600Permissions() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let secretsURL = tempDir.appendingPathComponent("nested/secrets.json", isDirectory: false)
        let store = SecretStore(fileURL: secretsURL)

        let initial = try await store.load()
        #expect(initial.isEmpty)

        let firstSecrets = ApiSecrets(pexelsAPIKey: " p1 ", pixabayAPIKey: "x2", wallhavenAPIKey: "  ")
        try await store.save(firstSecrets)

        let attrs1 = try FileManager.default.attributesOfItem(atPath: secretsURL.path)
        let perms1 = attrs1[.posixPermissions] as? Int
        #expect(perms1 == 0o600)

        let reloaded = try await SecretStore(fileURL: secretsURL).load()
        #expect(reloaded == ApiSecrets(pexelsAPIKey: "p1", pixabayAPIKey: "x2", wallhavenAPIKey: nil))

        // Overwriting preserves 0600 and leaves zero temp files
        try await store.save(ApiSecrets(pexelsAPIKey: "p2", pixabayAPIKey: nil, wallhavenAPIKey: "w3"))
        let attrs2 = try FileManager.default.attributesOfItem(atPath: secretsURL.path)
        #expect((attrs2[.posixPermissions] as? Int) == 0o600)

        let dirContents = try FileManager.default.contentsOfDirectory(at: secretsURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(dirContents.map(\.lastPathComponent) == ["secrets.json"])

        try await store.clear()
        #expect(!FileManager.default.fileExists(atPath: secretsURL.path))
        // Idempotent second clear
        try await store.clear()
        #expect((try await store.load()).isEmpty)
    }
}
