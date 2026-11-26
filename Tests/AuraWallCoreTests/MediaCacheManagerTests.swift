import Foundation
import os
import Testing
@testable import AuraWallCore

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (URLResponse, [Data])

    final class StreamSession: @unchecked Sendable {
        private struct State {
            var stopped = false
            var onStop: (@Sendable () -> Void)?
        }

        private let lock = OSAllocatedUnfairLock<State>(initialState: State())
        private weak var urlProtocol: MockURLProtocol?

        init(urlProtocol: MockURLProtocol) {
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

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])
    private static let asyncHandlers = OSAllocatedUnfairLock<[String: AsyncHandler]>(initialState: [:])
    static let testIDHeader = "X-AuraWall-Test-ID"

    private let streamLock = OSAllocatedUnfairLock<StreamSession?>(initialState: nil)

    static func register(testID: String, handler: @escaping Handler) {
        handlers.withLock { $0[testID] = handler }
    }

    static func registerAsync(testID: String, handler: @escaping AsyncHandler) {
        asyncHandlers.withLock { $0[testID] = handler }
    }

    static func unregister(testID: String) {
        _ = handlers.withLock { $0.removeValue(forKey: testID) }
        _ = asyncHandlers.withLock { $0.removeValue(forKey: testID) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: testIDHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let testID = request.value(forHTTPHeaderField: Self.testIDHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if let asyncHandler = Self.asyncHandlers.withLock({ $0[testID] }) {
            let session = StreamSession(urlProtocol: self)
            streamLock.withLock { $0 = session }
            let capturedRequest = request
            DispatchQueue.global(qos: .userInitiated).async {
                asyncHandler(capturedRequest, session)
            }
            return
        }

        guard let handler = Self.handlers.withLock({ $0[testID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, chunks) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        let session = streamLock.withLock { $0 }
        session?.markStopped()
    }
}

private final class LockedBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ initial: Value) {
        self.lock = OSAllocatedUnfairLock(initialState: initial)
    }

    func withValue<T: Sendable>(_ body: @Sendable (inout Value) -> T) -> T {
        lock.withLock(body)
    }
}

private final class AsyncSignal: Sendable {
    private let lock = OSAllocatedUnfairLock<(signaled: Bool, waiters: [CheckedContinuation<Void, Never>])>(
        initialState: (false, [])
    )

    func signal() {
        let waiters = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.signaled = true
            let w = state.waiters
            state.waiters.removeAll()
            return w
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

@Suite("MediaCacheManager Tests")
struct MediaCacheManagerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraWallCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMockSession(testID: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [MockURLProtocol.testIDHeader: testID]
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Deterministic cache path is stable, isolates sources, and sanitizes extensions")
    func deterministicCachePathBehavior() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = MediaCacheManager(cacheDirectory: tempDir)
        let url = URL(string: "https://cdn.example.com/media/clip.mov?token=abc")!

        let pexelsItem = WallpaperItem(id: "42", title: "A", source: .pexels, mediaType: .video, fullAssetURL: url)
        let pixabayItem = WallpaperItem(id: "42", title: "A", source: .pixabay, mediaType: .video, fullAssetURL: url)
        let weirdExtVideo = WallpaperItem(
            id: "43",
            title: "Weird",
            source: .starter,
            mediaType: .video,
            fullAssetURL: URL(string: "https://cdn.example.com/stream.php")!
        )
        let weirdExtImage = WallpaperItem(
            id: "44",
            title: "Weird Img",
            source: .wallhaven,
            mediaType: .image,
            fullAssetURL: URL(string: "https://cdn.example.com/image.exe")!
        )
        let noURLItem = WallpaperItem(id: "45", title: "No URL", source: .localImport, mediaType: .image)

        let path1 = await cache.deterministicCacheURL(for: pexelsItem)
        let path2 = await cache.deterministicCacheURL(for: pexelsItem)
        let pixabayPath = await cache.deterministicCacheURL(for: pixabayItem)
        let fallbackVideoPath = await cache.deterministicCacheURL(for: weirdExtVideo)
        let fallbackImagePath = await cache.deterministicCacheURL(for: weirdExtImage)

        #expect(path1 != nil)
        #expect(path1 == path2)
        #expect(path1?.pathExtension == "mov")
        #expect(pixabayPath != path1)
        #expect(fallbackVideoPath?.pathExtension == "mp4")
        #expect(fallbackImagePath?.pathExtension == "jpg")
        #expect(await cache.deterministicCacheURL(for: noURLItem) == nil)
    }

    @Test("Streaming download assembles chunks, reports monotonic progress, and hits cache on repeat")
    func streamingDownloadAndCacheHit() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testID = UUID().uuidString
        let callCount = LockedBox(0)
        let chunk1 = Data(repeating: 0xAA, count: 65_536)
        let chunk2 = Data(repeating: 0xBB, count: 65_536)
        let chunk3 = Data(repeating: 0xCC, count: 32_768)
        let totalLength = chunk1.count + chunk2.count + chunk3.count

        MockURLProtocol.register(testID: testID) { request in
            callCount.withValue { $0 += 1 }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(totalLength)"]
            )!
            return (response, [chunk1, chunk2, chunk3])
        }
        defer { MockURLProtocol.unregister(testID: testID) }

        let cache = MediaCacheManager(cacheDirectory: tempDir, urlSession: makeMockSession(testID: testID))
        let item = WallpaperItem(
            id: "starter:coastal",
            title: "Coastal",
            source: .starter,
            mediaType: .video,
            fullAssetURL: URL(string: "https://cdn.example.com/coastal.mp4")!
        )

        let reportedProgress = LockedBox<[Double]>([])
        let cachedURL = try await cache.download(item) { progress in
            reportedProgress.withValue { $0.append(progress) }
        }

        #expect(FileManager.default.fileExists(atPath: cachedURL.path))
        let downloadedData = try Data(contentsOf: cachedURL)
        #expect(downloadedData == chunk1 + chunk2 + chunk3)

        let values = reportedProgress.withValue { $0 }
        #expect(!values.isEmpty)
        #expect(values.last == 1.0)
        #expect(values.allSatisfy { !$0.isNaN && $0 >= 0.0 && $0 <= 1.0 })
        for idx in 1..<values.count {
            #expect(values[idx] >= values[idx - 1])
        }

        // Second download hits cache without hitting network
        let secondProgress = LockedBox<[Double]>([])
        let cachedURL2 = try await cache.download(item) { progress in
            secondProgress.withValue { $0.append(progress) }
        }
        #expect(cachedURL2 == cachedURL)
        #expect(callCount.withValue { $0 } == 1)
        #expect(secondProgress.withValue { $0 } == [1.0])
    }

    @Test("Streaming download handles unknown Content-Length (-1) with bounded monotonic progress")
    func streamingDownloadUnknownContentLength() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testID = UUID().uuidString
        let chunk = Data(repeating: 0x55, count: 100_000)

        MockURLProtocol.register(testID: testID) { request in
            let response = URLResponse(
                url: request.url!,
                mimeType: "video/mp4",
                expectedContentLength: -1,
                textEncodingName: nil
            )
            return (response, [chunk, chunk, chunk])
        }
        defer { MockURLProtocol.unregister(testID: testID) }

        let cache = MediaCacheManager(cacheDirectory: tempDir, urlSession: makeMockSession(testID: testID))
        let item = WallpaperItem(
            id: "unknown-len",
            title: "Stream",
            source: .customFeed,
            mediaType: .video,
            fullAssetURL: URL(string: "https://cdn.example.com/stream.mp4")!
        )

        let reported = LockedBox<[Double]>([])
        let url = try await cache.download(item) { progress in
            reported.withValue { $0.append(progress) }
        }

        #expect(try Data(contentsOf: url).count == 300_000)
        let values = reported.withValue { $0 }
        #expect(values.last == 1.0)
        #expect(values.allSatisfy { !$0.isNaN && $0 >= 0.0 && $0 <= 1.0 })
        for idx in 1..<values.count {
            #expect(values[idx] >= values[idx - 1])
        }
    }

    @Test("Failed HTTP download cleans up temporary files and throws")
    func failedHTTPDownloadCleansUpTempFiles() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testID = UUID().uuidString
        MockURLProtocol.register(testID: testID) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, [Data("Not Found".utf8)])
        }
        defer { MockURLProtocol.unregister(testID: testID) }

        let cache = MediaCacheManager(cacheDirectory: tempDir, urlSession: makeMockSession(testID: testID))
        let item = WallpaperItem(
            id: "missing-404",
            title: "Missing",
            source: .wallhaven,
            mediaType: .image,
            fullAssetURL: URL(string: "https://cdn.example.com/missing.jpg")!
        )

        await #expect(throws: MediaCacheError.invalidHTTPStatus(404)) {
            _ = try await cache.download(item)
        }

        #expect(await cache.cachedFileURL(for: item) == nil)
        #expect(await cache.totalCacheSizeBytes() == 0)
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
    }

    @Test("Concurrent duplicate downloads coalesce into one network transfer")
    func concurrentDuplicateDownloadsCoalesce() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testID = UUID().uuidString
        let networkCalls = LockedBox(0)
        let payload = Data(repeating: 0x7E, count: 128_000)

        MockURLProtocol.register(testID: testID) { request in
            networkCalls.withValue { $0 += 1 }
            // Brief deterministic sleep in protocol handler so concurrent requests overlap
            Thread.sleep(forTimeInterval: 0.05)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(payload.count)"]
            )!
            return (response, [payload])
        }
        defer { MockURLProtocol.unregister(testID: testID) }

        let cache = MediaCacheManager(cacheDirectory: tempDir, urlSession: makeMockSession(testID: testID))
        let item = WallpaperItem(
            id: "coalesce-1",
            title: "Coalesce",
            source: .pexels,
            mediaType: .video,
            fullAssetURL: URL(string: "https://cdn.example.com/coalesce.mp4")!
        )

        let p1 = LockedBox<[Double]>([])
        let p2 = LockedBox<[Double]>([])

        async let d1 = cache.download(item) { value in p1.withValue { $0.append(value) } }
        async let d2 = cache.download(item) { value in p2.withValue { $0.append(value) } }

        let (u1, u2) = try await (d1, d2)
        #expect(u1 == u2)
        #expect(networkCalls.withValue { $0 } == 1)
        #expect(p1.withValue { $0.last } == 1.0)
        #expect(p2.withValue { $0.last } == 1.0)
        #expect(try Data(contentsOf: u1) == payload)
    }

    @Test("totalCacheSizeBytes and clearCache preserve active /var vs /private/var URLs and ignore .tmp")
    func cacheSizeAndSafeClearCache() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testID = UUID().uuidString
        let activeBytes = Data(repeating: 0x11, count: 4096)
        let inactiveBytes = Data(repeating: 0x22, count: 8192)

        MockURLProtocol.register(testID: testID) { request in
            let body = request.url!.lastPathComponent == "active.mp4" ? activeBytes : inactiveBytes
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)"]
            )!
            return (response, [body])
        }
        defer { MockURLProtocol.unregister(testID: testID) }

        let cache = MediaCacheManager(cacheDirectory: tempDir, urlSession: makeMockSession(testID: testID))
        #expect(await cache.totalCacheSizeBytes() == 0)

        let activeItem = WallpaperItem(
            id: "active-1",
            title: "Active",
            source: .starter,
            mediaType: .video,
            fullAssetURL: URL(string: "https://cdn.example.com/active.mp4")!
        )
        let inactiveItem = WallpaperItem(
            id: "inactive-1",
            title: "Inactive",
            source: .wallhaven,
            mediaType: .image,
            fullAssetURL: URL(string: "https://cdn.example.com/inactive.jpg")!
        )

        let activeURL = try await cache.download(activeItem)
        let inactiveURL = try await cache.download(inactiveItem)

        // Add a stale .tmp file that should NOT be counted in totalCacheSizeBytes but SHOULD be cleaned by clearCache
        let staleTmp = tempDir.appendingPathComponent(".stale.1234.tmp")
        FileManager.default.createFile(atPath: staleTmp.path, contents: Data(repeating: 0x99, count: 512))

        #expect(await cache.totalCacheSizeBytes() == Int64(activeBytes.count + inactiveBytes.count))

        // Pass activeURL with /private prefix to verify canonical /var vs /private/var matching
        let nonCanonicalActiveURL = URL(
            fileURLWithPath: activeURL.path.hasPrefix("/private") ? String(activeURL.path.dropFirst("/private".count)) : "/private" + activeURL.path
        )

        let freed = try await cache.clearCache(preserving: [nonCanonicalActiveURL])
        #expect(freed == Int64(inactiveBytes.count))
        #expect(FileManager.default.fileExists(atPath: activeURL.path))
        #expect(!FileManager.default.fileExists(atPath: inactiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: staleTmp.path))
        #expect(await cache.totalCacheSizeBytes() == Int64(activeBytes.count))
    }

    @Test("Download without fullAssetURL throws missingAssetURL and empty body cleans up temp files")
    func missingAssetURLAndEmptyPayloadHandling() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testID = UUID().uuidString
        MockURLProtocol.register(testID: testID) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "0"]
            )!
            return (response, [])
        }
        defer { MockURLProtocol.unregister(testID: testID) }

        let cache = MediaCacheManager(cacheDirectory: tempDir, urlSession: makeMockSession(testID: testID))

        let noURLItem = WallpaperItem(id: "no-url", title: "No URL", source: .localImport, mediaType: .image)
        await #expect(throws: MediaCacheError.missingAssetURL) {
            _ = try await cache.download(noURLItem)
        }

        let emptyItem = WallpaperItem(
            id: "empty-200",
            title: "Empty",
            source: .starter,
            mediaType: .video,
            fullAssetURL: URL(string: "https://cdn.example.com/empty.mp4")!
        )
        await #expect(throws: MediaCacheError.self) {
            _ = try await cache.download(emptyItem)
        }

        let remaining = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        #expect(remaining.isEmpty)
    }

    @Test("Cancelling sole download caller allows immediate non-cancelled caller to succeed cleanly")
    func soleCallerCancellationAndImmediateReEntrySucceeds() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = Data(repeating: 0x3C, count: 65_536)
        let firstChunk = Data(payload.prefix(8_192))

        for iteration in 0..<25 {
            let testID = "reentry-\(iteration)-\(UUID().uuidString)"
            let attemptCounter = LockedBox(0)
            let firstAttemptInFlight = AsyncSignal()

            MockURLProtocol.registerAsync(testID: testID) { request, session in
                let attempt = attemptCounter.withValue { count -> Int in
                    count += 1
                    return count
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "\(payload.count)"]
                )!
                session.sendResponse(response)

                if attempt == 1 {
                    let holdUntilCancelled = DispatchSemaphore(value: 0)
                    session.setOnStop {
                        holdUntilCancelled.signal()
                    }
                    session.sendChunk(firstChunk)
                    firstAttemptInFlight.signal()
                    _ = holdUntilCancelled.wait(timeout: .now() + 5)
                    return
                }

                session.sendChunk(payload)
                session.finish()
            }
            defer { MockURLProtocol.unregister(testID: testID) }

            let cache = MediaCacheManager(cacheDirectory: tempDir, urlSession: makeMockSession(testID: testID))
            let item = WallpaperItem(
                id: "reentry-item-\(iteration)",
                title: "Reentry \(iteration)",
                source: .starter,
                mediaType: .video,
                fullAssetURL: URL(string: "https://cdn.example.com/reentry-\(iteration).mp4")!
            )

            let cancelledTask = Task {
                try await cache.download(item)
            }
            await firstAttemptInFlight.wait()
            cancelledTask.cancel()

            // Immediately start a non-cancelled caller for the same item before cancelledTask finishes unwinding
            let survivingURL = try await cache.download(item)
            #expect(try Data(contentsOf: survivingURL) == payload)

            let firstResult = await cancelledTask.result
            if case .success = firstResult {
                Issue.record("Expected first cancelled caller to fail with cancellation on iteration \(iteration)")
            }

            let tmpFiles = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".tmp") }
            #expect(tmpFiles.isEmpty)
        }
    }

    @Test("Cancelling one of two coalesced callers throws CancellationError promptly while surviving caller succeeds")
    func coalescedCallerIndividualCancellation() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testID = UUID().uuidString
        let chunk1 = Data(repeating: 0x1A, count: 65_536)
        let probeChunk = Data(repeating: 0x2B, count: 8_192)
        let probeChunkCount = 12
        let finalChunk = Data(repeating: 0x3C, count: 98_304)
        let totalPayload = chunk1 + Data(repeating: 0x2B, count: probeChunk.count * probeChunkCount) + finalChunk

        let networkCalls = LockedBox(0)
        let firstCallerStarted = AsyncSignal()
        let secondCallerScheduled = DispatchSemaphore(value: 0)
        let secondCallerJoined = AsyncSignal()
        let secondCallerSawProgress = DispatchSemaphore(value: 0)
        let allowFinalChunk = DispatchSemaphore(value: 0)

        MockURLProtocol.registerAsync(testID: testID) { request, session in
            networkCalls.withValue { $0 += 1 }
            session.setOnStop {
                secondCallerScheduled.signal()
                secondCallerSawProgress.signal()
                allowFinalChunk.signal()
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(totalPayload.count)"]
            )!
            session.sendResponse(response)
            session.sendChunk(chunk1)
            firstCallerStarted.signal()

            _ = secondCallerScheduled.wait(timeout: .now() + 5)
            guard !session.isStopped else { return }

            var sentProbeChunks = 0
            while sentProbeChunks < probeChunkCount && !session.isStopped {
                session.sendChunk(probeChunk)
                sentProbeChunks += 1
                if secondCallerSawProgress.wait(timeout: .now() + 0.02) == .success {
                    break
                }
            }

            _ = allowFinalChunk.wait(timeout: .now() + 5)
            guard !session.isStopped else { return }

            while sentProbeChunks < probeChunkCount {
                session.sendChunk(probeChunk)
                sentProbeChunks += 1
            }
            session.sendChunk(finalChunk)
            session.finish()
        }
        defer {
            secondCallerScheduled.signal()
            secondCallerSawProgress.signal()
            allowFinalChunk.signal()
            MockURLProtocol.unregister(testID: testID)
        }

        let cache = MediaCacheManager(cacheDirectory: tempDir, urlSession: makeMockSession(testID: testID))
        let item = WallpaperItem(
            id: "coalesce-cancel-1",
            title: "Coalesce Cancel",
            source: .pexels,
            mediaType: .video,
            fullAssetURL: URL(string: "https://cdn.example.com/coalesce-cancel.mp4")!
        )

        let p1 = LockedBox<[Double]>([])
        let p2 = LockedBox<[Double]>([])

        let task1 = Task {
            try await cache.download(item) { value in
                p1.withValue { $0.append(value) }
            }
        }
        await firstCallerStarted.wait()

        let task2 = Task {
            secondCallerScheduled.signal()
            return try await cache.download(item) { value in
                p2.withValue { $0.append(value) }
                secondCallerSawProgress.signal()
                secondCallerJoined.signal()
            }
        }
        await secondCallerJoined.wait()

        // Cancel task1 BEFORE allowFinalChunk is signalled: task1 must throw CancellationError promptly without waiting!
        task1.cancel()
        let task1Result = await task1.result
        switch task1Result {
        case .success(let url):
            Issue.record("Expected cancelled coalesced caller to throw CancellationError, got \(url)")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        // Now allow the shared transfer to complete for surviving caller task2
        allowFinalChunk.signal()
        let task2URL = try await task2.value

        #expect(networkCalls.withValue { $0 } == 1)
        #expect(try Data(contentsOf: task2URL) == totalPayload)
        #expect(p2.withValue { $0.last } == 1.0)
        #expect(p1.withValue { $0.last } != 1.0)

        let remainingFiles = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        #expect(remainingFiles.count == 1)
        #expect(!remainingFiles[0].lastPathComponent.hasSuffix(".tmp"))
    }
}
