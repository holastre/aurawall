import Darwin
import Foundation

public enum SecretStoreError: Error, LocalizedError, Sendable, Equatable {
    case posixError(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .posixError(let operation, let code):
            let message = String(cString: strerror(code))
            return "SecretStore \(operation) failed with errno \(code): \(message)"
        }
    }
}

public actor SecretStore {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = canonicalFileURL(fileURL)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = canonicalFileURL(
                appSupport
                    .appendingPathComponent("AuraWall", isDirectory: true)
                    .appendingPathComponent("secrets.json", isDirectory: false)
            )
        }
    }

    public func load() async throws -> ApiSecrets {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ApiSecrets()
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try Self.makeDecoder().decode(ApiSecrets.self, from: data)
        return decoded.normalized()
    }

    public func save(_ secrets: ApiSecrets) async throws {
        let normalized = secrets.normalized()
        let data = try Self.makeEncoder().encode(normalized)

        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempURL = parentDir.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        var fd: Int32 = -1
        var shouldCleanupTemp = true

        defer {
            if fd >= 0 {
                Darwin.close(fd)
            }
            if shouldCleanupTemp {
                Darwin.unlink(tempURL.path)
            }
        }

        let openFlags = O_WRONLY | O_CREAT | O_EXCL
        let mode: mode_t = S_IRUSR | S_IWUSR // 0o600
        fd = Darwin.open(tempURL.path, openFlags, mode)
        if fd < 0 {
            throw SecretStoreError.posixError(operation: "open", code: errno)
        }

        if Darwin.fchmod(fd, mode) != 0 {
            throw SecretStoreError.posixError(operation: "fchmod", code: errno)
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let bytesWritten = Darwin.write(
                    fd,
                    baseAddress.advanced(by: totalWritten),
                    rawBuffer.count - totalWritten
                )
                if bytesWritten < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SecretStoreError.posixError(operation: "write", code: errno)
                }
                totalWritten += bytesWritten
            }
        }

        if Darwin.fsync(fd) != 0 {
            throw SecretStoreError.posixError(operation: "fsync", code: errno)
        }

        if Darwin.close(fd) != 0 {
            let err = errno
            fd = -1
            throw SecretStoreError.posixError(operation: "close", code: err)
        }
        fd = -1

        if Darwin.rename(tempURL.path, fileURL.path) != 0 {
            throw SecretStoreError.posixError(operation: "rename", code: errno)
        }
        shouldCleanupTemp = false
    }

    public func clear() async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch let error as POSIXError where error.code == .ENOENT {
            return
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
