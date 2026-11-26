import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO

public enum LocalMediaImportError: Error, LocalizedError, Sendable, Equatable {
    case notAFileURL
    case unsupportedFormat(String)
    case emptyOrUnreadableFile
    case corruptMedia(String)

    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "not a local file URL"
        case .unsupportedFormat(let ext):
            return ext.isEmpty ? "unsupported format" : "unsupported format .\(ext)"
        case .emptyOrUnreadableFile:
            return "empty or unreadable file"
        case .corruptMedia(let detail):
            return detail
        }
    }
}

public enum LocalMediaImporter: Sendable {
    public static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "jpg", "jpeg", "png", "heic"
    ]

    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static func isSupportedExtension(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isVideoExtension(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    public static func importFile(
        from sourceURL: URL,
        importsDir: URL,
        thumbsDir: URL
    ) async throws -> WallpaperItem {
        guard sourceURL.isFileURL else {
            throw LocalMediaImportError.notAFileURL
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw LocalMediaImportError.unsupportedFormat(ext)
        }

        let canonicalSource = canonicalFileURL(sourceURL)
        let fm = FileManager.default
        guard let attrs = try? canonicalSource.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attrs.isRegularFile == true,
              let fileSizeInt = attrs.fileSize,
              fileSizeInt > 0,
              fm.isReadableFile(atPath: canonicalSource.path) else {
            throw LocalMediaImportError.emptyOrUnreadableFile
        }
        let fileSize = Int64(fileSizeInt)

        try fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

        let isVideo = videoExtensions.contains(ext)
        let contentHash = try streamingSHA256Hex(of: canonicalSource)
        let hashInput = "\(canonicalSource.path)|\(contentHash)"
        let digest = SHA256.hash(data: Data(hashInput.utf8)).map { String(format: "%02x", $0) }.joined()
        let shortID = String(digest.prefix(16))

        let rawBaseName = canonicalSource.deletingPathExtension().lastPathComponent
        let safeBaseName = sanitizeAndTruncateBaseName(rawBaseName, maxUTF8Bytes: 120)
        let destURL = importsDir.appendingPathComponent("\(shortID)_\(safeBaseName).\(ext)", isDirectory: false)
        let existedBefore = fm.fileExists(atPath: destURL.path)
        if !existedBefore {
            try fm.copyItem(at: canonicalSource, to: destURL)
        } else if !fm.contentsEqual(atPath: canonicalSource.path, andPath: destURL.path) {
            try fm.removeItem(at: destURL)
            try fm.copyItem(at: canonicalSource, to: destURL)
        }

        func cleanupOnFailure() {
            if !existedBefore {
                try? fm.removeItem(at: destURL)
            }
        }

        var width: Int?
        var height: Int?
        var duration: Double?
        var previewImageURL: URL?

        if isVideo {
            let asset = AVURLAsset(url: destURL)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .video)
            } catch {
                cleanupOnFailure()
                throw LocalMediaImportError.corruptMedia("corrupt or unreadable video file")
            }
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            guard let videoTrack = tracks.first, isPlayable else {
                cleanupOnFailure()
                throw LocalMediaImportError.corruptMedia("corrupt or unplayable video file")
            }

            if let cmDuration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(cmDuration)
                if seconds.isFinite && seconds > 0 {
                    duration = seconds
                }
            }
            let naturalSize = try? await videoTrack.load(.naturalSize)
            let transform = try? await videoTrack.load(.preferredTransform)
            if let naturalSize, let transform {
                let transformed = naturalSize.applying(transform)
                let w = Int(abs(transformed.width).rounded())
                let h = Int(abs(transformed.height).rounded())
                if w > 0 && h > 0 {
                    width = w
                    height = h
                }
            }
            if let thumbURL = try? await WallpaperEngine.extractFirstFrameStillImage(from: destURL, into: thumbsDir) {
                previewImageURL = thumbURL
            }
        } else {
            if let imageSource = CGImageSourceCreateWithURL(destURL as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            }
            let hasValidDimensions = (width ?? 0) > 0 && (height ?? 0) > 0
            guard hasValidDimensions || NSImage(contentsOf: destURL) != nil else {
                cleanupOnFailure()
                throw LocalMediaImportError.corruptMedia("corrupt or unreadable image file")
            }
            previewImageURL = destURL
        }

        return WallpaperItem(
            id: "local-\(shortID)",
            title: safeBaseName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "),
            category: "Imported",
            source: .localImport,
            mediaType: isVideo ? .video : .image,
            width: width,
            height: height,
            fileSize: fileSize,
            duration: duration,
            previewImageURL: previewImageURL,
            previewVideoURL: isVideo ? destURL : nil,
            fullAssetURL: destURL,
            localPath: destURL,
            tags: ["imported", isVideo ? "video" : "image"],
            dominantColors: [],
            createdAt: Date()
        )
    }

    private static func streamingSHA256Hex(of fileURL: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw LocalMediaImportError.emptyOrUnreadableFile
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 65_536)
            } catch {
                throw LocalMediaImportError.emptyOrUnreadableFile
            }
            guard let chunk, !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeAndTruncateBaseName(_ rawName: String, maxUTF8Bytes: Int) -> String {
        let cleaned = rawName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
            return "media"
        }

        if cleaned.utf8.count <= maxUTF8Bytes {
            return cleaned
        }

        var byteCount = 0
        var truncated = ""
        for ch in cleaned {
            let chBytes = ch.utf8.count
            if byteCount + chBytes > maxUTF8Bytes {
                break
            }
            truncated.append(ch)
            byteCount += chBytes
        }

        let trimmed = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            return "media"
        }
        return trimmed
    }
}
