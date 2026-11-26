import Foundation

public struct LibraryState: Codable, Equatable, Sendable {
    public var favorites: [WallpaperItem]
    public var localImports: [WallpaperItem]
    public var recents: [WallpaperItem]
    public var displayConfig: DisplayConfig
    public var settings: AppSettings

    public enum CodingKeys: String, CodingKey {
        case favorites
        case localImports
        case recents
        case displayConfig
        case settings
    }

    public init(
        favorites: [WallpaperItem] = [],
        localImports: [WallpaperItem] = [],
        recents: [WallpaperItem] = [],
        displayConfig: DisplayConfig = DisplayConfig(),
        settings: AppSettings = AppSettings()
    ) {
        self.favorites = favorites
        self.localImports = localImports
        self.recents = recents
        self.displayConfig = displayConfig
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.favorites = try container.decodeIfPresent([WallpaperItem].self, forKey: .favorites) ?? []
        self.localImports = try container.decodeIfPresent([WallpaperItem].self, forKey: .localImports) ?? []
        self.recents = try container.decodeIfPresent([WallpaperItem].self, forKey: .recents) ?? []
        self.displayConfig = try container.decodeIfPresent(DisplayConfig.self, forKey: .displayConfig) ?? DisplayConfig()
        self.settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}

public actor LibraryStore {
    public let baseDirectory: URL
    public var stateFileURL: URL {
        baseDirectory.appendingPathComponent("state.json", isDirectory: false)
    }

    public private(set) var state: LibraryState = LibraryState()
    public private(set) var lastLoadWarning: String?

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = canonicalFileURL(baseDirectory)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.baseDirectory = canonicalFileURL(
                appSupport.appendingPathComponent("AuraWall", isDirectory: true)
            )
        }
    }

    @discardableResult
    public func load(recoverFromCorruption: Bool = true) async throws -> LibraryState {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stateFileURL.path) else {
            lastLoadWarning = nil
            state = LibraryState()
            return state
        }

        let data = try Data(contentsOf: stateFileURL)
        do {
            let decoded = try Self.makeDecoder().decode(LibraryState.self, from: data)
            lastLoadWarning = nil
            state = decoded
            return decoded
        } catch {
            if !recoverFromCorruption {
                throw error
            }
            let backupURL = makeCorruptBackupURL()
            try? fileManager.moveItem(at: stateFileURL, to: backupURL)
            lastLoadWarning = "Corrupt state.json backed up to \(backupURL.lastPathComponent): \(error.localizedDescription)"
            state = LibraryState()
            return state
        }
    }

    public func save() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(state)
        try data.write(to: stateFileURL, options: [.atomic])
    }

    @discardableResult
    public func toggleFavorite(_ item: WallpaperItem) -> Bool {
        if let index = state.favorites.firstIndex(where: { Self.sameIdentity($0, item) }) {
            state.favorites.remove(at: index)
            return false
        } else {
            state.favorites.insert(item, at: 0)
            return true
        }
    }

    public func isFavorite(_ item: WallpaperItem) -> Bool {
        state.favorites.contains(where: { Self.sameIdentity($0, item) })
    }

    public func recordRecent(_ item: WallpaperItem, limit: Int = 50) {
        state.recents.removeAll(where: { Self.sameIdentity($0, item) })
        guard limit > 0 else {
            state.recents.removeAll()
            return
        }
        state.recents.insert(item, at: 0)
        if state.recents.count > limit {
            state.recents.removeSubrange(limit...)
        }
    }

    public func addLocalImport(_ item: WallpaperItem) {
        let itemCanonicalPath = item.localPath.flatMap { $0.isFileURL ? canonicalFileURL($0).path : nil }
        state.localImports.removeAll { existing in
            if Self.sameIdentity(existing, item) {
                return true
            }
            if let itemCanonicalPath,
               let existingPath = existing.localPath,
               existingPath.isFileURL,
               canonicalFileURL(existingPath).path == itemCanonicalPath {
                return true
            }
            return false
        }
        state.localImports.insert(item, at: 0)
    }

    public func removeLocalImport(_ item: WallpaperItem) {
        let itemCanonicalPath = item.localPath.flatMap { $0.isFileURL ? canonicalFileURL($0).path : nil }
        state.localImports.removeAll { existing in
            if Self.sameIdentity(existing, item) {
                return true
            }
            if let itemCanonicalPath,
               let existingPath = existing.localPath,
               existingPath.isFileURL,
               canonicalFileURL(existingPath).path == itemCanonicalPath {
                return true
            }
            return false
        }
    }

    public func removeRecent(_ item: WallpaperItem) {
        let itemCanonicalPath = item.localPath.flatMap { $0.isFileURL ? canonicalFileURL($0).path : nil }
        state.recents.removeAll { existing in
            if Self.sameIdentity(existing, item) {
                return true
            }
            if let itemCanonicalPath,
               let existingPath = existing.localPath,
               existingPath.isFileURL,
               canonicalFileURL(existingPath).path == itemCanonicalPath {
                return true
            }
            return false
        }
    }

    public func updateDisplayConfig(_ config: DisplayConfig) {
        state.displayConfig = config
    }

    public func updateSettings(_ settings: AppSettings) {
        state.settings = settings
    }

    public func activeWallpaperLocalURLs() -> Set<URL> {
        let activeItems = state.displayConfig.activeWallpapers()
        var urls = Set<URL>()
        for item in activeItems {
            if let localPath = item.localPath, localPath.isFileURL {
                urls.insert(canonicalFileURL(localPath))
            }
        }
        return urls
    }

    private static func sameIdentity(_ lhs: WallpaperItem, _ rhs: WallpaperItem) -> Bool {
        lhs.source == rhs.source && lhs.id == rhs.id
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

    private func makeCorruptBackupURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: Date())
        let candidate = baseDirectory.appendingPathComponent("state.corrupt-\(timestamp).json", isDirectory: false)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return baseDirectory.appendingPathComponent("state.corrupt-\(timestamp)-\(UUID().uuidString).json", isDirectory: false)
    }
}
