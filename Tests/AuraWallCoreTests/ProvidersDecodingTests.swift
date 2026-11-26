import Foundation
import os
import Testing
@testable import AuraWallCore

// MARK: - Parallel-Safe MockURLProtocol & Fixture Helpers

final class ProviderMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    typealias AsyncHandler = @Sendable (URLRequest, @escaping @Sendable (Result<(HTTPURLResponse, Data), Error>) -> Void) -> Void

    private enum RegisteredHandler: Sendable {
        case sync(Handler)
        case async(AsyncHandler)
    }

    static let testIDHeader = "X-AuraWall-ProviderTest-ID"
    private static let handlers = OSAllocatedUnfairLock<[String: RegisteredHandler]>(initialState: [:])

    static func register(testID: String, handler: @escaping Handler) {
        handlers.withLock { $0[testID] = .sync(handler) }
    }

    static func registerAsync(testID: String, handler: @escaping AsyncHandler) {
        handlers.withLock { $0[testID] = .async(handler) }
    }

    static func unregister(testID: String) {
        _ = handlers.withLock { $0.removeValue(forKey: testID) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: testIDHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let testID = request.value(forHTTPHeaderField: Self.testIDHeader),
              let registered = Self.handlers.withLock({ $0[testID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch registered {
        case .sync(let handler):
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        case .async(let handler):
            let protocolInstance = self
            handler(request) { outcome in
                switch outcome {
                case .success(let (response, data)):
                    protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                    if !data.isEmpty {
                        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: data)
                    }
                    protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
                case .failure(let error):
                    protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: error)
                }
            }
        }
    }

    override func stopLoading() {}
}

final class ProviderLockedBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ initial: Value) {
        self.lock = OSAllocatedUnfairLock(initialState: initial)
    }

    func withValue<T: Sendable>(_ body: @Sendable (inout Value) -> T) -> T {
        lock.withLock(body)
    }

    var value: Value {
        lock.withLock { $0 }
    }
}

func makeProviderMockSession(testID: String) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpAdditionalHeaders = [ProviderMockURLProtocol.testIDHeader: testID]
    config.protocolClasses = [ProviderMockURLProtocol.self]
    return URLSession(configuration: config)
}

func loadProviderFixture(_ filename: String) throws -> Data {
    let nsName = filename as NSString
    let name = nsName.deletingPathExtension
    let ext = nsName.pathExtension.isEmpty ? "json" : nsName.pathExtension
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
        "Missing test fixture \(filename) in Bundle.module/Fixtures"
    )
    return try Data(contentsOf: url)
}

// MARK: - Synthetic POSIX Tar Builder for Tests

func buildSyntheticTarArchive(
    entries: [(name: String, prefix: String, typeflag: UInt8, content: Data)],
    includeTrailingZeroBlocks: Bool = true
) -> Data {
    var archive = Data()

    for entry in entries {
        var header = [UInt8](repeating: 0, count: 512)
        let nameBytes = Array(entry.name.utf8.prefix(100))
        for (i, b) in nameBytes.enumerated() {
            header[i] = b
        }

        let modeBytes = Array("0000644\0".utf8)
        for (i, b) in modeBytes.enumerated() {
            header[100 + i] = b
        }

        let sizeOctal = String(format: "%011o", entry.content.count) + " "
        let sizeBytes = Array(sizeOctal.utf8.prefix(12))
        for (i, b) in sizeBytes.enumerated() {
            header[124 + i] = b
        }

        let mtimeBytes = Array("14500000000 ".utf8)
        for (i, b) in mtimeBytes.enumerated() {
            header[136 + i] = b
        }

        for i in 148..<156 {
            header[i] = 0x20
        }

        header[156] = entry.typeflag

        let ustarMagic = Array("ustar\0".utf8)
        for (i, b) in ustarMagic.enumerated() {
            header[257 + i] = b
        }
        header[263] = 0x30
        header[264] = 0x30

        let prefixBytes = Array(entry.prefix.utf8.prefix(155))
        for (i, b) in prefixBytes.enumerated() {
            header[345 + i] = b
        }

        let sum = header.reduce(0) { $0 + Int($1) }
        let checksumOctal = String(format: "%06o\0 ", sum)
        let checksumBytes = Array(checksumOctal.utf8.prefix(8))
        for (i, b) in checksumBytes.enumerated() {
            header[148 + i] = b
        }

        archive.append(contentsOf: header)
        archive.append(entry.content)

        let remainder = entry.content.count % 512
        if remainder != 0 {
            archive.append(Data(repeating: 0, count: 512 - remainder))
        }
    }

    if includeTrailingZeroBlocks {
        archive.append(Data(repeating: 0, count: 1024))
    }
    return archive
}

// MARK: - Decoding & Parser Tests

@Suite("Providers Decoding Tests")
struct ProvidersDecodingTests {

    @Test("Apple Aerials 2x entries.json decodes all 13 items with optional fields omitted")
    func aerial2xEntriesDecoding() throws {
        let data = try loadProviderFixture("aerial_2x_entries.json")
        let items = try StarterVideoProvider.parseAerialCatalog(data: data)

        #expect(items.count == 13)
        #expect(items.allSatisfy { $0.source == .starter })
        #expect(items.allSatisfy { $0.mediaType == .video })
        #expect(items.allSatisfy { $0.width == 3840 && $0.height == 2160 })

        let hk = try #require(items.last)
        #expect(hk.title == "Hong Kong Harbor")
        #expect(hk.category == "Aerial")
        #expect(hk.fullAssetURL?.lastPathComponent == "HK_H004_C013_4K_SDR_HEVC.mov")
        #expect(hk.previewVideoURL?.lastPathComponent == "HK_H004_C013_2K_SDR_HEVC.mov")
    }

    @Test("Apple Aerials resources-16 entries.json decodes categories, optional group, and 4K/2K variants")
    func aerialR16EntriesDecoding() throws {
        let data = try loadProviderFixture("aerial_r16_entries.json")
        let items = try StarterVideoProvider.parseAerialCatalog(data: data)

        #expect(items.count == 4)
        let seals = try #require(items.first(where: { $0.title == "Seals Underwater" }))
        #expect(seals.category == "Underwater")
        #expect(seals.width == 3840 && seals.height == 2160)
        #expect(seals.fullAssetURL?.lastPathComponent == "SE_A016_C009_4K_SDR.mov")
        #expect(seals.previewVideoURL?.lastPathComponent == "SE_A016_C009_2K_SDR.mov")
        #expect(seals.previewImageURL?.lastPathComponent == "SE_A016_C009_asset.jpg")
        #expect(seals.tags.contains("SE_A016_C009"))

        let orbit = try #require(items.first(where: { $0.title == "Caribbean Day Orbit" }))
        #expect(orbit.category == "Space")
        // Falls back to category previewImage when asset previewImage is omitted
        #expect(orbit.previewImageURL?.lastPathComponent == "space.jpg")
    }

    @Test("Apple Aerials legacy batch array format decodes cleanly")
    func aerialLegacyArrayDecoding() throws {
        let data = try loadProviderFixture("aerial_phobos_array.json")
        let items = try StarterVideoProvider.parseAerialCatalog(data: data)

        #expect(items.count == 3)
        #expect(items[0].id == "legacy-b1-1")
        #expect(items[0].title == "Hawaii Coast Day")
        #expect(items[0].category == "Day")
        #expect(items[1].category == "Night")
        #expect(items[2].fullAssetURL?.scheme == "https")
    }

    @Test("Curated fallback video list has 10 valid HTTPS .mov/.mp4 entries")
    func curatedFallbackVideosValidity() {
        let items = StarterVideoProvider.curatedFallbackVideos
        #expect(items.count == 10)
        for item in items {
            #expect(item.source == .starter)
            #expect(item.mediaType == .video)
            #expect(!item.title.isEmpty)
            #expect(item.fullAssetURL?.scheme == "https")
            let ext = item.fullAssetURL?.pathExtension.lowercased() ?? ""
            #expect(ext == "mov" || ext == "mp4")
        }
    }

    @Test("PosixTarExtractor extracts entries.json across standard, ./ prefix, UStar prefix, and PAX headers")
    func posixTarExtractorSuccessAndErrors() throws {
        let r16Data = try loadProviderFixture("aerial_r16_entries.json")

        // 1. Standard entry + ./ prefix normalization
        let tar1 = buildSyntheticTarArchive(entries: [
            (name: "README.txt", prefix: "", typeflag: 0x30, content: Data("hello".utf8)),
            (name: "./entries.json", prefix: "", typeflag: 0x30, content: r16Data)
        ])
        let extracted1 = try PosixTarExtractor.extractFile(named: "entries.json", from: tar1)
        #expect(extracted1 == r16Data)

        // 2. PAX 'x' extended header overriding path & size
        let paxLine = "path=entries.json\n"
        let totalLen = "\(paxLine.utf8.count)".count + 1 + paxLine.utf8.count
        let paxRecord = "\(totalLen) \(paxLine)"
        let fixedPaxContent = Data(paxRecord.utf8)

        let tar2 = buildSyntheticTarArchive(entries: [
            (name: "ignored-short-name", prefix: "", typeflag: 0x78, content: fixedPaxContent),
            (name: "placeholder.json", prefix: "", typeflag: 0x30, content: r16Data)
        ])
        let extracted2 = try PosixTarExtractor.extractFile(named: "entries.json", from: tar2)
        #expect(extracted2 == r16Data)

        // 2b. UStar prefix + GNU 'L' long filename
        let tar2b = buildSyntheticTarArchive(entries: [
            (name: "entries.json", prefix: ".", typeflag: 0x30, content: r16Data)
        ])
        #expect(try PosixTarExtractor.extractFile(named: "entries.json", from: tar2b) == r16Data)

        let tar2c = buildSyntheticTarArchive(entries: [
            (name: "short", prefix: "", typeflag: 0x4C, content: Data("entries.json\0".utf8)),
            (name: "wrong.txt", prefix: "", typeflag: 0x30, content: r16Data)
        ])
        #expect(try PosixTarExtractor.extractFile(named: "entries.json", from: tar2c) == r16Data)

        // 2d. PAX 'x' (size override) followed by GNU 'L' (long name) followed by regular file with header size 0
        let paxSizeLine = "size=\(r16Data.count)\n"
        let paxSizeInitialLen = "\(paxSizeLine.utf8.count)".count + 1 + paxSizeLine.utf8.count
        let paxSizeTotalLen = "\(paxSizeInitialLen)".count + 1 + paxSizeLine.utf8.count
        let paxSizeRecord = Data("\(paxSizeTotalLen) \(paxSizeLine)".utf8)

        let zeroSizeFileArchive = buildSyntheticTarArchive(entries: [
            (name: "pax-size", prefix: "", typeflag: 0x78, content: paxSizeRecord),
            (name: "gnu-long", prefix: "", typeflag: 0x4C, content: Data("entries.json\0".utf8))
        ], includeTrailingZeroBlocks: false)

        // Append regular file header with size=0 (must use pendingPAXSize, while 'L' used its own headerSize)
        var regularHeader = [UInt8](repeating: 0, count: 512)
        for (i, b) in Array("placeholder.txt".utf8).enumerated() { regularHeader[i] = b }
        for (i, b) in Array("0000644\0".utf8).enumerated() { regularHeader[100 + i] = b }
        for (i, b) in Array("00000000000 ".utf8).enumerated() { regularHeader[124 + i] = b }
        for (i, b) in Array("14500000000 ".utf8).enumerated() { regularHeader[136 + i] = b }
        for i in 148..<156 { regularHeader[i] = 0x20 }
        regularHeader[156] = 0x30
        let sum = regularHeader.reduce(0) { $0 + Int($1) }
        for (i, b) in Array(String(format: "%06o\0 ", sum).utf8.prefix(8)).enumerated() { regularHeader[148 + i] = b }

        var paxAndGnuTar = zeroSizeFileArchive
        paxAndGnuTar.append(contentsOf: regularHeader)
        paxAndGnuTar.append(r16Data)
        let rem = r16Data.count % 512
        if rem != 0 {
            paxAndGnuTar.append(Data(repeating: 0, count: 512 - rem))
        }
        paxAndGnuTar.append(Data(repeating: 0, count: 1024))

        #expect(try PosixTarExtractor.extractFile(named: "entries.json", from: paxAndGnuTar) == r16Data)

        // 3. Invalid checksum throws invalidChecksum
        var corruptChecksumTar = tar1
        corruptChecksumTar[148] = UInt8(ascii: "9")
        #expect(throws: TarExtractionError.invalidChecksum) {
            _ = try PosixTarExtractor.extractFile(named: "entries.json", from: corruptChecksumTar)
        }

        // 4. Truncated payload throws truncatedArchive
        let truncatedTar = Data(tar1.prefix(600))
        #expect(throws: TarExtractionError.truncatedArchive) {
            _ = try PosixTarExtractor.extractFile(named: "entries.json", from: truncatedTar)
        }

        // 5. Missing file throws fileNotFound
        let tarNoEntries = buildSyntheticTarArchive(entries: [
            (name: "other.json", prefix: "", typeflag: 0x30, content: Data("{}".utf8))
        ])
        #expect(throws: TarExtractionError.fileNotFound("entries.json")) {
            _ = try PosixTarExtractor.extractFile(named: "entries.json", from: tarNoEntries)
        }
    }

    @Test("Wallhaven search string query fixture handles empty source, dates, and pagination")
    func wallhavenStringQueryDecoding() throws {
        let data = try loadProviderFixture("wallhaven_search_string_query.json")
        let payload = try WallhavenProvider.decodeSearchResponse(data: data)

        #expect(payload.items.count == 2)
        #expect(payload.hasNextPage == true)
        #expect(payload.queryMeta == .text("landscape"))
        #expect(payload.seed == nil)

        let first = payload.items[0]
        #expect(first.id == "9oe8yd")
        #expect(first.source == .wallhaven)
        #expect(first.mediaType == .image)
        #expect(first.width == 3840 && first.height == 1634)
        #expect(first.fileSize == 2_814_332)
        #expect(first.dominantColors == ["#000000", "#663300", "#424153"])
        #expect(first.createdAt != nil)
        #expect(first.previewImageURL?.absoluteString == "https://th.wallhaven.cc/lg/9o/9oe8yd.jpg")
    }

    @Test("Wallhaven search tag object query fixture decodes polymorphic meta.query object and seed")
    func wallhavenTagObjectQueryDecoding() throws {
        let data = try loadProviderFixture("wallhaven_search_tag_object_query.json")
        let payload = try WallhavenProvider.decodeSearchResponse(data: data)

        #expect(payload.items.count == 1)
        #expect(payload.queryMeta == .tag(id: 37, tag: "nature"))
        #expect(payload.seed == "uwn0FK")
        #expect(payload.hasNextPage == true)
    }

    @Test("Pexels videos fixture filters HLS/null/portrait and selects UHD full + SD preview")
    func pexelsVideosDecoding() throws {
        let data = try loadProviderFixture("pexels_videos_search.json")
        let page = try PexelsProvider.parseVideosResponse(data: data)

        #expect(page.hasNextPage == true)
        #expect(page.items.count == 1)
        let item = page.items[0]
        #expect(item.id == "pexels-video-855675")
        #expect(item.source == .pexels)
        #expect(item.mediaType == .video)
        #expect(item.width == 3840 && item.height == 2160)
        #expect(item.duration == 15)
        #expect(item.fullAssetURL?.absoluteString == "https://videos.pexels.com/video-files/855675/855675-uhd-3840x2160.mp4")
        #expect(item.previewVideoURL?.absoluteString == "https://videos.pexels.com/video-files/855675/855675-sd-640x360.mp4")
        #expect(item.previewImageURL?.absoluteString == "https://images.pexels.com/videos/855675/poster.jpg")
        #expect(item.title == "Aerial View Of Ocean Waves")
    }

    @Test("Pexels curated photos fixture handles optional alt and avg_color nulls")
    func pexelsPhotosDecoding() throws {
        let data = try loadProviderFixture("pexels_photos_curated.json")
        let page = try PexelsProvider.parsePhotosResponse(data: data)

        #expect(page.hasNextPage == true)
        #expect(page.items.count == 2)
        #expect(page.items[0].title == "Brown Rocks During Golden Hour")
        #expect(page.items[0].dominantColors == ["#978E82"])
        #expect(page.items[1].title == "Photo by Alex Rivera")
        #expect(page.items[1].dominantColors.isEmpty)
    }

    @Test("Pixabay videos fixture falls back from empty large url/size=0 to medium and thumbnail")
    func pixabayVideosDecoding() throws {
        let data = try loadProviderFixture("pixabay_videos.json")
        let page = try PixabayProvider.parseVideosResponse(data: data, page: 1)

        #expect(page.hasNextPage == false)
        #expect(page.items.count == 2)

        let first = page.items[0]
        #expect(first.width == 3840 && first.height == 2160)
        #expect(first.fullAssetURL?.absoluteString == "https://cdn.pixabay.com/video/12573/12573-large.mp4")
        #expect(first.previewVideoURL?.absoluteString == "https://cdn.pixabay.com/video/12573/12573-small.mp4")

        let second = page.items[1]
        #expect(second.width == 1920 && second.height == 1080)
        #expect(second.fileSize == 3_180_000)
        #expect(second.fullAssetURL?.absoluteString == "https://cdn.pixabay.com/video/24891/24891-medium.mp4")
        #expect(second.previewImageURL?.absoluteString == "https://cdn.pixabay.com/video/24891/24891-medium-thumb.jpg")
    }

    @Test("Pixabay photos fixture falls back to largeImageURL and handles empty userImageURL")
    func pixabayPhotosDecoding() throws {
        let data = try loadProviderFixture("pixabay_photos.json")
        let page = try PixabayProvider.parsePhotosResponse(data: data, page: 1)

        #expect(page.hasNextPage == false)
        #expect(page.items.count == 2)
        #expect(page.items[0].fullAssetURL?.absoluteString == "https://pixabay.com/get/736885_1280.jpg")
        #expect(page.items[1].fullAssetURL?.absoluteString == "https://pixabay.com/get/736886_1280.png")
    }

    @Test("Custom feed wrapped and bare array fixtures decode, infer mediaType, and reject insecure items")
    func customFeedWrappedAndArrayDecoding() throws {
        let wrappedData = try loadProviderFixture("custom_feed_wrapped.json")
        let wrappedItems = try CustomFeedProvider.parseCustomFeed(data: wrappedData)
        #expect(wrappedItems.count == 2)
        #expect(wrappedItems[0].source == .customFeed)
        #expect(wrappedItems[0].mediaType == .video)
        #expect(wrappedItems[0].dominantColors == ["#0F2C3F", "#E68A5C"])
        #expect(wrappedItems[1].mediaType == .image)

        let arrayData = try loadProviderFixture("custom_feed_array.json")
        let arrayItems = try CustomFeedProvider.parseCustomFeed(data: arrayData)
        #expect(arrayItems.count == 2)
        #expect(arrayItems[0].mediaType == .video)
        #expect(arrayItems[0].id.hasPrefix("custom-"))
        #expect(arrayItems[0].previewImageURL == nil)
        #expect(arrayItems[1].mediaType == .image)
        #expect(arrayItems[1].title == "horizon-still")

        // Dual-alias keys (used by E2EHelpers / alternative feeds)
        let dualAliasJSON = Data("""
        {
          "items": [
            {
              "id": "alias-1",
              "title": "Alias Clip",
              "fullAssetURL": "https://cdn.example.com/clip.mov",
              "previewImageURL": "https://cdn.example.com/thumb.jpg",
              "previewVideoURL": "https://cdn.example.com/preview.mp4",
              "dominantColors": ["#112233"]
            }
          ]
        }
        """.utf8)
        let aliasItems = try CustomFeedProvider.parseCustomFeed(data: dualAliasJSON)
        #expect(aliasItems.count == 1)
        #expect(aliasItems[0].mediaType == .video)
        #expect(aliasItems[0].fullAssetURL?.absoluteString == "https://cdn.example.com/clip.mov")
        #expect(aliasItems[0].previewImageURL?.absoluteString == "https://cdn.example.com/thumb.jpg")
        #expect(aliasItems[0].previewVideoURL?.absoluteString == "https://cdn.example.com/preview.mp4")
        #expect(aliasItems[0].dominantColors == ["#112233"])

        // Empty/whitespace primary keys fall back to non-empty alias keys
        let emptyPrimaryFallbackJSON = Data("""
        {
          "items": [
            {
              "id": "empty-primary-1",
              "title": "Empty Primary Fallback",
              "url": "",
              "fullAssetURL": "https://cdn.example.com/fallback.mp4",
              "previewUrl": "   ",
              "previewImageURL": "https://cdn.example.com/fallback-thumb.jpg",
              "previewVideoUrl": "",
              "previewVideoURL": "https://cdn.example.com/fallback-preview.mp4",
              "colors": [],
              "dominantColors": ["#AABBCC"]
            }
          ]
        }
        """.utf8)
        let emptyFallbackItems = try CustomFeedProvider.parseCustomFeed(data: emptyPrimaryFallbackJSON)
        #expect(emptyFallbackItems.count == 1)
        #expect(emptyFallbackItems[0].fullAssetURL?.absoluteString == "https://cdn.example.com/fallback.mp4")
        #expect(emptyFallbackItems[0].previewImageURL?.absoluteString == "https://cdn.example.com/fallback-thumb.jpg")
        #expect(emptyFallbackItems[0].previewVideoURL?.absoluteString == "https://cdn.example.com/fallback-preview.mp4")
        #expect(emptyFallbackItems[0].dominantColors == ["#AABBCC"])
    }

    @Test("WallhavenProvider rejects non-positive minResolution dimensions and PixabayProvider preserves trailing slash")
    func providerURLBuildersValidation() throws {
        let wallhaven = WallhavenProvider()
        for invalidRes in ["-1920x0", "0x1080", "1920x0", "-1920x-1080", "1920xx1080"] {
            let url = try wallhaven.buildSearchURL(query: WallpaperQuery(minResolution: invalidRes))
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(!items.contains(where: { $0.name == "atleast" }), "Unexpected atleast for \(invalidRes)")
        }

        let validWallhavenURL = try wallhaven.buildSearchURL(query: WallpaperQuery(minResolution: "2560x1440"))
        let validItems = URLComponents(url: validWallhavenURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(validItems.contains(URLQueryItem(name: "atleast", value: "2560x1440")))

        let pixabay = PixabayProvider()
        let photosURL = try pixabay.buildURL(
            path: "api/",
            isPhotos: true,
            query: WallpaperQuery(text: "nature"),
            apiKey: "pb-key",
            page: 1
        )
        let photosNoSlashURL = try pixabay.buildURL(
            path: "api",
            isPhotos: true,
            query: WallpaperQuery(text: "nature"),
            apiKey: "pb-key",
            page: 1
        )
        let videosURL = try pixabay.buildURL(
            path: "api/videos/",
            isPhotos: false,
            query: WallpaperQuery(text: "nature"),
            apiKey: "pb-key",
            page: 1
        )
        let videosNoSlashURL = try pixabay.buildURL(
            path: "api/videos",
            isPhotos: false,
            query: WallpaperQuery(text: "nature"),
            apiKey: "pb-key",
            page: 1
        )

        #expect(photosURL.absoluteString.hasPrefix("https://pixabay.com/api/?"))
        #expect(photosNoSlashURL.absoluteString.hasPrefix("https://pixabay.com/api/?"))
        #expect(videosURL.absoluteString.hasPrefix("https://pixabay.com/api/videos/?"))
        #expect(videosNoSlashURL.absoluteString.hasPrefix("https://pixabay.com/api/videos/?"))
        #expect(URLComponents(url: photosURL, resolvingAgainstBaseURL: false)?.path == "/api/")
        #expect(URLComponents(url: videosURL, resolvingAgainstBaseURL: false)?.path == "/api/videos/")
    }

    @Test("ProviderURLValidator allows HTTPS and loopback HTTP, rejecting remote HTTP and file/ftp")
    func providerURLValidatorPolicy() {
        #expect(ProviderURLValidator.isAllowedRemoteURL(URL(string: "https://example.com/a.mp4")!))
        #expect(ProviderURLValidator.isAllowedRemoteURL(URL(string: "http://127.0.0.1:8080/feed.json")!))
        #expect(ProviderURLValidator.isAllowedRemoteURL(URL(string: "http://localhost:3000/feed.json")!))
        #expect(ProviderURLValidator.isAllowedRemoteURL(URL(string: "http://[::1]:9000/feed.json")!))

        #expect(!ProviderURLValidator.isAllowedRemoteURL(URL(string: "http://example.com/a.mp4")!))
        #expect(!ProviderURLValidator.isAllowedRemoteURL(URL(string: "ftp://example.com/a.mp4")!))
        #expect(!ProviderURLValidator.isAllowedRemoteURL(URL(string: "file:///tmp/a.mp4")!))
    }
}
