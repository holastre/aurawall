import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import AuraWallCore

// MARK: - Tier 5 Isolated Helpers

private final class Tier5StreamMockURLProtocol: URLProtocol, @unchecked Sendable {
    final class StreamSession: @unchecked Sendable {
        private struct State {
            var stopped = false
            var onStop: (@Sendable () -> Void)?
        }

        private let lock = OSAllocatedUnfairLock<State>(initialState: State())
        private weak var urlProtocol: Tier5StreamMockURLProtocol?

        init(urlProtocol: Tier5StreamMockURLProtocol) {
            self.urlProtocol = urlProtocol
        }

        var isStopped: Bool {
            lock.withLock { $0.stopped }
        }

        func setOnStop(_ handler: @escaping @Sendable () -> Void) {
            let alreadyStopped = lock.withLock { state -> Bool in
                state.onStop = handler
                return state.stopped
            }
            if alreadyStopped {
                handler()
            }
        }

        func markStopped() {
            let onStop = lock.withLock { state -> (@Sendable () -> Void)? in
                guard !state.stopped else { return nil }
                state.stopped = true
                let cb = state.onStop
                state.onStop = nil
                return cb
            }
            onStop?()
        }

        func sendResponse(_ response: URLResponse) {
            guard !isStopped, let proto = urlProtocol else { return }
            proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        func sendChunk(_ data: Data) {
            guard !isStopped, let proto = urlProtocol else { return }
            proto.client?.urlProtocol(proto, didLoad: data)
        }

        func finish() {
            guard !isStopped, let proto = urlProtocol else { return }
            proto.client?.urlProtocolDidFinishLoading(proto)
        }

        func fail(_ error: Error) {
            guard !isStopped, let proto = urlProtocol else { return }
            proto.client?.urlProtocol(proto, didFailWithError: error)
        }
    }

    typealias AsyncHandler = @Sendable (URLRequest, StreamSession) -> Void

    static let testIDHeader = "X-AuraWall-Tier5CacheTest-ID"
    private static let handlers = OSAllocatedUnfairLock<[String: AsyncHandler]>(initialState: [:])
    private let streamLock = OSAllocatedUnfairLock<StreamSession?>(initialState: nil)

    static func register(testID: String, handler: @escaping AsyncHandler) {
        handlers.withLock { $0[testID] = handler }
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
              let handler = Self.handlers.withLock({ $0[testID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let session = StreamSession(urlProtocol: self)
        streamLock.withLock { $0 = session }
        let capturedRequest = request
        DispatchQueue.global(qos: .userInitiated).async {
            handler(capturedRequest, session)
        }
    }

    override func stopLoading() {
        let session = streamLock.withLock { $0 }
        session?.markStopped()
    }
}

private final class Tier5NonHTTPMockURLProtocol: URLProtocol, @unchecked Sendable {
    static let testIDHeader = "X-AuraWall-Tier5NonHTTP-ID"

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: testIDHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = URLResponse(
            url: request.url!,
            mimeType: "application/octet-stream",
            expectedContentLength: 2,
            textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x01, 0x02]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class Tier5Signal: Sendable {
    private let lock = OSAllocatedUnfairLock<(signaled: Bool, waiters: [CheckedContinuation<Void, Never>])>(
        initialState: (false, [])
    )

    func signal() {
        let waiters = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.signaled = true
            let current = state.waiters
            state.waiters.removeAll()
            return current
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = lock.withLock { state -> Bool in
                if state.signaled {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}

private func makeTier5StreamSession(testID: String) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpAdditionalHeaders = [Tier5StreamMockURLProtocol.testIDHeader: testID]
    config.protocolClasses = [Tier5StreamMockURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("Tier 5 Adversarial Tests")
struct Tier5AdversarialTests {
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

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraWallTier5Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func pumpMainRunLoopSlice() {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }

    private func createValidImage(
        in dir: URL,
        name: String,
        utType: UTType,
        width: Int = 64,
        height: Int = 36,
        color: NSColor = .systemIndigo
    ) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw WallpaperEngineError.imageEncodingFailed
        }
        ctx.setFillColor(color.usingColorSpace(.deviceRGB)?.cgColor ?? CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw WallpaperEngineError.imageEncodingFailed
        }

        let outURL = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, utType.identifier as CFString, 1, nil) else {
            throw WallpaperEngineError.imageEncodingFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WallpaperEngineError.imageEncodingFailed
        }
        return outURL
    }

    private func createValidVideo(
        in dir: URL,
        name: String = "sample.mp4",
        fileType: AVFileType = .mp4
    ) async throws -> URL {
        let outURL = dir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: fileType)
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

    private static func makeCGWindow(
        layer: Int = 0,
        alpha: Double = 1.0,
        isOnscreen: Bool = true,
        ownerPID: Int32 = 12345,
        ownerName: String = "Safari",
        bounds: CGRect
    ) -> [String: Any] {
        [
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowIsOnscreen as String: isOnscreen,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowOwnerName as String: ownerName,
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary
        ]
    }

    // MARK: - T5-01

    @MainActor
    @Test("T5-01: teardownAllVideoWindows and window.onFailure do not resurrect on refreshLayoutForConnectedDisplays")
    func t5_01_teardownAndFailureDoNotResurrect() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = try await createValidVideo(in: tempDir, name: "mirror.mp4")
        let jpgURL = try createValidImage(in: tempDir, name: "static.jpg", utType: .jpeg)

        let screen1 = MockScreen(id: 101, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "Display-101")
        let screen2 = MockScreen(id: 102, frame: NSRect(x: 1280, y: 0, width: 1920, height: 1080), name: "Display-102")
        let holder = ScreenListHolder([screen1, screen2])

        let engine = WallpaperEngine(
            displayManager: DisplayManager(screensProvider: { holder.screens }),
            extractFirstFrameStill: false,
            desktopImageSetter: { _, _, _ in },
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true)
        )

        let videoItem = WallpaperItem(id: "t5-vid", title: "Mirror Vid", source: .starter, mediaType: .video, localPath: mp4URL)
        let imageItem = WallpaperItem(id: "t5-img", title: "Static Img", source: .wallhaven, mediaType: .image, localPath: jpgURL)

        // Pre-seed a stale independent image on 101, then switch to mirrorAll video, then tear down all videos
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: 101, mode: .independent, scaling: .fill)
        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: nil, mode: .mirrorAll, scaling: .fill)
        #expect(engine.activeVideoDisplayIDs == [101, 102])

        engine.teardownAllVideoWindows()
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers.isEmpty)

        // Resizing / refreshing must NOT resurrect torn-down video OR leak stale independent image into mirror mode
        screen1.mockFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        engine.refreshLayoutForConnectedDisplays()
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers.isEmpty)

        // Independent mode: 101 video + 102 static image -> teardownAllVideoWindows preserves 102 image only
        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: 101, mode: .independent, scaling: .fill)
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: 102, mode: .independent, scaling: .fill)
        #expect(engine.activeVideoDisplayIDs == [101])
        #expect(engine.activeWallpapers[102]?.id == imageItem.id)

        engine.teardownAllVideoWindows()
        engine.refreshLayoutForConnectedDisplays()
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers[101] == nil)
        #expect(engine.activeWallpapers[102]?.id == imageItem.id)

        // Non-empty corrupt video async onFailure must clear failed video from currentConfig
        let corruptMP4 = tempDir.appendingPathComponent("corrupt_t5.mp4")
        try Data("NOT_A_VALID_MP4_T5".utf8).write(to: corruptMP4, options: .atomic)
        let badVideo = WallpaperItem(id: "t5-bad", title: "Bad Vid", source: .localImport, mediaType: .video, localPath: corruptMP4)
        engine.apply(wallpaper: badVideo, localURL: corruptMP4, to: 101, mode: .independent, scaling: .fill)
        #expect(engine.activeVideoDisplayIDs == [101])

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            pumpMainRunLoopSlice()
            try await Task.sleep(for: .milliseconds(20))
            if engine.activeVideoDisplayIDs.isEmpty {
                break
            }
        }
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers[101] == nil)

        // Refreshing layout after async onFailure must NOT resurrect the corrupt video
        screen1.mockFrame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        engine.refreshLayoutForConnectedDisplays()
        #expect(engine.activeVideoDisplayIDs.isEmpty)
        #expect(engine.activeWallpapers[101] == nil)
        #expect(engine.activeWallpapers[102]?.id == imageItem.id)

        engine.teardownAllVideoWindows()
    }

    // MARK: - T5-02

    @MainActor
    @Test("T5-02: apply(config:) clears stale static images on unassigned displays and tolerates duplicate display IDs")
    func t5_02_staleStaticClearedAndDuplicateIDsSafe() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpgURL = try createValidImage(in: tempDir, name: "mirror.jpg", utType: .jpeg)
        let screen101a = MockScreen(id: 101, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "Dup-A")
        let screen101b = MockScreen(id: 101, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "Dup-B")
        let screen102 = MockScreen(id: 102, frame: NSRect(x: 1280, y: 0, width: 1920, height: 1080), name: "Disp-102")
        let holder = ScreenListHolder([screen101a, screen102])

        let displayManager = DisplayManager(screensProvider: { holder.screens })
        let engine = WallpaperEngine(
            displayManager: displayManager,
            extractFirstFrameStill: false,
            desktopImageSetter: { _, _, _ in },
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true)
        )

        let imageItem = WallpaperItem(id: "static-mirror", title: "Static Mirror", source: .wallhaven, mediaType: .image, localPath: jpgURL)
        engine.apply(wallpaper: imageItem, localURL: jpgURL, to: nil, mode: .mirrorAll, scaling: .fill)
        #expect(engine.activeWallpapers[101]?.id == imageItem.id)
        #expect(engine.activeWallpapers[102]?.id == imageItem.id)

        // Apply independent config assigning ONLY 101 -> 102 must be cleared from activeWallpapers
        let independentConfig = DisplayConfig(
            mode: .independent,
            assignments: [
                DisplayConfig.key(for: 101): DisplayAssignment(
                    displayID: 101,
                    displayName: "Disp-101",
                    wallpaper: imageItem,
                    scalingMode: .fill
                )
            ]
        )
        engine.apply(config: independentConfig)
        #expect(engine.activeWallpapers[101]?.id == imageItem.id)
        #expect(engine.activeWallpapers[102] == nil)

        // Duplicate display IDs from NSScreen provider must deduplicate safely without Dictionary trap
        holder.screens = [screen101a, screen101b, screen102]
        engine.refreshLayoutForConnectedDisplays()
        #expect(displayManager.displays.count == 2)
        #expect(displayManager.displays.map(\.id) == [101, 102])

        engine.teardownAllVideoWindows()
    }

    // MARK: - T5-03

    @Test("T5-03: PexelsProvider & PixabayProvider surface partial errors and propagate CancellationError under .all")
    func t5_03_pexelsAndPixabayPartialFailuresAndCancellation() async throws {
        let pexelsVideosData = try loadProviderFixture("pexels_videos_search.json")
        let pexelsPhotosData = try loadProviderFixture("pexels_photos_curated.json")
        let pixabayVideosData = try loadProviderFixture("pixabay_videos.json")
        let pixabayPhotosData = try loadProviderFixture("pixabay_photos.json")

        // 1. Pexels: videos -> 429, photos -> 200 (direct + CatalogService)
        let pexelsVid429ID = UUID().uuidString
        ProviderMockURLProtocol.register(testID: pexelsVid429ID) { request in
            let path = request.url?.path ?? ""
            if path.contains("/v1/videos/") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Retry-After": "30"]
                )!
                return (resp, Data("Rate limit exceeded".utf8))
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, pexelsPhotosData)
        }
        defer { ProviderMockURLProtocol.unregister(testID: pexelsVid429ID) }

        let pexelsClient1 = ProviderHTTPClient(urlSession: makeProviderMockSession(testID: pexelsVid429ID))
        let pexelsProvider1 = PexelsProvider(httpClient: pexelsClient1)
        let secrets = ApiSecrets(pexelsAPIKey: "px_key", pixabayAPIKey: "pb_key")

        let pexelsPartial1 = try await pexelsProvider1.fetch(
            query: WallpaperQuery(text: "waves", mediaType: .all, sources: [.pexels]),
            secrets: secrets,
            customFeedURL: nil
        )
        #expect(!pexelsPartial1.items.isEmpty)
        #expect(pexelsPartial1.items.allSatisfy { $0.mediaType == .image })
        #expect(pexelsPartial1.errorMessage != nil)
        #expect(pexelsPartial1.errorMessage?.localizedCaseInsensitiveContains("rate limit") == true)

        let pexelsCatalog1 = await CatalogService(providers: [pexelsProvider1]).fetchCatalog(
            query: WallpaperQuery(text: "waves", mediaType: .all, sources: [.pexels]),
            secrets: secrets,
            customFeedURL: nil
        )
        #expect(!pexelsCatalog1.items.isEmpty)
        #expect(pexelsCatalog1.errorsBySource[.pexels]?.localizedCaseInsensitiveContains("rate limit") == true)

        // 2. Pexels reverse: videos -> 200, photos -> 500 HTML
        let pexelsPhoto500ID = UUID().uuidString
        ProviderMockURLProtocol.register(testID: pexelsPhoto500ID) { request in
            let path = request.url?.path ?? ""
            if path.contains("/v1/videos/") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, pexelsVideosData)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            return (resp, Data("<html><body>500 Server Error</body></html>".utf8))
        }
        defer { ProviderMockURLProtocol.unregister(testID: pexelsPhoto500ID) }

        let pexelsProvider2 = PexelsProvider(httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: pexelsPhoto500ID)))
        let pexelsPartial2 = try await pexelsProvider2.fetch(
            query: WallpaperQuery(text: "waves", mediaType: .all, sources: [.pexels]),
            secrets: secrets,
            customFeedURL: nil
        )
        #expect(!pexelsPartial2.items.isEmpty)
        #expect(pexelsPartial2.items.allSatisfy { $0.mediaType == .video })
        #expect(pexelsPartial2.errorMessage != nil)
        #expect(pexelsPartial2.errorMessage?.contains("500") == true)

        // 3. Pixabay: videos -> 429, photos -> 200 (direct + CatalogService)
        let pixabayVid429ID = UUID().uuidString
        ProviderMockURLProtocol.register(testID: pixabayVid429ID) { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/videos") {
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Retry-After": "30"]
                )!
                return (resp, Data("[ERROR 429] API rate limit exceeded".utf8))
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, pixabayPhotosData)
        }
        defer { ProviderMockURLProtocol.unregister(testID: pixabayVid429ID) }

        let pixabayProvider1 = PixabayProvider(httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: pixabayVid429ID)))
        let pixabayPartial1 = try await pixabayProvider1.fetch(
            query: WallpaperQuery(text: "nature", mediaType: .all, sources: [.pixabay]),
            secrets: secrets,
            customFeedURL: nil
        )
        #expect(!pixabayPartial1.items.isEmpty)
        #expect(pixabayPartial1.items.allSatisfy { $0.mediaType == .image })
        #expect(pixabayPartial1.errorMessage?.localizedCaseInsensitiveContains("rate limit") == true)

        let pixabayCatalog1 = await CatalogService(providers: [pixabayProvider1]).fetchCatalog(
            query: WallpaperQuery(text: "nature", mediaType: .all, sources: [.pixabay]),
            secrets: secrets,
            customFeedURL: nil
        )
        #expect(!pixabayCatalog1.items.isEmpty)
        #expect(pixabayCatalog1.errorsBySource[.pixabay]?.localizedCaseInsensitiveContains("rate limit") == true)

        // 4. Pixabay reverse: videos -> 200, photos -> 500 HTML
        let pixabayPhoto500ID = UUID().uuidString
        ProviderMockURLProtocol.register(testID: pixabayPhoto500ID) { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/videos") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, pixabayVideosData)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("<html><body>500 Bad Gateway</body></html>".utf8))
        }
        defer { ProviderMockURLProtocol.unregister(testID: pixabayPhoto500ID) }

        let pixabayProvider2 = PixabayProvider(httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: pixabayPhoto500ID)))
        let pixabayPartial2 = try await pixabayProvider2.fetch(
            query: WallpaperQuery(text: "nature", mediaType: .all, sources: [.pixabay]),
            secrets: secrets,
            customFeedURL: nil
        )
        #expect(!pixabayPartial2.items.isEmpty)
        #expect(pixabayPartial2.items.allSatisfy { $0.mediaType == .video })
        #expect(pixabayPartial2.errorMessage?.contains("500") == true)

        // 5. Partial CancellationError propagation (photos completes 200, videos remains pending, task cancelled)
        for isPexels in [true, false] {
            let cancelTestID = UUID().uuidString
            let photosDone = Tier5Signal()
            let videosStarted = Tier5Signal()
            let photosPayload = isPexels ? pexelsPhotosData : pixabayPhotosData

            ProviderMockURLProtocol.registerAsync(testID: cancelTestID) { request, finish in
                let path = request.url?.path ?? ""
                if path.contains("/videos") {
                    videosStarted.signal()
                    // Leave videos pending until task.cancel() cancels URLSession task.
                    return
                }
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                finish(.success((resp, photosPayload)))
                photosDone.signal()
            }
            defer { ProviderMockURLProtocol.unregister(testID: cancelTestID) }

            let client = ProviderHTTPClient(urlSession: makeProviderMockSession(testID: cancelTestID))
            let task = Task { () -> ProviderResult in
                if isPexels {
                    return try await PexelsProvider(httpClient: client).fetch(
                        query: WallpaperQuery(text: "waves", mediaType: .all, sources: [.pexels]),
                        secrets: secrets,
                        customFeedURL: nil
                    )
                } else {
                    return try await PixabayProvider(httpClient: client).fetch(
                        query: WallpaperQuery(text: "waves", mediaType: .all, sources: [.pixabay]),
                        secrets: secrets,
                        customFeedURL: nil
                    )
                }
            }

            await photosDone.wait()
            await videosStarted.wait()
            try await Task.sleep(for: .milliseconds(25))
            task.cancel()

            do {
                let unexpected = try await task.value
                Issue.record("Expected CancellationError, got \(unexpected.items.count) items")
            } catch is CancellationError {
                // Expected
            }
        }
    }

    // MARK: - T5-04

    @Test("T5-04: PowerPolicyEvaluator evaluates mixed video + static image displays accurately")
    func t5_04_mixedVideoAndStaticPowerStatus() {
        // Display 1 = .video (fullscreen occluded), Display 2 = .image (unoccluded)
        let occludedVideoInputs = PowerInputs(fullscreenDisplayIDs: [1])
        let d1 = PowerPolicyEvaluator.aggregateDecision(
            inputs: occludedVideoInputs,
            activeVideoDisplayIDs: [1],
            fallbackDisplayIDs: [1, 2]
        )
        let l1 = PowerPolicyEvaluator.menuBarStatusLabel(
            inputs: occludedVideoInputs,
            activeVideoDisplayIDs: [1],
            fallbackDisplayIDs: [1, 2],
            primaryMediaType: .video
        )
        #expect(d1 == .pause(.fullscreenOccluded))
        #expect(l1 == "Paused — Fullscreen App")

        // Display 1 (primary) = .image, Display 2 = .video (playing) -> "Playing", NOT "Static"
        let playingInputs = PowerInputs()
        let d2 = PowerPolicyEvaluator.aggregateDecision(
            inputs: playingInputs,
            activeVideoDisplayIDs: [2],
            fallbackDisplayIDs: [1, 2]
        )
        let l2 = PowerPolicyEvaluator.menuBarStatusLabel(
            inputs: playingInputs,
            activeVideoDisplayIDs: [2],
            fallbackDisplayIDs: [1, 2],
            primaryMediaType: .image
        )
        #expect(d2 == .play)
        #expect(l2 == "Playing")

        // Display 1 (primary) = .image, Display 2 = .video (onBattery = true) -> "Paused — On Battery"
        let batteryInputs = PowerInputs(onBattery: true, pauseOnBatteryEnabled: true)
        let d3 = PowerPolicyEvaluator.aggregateDecision(
            inputs: batteryInputs,
            activeVideoDisplayIDs: [2],
            fallbackDisplayIDs: [1, 2]
        )
        let l3 = PowerPolicyEvaluator.menuBarStatusLabel(
            inputs: batteryInputs,
            activeVideoDisplayIDs: [2],
            fallbackDisplayIDs: [1, 2],
            primaryMediaType: .image
        )
        #expect(d3 == .pause(.onBattery))
        #expect(l3 == "Paused — On Battery")

        // Display 1 = .image, Display 2 = .image (no active video) -> "Static"
        let l4 = PowerPolicyEvaluator.menuBarStatusLabel(
            inputs: batteryInputs,
            activeVideoDisplayIDs: [],
            fallbackDisplayIDs: [1, 2],
            primaryMediaType: .image
        )
        #expect(l4 == "Static")

        // No wallpapers -> "Ready"
        let l5 = PowerPolicyEvaluator.menuBarStatusLabel(
            inputs: playingInputs,
            activeVideoDisplayIDs: [],
            fallbackDisplayIDs: [1, 2],
            primaryMediaType: nil
        )
        #expect(l5 == "Ready")
    }

    // MARK: - T5-05

    @MainActor
    @Test("T5-05: PowerMonitor sleep/wake/lock/unlock/space-change observers & polling via injected NotificationCenters")
    func t5_05_powerMonitorObserversAndPolling() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = try await createValidVideo(in: tempDir)
        let screen = MockScreen(id: 1, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), name: "Main-1")
        let engine = WallpaperEngine(
            displayManager: DisplayManager(screensProvider: { [screen] }),
            extractFirstFrameStill: false,
            desktopImageSetter: { _, _, _ in },
            stillCacheDirectory: tempDir.appendingPathComponent("Stills", isDirectory: true)
        )
        let videoItem = WallpaperItem(id: "pm-vid", title: "PM Video", source: .starter, mediaType: .video, localPath: mp4URL)
        engine.apply(wallpaper: videoItem, localURL: mp4URL, to: 1, mode: .independent, scaling: .fill)
        #expect(engine.isPaused(for: 1) == false)

        let wsCenter = NotificationCenter()
        let distCenter = NotificationCenter()
        let defCenter = NotificationCenter()
        let showFullscreen = OSAllocatedUnfairLock<Bool>(initialState: false)
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let monitor = PowerMonitor(
            initialSettings: PowerSettings(pauseOnBattery: true, pauseOnFullscreen: true, pauseOnScreenLockOrSleep: true),
            occlusionPollingInterval: 0.03,
            batteryStateProvider: { false },
            windowListProvider: {
                showFullscreen.withLock { $0 }
                    ? [Self.makeCGWindow(ownerPID: 8888, ownerName: "VLC", bounds: bounds)]
                    : []
            },
            displaysProvider: { [(id: UInt32(1), bounds: bounds)] },
            workspaceNotificationCenter: wsCenter,
            distributedNotificationCenter: distCenter,
            defaultNotificationCenter: defCenter
        )

        var emissions: [PowerInputs] = []
        monitor.onInputsChanged = { inputs in
            emissions.append(inputs)
            engine.updatePowerInputs(inputs)
        }
        monitor.start()
        defer { monitor.stop() }

        // Sleep & Wake (NSWorkspace.willSleepNotification / didWakeNotification)
        wsCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(monitor.inputs.displayAsleep == true)
        #expect(engine.isPaused(for: 1) == true)
        #expect(engine.currentDecisions[1] == .pause(.displayAsleepOrLocked))

        let countBeforeWake = emissions.count
        wsCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(monitor.inputs.displayAsleep == false)
        #expect(engine.isPaused(for: 1) == false)
        #expect(emissions.count == countBeforeWake + 1)

        // screensDidSleep / screensDidWake
        wsCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(monitor.inputs.displayAsleep == true)
        wsCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(monitor.inputs.displayAsleep == false)

        // Distributed screenIsLocked / screenIsUnlocked
        distCenter.post(name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(monitor.inputs.screenLocked == true)
        #expect(engine.currentDecisions[1] == .pause(.displayAsleepOrLocked))

        let countBeforeUnlock = emissions.count
        distCenter.post(name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        #expect(monitor.inputs.screenLocked == false)
        #expect(engine.currentDecisions[1] == .play)
        #expect(emissions.count == countBeforeUnlock + 1)

        // sessionDidResignActive / sessionDidBecomeActive
        wsCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(monitor.inputs.screenLocked == true)
        wsCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(monitor.inputs.screenLocked == false)

        // activeSpaceDidChange, didActivateApplication, didChangeScreenParameters
        showFullscreen.withLock { $0 = true }
        wsCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #expect(monitor.inputs.fullscreenDisplayIDs == [1])
        #expect(engine.currentDecisions[1] == .pause(.fullscreenOccluded))

        showFullscreen.withLock { $0 = false }
        wsCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(monitor.inputs.fullscreenDisplayIDs.isEmpty)

        showFullscreen.withLock { $0 = true }
        defCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(monitor.inputs.fullscreenDisplayIDs == [1])

        // Polling interval (0.03s) automatically picks up cleared occlusion without notifications
        showFullscreen.withLock { $0 = false }
        for _ in 0..<25 {
            if monitor.inputs.fullscreenDisplayIDs.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(monitor.inputs.fullscreenDisplayIDs.isEmpty)
        #expect(engine.currentDecisions[1] == .play)

        // stop() unregisters observers so subsequent notifications do not mutate inputs
        monitor.stop()
        wsCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        distCenter.post(name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(monitor.inputs.displayAsleep == false)
        #expect(monitor.inputs.screenLocked == false)

        engine.teardownAllVideoWindows()
    }

    // MARK: - T5-06

    @Test("T5-06: StarterVideoProvider ATS enforcement and PosixTarExtractor adversarial tar cases")
    func t5_06_starterATSAndPosixTarAdversarial() throws {
        // 1. StarterVideoProvider modern catalog rejects http:// previewImageURL & previewVideoURL
        let modernInsecureJSON = """
        {
          "version": 1,
          "categories": [
            {
              "id": "cat-1",
              "localizedNameKey": "AerialCategoryNature",
              "previewImage": "http://insecure.example.com/cat.jpg"
            }
          ],
          "assets": [
            {
              "id": "asset-1",
              "accessibilityLabel": "Test Aerial",
              "categories": ["cat-1"],
              "previewImage": "http://insecure.example.com/thumb.jpg",
              "url-4K-SDR": "https://sylvan.apple.com/Aerials/test_4k.mov",
              "url-1080-SDR": "http://a1.phobos.apple.com/1080.mov"
            }
          ]
        }
        """
        let decodedModern = try StarterVideoProvider.parseAerialCatalog(data: Data(modernInsecureJSON.utf8))
        #expect(decodedModern.count == 1)
        #expect(decodedModern[0].previewImageURL == nil)
        #expect(decodedModern[0].previewVideoURL?.scheme?.lowercased() == "https")
        #expect(decodedModern[0].fullAssetURL?.scheme?.lowercased() == "https")

        // Legacy phobos batch rejects http:// URL while keeping https:// URL
        let phobosMixedJSON = """
        [
          {
            "id": "b1",
            "assets": [
              {"id": "bad", "type": "video", "url": "http://a1.phobos.apple.com/bad.mov"},
              {"id": "good", "type": "video", "url": "https://sylvan.apple.com/good.mov"}
            ]
          }
        ]
        """
        let decodedPhobos = try StarterVideoProvider.parseAerialCatalog(data: Data(phobosMixedJSON.utf8))
        #expect(decodedPhobos.map(\.id) == ["good"])

        // 2. PosixTarExtractor: GNU base-256 size header
        let payload = Data(#"{"version":1,"assets":[]}"#.utf8)
        var base256Header = [UInt8](repeating: 0, count: 512)
        for (i, b) in Array("entries.json".utf8).enumerated() {
            base256Header[i] = b
        }
        // Size field [124..<136]: 0x80 followed by big-endian UInt64 length at bytes 4..11
        base256Header[124] = 0x80
        let count64 = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: count64) { ptr in
            for i in 0..<8 {
                base256Header[128 + i] = ptr[i]
            }
        }
        base256Header[156] = 0x30
        for i in 148..<156 { base256Header[i] = 0x20 }
        let sum = base256Header.reduce(0) { $0 + Int($1) }
        for (i, b) in Array(String(format: "%06o\0 ", sum).utf8).enumerated() {
            base256Header[148 + i] = b
        }
        var base256Tar = Data(base256Header)
        base256Tar.append(payload)
        let padRem = payload.count % 512
        if padRem != 0 {
            base256Tar.append(Data(repeating: 0, count: 512 - padRem))
        }
        base256Tar.append(Data(repeating: 0, count: 1024))
        let extractedBase256 = try PosixTarExtractor.extractFile(named: "entries.json", from: base256Tar)
        #expect(extractedBase256 == payload)

        // PAX 'g' global header + directory '5' + symlink '2' preceding entries.json
        let paxGlobal = Data("19 comment=ignored\n".utf8)
        let mixedTar = buildSyntheticTarArchive(entries: [
            (name: "pax_global_header", prefix: "", typeflag: 0x67, content: paxGlobal),
            (name: "dir/", prefix: "", typeflag: 0x35, content: Data()),
            (name: "link", prefix: "", typeflag: 0x32, content: Data()),
            (name: "entries.json", prefix: "", typeflag: 0x30, content: payload)
        ])
        let extractedMixed = try PosixTarExtractor.extractFile(named: "entries.json", from: mixedTar)
        #expect(extractedMixed == payload)

        // Invalid PAX size=-5 throws .malformedHeader
        let badPAXRecord = "11 size=-5\n"
        let badPAXTar = buildSyntheticTarArchive(entries: [
            (name: "PaxHeader/entries.json", prefix: "", typeflag: 0x78, content: Data(badPAXRecord.utf8)),
            (name: "entries.json", prefix: "", typeflag: 0x30, content: payload)
        ])
        #expect(throws: TarExtractionError.malformedHeader) {
            _ = try PosixTarExtractor.extractFile(named: "entries.json", from: badPAXTar)
        }

        // Truncated header without trailing zero blocks throws .truncatedArchive
        var truncatedArchive = buildSyntheticTarArchive(
            entries: [(name: "other.txt", prefix: "", typeflag: 0x30, content: Data("hi".utf8))],
            includeTrailingZeroBlocks: false
        )
        truncatedArchive.append(Data([0x01, 0x02, 0x03]))
        #expect(throws: TarExtractionError.truncatedArchive) {
            _ = try PosixTarExtractor.extractFile(named: "entries.json", from: truncatedArchive)
        }

        // Empty target name throws .fileNotFound
        #expect(throws: TarExtractionError.fileNotFound("")) {
            _ = try PosixTarExtractor.extractFile(named: "", from: mixedTar)
        }
    }

    // MARK: - T5-07

    @Test("T5-07: LocalMediaImporter validates formats, rejects corrupt files, clips long names, and hashes content")
    func t5_07_localMediaImporterAdversarialAndHappyPath() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let importsDir = tempDir.appendingPathComponent("Imports", isDirectory: true)
        let thumbsDir = importsDir.appendingPathComponent("Thumbnails", isDirectory: true)

        // Valid .mp4, .mov, .jpg, .png, .heic
        let mp4URL = try await createValidVideo(in: tempDir, name: "clip.mp4", fileType: .mp4)
        let movURL = try await createValidVideo(in: tempDir, name: "clip.mov", fileType: .mov)
        let jpgURL = try createValidImage(in: tempDir, name: "photo.jpg", utType: .jpeg, width: 80, height: 40)
        let pngURL = try createValidImage(in: tempDir, name: "photo.png", utType: .png, width: 64, height: 32)
        let heicURL = try createValidImage(in: tempDir, name: "photo.heic", utType: .heic, width: 48, height: 24)

        let importedMP4 = try await LocalMediaImporter.importFile(from: mp4URL, importsDir: importsDir, thumbsDir: thumbsDir)
        #expect(importedMP4.source == .localImport)
        #expect(importedMP4.mediaType == .video)
        #expect(importedMP4.width == 64 && importedMP4.height == 64)
        #expect((importedMP4.duration ?? 0) > 0)
        #expect(importedMP4.previewImageURL != nil)

        let importedMOV = try await LocalMediaImporter.importFile(from: movURL, importsDir: importsDir, thumbsDir: thumbsDir)
        #expect(importedMOV.mediaType == .video)

        for (imgURL, expectedW, expectedH) in [(jpgURL, 80, 40), (pngURL, 64, 32), (heicURL, 48, 24)] {
            let item = try await LocalMediaImporter.importFile(from: imgURL, importsDir: importsDir, thumbsDir: thumbsDir)
            #expect(item.source == .localImport)
            #expect(item.mediaType == .image)
            #expect(item.width == expectedW && item.height == expectedH)
            #expect(item.previewImageURL == item.localPath)
        }

        // Rejects remote URL, unsupported extensions, 0-byte, corrupt non-empty, missing
        await #expect(throws: LocalMediaImportError.notAFileURL) {
            _ = try await LocalMediaImporter.importFile(
                from: URL(string: "https://example.com/a.mp4")!,
                importsDir: importsDir,
                thumbsDir: thumbsDir
            )
        }

        let txtURL = tempDir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: txtURL)
        await #expect(throws: LocalMediaImportError.unsupportedFormat("txt")) {
            _ = try await LocalMediaImporter.importFile(from: txtURL, importsDir: importsDir, thumbsDir: thumbsDir)
        }

        let emptyJPG = tempDir.appendingPathComponent("empty.jpg")
        try Data().write(to: emptyJPG)
        await #expect(throws: LocalMediaImportError.emptyOrUnreadableFile) {
            _ = try await LocalMediaImporter.importFile(from: emptyJPG, importsDir: importsDir, thumbsDir: thumbsDir)
        }

        let missingJPG = tempDir.appendingPathComponent("does_not_exist.jpg")
        await #expect(throws: LocalMediaImportError.emptyOrUnreadableFile) {
            _ = try await LocalMediaImporter.importFile(from: missingJPG, importsDir: importsDir, thumbsDir: thumbsDir)
        }

        let corruptMP4 = tempDir.appendingPathComponent("bad.mp4")
        try Data("NOT_AN_MP4_AT_ALL".utf8).write(to: corruptMP4)
        do {
            _ = try await LocalMediaImporter.importFile(from: corruptMP4, importsDir: importsDir, thumbsDir: thumbsDir)
            Issue.record("Expected corruptMedia for bad.mp4")
        } catch LocalMediaImportError.corruptMedia {
            // Expected
        }

        let corruptJPG = tempDir.appendingPathComponent("bad.jpg")
        try Data("NOT_A_JPG_AT_ALL".utf8).write(to: corruptJPG)
        do {
            _ = try await LocalMediaImporter.importFile(from: corruptJPG, importsDir: importsDir, thumbsDir: thumbsDir)
            Issue.record("Expected corruptMedia for bad.jpg")
        } catch LocalMediaImportError.corruptMedia {
            // Expected
        }

        // Long filename (>= 245 chars) must succeed without ENAMETOOLONG
        let longName = String(repeating: "a", count: 245) + ".jpg"
        let seedLongSource = try createValidImage(in: tempDir, name: "long_seed.jpg", utType: .jpeg)
        let longSource = tempDir.appendingPathComponent(longName)
        try FileManager.default.moveItem(at: seedLongSource, to: longSource)
        let importedLong = try await LocalMediaImporter.importFile(from: longSource, importsDir: importsDir, thumbsDir: thumbsDir)
        let destFilename = try #require(importedLong.localPath?.lastPathComponent)
        #expect(destFilename.utf8.count <= 255)
        #expect(FileManager.default.fileExists(atPath: importedLong.localPath!.path))

        // Same-path, same-byte-size modification must produce updated content (no stale file reuse)
        let mutableURL = tempDir.appendingPathComponent("mutable.jpg")
        let bytesA = try Data(contentsOf: createValidImage(in: tempDir, name: "srcA.jpg", utType: .jpeg, color: .red))
        let rawB = try Data(contentsOf: createValidImage(in: tempDir, name: "srcB.jpg", utType: .jpeg, color: .blue))
        // Pad both to identical byte length (trailing bytes after JPEG EOI are ignored by decoders)
        let targetCount = max(bytesA.count, rawB.count) + 16
        let paddedA = bytesA + Data(repeating: 0x00, count: targetCount - bytesA.count)
        let paddedB = rawB + Data(repeating: 0xFF, count: targetCount - rawB.count)
        #expect(paddedA.count == paddedB.count)

        try paddedA.write(to: mutableURL, options: .atomic)
        let firstImport = try await LocalMediaImporter.importFile(from: mutableURL, importsDir: importsDir, thumbsDir: thumbsDir)

        try paddedB.write(to: mutableURL, options: .atomic)
        let secondImport = try await LocalMediaImporter.importFile(from: mutableURL, importsDir: importsDir, thumbsDir: thumbsDir)

        #expect(firstImport.id != secondImport.id)
        let storedSecondBytes = try Data(contentsOf: try #require(secondImport.localPath))
        #expect(storedSecondBytes == paddedB)
    }

    // MARK: - T5-08

    @Test("T5-08: PathCanonicalizer, RFC Retry-After, CatalogService cancel, and MediaCacheManager mid-stream/activeTempURLs")
    func t5_08_canonicalizerHTTPRateLimitCatalogCancelAndCacheSafety() async throws {
        // 1. PathCanonicalizer
        let varURL = URL(fileURLWithPath: "/var/tmp/aurawall_nonexistent_dir/leaf.mp4")
        let privateVarURL = URL(fileURLWithPath: "/private/var/tmp/aurawall_nonexistent_dir/leaf.mp4")
        #expect(PathCanonicalizer.canonicalFileURL(varURL).path == PathCanonicalizer.canonicalFileURL(privateVarURL).path)
        let remoteURL = URL(string: "https://example.com/a/../b.mp4")!
        #expect(PathCanonicalizer.canonicalFileURL(remoteURL) == remoteURL.standardized)
        #expect(PathCanonicalizer.canonicalFileURL(URL(fileURLWithPath: "/")).path == "/")

        // 2. ProviderHTTPClient RFC 1123/850/asctime Retry-After & non-HTTP response & disallowed probeAvailability
        let fixedNow = Date(timeIntervalSince1970: 1_795_649_880) // Thu, 26 Nov 2026 00:58:00 GMT
        let futureFormatter = DateFormatter()
        futureFormatter.locale = Locale(identifier: "en_US_POSIX")
        futureFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        futureFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let futureHeader = futureFormatter.string(from: fixedNow.addingTimeInterval(120))
        let pastHeader = futureFormatter.string(from: fixedNow.addingTimeInterval(-60))

        let futureLimit = ProviderHTTPClient.parseRateLimit(headers: ["retry-after": futureHeader], now: fixedNow)
        #expect(futureLimit?.retryAfterSeconds == 120)
        let pastLimit = ProviderHTTPClient.parseRateLimit(headers: ["retry-after": pastHeader], now: fixedNow)
        #expect(pastLimit?.retryAfterSeconds == 0)

        let nonHTTPConfig = URLSessionConfiguration.ephemeral
        nonHTTPConfig.httpAdditionalHeaders = [Tier5NonHTTPMockURLProtocol.testIDHeader: "1"]
        nonHTTPConfig.protocolClasses = [Tier5NonHTTPMockURLProtocol.self]
        let nonHTTPClient = ProviderHTTPClient(urlSession: URLSession(configuration: nonHTTPConfig))
        await #expect(throws: ProviderError.invalidResponse) {
            _ = try await nonHTTPClient.get(URL(string: "https://mock.aurawall.local/nonhttp")!)
        }
        let disallowedProbe = try await nonHTTPClient.probeAvailability(URL(string: "http://insecure.example.com/v.mp4")!)
        #expect(disallowedProbe == false)

        // 3. CatalogService cancellation does not surface CancellationError in errorsBySource
        let cancelCatalogID = UUID().uuidString
        let catalogStarted = Tier5Signal()
        ProviderMockURLProtocol.registerAsync(testID: cancelCatalogID) { _, _ in
            catalogStarted.signal()
        }
        defer { ProviderMockURLProtocol.unregister(testID: cancelCatalogID) }

        let cancelService = CatalogService(
            providers: [CustomFeedProvider(httpClient: ProviderHTTPClient(urlSession: makeProviderMockSession(testID: cancelCatalogID)))]
        )
        let cancelTask = Task {
            await cancelService.fetchCatalog(
                query: WallpaperQuery(sources: [.customFeed]),
                secrets: ApiSecrets(),
                customFeedURL: URL(string: "http://127.0.0.1:9999/slow.json")!
            )
        }
        await catalogStarted.wait()
        cancelTask.cancel()
        let aggResult = await cancelTask.value
        #expect(aggResult.errorsBySource.isEmpty)

        // 4. MediaCacheManager mid-stream failure & clearCache preserving activeTempURLs
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheTestID = UUID().uuidString
        let secondStarted = Tier5Signal()
        let releaseSecond = Tier5Signal()

        Tier5StreamMockURLProtocol.register(testID: cacheTestID) { request, session in
            let path = request.url?.path ?? ""
            if path == "/midstream_fail.mp4" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1024"])!
                session.sendResponse(resp)
                session.sendChunk(Data(repeating: 0xAA, count: 64))
                session.fail(URLError(.networkConnectionLost))
                return
            }

            if path == "/in_flight.mp4" {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "128"])!
                session.sendResponse(resp)
                session.sendChunk(Data(repeating: 0xBB, count: 32))
                secondStarted.signal()
                Task {
                    await releaseSecond.wait()
                    if !session.isStopped {
                        session.sendChunk(Data(repeating: 0xCC, count: 96))
                        session.finish()
                    }
                }
                return
            }

            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            session.sendResponse(resp)
            session.finish()
        }
        defer { Tier5StreamMockURLProtocol.unregister(testID: cacheTestID) }

        let cacheDir = tempDir.appendingPathComponent("MediaCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let manager = MediaCacheManager(cacheDirectory: cacheDir, urlSession: makeTier5StreamSession(testID: cacheTestID))

        let failItem = WallpaperItem(
            id: "midfail",
            title: "Mid Fail",
            source: .starter,
            mediaType: .video,
            fullAssetURL: URL(string: "https://mock.aurawall.local/midstream_fail.mp4")!
        )
        do {
            _ = try await manager.download(failItem)
            Issue.record("Expected mid-stream download failure")
        } catch {
            // Expected URLError(.networkConnectionLost)
        }
        let afterFailFiles = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(afterFailFiles.isEmpty)

        // Seed a stale .tmp file and an unreferenced cached file, start an in-flight download, and call clearCache()
        let staleTmp = cacheDir.appendingPathComponent("stale.tmp")
        try Data("stale".utf8).write(to: staleTmp)
        let unusedCached = cacheDir.appendingPathComponent("unused.mp4")
        try Data(repeating: 0x11, count: 256).write(to: unusedCached)

        let inFlightItem = WallpaperItem(
            id: "inflight",
            title: "In Flight",
            source: .starter,
            mediaType: .video,
            fullAssetURL: URL(string: "https://mock.aurawall.local/in_flight.mp4")!
        )
        let inFlightTask = Task {
            try await manager.download(inFlightItem)
        }
        await secondStarted.wait()
        // Wait briefly for temp file creation & initial chunk write
        try await Task.sleep(for: .milliseconds(30))

        let freed = try await manager.clearCache(preserving: [])
        #expect(freed == 256)
        #expect(!FileManager.default.fileExists(atPath: staleTmp.path))
        #expect(!FileManager.default.fileExists(atPath: unusedCached.path))

        // Active in-flight .tmp file must still exist until download finishes
        let midClearContents = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(midClearContents.contains(where: { $0.hasSuffix(".tmp") }))

        releaseSecond.signal()
        let committedURL = try await inFlightTask.value
        let finalBytes = try Data(contentsOf: committedURL)
        #expect(finalBytes.count == 128)
    }
}
