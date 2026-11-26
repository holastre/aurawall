import Foundation
import Testing
@testable import AuraWallCore

@Suite("CatalogService & Provider HTTP Integration Tests")
struct CatalogServiceTests {

    @Test("ProviderHTTPClient preserves session headers, parses rate limits, and handles HTML/plain-text errors")
    func httpClientHeadersRateLimitAndErrors() async throws {
        let testID = UUID().uuidString
        let sawTestHeader = ProviderLockedBox(false)
        let sawUserAgent = ProviderLockedBox<String?>(nil)

        ProviderMockURLProtocol.register(testID: testID) { request in
            sawTestHeader.withValue {
                $0 = request.value(forHTTPHeaderField: ProviderMockURLProtocol.testIDHeader) == testID
            }
            sawUserAgent.withValue {
                $0 = request.value(forHTTPHeaderField: "User-Agent")
            }

            let path = request.url?.path ?? ""
            if path == "/html500" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=UTF-8"]
                )!
                return (response, Data("<html><body><h1>It broke - wallhaven.cc</h1></body></html>".utf8))
            }

            if path == "/ratelimit429" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Retry-After": "45",
                        "X-RateLimit-Limit": "45",
                        "X-RateLimit-Remaining": "0"
                    ]
                )!
                return (response, Data("API rate limit exceeded".utf8))
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "X-Ratelimit-Limit": "200",
                    "X-Ratelimit-Remaining": "199",
                    "X-Ratelimit-Reset": "3600"
                ]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }
        defer { ProviderMockURLProtocol.unregister(testID: testID) }

        let client = ProviderHTTPClient(urlSession: makeProviderMockSession(testID: testID))

        let okResponse = try await client.get(URL(string: "https://mock.aurawall.local/ok")!, source: .wallhaven)
        #expect(sawTestHeader.value == true)
        #expect(sawUserAgent.value == "AuraWall/1.0")
        #expect(okResponse.rateLimit?.limit == 200)
        #expect(okResponse.rateLimit?.remaining == 199)
        #expect(okResponse.rateLimit?.resetSeconds == 3600)

        do {
            _ = try await client.get(URL(string: "https://mock.aurawall.local/html500")!, source: .wallhaven)
            Issue.record("Expected HTTP 500 error")
        } catch let error as ProviderError {
            guard case .httpError(let statusCode, let snippet) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(statusCode == 500)
            #expect(snippet?.contains("It broke - wallhaven.cc") == true)
        }

        do {
            _ = try await client.get(URL(string: "https://mock.aurawall.local/ratelimit429")!, source: .pixabay)
            Issue.record("Expected HTTP 429 error")
        } catch let error as ProviderError {
            #expect(error == .rateLimited(source: .pixabay, retryAfter: 45, message: "API rate limit exceeded"))
        }

        // probeAvailability falls back from HEAD 405 to Range GET 206
        let probeTestID = UUID().uuidString
        let sawRangeFallback = ProviderLockedBox(false)
        ProviderMockURLProtocol.register(testID: probeTestID) { request in
            if request.httpMethod == "HEAD" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
            if request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Range") == "bytes=0-0" {
                sawRangeFallback.withValue { $0 = true }
                let resp = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data([0x00]))
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }
        defer { ProviderMockURLProtocol.unregister(testID: probeTestID) }

        let probeClient = ProviderHTTPClient(urlSession: makeProviderMockSession(testID: probeTestID))
        let available = try await probeClient.probeAvailability(URL(string: "https://mock.aurawall.local/video.mov")!)
        #expect(available == true)
        #expect(sawRangeFallback.value == true)
    }

    @Test("StarterVideoProvider prefers resources-16.tar, filters 2x 404s, and falls back to curated HTTPS")
    func starterResilienceCascade() async throws {
        // 1. Primary resources-16.tar success
        let tarTestID = UUID().uuidString
        let r16Data = try loadProviderFixture("aerial_r16_entries.json")
        let tarBytes = buildSyntheticTarArchive(entries: [
            (name: "entries.json", prefix: "", typeflag: 0x30, content: r16Data)
        ])

        ProviderMockURLProtocol.register(testID: tarTestID) { request in
            if request.url?.path == "/Aerials/resources-16.tar" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, tarBytes)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }
        defer { ProviderMockURLProtocol.unregister(testID: tarTestID) }

        let tarProvider = StarterVideoProvider(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: tarTestID))
        )
        let tarResult = try await tarProvider.fetch(
            query: WallpaperQuery(mediaType: .video, sources: [.starter]),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )
        #expect(tarResult.errorMessage == nil)
        #expect(tarResult.items.count == 4)
        #expect(tarResult.items.allSatisfy { $0.source == .starter })

        // 2. Fallback to 2x/entries.json: 12/13 return 404, 1 returns 200, merged with curated 10
        let fallback2xTestID = UUID().uuidString
        let entries2xData = try loadProviderFixture("aerial_2x_entries.json")

        ProviderMockURLProtocol.register(testID: fallback2xTestID) { request in
            let path = request.url?.path ?? ""
            if path == "/Aerials/resources-16.tar" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
            if path == "/Aerials/2x/entries.json" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, entries2xData)
            }
            if path.contains("HK_H004_C013_4K_SDR_HEVC.mov") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data(#"{"httpStatusCode":404}"#.utf8))
        }
        defer { ProviderMockURLProtocol.unregister(testID: fallback2xTestID) }

        let fallbackProvider = StarterVideoProvider(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: fallback2xTestID))
        )
        let mergedResult = try await fallbackProvider.fetch(
            query: WallpaperQuery(mediaType: .video, sources: [.starter]),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )
        #expect(mergedResult.errorMessage == nil)
        #expect(mergedResult.items.count == 11) // 1 surviving HK item + 10 curated fallback items
        #expect(mergedResult.items.allSatisfy { !($0.fullAssetURL?.path.contains("/missing/") ?? true) })

        // 3. Complete offline error still yields 10 curated fallback videos with errorMessage == nil
        let offlineTestID = UUID().uuidString
        ProviderMockURLProtocol.register(testID: offlineTestID) { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { ProviderMockURLProtocol.unregister(testID: offlineTestID) }

        let offlineProvider = StarterVideoProvider(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: offlineTestID))
        )
        let offlineResult = try await offlineProvider.fetch(
            query: WallpaperQuery(mediaType: .video, sources: [.starter]),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )
        #expect(offlineResult.errorMessage == nil)
        #expect(offlineResult.items.count == 10)
    }

    @Test("WallhavenProvider normalizes page <= 0, sends SFW & API key headers, and handles 401/500")
    func wallhavenProviderIntegration() async throws {
        let testID = UUID().uuidString
        let capturedQuery = ProviderLockedBox<String?>(nil)
        let capturedKeyHeader = ProviderLockedBox<String?>(nil)
        let stringFixture = try loadProviderFixture("wallhaven_search_string_query.json")

        ProviderMockURLProtocol.register(testID: testID) { request in
            capturedQuery.withValue { $0 = request.url?.query }
            capturedKeyHeader.withValue { $0 = request.value(forHTTPHeaderField: "X-API-Key") }

            if request.value(forHTTPHeaderField: "X-API-Key") == "bad-key" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data(#"{"error":"Unauthorized"}"#.utf8))
            }

            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["x-ratelimit-limit": "45", "x-ratelimit-remaining": "44"]
            )!
            return (resp, stringFixture)
        }
        defer { ProviderMockURLProtocol.unregister(testID: testID) }

        let provider = WallhavenProvider(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: testID))
        )

        let result = try await provider.fetch(
            query: WallpaperQuery(
                text: "landscape",
                mediaType: .image,
                sources: [.wallhaven],
                minResolution: "4K",
                aspectRatio: "16:9",
                sorting: .trending,
                page: -1
            ),
            secrets: ApiSecrets(wallhavenAPIKey: "wh-test-key"),
            customFeedURL: nil
        )

        #expect(result.items.count == 2)
        #expect(result.hasNextPage == true)
        #expect(result.rateLimit?.limit == 45)
        #expect(capturedKeyHeader.value == "wh-test-key")
        let queryString = try #require(capturedQuery.value)
        #expect(queryString.contains("page=1"))
        #expect(queryString.contains("purity=100"))
        #expect(queryString.contains("atleast=3840x2160"))
        #expect(queryString.contains("ratios=16x9"))

        // Short-circuits on .video without network
        let videoShortCircuit = try await provider.fetch(
            query: WallpaperQuery(mediaType: .video, sources: [.wallhaven]),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )
        #expect(videoShortCircuit.items.isEmpty)

        // 401 JSON handling
        await #expect(throws: ProviderError.unauthorized(source: .wallhaven, message: "Unauthorized")) {
            _ = try await provider.fetch(
                query: WallpaperQuery(sources: [.wallhaven]),
                secrets: ApiSecrets(wallhavenAPIKey: "bad-key"),
                customFeedURL: nil
            )
        }
    }

    @Test("PexelsProvider enforces API key, sends raw Authorization without Bearer, and aggregates videos+photos")
    func pexelsProviderIntegration() async throws {
        let testID = UUID().uuidString
        let capturedAuth = ProviderLockedBox<String?>(nil)
        let videosFixture = try loadProviderFixture("pexels_videos_search.json")
        let photosFixture = try loadProviderFixture("pexels_photos_curated.json")

        ProviderMockURLProtocol.register(testID: testID) { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            capturedAuth.withValue { $0 = auth }

            if auth != "valid-pexels-key" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data(#"{"status":401,"code":"Unauthorized","message":"Missing API key"}"#.utf8))
            }

            let path = request.url?.path ?? ""
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            if path.contains("/videos/") {
                return (resp, videosFixture)
            }
            return (resp, photosFixture)
        }
        defer { ProviderMockURLProtocol.unregister(testID: testID) }

        let provider = PexelsProvider(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: testID))
        )

        await #expect(throws: ProviderError.missingAPIKey(.pexels)) {
            _ = try await provider.fetch(
                query: WallpaperQuery(sources: [.pexels]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
        }

        let result = try await provider.fetch(
            query: WallpaperQuery(text: "waves", mediaType: .all, sources: [.pexels]),
            secrets: ApiSecrets(pexelsAPIKey: "valid-pexels-key"),
            customFeedURL: nil
        )
        #expect(capturedAuth.value == "valid-pexels-key")
        #expect(capturedAuth.value?.hasPrefix("Bearer ") == false)
        #expect(result.items.count == 3)
        #expect(result.items.contains(where: { $0.mediaType == .video }))
        #expect(result.items.contains(where: { $0.mediaType == .image }))
        #expect(result.hasNextPage == true)
    }

    @Test("PixabayProvider sends key & safesearch=true and maps plain-text 400/429 errors")
    func pixabayProviderIntegration() async throws {
        let testID = UUID().uuidString
        let capturedQueries = ProviderLockedBox<[String]>([])
        let videosFixture = try loadProviderFixture("pixabay_videos.json")
        let photosFixture = try loadProviderFixture("pixabay_photos.json")

        ProviderMockURLProtocol.register(testID: testID) { request in
            let q = request.url?.query ?? ""
            capturedQueries.withValue { $0.append(q) }

            if q.contains("key=bad-pb-key") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (resp, Data("[ERROR 400] Invalid or missing API key (https://pixabay.com/api/docs/).".utf8))
            }

            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            if request.url?.path.contains("/videos") == true {
                return (resp, videosFixture)
            }
            return (resp, photosFixture)
        }
        defer { ProviderMockURLProtocol.unregister(testID: testID) }

        let provider = PixabayProvider(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: testID))
        )

        await #expect(throws: ProviderError.missingAPIKey(.pixabay)) {
            _ = try await provider.fetch(
                query: WallpaperQuery(sources: [.pixabay]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
        }

        let result = try await provider.fetch(
            query: WallpaperQuery(text: "nature", mediaType: .all, sources: [.pixabay]),
            secrets: ApiSecrets(pixabayAPIKey: "valid-pb-key"),
            customFeedURL: nil
        )
        #expect(result.items.count == 4)
        #expect(capturedQueries.value.allSatisfy { $0.contains("key=valid-pb-key") && $0.contains("safesearch=true") })

        do {
            _ = try await provider.fetch(
                query: WallpaperQuery(mediaType: .video, sources: [.pixabay]),
                secrets: ApiSecrets(pixabayAPIKey: "bad-pb-key"),
                customFeedURL: nil
            )
            Issue.record("Expected unauthorized error for invalid Pixabay key")
        } catch let error as ProviderError {
            guard case .unauthorized(let source, let message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(source == .pixabay)
            #expect(message?.contains("Invalid or missing API key") == true)
        }
    }

    @Test("CatalogService aggregates concurrently, isolates provider errors, and enforces gating rules")
    func catalogServiceAggregationAndIsolation() async throws {
        let testID = UUID().uuidString
        let customWrapped = try loadProviderFixture("custom_feed_wrapped.json")
        let wallhavenData = try loadProviderFixture("wallhaven_search_string_query.json")
        let r16Data = try loadProviderFixture("aerial_r16_entries.json")
        let tarBytes = buildSyntheticTarArchive(entries: [
            (name: "entries.json", prefix: "", typeflag: 0x30, content: r16Data)
        ])

        ProviderMockURLProtocol.register(testID: testID) { request in
            let host = request.url?.host ?? ""
            let path = request.url?.path ?? ""

            if host == "sylvan.apple.com" && path == "/Aerials/resources-16.tar" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, tarBytes)
            }
            if host == "wallhaven.cc" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, wallhavenData)
            }
            if path == "/good-feed.json" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, customWrapped)
            }
            if path == "/broken-feed.html" {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!, Data("<html>500</html>".utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        defer { ProviderMockURLProtocol.unregister(testID: testID) }

        let client = ProviderHTTPClient(urlSession: makeProviderMockSession(testID: testID))
        let service = CatalogService(httpClient: client)

        // 1. Multi-source with missing Pexels/Pixabay keys skips them cleanly without error, while broken customFeed isolates error
        let brokenCustomResult = await service.fetchCatalog(
            query: WallpaperQuery(mediaType: .all, sources: Set(WallpaperSource.allCases)),
            secrets: ApiSecrets(),
            customFeedURL: URL(string: "http://127.0.0.1:9999/broken-feed.html")!
        )

        #expect(brokenCustomResult.items.contains(where: { $0.source == .starter }))
        #expect(brokenCustomResult.items.contains(where: { $0.source == .wallhaven }))
        #expect(brokenCustomResult.errorsBySource[.customFeed] != nil)
        #expect(brokenCustomResult.errorsBySource[.pexels] == nil)
        #expect(brokenCustomResult.errorsBySource[.pixabay] == nil)
        #expect(brokenCustomResult.hasNextPage == true)

        // 2. Single-source missing API key reports missingAPIKey error
        let singlePexels = await service.fetchCatalog(
            query: WallpaperQuery(sources: [.pexels]),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )
        #expect(singlePexels.items.isEmpty)
        #expect(singlePexels.errorsBySource[.pexels] == ProviderError.missingAPIKey(.pexels).localizedDescription)

        // 3. mediaType == .video skips .wallhaven; mediaType == .image skips .starter
        let videoOnly = await service.fetchCatalog(
            query: WallpaperQuery(mediaType: .video, sources: [.starter, .wallhaven]),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )
        #expect(videoOnly.providerResults.map(\.source) == [.starter])
        #expect(videoOnly.items.allSatisfy { $0.mediaType == .video })

        let imageOnly = await service.fetchCatalog(
            query: WallpaperQuery(mediaType: .image, sources: [.starter, .wallhaven]),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )
        #expect(imageOnly.providerResults.map(\.source) == [.wallhaven])
        #expect(imageOnly.items.allSatisfy { $0.mediaType == .image })

        // 4. Healthy loopback custom feed filters by tag ("ocean") cleanly
        let tagFiltered = await service.fetchCatalog(
            query: WallpaperQuery(text: "ocean", sources: [.customFeed]),
            secrets: ApiSecrets(),
            customFeedURL: URL(string: "http://127.0.0.1:9999/good-feed.json")!
        )
        #expect(tagFiltered.items.count == 1)
        #expect(tagFiltered.items[0].title == "Pacific Dawn")

        // 5. Disallowed non-loopback HTTP custom feed URL produces errorMessage via isolation
        let insecureCustom = await service.fetchCatalog(
            query: WallpaperQuery(sources: [.customFeed]),
            secrets: ApiSecrets(),
            customFeedURL: URL(string: "http://insecure.example.com/feed.json")!
        )
        #expect(insecureCustom.items.isEmpty)
        #expect(insecureCustom.errorsBySource[.customFeed] != nil)
    }

    @Test("Unix-epoch X-RateLimit-Reset converts to relative delta seconds on 429 and parseRateLimit")
    func unixEpochRateLimitResetHandling() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_795_649_880)
        let parsedFuture = ProviderHTTPClient.parseRateLimit(
            headers: ["x-ratelimit-reset": "1795650000"],
            now: fixedNow
        )
        #expect(parsedFuture?.resetSeconds == 120)

        let parsedPast = ProviderHTTPClient.parseRateLimit(
            headers: ["x-ratelimit-reset": "1795649000"],
            now: fixedNow
        )
        #expect(parsedPast?.resetSeconds == 0)

        let testID = UUID().uuidString
        let futureEpoch = Int(Date().timeIntervalSince1970) + 120
        ProviderMockURLProtocol.register(testID: testID) { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "X-Ratelimit-Limit": "200",
                    "X-Ratelimit-Remaining": "0",
                    "X-Ratelimit-Reset": "\(futureEpoch)"
                ]
            )!
            return (resp, Data("Too many requests".utf8))
        }
        defer { ProviderMockURLProtocol.unregister(testID: testID) }

        let client = ProviderHTTPClient(urlSession: makeProviderMockSession(testID: testID))
        do {
            _ = try await client.get(URL(string: "https://mock.aurawall.local/pexels-429")!, source: .pexels)
            Issue.record("Expected rateLimited error")
        } catch let error as ProviderError {
            guard case .rateLimited(let source, let retryAfter, let message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(source == .pexels)
            #expect(message == "Too many requests")
            let seconds = try #require(retryAfter)
            #expect(seconds >= 0 && seconds <= 125)
        }
    }

    @Test("PixabayProvider surfaces non-auth 400 parameter errors as httpError instead of unauthorized")
    func pixabayNonAuth400ErrorSurfacesAsHTTPError() async throws {
        let testID = UUID().uuidString
        let capturedPaths = ProviderLockedBox<[String]>([])
        ProviderMockURLProtocol.register(testID: testID) { request in
            if let url = request.url,
               let comp = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                capturedPaths.withValue { $0.append(comp.path) }
            }
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (resp, Data(#"[ERROR 400] Invalid value for "per_page""#.utf8))
        }
        defer { ProviderMockURLProtocol.unregister(testID: testID) }

        let provider = PixabayProvider(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: testID))
        )

        do {
            _ = try await provider.fetch(
                query: WallpaperQuery(mediaType: .image, sources: [.pixabay]),
                secrets: ApiSecrets(pixabayAPIKey: "valid-key"),
                customFeedURL: nil
            )
            Issue.record("Expected HTTP 400 error")
        } catch let error as ProviderError {
            guard case .httpError(let statusCode, let snippet) = error else {
                Issue.record("Expected .httpError(400), got: \(error)")
                return
            }
            #expect(statusCode == 400)
            #expect(snippet?.contains(#"Invalid value for "per_page""#) == true)
        }
        #expect(capturedPaths.value == ["/api/"])
    }

    @Test("StarterVideoProvider and probeAvailability propagate CancellationError instead of falling back")
    func cancellationErrorPropagation() async throws {
        let starterTestID = UUID().uuidString
        let startedStream = AsyncStream<Void>.makeStream()
        let saw2xFallbackRequest = ProviderLockedBox(false)
        ProviderMockURLProtocol.registerAsync(testID: starterTestID) { request, _ in
            if request.url?.path.contains("2x/entries.json") == true {
                saw2xFallbackRequest.withValue { $0 = true }
            }
            startedStream.continuation.yield()
            // Leave request pending without blocking CFNetwork's CustomProtocols queue;
            // Task.cancel() cancels URLSession immediately.
        }
        defer { ProviderMockURLProtocol.unregister(testID: starterTestID) }

        let starterProvider = StarterVideoProvider(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: starterTestID))
        )
        let starterTask = Task {
            try await starterProvider.fetch(
                query: WallpaperQuery(mediaType: .video, sources: [.starter]),
                secrets: ApiSecrets(),
                customFeedURL: nil
            )
        }
        var iterator = startedStream.stream.makeAsyncIterator()
        _ = await iterator.next()
        starterTask.cancel()

        do {
            let unexpected = try await starterTask.value
            Issue.record("Expected CancellationError, got \(unexpected.items.count) items")
        } catch is CancellationError {
            // Expected
        }
        #expect(saw2xFallbackRequest.value == false)

        // Also verify ProviderHTTPClient.probeAvailability propagates CancellationError
        let probeTestID = UUID().uuidString
        let probeStarted = AsyncStream<Void>.makeStream()
        let sawRangeAfterCancel = ProviderLockedBox(false)
        ProviderMockURLProtocol.registerAsync(testID: probeTestID) { request, _ in
            if request.httpMethod == "GET" {
                sawRangeAfterCancel.withValue { $0 = true }
            }
            probeStarted.continuation.yield()
        }
        defer { ProviderMockURLProtocol.unregister(testID: probeTestID) }

        let probeClient = ProviderHTTPClient(urlSession: makeProviderMockSession(testID: probeTestID))
        let probeTask = Task {
            try await probeClient.probeAvailability(URL(string: "https://mock.aurawall.local/slow.mov")!)
        }
        var probeIterator = probeStarted.stream.makeAsyncIterator()
        _ = await probeIterator.next()
        probeTask.cancel()

        do {
            let result = try await probeTask.value
            Issue.record("Expected CancellationError from probeAvailability, got \(result)")
        } catch is CancellationError {
            // Expected
        }
        #expect(sawRangeAfterCancel.value == false)
    }

    @Test("Non-finite and overflowing rate-limit headers are rejected cleanly without crashing")
    func nonFiniteAndOverflowingRateLimitHeaders() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_795_649_880)

        for badValue in ["Infinity", "-Infinity", "inf", "NaN", "1e25", "-5", "9223372036854775808"] {
            let resetOnly = ProviderHTTPClient.parseRateLimit(
                headers: ["x-ratelimit-reset": badValue],
                now: fixedNow
            )
            #expect(resetOnly == nil)

            let retryOnly = ProviderHTTPClient.parseRateLimit(
                headers: ["retry-after": badValue],
                now: fixedNow
            )
            #expect(retryOnly == nil)
        }

        // Valid siblings remain preserved when a non-finite/overflowing header is ignored
        let partial = ProviderHTTPClient.parseRateLimit(
            headers: [
                "x-ratelimit-limit": "100",
                "x-ratelimit-reset": "Infinity",
                "retry-after": "1e25"
            ],
            now: fixedNow
        )
        #expect(partial?.limit == 100)
        #expect(partial?.resetSeconds == nil)
        #expect(partial?.retryAfterSeconds == nil)

        // Direct ProviderError.rateLimited localizedDescription never traps on non-finite/out-of-range values
        #expect(
            ProviderError.rateLimited(source: .pexels, retryAfter: .infinity, message: "Slow down").localizedDescription
                == "Pexels rate limit exceeded: Slow down"
        )
        #expect(
            ProviderError.rateLimited(source: .pexels, retryAfter: -.infinity, message: nil).localizedDescription
                == "Pexels rate limit exceeded."
        )
        #expect(
            ProviderError.rateLimited(source: .pexels, retryAfter: .nan, message: "").localizedDescription
                == "Pexels rate limit exceeded."
        )
        #expect(
            ProviderError.rateLimited(source: .pexels, retryAfter: 1e25, message: nil).localizedDescription
                == "Pexels rate limit exceeded."
        )
        #expect(
            ProviderError.rateLimited(source: .pexels, retryAfter: Double(Int.max), message: nil).localizedDescription
                == "Pexels rate limit exceeded."
        )
        #expect(
            ProviderError.rateLimited(source: .pexels, retryAfter: -1, message: nil).localizedDescription
                == "Pexels rate limit exceeded."
        )
        #expect(
            ProviderError.rateLimited(source: .pexels, retryAfter: -0.0, message: nil).localizedDescription
                == "Pexels rate limit exceeded (retry after 0s)."
        )
        #expect(
            ProviderError.rateLimited(source: .pexels, retryAfter: 12.1, message: nil).localizedDescription
                == "Pexels rate limit exceeded (retry after 13s)."
        )

        // End-to-end CatalogService.fetchCatalog against HTTP 429 responses with hostile headers
        let testID = UUID().uuidString
        ProviderMockURLProtocol.register(testID: testID) { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/inf-reset":
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["X-RateLimit-Reset": "Infinity"]
                )!
                return (resp, Data("Slow down".utf8))
            case "/huge-retry":
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Retry-After": "1e25"]
                )!
                return (resp, Data())
            case "/nan-retry":
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Retry-After": "NaN"]
                )!
                return (resp, Data())
            default:
                let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
        }
        defer { ProviderMockURLProtocol.unregister(testID: testID) }

        let service = CatalogService(
            httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: testID))
        )

        let infResult = await service.fetchCatalog(
            query: WallpaperQuery(sources: [.customFeed]),
            secrets: ApiSecrets(),
            customFeedURL: URL(string: "http://127.0.0.1:9999/inf-reset")!
        )
        #expect(infResult.items.isEmpty)
        #expect(infResult.errorsBySource[.customFeed] == "Custom Feed rate limit exceeded: Slow down")

        let hugeResult = await service.fetchCatalog(
            query: WallpaperQuery(sources: [.customFeed]),
            secrets: ApiSecrets(),
            customFeedURL: URL(string: "http://127.0.0.1:9999/huge-retry")!
        )
        #expect(hugeResult.items.isEmpty)
        #expect(hugeResult.errorsBySource[.customFeed] == "Custom Feed rate limit exceeded.")

        let nanResult = await service.fetchCatalog(
            query: WallpaperQuery(sources: [.customFeed]),
            secrets: ApiSecrets(),
            customFeedURL: URL(string: "http://127.0.0.1:9999/nan-retry")!
        )
        #expect(nanResult.items.isEmpty)
        #expect(nanResult.errorsBySource[.customFeed] == "Custom Feed rate limit exceeded.")
    }
}

// MARK: - Opt-In Live Smoke Tests

@Suite(
    "Live Smoke Tests",
    .enabled(if: ProcessInfo.processInfo.environment["AURAWALL_RUN_LIVE_SMOKE"] == "1")
)
struct LiveSmokeTests {

    @Test("Live StarterVideoProvider returns playable HTTPS video URLs")
    func liveStarterVideoSmoke() async throws {
        let provider = StarterVideoProvider()
        let result = try await provider.fetch(
            query: WallpaperQuery(mediaType: .video, sources: [.starter]),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )

        #expect(result.errorMessage == nil)
        #expect(result.items.count >= 10)
        #expect(result.items.allSatisfy { $0.mediaType == .video })
        #expect(result.items.allSatisfy { $0.fullAssetURL?.scheme?.lowercased() == "https" })

        let firstURL = try #require(result.items.first?.fullAssetURL)
        var req = URLRequest(url: firstURL, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("bytes=0-511", forHTTPHeaderField: "Range")
        req.setValue(ProviderHTTPClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200 || http.statusCode == 206)
        #expect(!data.isEmpty)
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        #expect(contentType.contains("video/") || contentType.contains("octet-stream"))
    }

    @Test("Live WallhavenProvider SFW returns valid playable HTTPS image URLs")
    func liveWallhavenSFWSmoke() async throws {
        let provider = WallhavenProvider()
        let result = try await provider.fetch(
            query: WallpaperQuery(text: "landscape", mediaType: .image, sources: [.wallhaven], sorting: .top, page: 1),
            secrets: ApiSecrets(),
            customFeedURL: nil
        )

        #expect(result.errorMessage == nil)
        #expect(!result.items.isEmpty)
        #expect(result.items.allSatisfy { $0.mediaType == .image })
        #expect(result.items.allSatisfy { $0.fullAssetURL?.scheme?.lowercased() == "https" })

        let firstURL = try #require(result.items.first?.fullAssetURL)
        var req = URLRequest(url: firstURL, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("bytes=0-511", forHTTPHeaderField: "Range")
        req.setValue(ProviderHTTPClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200 || http.statusCode == 206)
        #expect(!data.isEmpty)
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        #expect(contentType.contains("image/"))
    }
}
