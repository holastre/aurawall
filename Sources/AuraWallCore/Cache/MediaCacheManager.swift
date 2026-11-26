import CryptoKit
import Darwin
import Foundation
import os

public enum MediaCacheError: Error, LocalizedError, Sendable, Equatable {
    case missingAssetURL
    case invalidResponse
    case invalidHTTPStatus(Int)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAssetURL:
            return "Wallpaper item does not have a remote asset URL."
        case .invalidResponse:
            return "Received an invalid response while downloading media."
        case .invalidHTTPStatus(let statusCode):
            return "Media download failed with HTTP status \(statusCode)."
        case .downloadFailed(let reason):
            return "Media download failed: \(reason)"
        }
    }
}

public actor MediaCacheManager {
    private static let allowedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "jpg", "jpeg", "png", "heic", "webp"
    ]

    public let cacheDirectory: URL
    private let urlSession: URLSession

    private var inFlightDownloads: [URL: InFlightEntry] = [:]
    private var activeTempURLs: Set<URL> = []

    public init(cacheDirectory: URL? = nil, urlSession: URLSession = .shared) {
        if let cacheDirectory {
            self.cacheDirectory = canonicalFileURL(cacheDirectory)
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Caches", isDirectory: true)
            self.cacheDirectory = canonicalFileURL(
                cachesDir
                    .appendingPathComponent("AuraWall", isDirectory: true)
                    .appendingPathComponent("Media", isDirectory: true)
            )
        }
        self.urlSession = urlSession
    }

    public func deterministicCacheURL(for item: WallpaperItem) -> URL? {
        guard let fullURL = item.fullAssetURL else {
            return nil
        }
        let key = "\(item.source.rawValue)|\(item.id)|\(fullURL.absoluteString)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        let rawExtension = fullURL.pathExtension.lowercased()
        let ext: String
        if Self.allowedExtensions.contains(rawExtension) {
            ext = rawExtension
        } else {
            ext = item.mediaType == .video ? "mp4" : "jpg"
        }

        return cacheDirectory.appendingPathComponent("\(hex).\(ext)", isDirectory: false)
    }

    public func cachedFileURL(for item: WallpaperItem) -> URL? {
        guard let targetURL = deterministicCacheURL(for: item) else {
            return nil
        }
        let canonical = canonicalFileURL(targetURL)
        guard let values = try? canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            return nil
        }
        return canonical
    }

    public func download(
        _ item: WallpaperItem,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try Task.checkCancellation()

        guard let remoteURL = item.fullAssetURL else {
            throw MediaCacheError.missingAssetURL
        }

        if let existing = cachedFileURL(for: item) {
            onProgress?(1.0)
            return existing
        }

        guard let targetURL = deterministicCacheURL(for: item) else {
            throw MediaCacheError.missingAssetURL
        }
        let canonicalTarget = canonicalFileURL(targetURL)

        let waiterID = UUID()
        let progressToken = onProgress != nil ? UUID() : nil

        let entry: InFlightEntry
        if let existingEntry = inFlightDownloads[canonicalTarget],
           existingEntry.tryReserveWaiter(id: waiterID, progressToken: progressToken, onProgress: onProgress) {
            entry = existingEntry
        } else {
            if let existing = cachedFileURL(for: item) {
                onProgress?(1.0)
                return existing
            }

            let hub = ProgressHub()
            let newEntry = InFlightEntry(progressHub: hub)
            let reserved = newEntry.tryReserveWaiter(id: waiterID, progressToken: progressToken, onProgress: onProgress)
            precondition(reserved, "Fresh InFlightEntry must accept initial waiter.")
            inFlightDownloads[canonicalTarget] = newEntry

            let downloadTask = Task<URL, Error> {
                do {
                    let url = try await self.performDownload(
                        remoteURL: remoteURL,
                        canonicalTarget: canonicalTarget,
                        entryID: newEntry.id,
                        progressHub: hub
                    )
                    newEntry.complete(with: .success(url))
                    return url
                } catch {
                    newEntry.complete(with: .failure(error))
                    throw error
                }
            }
            newEntry.setTask(downloadTask)
            entry = newEntry
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                entry.attachContinuation(continuation, forWaiter: waiterID)
            }
        } onCancel: {
            entry.cancelWaiter(id: waiterID)
        }
    }

    public func totalCacheSizeBytes() async -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheDirectory.path) else {
            return 0
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for fileURL in contents {
            if fileURL.lastPathComponent.hasSuffix(".tmp") {
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    @discardableResult
    public func clearCache(preserving activeURLs: Set<URL> = []) async throws -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheDirectory.path) else {
            return 0
        }

        let preservedPaths = Set(
            activeURLs
                .filter(\.isFileURL)
                .map { canonicalFileURL($0).path }
        )

        let contents = try fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsSubdirectoryDescendants]
        )

        var freedBytes: Int64 = 0
        for fileURL in contents {
            let canonical = canonicalFileURL(fileURL)
            if fileURL.lastPathComponent.hasSuffix(".tmp") {
                if !activeTempURLs.contains(canonical) {
                    try? fileManager.removeItem(at: fileURL)
                }
                continue
            }

            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                continue
            }

            if preservedPaths.contains(canonical.path) {
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            try fileManager.removeItem(at: fileURL)
            freedBytes += size
        }
        return freedBytes
    }

    // MARK: - Internal Download Execution

    private func performDownload(
        remoteURL: URL,
        canonicalTarget: URL,
        entryID: UUID,
        progressHub: ProgressHub
    ) async throws -> URL {
        defer {
            if inFlightDownloads[canonicalTarget]?.id == entryID {
                inFlightDownloads.removeValue(forKey: canonicalTarget)
            }
        }

        try Task.checkCancellation()

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let tempURL = cacheDirectory.appendingPathComponent(
            ".\(canonicalTarget.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let canonicalTemp = canonicalFileURL(tempURL)
        activeTempURLs.insert(canonicalTemp)

        defer {
            activeTempURLs.remove(canonicalTemp)
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        guard fileManager.createFile(atPath: tempURL.path, contents: nil) else {
            throw MediaCacheError.downloadFailed("Unable to create temporary cache file.")
        }
        let fileHandle = try FileHandle(forWritingTo: tempURL)

        let request = URLRequest(url: remoteURL)
        try await Self.streamRequest(
            request,
            using: urlSession,
            to: fileHandle,
            progressHub: progressHub
        )

        try fileHandle.synchronize()
        try fileHandle.close()

        let attrs = try fileManager.attributesOfItem(atPath: tempURL.path)
        let writtenSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard writtenSize > 0 else {
            throw MediaCacheError.downloadFailed("Downloaded media file was empty.")
        }

        if Darwin.rename(tempURL.path, canonicalTarget.path) != 0 {
            let err = errno
            throw MediaCacheError.downloadFailed("Failed to commit cached file (errno \(err)).")
        }

        progressHub.emit(1.0)
        return canonicalTarget
    }

    private static func streamRequest(
        _ request: URLRequest,
        using urlSession: URLSession,
        to fileHandle: FileHandle,
        progressHub: ProgressHub
    ) async throws {
        let delegate = StreamingDownloadDelegate(fileHandle: fileHandle, progressHub: progressHub)
        let task = urlSession.dataTask(with: request)
        task.delegate = delegate

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    delegate.closeFileHandleSafely()
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                delegate.attach(continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

// MARK: - Concurrency Helpers

private final class ProgressHub: @unchecked Sendable {
    private struct Callback: Sendable {
        let token: UUID
        let handler: @Sendable (Double) -> Void
    }

    private let lock = OSAllocatedUnfairLock<[Callback]>(initialState: [])

    func add(token: UUID, callback: @escaping @Sendable (Double) -> Void) {
        lock.withLock { callbacks in
            callbacks.append(Callback(token: token, handler: callback))
        }
    }

    func remove(token: UUID) {
        lock.withLock { callbacks in
            callbacks.removeAll { $0.token == token }
        }
    }

    func emit(_ value: Double) {
        let snapshot = lock.withLock { $0 }
        for callback in snapshot {
            callback.handler(value)
        }
    }
}

private final class InFlightEntry: Sendable {
    private struct Waiter: Sendable {
        var continuation: CheckedContinuation<URL, Error>?
        var progressToken: UUID?
    }

    private struct State: Sendable {
        var task: Task<URL, Error>?
        var waiters: [UUID: Waiter] = [:]
        var cancelledWaiterIDs: Set<UUID> = []
        var result: Result<URL, Error>?
        var isCancelled: Bool = false
    }

    let id: UUID
    let progressHub: ProgressHub
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    init(id: UUID = UUID(), progressHub: ProgressHub) {
        self.id = id
        self.progressHub = progressHub
    }

    func setTask(_ task: Task<URL, Error>) {
        let shouldCancelImmediately: Bool = lock.withLock { state in
            state.task = task
            return state.isCancelled
        }
        if shouldCancelImmediately {
            task.cancel()
        }
    }

    func tryReserveWaiter(
        id waiterID: UUID,
        progressToken: UUID?,
        onProgress: (@Sendable (Double) -> Void)?
    ) -> Bool {
        let reserved: Bool = lock.withLock { state in
            guard !state.isCancelled, state.result == nil else {
                return false
            }
            if let progressToken, let onProgress {
                progressHub.add(token: progressToken, callback: onProgress)
            }
            state.waiters[waiterID] = Waiter(continuation: nil, progressToken: progressToken)
            return true
        }
        return reserved
    }

    func attachContinuation(_ continuation: CheckedContinuation<URL, Error>, forWaiter waiterID: UUID) {
        enum AttachAction {
            case stored
            case resume(Result<URL, Error>)
        }

        let action: AttachAction = lock.withLock { state in
            if state.cancelledWaiterIDs.remove(waiterID) != nil {
                return .resume(.failure(CancellationError()))
            }
            if let result = state.result {
                return .resume(result)
            }
            if state.waiters[waiterID] != nil {
                state.waiters[waiterID]?.continuation = continuation
                return .stored
            }
            return .resume(.failure(CancellationError()))
        }

        if case .resume(let result) = action {
            continuation.resume(with: result)
        }
    }

    func cancelWaiter(id waiterID: UUID) {
        let outcome: (
            continuation: CheckedContinuation<URL, Error>?,
            progressToken: UUID?,
            taskToCancel: Task<URL, Error>?
        ) = lock.withLock { state in
            guard let waiter = state.waiters.removeValue(forKey: waiterID) else {
                return (nil, nil, nil)
            }
            if waiter.continuation == nil {
                state.cancelledWaiterIDs.insert(waiterID)
            }
            let taskToCancel: Task<URL, Error>?
            if state.waiters.isEmpty, state.result == nil {
                state.isCancelled = true
                taskToCancel = state.task
            } else {
                taskToCancel = nil
            }
            return (waiter.continuation, waiter.progressToken, taskToCancel)
        }

        if let progressToken = outcome.progressToken {
            progressHub.remove(token: progressToken)
        }
        outcome.continuation?.resume(throwing: CancellationError())
        outcome.taskToCancel?.cancel()
    }

    func complete(with result: Result<URL, Error>) {
        let drained: (
            continuations: [CheckedContinuation<URL, Error>],
            progressTokens: [UUID]
        ) = lock.withLock { state in
            guard state.result == nil else {
                return ([], [])
            }
            state.result = result
            let waiters = state.waiters
            state.waiters.removeAll()
            let continuations = waiters.values.compactMap(\.continuation)
            let tokens = waiters.values.compactMap(\.progressToken)
            return (continuations, tokens)
        }

        for token in drained.progressTokens {
            progressHub.remove(token: token)
        }
        for continuation in drained.continuations {
            continuation.resume(with: result)
        }
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var fileHandle: FileHandle?
        var continuation: CheckedContinuation<Void, Error>?
        var expectedContentLength: Int64 = -1
        var bytesReceived: Int64 = 0
        var lastReportedProgress: Double = -1.0
        var terminalError: Error?
        var completed: Bool = false
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let progressHub: ProgressHub

    init(fileHandle: FileHandle, progressHub: ProgressHub) {
        self.lock = OSAllocatedUnfairLock(initialState: State(fileHandle: fileHandle))
        self.progressHub = progressHub
    }

    func attach(continuation: CheckedContinuation<Void, Error>) {
        let immediateError: Error? = lock.withLock { state in
            if state.completed {
                return state.terminalError ?? MediaCacheError.downloadFailed("Task completed before continuation attached.")
            }
            state.continuation = continuation
            return nil
        }
        if let immediateError {
            continuation.resume(throwing: immediateError)
        }
    }

    func closeFileHandleSafely() {
        let handle = lock.withLock { state -> FileHandle? in
            let fh = state.fileHandle
            state.fileHandle = nil
            return fh
        }
        try? handle?.close()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let statusError = MediaCacheError.invalidHTTPStatus(httpResponse.statusCode)
            finish(with: .failure(statusError), closeHandle: true)
            completionHandler(.cancel)
            return
        }

        let shouldEmitInitial = lock.withLock { state -> Bool in
            state.expectedContentLength = response.expectedContentLength
            if state.lastReportedProgress < 0 {
                state.lastReportedProgress = 0.0
                return true
            }
            return false
        }

        if shouldEmitInitial {
            progressHub.emit(0.0)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        enum ChunkOutcome {
            case wrote(progress: Double?)
            case failed(Error)
            case ignored
        }

        let outcome: ChunkOutcome = lock.withLock { state in
            guard !state.completed, let handle = state.fileHandle else {
                return .ignored
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                return .failed(error)
            }

            state.bytesReceived += Int64(data.count)
            let progress: Double
            if state.expectedContentLength > 0 {
                progress = min(0.999, Double(state.bytesReceived) / Double(state.expectedContentLength))
            } else {
                progress = min(0.95, 1.0 - exp(-Double(state.bytesReceived) / 5_000_000.0))
            }

            if progress - state.lastReportedProgress >= 0.01 {
                state.lastReportedProgress = progress
                return .wrote(progress: progress)
            }
            return .wrote(progress: nil)
        }

        switch outcome {
        case .wrote(let progress):
            if let progress {
                progressHub.emit(progress)
            }
        case .failed(let error):
            finish(with: .failure(error), closeHandle: true)
            dataTask.cancel()
        case .ignored:
            break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error), closeHandle: true)
        } else {
            finish(with: .success(()), closeHandle: false)
        }
    }

    private func finish(with result: Result<Void, Error>, closeHandle: Bool) {
        enum FinishAction {
            case none
            case resumeSuccess(CheckedContinuation<Void, Error>)
            case resumeFailure(CheckedContinuation<Void, Error>, Error)
        }

        let (action, handleToClose): (FinishAction, FileHandle?) = lock.withLock { state in
            if state.completed {
                return (.none, nil)
            }
            state.completed = true

            let fh: FileHandle?
            if closeHandle {
                fh = state.fileHandle
                state.fileHandle = nil
            } else {
                fh = nil
            }

            switch result {
            case .success:
                if let terminalError = state.terminalError {
                    if let cont = state.continuation {
                        state.continuation = nil
                        return (.resumeFailure(cont, terminalError), fh)
                    }
                } else if let cont = state.continuation {
                    state.continuation = nil
                    return (.resumeSuccess(cont), fh)
                }
                return (.none, fh)
            case .failure(let error):
                let finalError = state.terminalError ?? error
                state.terminalError = finalError
                if let cont = state.continuation {
                    state.continuation = nil
                    return (.resumeFailure(cont, finalError), fh)
                }
                return (.none, fh)
            }
        }

        try? handleToClose?.close()

        switch action {
        case .none:
            break
        case .resumeSuccess(let cont):
            cont.resume()
        case .resumeFailure(let cont, let error):
            cont.resume(throwing: error)
        }
    }
}
