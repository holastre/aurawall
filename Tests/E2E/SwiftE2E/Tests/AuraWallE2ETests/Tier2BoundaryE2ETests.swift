import AppKit
import Foundation
import Testing
import AuraWallCore

@Suite("Tier2 Boundary E2E Tests")
struct Tier2BoundaryE2ETests {

    // MARK: - F2 Boundaries

    @Test("T2-F2-01: StarterVideoProvider 12-of-13 404 resilience, curated fallback merge, and live boundary")
    func starterVideoProviderResilienceAndLiveBoundary() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            let provider = StarterVideoProvider(
                resources16TarURL: baseURL.appendingPathComponent("aerials/missing/resources-16.tar"),
                aerials2xURL: baseURL.appendingPathComponent("aerials/2x/entries.json"),
                probeURLsIn2xFallback: true
            )
            let service = CatalogService(providers: [provider])
            let result = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(mediaType: .video, sources: [.starter]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            let starterResult = try #require(
                E2EHelpers.extractProviderResults(from: result).first(where: { $0.source == .starter })
            )
            #expect(starterResult.errorMessage == nil)
            #expect(result.items.count >= 10)
            #expect(result.items.contains(where: { $0.id == "FE8E1171-C013-4000-8000-000000000013" }))
            #expect(!result.items.contains(where: { $0.fullAssetURL?.absoluteString.contains("/missing/") == true }))
            #expect(result.items.allSatisfy { $0.source == .starter && $0.mediaType == .video && $0.fullAssetURL != nil })

            // Also verify resources-16.tar primary path works cleanly on mock server
            let tarProvider = StarterVideoProvider(
                resources16TarURL: baseURL.appendingPathComponent("aerials/resources-16.tar"),
                aerials2xURL: baseURL.appendingPathComponent("aerials/missing/entries.json"),
                probeURLsIn2xFallback: true
            )
            let tarService = CatalogService(providers: [tarProvider])
            let tarResult = await tarService.fetchCatalog(
                query: E2EHelpers.makeQuery(mediaType: .video, sources: [.starter]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            let tarProviderResult = try #require(
                E2EHelpers.extractProviderResults(from: tarResult).first(where: { $0.source == .starter })
            )
            #expect(tarProviderResult.errorMessage == nil)
            #expect(tarResult.items.count >= 4)
        }

        if !E2EEnvironment.noLive {
            let liveService = CatalogService(providers: [StarterVideoProvider()])
            let liveResult = await liveService.fetchCatalog(
                query: E2EHelpers.makeQuery(mediaType: .video, sources: [.starter]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            let liveProvider = try #require(
                E2EHelpers.extractProviderResults(from: liveResult).first(where: { $0.source == .starter })
            )
            #expect(liveProvider.errorMessage == nil)
            #expect(liveResult.items.count >= 10)
            #expect(liveResult.items.allSatisfy { $0.source == .starter && $0.fullAssetURL?.scheme?.lowercased() == "https" })
        }
    }

    @Test("T2-F2-02: WallhavenProvider polymorphic meta.query, empty source, and unauthenticated purity=001")
    func wallhavenPolymorphicMetaQueryAndEmptySource() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            // 1. Tag object meta.query + seed + empty source via decodeSearchResponse & CatalogService
            let tagURL = try #require(URL(string: "/wallhaven/api/v1/search?q=id:37&purity=100", relativeTo: baseURL))
            let (tagData, _) = try await URLSession.shared.data(from: tagURL)
            let tagPayload = try WallhavenProvider.decodeSearchResponse(data: tagData)
            #expect(tagPayload.queryMeta == .tag(id: 37, tag: "nature"))
            #expect(tagPayload.seed == "uwn0FK")
            #expect(tagPayload.items.count == 1)
            #expect(tagPayload.items.first?.id == "37tag1")

            let provider = WallhavenProvider(baseURL: baseURL.appendingPathComponent("wallhaven"))
            let service = CatalogService(providers: [provider])
            let tagCatalog = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "id:37", mediaType: .image, sources: [.wallhaven]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            let tagProviderResult = try #require(
                E2EHelpers.extractProviderResults(from: tagCatalog).first(where: { $0.source == .wallhaven })
            )
            #expect(tagProviderResult.errorMessage == nil)
            #expect(tagCatalog.items.count == 1)

            // 2. Omitted q -> meta.query == .none + empty source item decoded cleanly
            let nilQueryURL = try #require(URL(string: "/wallhaven/api/v1/search?purity=100", relativeTo: baseURL))
            let (nilQueryData, _) = try await URLSession.shared.data(from: nilQueryURL)
            let nilQueryPayload = try WallhavenProvider.decodeSearchResponse(data: nilQueryData)
            #expect(nilQueryPayload.queryMeta == nil)
            #expect(nilQueryPayload.items.count >= 2)

            let emptyTextCatalog = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "", mediaType: .image, sources: [.wallhaven]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            #expect(emptyTextCatalog.errorsBySource[.wallhaven] == nil)
            #expect(emptyTextCatalog.items.count >= 2)

            // 3. Unauthenticated purity=001 -> empty data array
            let nsfwURL = try #require(URL(string: "/wallhaven/api/v1/search?purity=001", relativeTo: baseURL))
            let (nsfwData, _) = try await URLSession.shared.data(from: nsfwURL)
            let nsfwPayload = try WallhavenProvider.decodeSearchResponse(data: nsfwData)
            #expect(nsfwPayload.items.isEmpty)
            #expect(nsfwPayload.hasNextPage == false)
        }
    }

    @Test("T2-F2-03: WallhavenProvider page clamping, 500 HTML / 401 / 429 isolation, and live boundary")
    func wallhavenPageClampingAndErrorIsolation() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            let provider = WallhavenProvider(baseURL: baseURL.appendingPathComponent("wallhaven"))
            let clampedURL = try provider.buildSearchURL(query: E2EHelpers.makeQuery(text: "landscape", page: -1))
            let components = try #require(URLComponents(url: clampedURL, resolvingAgainstBaseURL: false))
            let pageItem = components.queryItems?.first(where: { $0.name == "page" })?.value
            #expect(pageItem == "1")

            // Raw ProviderHTTPClient on page=-1 receives HTTP 500 HTML without crashing JSON decoders
            let client = ProviderHTTPClient()
            let raw500URL = try #require(URL(string: "/wallhaven/api/v1/search?page=-1", relativeTo: baseURL))
            do {
                _ = try await client.get(raw500URL, source: .wallhaven)
                Issue.record("Expected ProviderError.httpError(500) for page=-1")
            } catch ProviderError.httpError(let statusCode, let snippet) {
                #expect(statusCode == 500)
                #expect(snippet?.contains("It broke") == true)
            }

            let service = CatalogService(providers: [provider])

            // 500 HTML via q=error500 isolated in CatalogService
            let error500Result = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "error500", mediaType: .image, sources: [.wallhaven]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            #expect(error500Result.items.isEmpty)
            #expect(error500Result.errorsBySource[.wallhaven]?.contains("500") == true)

            // 401 unauthorized isolated
            let unauthResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "landscape", mediaType: .image, sources: [.wallhaven]),
                secrets: ApiSecrets(wallhavenAPIKey: "invalid_key_123"),
                customFeedURL: nil
            )
            #expect(unauthResult.items.isEmpty)
            #expect(unauthResult.errorsBySource[.wallhaven]?.localizedCaseInsensitiveContains("unauthorized") == true)

            // 429 rate limit with Retry-After: 60 isolated
            let rateLimitResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "ratelimit", mediaType: .image, sources: [.wallhaven]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            #expect(rateLimitResult.items.isEmpty)
            let rlMessage = rateLimitResult.errorsBySource[.wallhaven] ?? ""
            #expect(rlMessage.localizedCaseInsensitiveContains("rate limit"))
            #expect(rlMessage.contains("60s"))
        }

        if !E2EEnvironment.noLive {
            let liveService = CatalogService(providers: [WallhavenProvider()])
            let liveResult = await liveService.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "landscape", mediaType: .image, sources: [.wallhaven], page: -1),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            let liveProvider = try #require(
                E2EHelpers.extractProviderResults(from: liveResult).first(where: { $0.source == .wallhaven })
            )
            #expect(liveProvider.errorMessage == nil)
            #expect(!liveResult.items.isEmpty)
            #expect(liveResult.items.allSatisfy { $0.source == .wallhaven && $0.fullAssetURL?.scheme?.lowercased() == "https" })
        }
    }

    @Test("T2-F2-04: PexelsProvider missing/Bearer/invalid key 401, 429 rate limit, and HLS/portrait filtering")
    func pexelsAuthRateLimitAndStreamFiltering() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            let provider = PexelsProvider(baseURL: baseURL.appendingPathComponent("pexels"))
            let service = CatalogService(providers: [provider])

            // 1. Missing API key
            await #expect(throws: ProviderError.missingAPIKey(.pexels)) {
                _ = try await provider.fetch(
                    query: E2EHelpers.makeQuery(text: "waves", mediaType: .video, sources: [.pexels]),
                    secrets: ApiSecrets(),
                    customFeedURL: nil
                )
            }
            let missingKeyResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "waves", mediaType: .video, sources: [.pexels]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
            #expect(missingKeyResult.items.isEmpty)
            #expect(missingKeyResult.errorsBySource[.pexels] != nil)

            // 2. Bearer prefix & invalid key 401
            for badKey in ["Bearer valid_key", "invalid_key_123"] {
                let badKeyResult = await service.fetchCatalog(
                    query: E2EHelpers.makeQuery(text: "waves", mediaType: .video, sources: [.pexels]),
                    secrets: ApiSecrets(pexelsAPIKey: badKey),
                    customFeedURL: nil
                )
                #expect(badKeyResult.items.isEmpty)
                let msg = badKeyResult.errorsBySource[.pexels] ?? ""
                #expect(msg.localizedCaseInsensitiveContains("authentication failed") || msg.localizedCaseInsensitiveContains("invalid"))
            }

            // 3. 429 rate limit
            let rlResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "ratelimit", mediaType: .video, sources: [.pexels]),
                secrets: ApiSecrets(pexelsAPIKey: "valid_key"),
                customFeedURL: nil
            )
            #expect(rlResult.items.isEmpty)
            let rlMessage = rlResult.errorsBySource[.pexels] ?? ""
            #expect(rlMessage.localizedCaseInsensitiveContains("rate limit"))
            #expect(rlMessage.contains("60s"))

            // 4. HLS null & portrait stream filtering
            let okResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "waves", mediaType: .video, sources: [.pexels]),
                secrets: ApiSecrets(pexelsAPIKey: "valid_key"),
                customFeedURL: nil
            )
            #expect(okResult.errorsBySource[.pexels] == nil)
            let video = try #require(okResult.items.first)
            #expect(video.width == 3840)
            #expect(video.height == 2160)
            #expect(video.fullAssetURL?.pathExtension.lowercased() == "mp4")
            #expect(video.previewVideoURL?.pathExtension.lowercased() == "mp4")
            #expect(video.previewVideoURL?.absoluteString.contains(".m3u8") == false)
        }
    }

    @Test("T2-F2-05: PixabayProvider empty large fallback to medium, plain-text 400 unauthorized, and 429 rate limit")
    func pixabayEmptyLargeFallbackAndPlainTextErrors() async throws {
        try await E2EHelpers.withMockBaseURL { baseURL in
            let provider = PixabayProvider(baseURL: baseURL.appendingPathComponent("pixabay"))
            let service = CatalogService(providers: [provider])

            // 1. Plain-text 400 invalid key -> ProviderError.unauthorized
            await #expect(throws: (any Error).self) {
                do {
                    _ = try await provider.fetch(
                        query: E2EHelpers.makeQuery(text: "nature", mediaType: .video, sources: [.pixabay]),
                        secrets: ApiSecrets(pixabayAPIKey: "invalid_key_123"),
                        customFeedURL: nil
                    )
                } catch let err as ProviderError {
                    guard case .unauthorized(let src, _) = err, src == .pixabay else {
                        Issue.record("Expected ProviderError.unauthorized(.pixabay), got \(err)")
                        return
                    }
                    throw err
                }
            }
            let invalidKeyResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "nature", mediaType: .video, sources: [.pixabay]),
                secrets: ApiSecrets(pixabayAPIKey: "invalid_key_123"),
                customFeedURL: nil
            )
            #expect(invalidKeyResult.items.isEmpty)
            #expect(invalidKeyResult.errorsBySource[.pixabay]?.localizedCaseInsensitiveContains("authentication failed") == true)

            // 2. 429 rate limit
            let rlResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "ratelimit", mediaType: .image, sources: [.pixabay]),
                secrets: ApiSecrets(pixabayAPIKey: "valid_key"),
                customFeedURL: nil
            )
            #expect(rlResult.items.isEmpty)
            let rlMsg = rlResult.errorsBySource[.pixabay] ?? ""
            #expect(rlMsg.localizedCaseInsensitiveContains("rate limit"))
            #expect(rlMsg.contains("60s"))

            // 3. Empty videos.large.url falls back to medium (1920x1080)
            let okResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(text: "", mediaType: .video, sources: [.pixabay]),
                secrets: ApiSecrets(pixabayAPIKey: "valid_key"),
                customFeedURL: nil
            )
            #expect(okResult.errorsBySource[.pixabay] == nil)
            let fallbackVideo = try #require(okResult.items.first(where: { $0.id == "pixabay-video-24891" }))
            #expect(fallbackVideo.width == 1920)
            #expect(fallbackVideo.height == 1080)
            #expect(fallbackVideo.fullAssetURL?.lastPathComponent == "sample_video.mp4")
        }
    }

    @Test("T2-F2-06: Custom feed empty/malformed/500 isolation and SecretStore 0644 -> 0600 overwrite")
    func customFeedEdgeCasesAndSecretPermissionOverwrite() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let service = E2EHelpers.makeCatalogService()

                // 1. Empty array feed succeeds with zero items and no error
                let emptyResult = await service.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.customFeed]),
                    secrets: ApiSecrets(),
                    customFeedURL: baseURL.appendingPathComponent("custom/empty.json")
                )
                #expect(E2EHelpers.extractItems(from: emptyResult).isEmpty)
                let emptyProvider = E2EHelpers.extractProviderResults(from: emptyResult)
                    .first(where: { $0.source == .customFeed })
                #expect(emptyProvider != nil)
                #expect(emptyProvider?.errorMessage == nil)

                // 2. Malformed JSON feed isolates error without crashing
                let malformedResult = await service.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.customFeed]),
                    secrets: ApiSecrets(),
                    customFeedURL: baseURL.appendingPathComponent("custom/malformed.json")
                )
                #expect(E2EHelpers.extractItems(from: malformedResult).isEmpty)
                let malformedProvider = E2EHelpers.extractProviderResults(from: malformedResult)
                    .first(where: { $0.source == .customFeed })
                #expect(malformedProvider?.errorMessage != nil)

                // 3. HTTP 500 HTML error isolates error without crashing
                let html500Result = await service.fetchCatalog(
                    query: E2EHelpers.makeQuery(sources: [.customFeed]),
                    secrets: ApiSecrets(),
                    customFeedURL: baseURL.appendingPathComponent("custom/error500.html")
                )
                #expect(E2EHelpers.extractItems(from: html500Result).isEmpty)
                let html500Provider = E2EHelpers.extractProviderResults(from: html500Result)
                    .first(where: { $0.source == .customFeed })
                #expect(html500Provider?.errorMessage != nil)
            }

            // 4. SecretStore overwrites pre-existing 0o644 file back to 0o600 and persists value
            let secretsURL = tempDir.appendingPathComponent("secrets/secrets.json")
            try FileManager.default.createDirectory(at: secretsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: secretsURL.path,
                contents: Data("{}".utf8),
                attributes: [.posixPermissions: 0o644]
            )
            let initialPerms = try E2EHelpers.posixPermissions(of: secretsURL)
            #expect(initialPerms == 0o644)

            let secretStore = SecretStore(fileURL: secretsURL)
            try await secretStore.save(ApiSecrets(pexelsAPIKey: "overwritten-key"))
            let updatedPerms = try E2EHelpers.posixPermissions(of: secretsURL)
            #expect(updatedPerms == 0o600)
            let loadedSecrets = try await SecretStore(fileURL: secretsURL).load()
            #expect(loadedSecrets.pexelsAPIKey == "overwritten-key")
        }
    }

    // MARK: - F3 Boundaries

    @Test("T2-F3-01: Corrupt/truncated state.json throws when recovery disabled and recovers safely when enabled")
    func corruptStateJSONRecovery() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let stateURL = await store.stateFileURL
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{corrupt".utf8).write(to: stateURL)

            await #expect(throws: (any Error).self) {
                _ = try await store.load(recoverFromCorruption: false)
            }
            #expect(FileManager.default.fileExists(atPath: stateURL.path))

            let recovered = try await store.load(recoverFromCorruption: true)
            #expect(recovered == LibraryState())
            #expect(await store.lastLoadWarning != nil)
            #expect(!FileManager.default.fileExists(atPath: stateURL.path))

            let entries = try FileManager.default.contentsOfDirectory(
                at: await store.baseDirectory,
                includingPropertiesForKeys: nil
            )
            #expect(entries.contains {
                let name = $0.lastPathComponent
                return name.hasPrefix("state.corrupt-") && name.hasSuffix(".json")
            })
        }
    }

    @Test("T2-F3-02: Zero/negative dimensions and empty metadata encode/decode cleanly")
    func zeroAndNegativeDimensionsMetadata() throws {
        let item = WallpaperItem(
            id: "zero-dim",
            title: "Zero Dimensions",
            source: .customFeed,
            mediaType: .video,
            width: 0,
            height: -1,
            duration: 0,
            tags: [],
            dominantColors: []
        )
        #expect(item.resolutionLabel == nil)
        #expect(item.aspectRatio == nil)

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WallpaperItem.self, from: data)
        #expect(decoded == item)
    }

    @Test("T2-F3-03: Duplicate favorite toggle and repeat recordRecent idempotency")
    func duplicateFavoriteAndRecentIdempotency() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let item = WallpaperItem(id: "dup-1", title: "Dup", source: .wallhaven, mediaType: .image)

            #expect(await store.toggleFavorite(item) == true)
            #expect(await store.toggleFavorite(item) == false)
            #expect(await store.state.favorites.isEmpty)

            await store.recordRecent(item)
            await store.recordRecent(item)
            await store.recordRecent(item)
            #expect(await store.state.recents.count == 1)
        }
    }

    @Test("T2-F3-04: Empty cache metrics and nil fullAssetURL download throws cleanly")
    func emptyCacheAndMissingFullAssetURL() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let cache = E2EHelpers.makeCacheManager(in: tempDir)
            #expect(await cache.totalCacheSizeBytes() == 0)
            let cleared = try await cache.clearCache(preserving: [])
            #expect(cleared == 0)

            let noURLItem = WallpaperItem(
                id: "no-url",
                title: "Missing URL",
                source: .starter,
                mediaType: .video,
                fullAssetURL: nil
            )
            await #expect(throws: MediaCacheError.missingAssetURL) {
                _ = try await cache.download(noURLItem)
            }
        }
    }

    @Test("T2-F3-05: Failed 404 and 500 downloads throw and leave zero partial cache or .tmp entries")
    func failed404And500DownloadNoPartialCache() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let cache = E2EHelpers.makeCacheManager(in: tempDir)

                let item404 = WallpaperItem(
                    id: "fail-404",
                    title: "Missing 404",
                    source: .customFeed,
                    mediaType: .video,
                    fullAssetURL: baseURL.appendingPathComponent("media/not_found_e2e.mp4")
                )
                let item500 = WallpaperItem(
                    id: "fail-500",
                    title: "Broken 500",
                    source: .customFeed,
                    mediaType: .video,
                    fullAssetURL: baseURL.appendingPathComponent("custom/error500.html")
                )

                await #expect(throws: (any Error).self) {
                    _ = try await cache.download(item404)
                }
                await #expect(throws: (any Error).self) {
                    _ = try await cache.download(item500)
                }

                #expect(await cache.cachedFileURL(for: item404) == nil)
                #expect(await cache.cachedFileURL(for: item500) == nil)
                #expect(await cache.totalCacheSizeBytes() == 0)

                let cacheContents = try FileManager.default.contentsOfDirectory(
                    at: await cache.cacheDirectory,
                    includingPropertiesForKeys: nil
                )
                #expect(cacheContents.isEmpty)
            }
        }
    }

    @Test("T2-F3-06: Clearing cache preserves 2 active files byte-for-byte while deleting 2 unreferenced files")
    func clearCachePreservesTwoOfFourFiles() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            try await E2EHelpers.withMockBaseURL { baseURL in
                let videoURL = try await E2EHelpers.firstVideoURL(from: baseURL)
                let imageURL = try await E2EHelpers.firstImageURL(from: baseURL)
                let cache = E2EHelpers.makeCacheManager(in: tempDir)

                let keepVideo = WallpaperItem(id: "keep-v1", title: "Keep Video", source: .customFeed, mediaType: .video, fullAssetURL: videoURL)
                let keepStill = WallpaperItem(id: "keep-s1", title: "Keep Still", source: .customFeed, mediaType: .image, fullAssetURL: imageURL)
                let dropVideo = WallpaperItem(id: "drop-v2", title: "Drop Video", source: .customFeed, mediaType: .video, fullAssetURL: videoURL)
                let dropStill = WallpaperItem(id: "drop-s2", title: "Drop Still", source: .customFeed, mediaType: .image, fullAssetURL: imageURL)

                let urlKeepV = try await cache.download(keepVideo)
                let urlKeepS = try await cache.download(keepStill)
                let urlDropV = try await cache.download(dropVideo)
                let urlDropS = try await cache.download(dropStill)

                let bytesKeepV = try Data(contentsOf: urlKeepV)
                let bytesKeepS = try Data(contentsOf: urlKeepS)
                let bytesDropV = try Data(contentsOf: urlDropV)
                let bytesDropS = try Data(contentsOf: urlDropS)

                let freed = try await cache.clearCache(preserving: [urlKeepV, urlKeepS])
                #expect(freed == Int64(bytesDropV.count + bytesDropS.count))
                let afterKeepV = try Data(contentsOf: urlKeepV)
                let afterKeepS = try Data(contentsOf: urlKeepS)
                #expect(afterKeepV == bytesKeepV)
                #expect(afterKeepS == bytesKeepS)
                #expect(!FileManager.default.fileExists(atPath: urlDropV.path))
                #expect(!FileManager.default.fileExists(atPath: urlDropS.path))
                #expect(await cache.totalCacheSizeBytes() == Int64(bytesKeepV.count + bytesKeepS.count))
            }
        }
    }

    // MARK: - F4 Boundaries

    @MainActor
    @Test("T2-F4-01: WallpaperEngine rejects nil URLs and remote-only static image URLs while tearing down active video")
    func wallpaperEngineApplyNilLocalURL() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: false)
            let expectedDisplayIDs = Set(engine.displayManager.displays.map(\.id))
            #expect(!expectedDisplayIDs.isEmpty)

            // Apply a valid video first to verify nil-URL application tears it down
            let validVideo = WallpaperItem(id: "valid-v", title: "Valid", source: .starter, mediaType: .video, localPath: mp4URL)
            engine.apply(wallpaper: validVideo, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.activeVideoDisplayIDs == expectedDisplayIDs)
            #expect(engine.lastErrorMessage == nil)

            let emptyItem = WallpaperItem(id: "nil-urls", title: "Empty", source: .starter, mediaType: .video)
            engine.apply(wallpaper: emptyItem, localURL: nil, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage == "No playable or displayable URL for wallpaper nil-urls.")
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
            #expect(desktopCalls.value.isEmpty)

            // Remote-only .image (no localPath) must be rejected without invoking desktopImageSetter
            let remoteOnlyImage = WallpaperItem(
                id: "remote-img",
                title: "Remote Image",
                source: .wallhaven,
                mediaType: .image,
                fullAssetURL: URL(string: "https://example.com/wallpaper.jpg")
            )
            engine.apply(wallpaper: remoteOnlyImage, localURL: nil, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage == "Static desktop image must be a local file URL.")
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(desktopCalls.value.isEmpty)

            engine.teardownAllVideoWindows()
        }
    }

    @MainActor
    @Test("T2-F4-02: WallpaperEngine disconnected or zero displayID reports error and preserves connected display")
    func wallpaperEngineDisconnectedDisplayID() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let jpgURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)
            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: false)
            let connectedID = try #require(engine.displayManager.displays.first?.id)

            // Establish an active wallpaper on a connected display first
            let connectedItem = WallpaperItem(id: "conn-1", title: "Connected", source: .starter, mediaType: .video, localPath: mp4URL)
            engine.apply(wallpaper: connectedItem, localURL: mp4URL, to: connectedID, mode: .independent, scaling: .fill)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs == [connectedID])
            #expect(engine.activeWallpapers[connectedID]?.id == "conn-1")
            let desktopCallsBefore = desktopCalls.value.count

            let videoItem = WallpaperItem(id: "disc-1", title: "Disconnected Video", source: .starter, mediaType: .video, localPath: mp4URL)
            engine.apply(wallpaper: videoItem, localURL: mp4URL, to: 999_999, mode: .independent, scaling: .fill)
            #expect(engine.lastErrorMessage == "Display 999999 is not connected.")
            #expect(engine.activeWallpapers[999_999] == nil)
            #expect(engine.activeWallpapers[connectedID]?.id == "conn-1")
            #expect(engine.activeVideoDisplayIDs == [connectedID])
            #expect(desktopCalls.value.count == desktopCallsBefore)

            let imageItem = WallpaperItem(id: "disc-0", title: "Disconnected Image", source: .wallhaven, mediaType: .image, localPath: jpgURL)
            engine.apply(wallpaper: imageItem, localURL: jpgURL, to: 0, mode: .independent, scaling: .fit)
            #expect(engine.lastErrorMessage == "Display 0 is not connected.")
            #expect(engine.activeWallpapers[0] == nil)
            #expect(engine.activeWallpapers[connectedID]?.id == "conn-1")
            #expect(desktopCalls.value.count == desktopCallsBefore)

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
        }
    }

    @MainActor
    @Test("T2-F4-03: Idempotent repeated teardownAllVideoWindows clears videos and preserves static images")
    func wallpaperEngineIdempotentRepeatedTeardown() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let jpgURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)
            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: false)
            let expectedDisplayIDs = Set(engine.displayManager.displays.map(\.id))
            #expect(!expectedDisplayIDs.isEmpty)

            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
            #expect(engine.lastErrorMessage == nil)

            engine.teardownAllVideoWindows()
            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(engine.currentDecisions.isEmpty)
            #expect(engine.lastErrorMessage == nil)

            // Teardown after static image leaves active static wallpaper intact
            let staticItem = WallpaperItem(id: "static-keep", title: "Static", source: .wallhaven, mediaType: .image, localPath: jpgURL)
            engine.apply(wallpaper: staticItem, localURL: jpgURL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage == nil)
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(desktopCalls.value.count == expectedDisplayIDs.count)

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.lastErrorMessage == nil)
            #expect(expectedDisplayIDs.allSatisfy { engine.activeWallpapers[$0]?.id == "static-keep" })
        }
    }

    @MainActor
    @Test("T2-F4-04: Corrupt 0-byte MP4/JPG, missing local file, and still extraction failure are handled safely")
    func wallpaperEngineCorruptZeroByteMP4AndMissingFiles() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let corruptMP4 = try E2EHelpers.resolveCorruptZeroMP4(in: tempDir)
            let corruptJPG = try E2EHelpers.resolveCorruptZeroJPG(in: tempDir)
            let missingURL = tempDir.appendingPathComponent("does_not_exist.mp4", isDirectory: false)
            #expect(try Data(contentsOf: corruptMP4).isEmpty)
            #expect(try Data(contentsOf: corruptJPG).isEmpty)

            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: false)

            // 1. 0-byte MP4 rejected
            let videoItem = WallpaperItem(id: "corrupt-mp4", title: "Corrupt MP4", source: .localImport, mediaType: .video, localPath: corruptMP4)
            engine.apply(wallpaper: videoItem, localURL: corruptMP4, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage?.contains("Media file missing or empty") == true)
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(desktopCalls.value.isEmpty)

            // 2. 0-byte JPG rejected
            let imageItem = WallpaperItem(id: "corrupt-jpg", title: "Corrupt JPG", source: .localImport, mediaType: .image, localPath: corruptJPG)
            engine.apply(wallpaper: imageItem, localURL: corruptJPG, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage?.contains("Media file missing or empty") == true)
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(desktopCalls.value.isEmpty)

            // 3. Missing local file rejected
            let missingItem = WallpaperItem(id: "missing-mp4", title: "Missing MP4", source: .localImport, mediaType: .video, localPath: missingURL)
            engine.apply(wallpaper: missingItem, localURL: missingURL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.lastErrorMessage?.contains("Media file missing or empty") == true)
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(desktopCalls.value.isEmpty)

            // 4. First-frame still extraction throws on corrupt 0-byte MP4
            let stillsDir = tempDir.appendingPathComponent("CorruptStills", isDirectory: true)
            await #expect(throws: (any Error).self) {
                _ = try await WallpaperEngine.extractFirstFrameStillImage(from: corruptMP4, into: stillsDir)
            }

            engine.updatePowerInputs(PowerInputs(onBattery: true))
            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
        }
    }

    @MainActor
    @Test("T2-F4-05: Mirror and independent DisplayConfig with empty or nil-wallpaper assignments tear down active videos")
    func mirrorVsIndependentEmptyAssignments() async throws {
        let emptyIndep = DisplayConfig(mode: .independent, assignments: [:])
        #expect(emptyIndep.assignment(for: 1) == nil)
        #expect(emptyIndep.activeWallpapers().isEmpty)

        let nilMirror = DisplayConfig(
            mode: .mirrorAll,
            assignments: [
                DisplayConfig.mirrorAssignmentKey: DisplayAssignment(displayID: 0, displayName: "Mirror", wallpaper: nil)
            ]
        )
        #expect(nilMirror.activeWallpapers().isEmpty)

        let decodedIndep = try JSONDecoder().decode(DisplayConfig.self, from: try JSONEncoder().encode(emptyIndep))
        let decodedMirror = try JSONDecoder().decode(DisplayConfig.self, from: try JSONEncoder().encode(nilMirror))
        #expect(decodedIndep == emptyIndep)
        #expect(decodedMirror == nilMirror)

        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(in: tempDir, extractFirstFrameStill: false)
            let expectedDisplayIDs = Set(engine.displayManager.displays.map(\.id))
            let validVideo = WallpaperItem(id: "cfg-v", title: "Config Video", source: .starter, mediaType: .video, localPath: mp4URL)

            engine.apply(wallpaper: validVideo, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.activeVideoDisplayIDs == expectedDisplayIDs)

            engine.apply(config: emptyIndep)
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(desktopCalls.value.isEmpty)

            engine.apply(wallpaper: validVideo, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
            #expect(engine.activeVideoDisplayIDs == expectedDisplayIDs)

            engine.apply(config: nilMirror)
            #expect(engine.activeVideoDisplayIDs.isEmpty)
            #expect(engine.activeWallpapers.isEmpty)
            #expect(desktopCalls.value.isEmpty)
        }
    }

    // MARK: - F5 Boundaries

    @Test("T2-F5-01: Battery override active while on AC power evaluates to .play")
    func batteryOverrideWithoutBattery() {
        let inputs = PowerInputs(
            onBattery: false,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .play)
    }

    @Test("T2-F5-02: Screen lock/sleep overrides active battery override")
    func batteryOverrideUnderLockAndSleep() {
        let inputs = PowerInputs(
            displayAsleep: false,
            screenLocked: true,
            onBattery: true,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true,
            pauseOnLockSleepEnabled: true
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .pause(.displayAsleepOrLocked))
    }

    @Test("T2-F5-03: Fullscreen occlusion overrides battery override on occluded display only")
    func batteryOverrideUnderFullscreen() {
        let inputs = PowerInputs(
            onBattery: true,
            batteryOverrideActive: true,
            pauseOnBatteryEnabled: true,
            pauseOnFullscreenEnabled: true,
            fullscreenDisplayIDs: [1]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 2) == .play)
    }

    @Test("T2-F5-04: Disabled power settings bypass lock, battery, and fullscreen while manualPause still pauses")
    func disabledPowerSettingsTogglesBypass() {
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

    @Test("T2-F5-05: Boundary displayIDs 0 and UInt32.max match fullscreenDisplayIDs accurately")
    func boundaryDisplayIDsZeroAndUInt32Max() {
        let inputs = PowerInputs(
            pauseOnFullscreenEnabled: true,
            fullscreenDisplayIDs: [0, UInt32.max]
        )
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 0) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: UInt32.max) == .pause(.fullscreenOccluded))
        #expect(PowerPolicyEvaluator.evaluate(inputs: inputs, forDisplay: 1) == .play)
    }

    // MARK: - F6 Boundaries

    @Test("T2-F6-01: LocalMediaImporter rejects unsupported formats (.txt/.svg/.dmg) and imports supported media")
    func localMediaImporterExtensionsAndPersistence() async throws {
        #expect(LocalMediaImporter.supportedExtensions == ["mp4", "mov", "m4v", "jpg", "jpeg", "png", "heic"])

        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let store = E2EHelpers.makeLibraryStore(in: tempDir)
            let importsDir = await store.baseDirectory.appendingPathComponent("Imports", isDirectory: true)
            let thumbsDir = importsDir.appendingPathComponent("Thumbnails", isDirectory: true)

            let txtURL = try E2EHelpers.resolveNegativeMediaFixture(
                named: "sample.txt",
                in: tempDir,
                fallbackContent: Data("plain text".utf8)
            )
            let svgURL = try E2EHelpers.resolveNegativeMediaFixture(
                named: "sample.svg",
                in: tempDir,
                fallbackContent: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
            )
            let dmgURL = tempDir.appendingPathComponent("installer.dmg", isDirectory: false)
            try Data("fake dmg".utf8).write(to: dmgURL)

            for (badURL, expectedExt) in [(txtURL, "txt"), (svgURL, "svg"), (dmgURL, "dmg")] {
                #expect(!LocalMediaImporter.isSupportedExtension(badURL))
                await #expect(throws: LocalMediaImportError.unsupportedFormat(expectedExt)) {
                    _ = try await LocalMediaImporter.importFile(
                        from: badURL,
                        importsDir: importsDir,
                        thumbsDir: thumbsDir
                    )
                }
            }

            // Prepare supported media including .m4v
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let movURL = try E2EHelpers.resolveMediaFixture(extension: "mov", in: tempDir)
            let m4vURL = tempDir.appendingPathComponent("sample_clip.m4v", isDirectory: false)
            try Data(contentsOf: mp4URL).write(to: m4vURL)
            let jpgURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)
            let pngURL = try E2EHelpers.resolveMediaFixture(extension: "png", in: tempDir)
            let heicURL = try E2EHelpers.resolveMediaFixture(extension: "heic", in: tempDir)

            let expectedCases: [(URL, WallpaperMediaType)] = [
                (mp4URL, .video),
                (movURL, .video),
                (m4vURL, .video),
                (jpgURL, .image),
                (pngURL, .image),
                (heicURL, .image)
            ]

            for (sourceURL, expectedType) in expectedCases {
                let imported = try await LocalMediaImporter.importFile(
                    from: sourceURL,
                    importsDir: importsDir,
                    thumbsDir: thumbsDir
                )
                #expect(imported.source == .localImport)
                #expect(imported.mediaType == expectedType)
                let localPath = try #require(imported.localPath)
                #expect(FileManager.default.fileExists(atPath: localPath.path))
                #expect((imported.width ?? 0) > 0)
                #expect((imported.height ?? 0) > 0)
                await store.addLocalImport(imported)
            }

            try await store.save()
            let reloaded = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
            #expect(reloaded.localImports.count == expectedCases.count)
        }
    }

    @Test("T2-F6-02: LocalMediaImporter rejects 0-byte and disguised corrupt media without leaving orphan files")
    func localMediaImporterCorruptMediaLeavesNoOrphans() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let importsDir = tempDir.appendingPathComponent("Imports", isDirectory: true)
            let thumbsDir = importsDir.appendingPathComponent("Thumbnails", isDirectory: true)

            let zeroMP4 = try E2EHelpers.resolveCorruptZeroMP4(in: tempDir)
            let zeroJPG = try E2EHelpers.resolveCorruptZeroJPG(in: tempDir)

            for emptyURL in [zeroMP4, zeroJPG] {
                await #expect(throws: LocalMediaImportError.emptyOrUnreadableFile) {
                    _ = try await LocalMediaImporter.importFile(
                        from: emptyURL,
                        importsDir: importsDir,
                        thumbsDir: thumbsDir
                    )
                }
            }

            let disguisedMP4 = tempDir.appendingPathComponent("disguised_corrupt.mp4", isDirectory: false)
            let disguisedJPG = tempDir.appendingPathComponent("disguised_corrupt.jpg", isDirectory: false)
            try Data("definitely not valid mp4 atoms".utf8).write(to: disguisedMP4)
            try Data("definitely not valid jpeg header".utf8).write(to: disguisedJPG)

            for corruptURL in [disguisedMP4, disguisedJPG] {
                await #expect(throws: (any Error).self) {
                    _ = try await LocalMediaImporter.importFile(
                        from: corruptURL,
                        importsDir: importsDir,
                        thumbsDir: thumbsDir
                    )
                }
            }

            if FileManager.default.fileExists(atPath: importsDir.path) {
                let importEntries = try FileManager.default.contentsOfDirectory(
                    at: importsDir,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )
                let orphanImportFiles = importEntries.filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                #expect(orphanImportFiles.isEmpty)
            }

            if FileManager.default.fileExists(atPath: thumbsDir.path) {
                let thumbEntries = try FileManager.default.contentsOfDirectory(
                    at: thumbsDir,
                    includingPropertiesForKeys: nil
                )
                #expect(thumbEntries.isEmpty)
            }
        }
    }

    @Test("T2-F6-03: Invalid customFeedURLs validate to nil and non-loopback http:// is rejected by CustomFeedProvider")
    func emptyNilAndInvalidCustomFeedURL() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let candidates: [String?] = [
                nil,
                "",
                "   \n ",
                "not a url",
                "javascript:alert(1)",
                "ftp://example.com/feed.json",
                "file:///tmp/feed.json"
            ]
            let store = E2EHelpers.makeLibraryStore(in: tempDir)

            for raw in candidates {
                let settings = AppSettings(customFeedURL: raw)
                #expect(settings.validatedCustomFeedURL == nil)
                await store.updateSettings(settings)
                try await store.save()
                let reloaded = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
                #expect(reloaded.settings.validatedCustomFeedURL == nil)
            }

            // Non-loopback http:// fails CustomFeedProvider & CatalogService remote URL policy
            let insecureSettings = AppSettings(customFeedURL: "http://example.com/feed.json")
            let insecureURL = try #require(insecureSettings.validatedCustomFeedURL)
            let service = E2EHelpers.makeCatalogService()
            let catalogResult = await service.fetchCatalog(
                query: E2EHelpers.makeQuery(sources: [.customFeed]),
                secrets: ApiSecrets(),
                customFeedURL: insecureURL
            )
            #expect(catalogResult.items.isEmpty)
            #expect(catalogResult.errorsBySource[.customFeed] != nil)
        }
    }

    @MainActor
    @Test("T2-F6-04: Toggling DisplayConfig.mode between .mirrorAll and .independent preserves assignments and updates engine")
    func displayModeTogglePreservesAssignments() async throws {
        try await E2EHelpers.withIsolatedWorkspace { tempDir in
            let mp4URL = try E2EHelpers.resolveMediaFixture(extension: "mp4", in: tempDir)
            let jpgURL = try E2EHelpers.resolveMediaFixture(extension: "jpg", in: tempDir)
            let store = E2EHelpers.makeLibraryStore(in: tempDir)

            let w1 = WallpaperItem(id: "m-101", title: "W1", source: .starter, mediaType: .video, localPath: mp4URL)
            let w2 = WallpaperItem(id: "m-202", title: "W2", source: .wallhaven, mediaType: .image, localPath: jpgURL)

            let (engine, desktopCalls) = E2EHelpers.makeObservedWallpaperEngine(
                in: tempDir,
                extractFirstFrameStill: false,
                mockDisplays: [
                    (id: 101, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "Built-in"),
                    (id: 202, frame: NSRect(x: 1920, y: 0, width: 2560, height: 1440), name: "External")
                ]
            )

            var config = DisplayConfig(
                mode: .independent,
                assignments: [
                    "101": DisplayAssignment(displayID: 101, displayName: "Built-in", wallpaper: w1, scalingMode: .fill),
                    "202": DisplayAssignment(displayID: 202, displayName: "External", wallpaper: w2, scalingMode: .fit)
                ]
            )
            #expect(config.assignment(for: 101)?.wallpaper?.id == "m-101")
            #expect(config.assignment(for: 202)?.wallpaper?.id == "m-202")
            #expect(Set(config.activeWallpapers().map(\.id)) == ["m-101", "m-202"])

            engine.apply(config: config)
            #expect(engine.activeVideoDisplayIDs == [101])
            #expect(engine.activeWallpapers[101]?.id == "m-101")
            #expect(engine.activeWallpapers[202]?.id == "m-202")
            #expect(desktopCalls.value.contains { $0.displayID == 202 && $0.imageURL == jpgURL && $0.allowClipping == false })

            config.mode = .mirrorAll
            config.assignments[DisplayConfig.mirrorAssignmentKey] = DisplayAssignment(
                displayID: 0,
                displayName: "Mirror",
                wallpaper: w1,
                scalingMode: .fill
            )
            #expect(config.assignment(for: 101)?.wallpaper?.id == "m-101")
            #expect(config.assignment(for: 202)?.wallpaper?.id == "m-101")
            #expect(config.activeWallpapers().map(\.id) == ["m-101"])

            await store.updateDisplayConfig(config)
            try await store.save()

            let reloaded = LibraryStore(baseDirectory: await store.baseDirectory)
            var loadedState = try await reloaded.load()
            #expect(loadedState.displayConfig.mode == .mirrorAll)
            #expect(loadedState.displayConfig.assignments["101"]?.wallpaper?.id == "m-101")
            #expect(loadedState.displayConfig.assignments["202"]?.wallpaper?.id == "m-202")

            engine.apply(config: loadedState.displayConfig)
            #expect(engine.activeVideoDisplayIDs == [101, 202])
            #expect(engine.activeWallpapers[101]?.id == "m-101")
            #expect(engine.activeWallpapers[202]?.id == "m-101")

            loadedState.displayConfig.mode = .independent
            await reloaded.updateDisplayConfig(loadedState.displayConfig)
            try await reloaded.save()

            let finalState = try await LibraryStore(baseDirectory: await store.baseDirectory).load()
            #expect(finalState.displayConfig.assignment(for: 101)?.wallpaper?.id == "m-101")
            #expect(finalState.displayConfig.assignment(for: 202)?.wallpaper?.id == "m-202")
            #expect(finalState.displayConfig.assignment(for: 202)?.scalingMode == .fit)

            engine.apply(config: finalState.displayConfig)
            #expect(engine.activeVideoDisplayIDs == [101])
            #expect(engine.activeWallpapers[101]?.id == "m-101")
            #expect(engine.activeWallpapers[202]?.id == "m-202")

            engine.teardownAllVideoWindows()
            #expect(engine.activeVideoDisplayIDs.isEmpty)
        }
    }
}
