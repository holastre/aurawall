import Foundation

public enum WallpaperMediaFilter: String, Codable, Hashable, Sendable, CaseIterable {
    case all
    case video
    case image

    public var displayName: String {
        switch self {
        case .all: "All"
        case .video: "Videos"
        case .image: "Images"
        }
    }

    public func matches(_ mediaType: WallpaperMediaType) -> Bool {
        switch self {
        case .all: true
        case .video: mediaType == .video
        case .image: mediaType == .image
        }
    }
}

public enum CatalogSort: String, Codable, Hashable, Sendable, CaseIterable {
    case trending
    case latest
    case top
    case random

    public var displayName: String {
        switch self {
        case .trending: "Trending"
        case .latest: "Latest"
        case .top: "Top"
        case .random: "Random"
        }
    }
}

public struct WallpaperQuery: Sendable, Equatable, Hashable {
    public var text: String
    public var mediaType: WallpaperMediaFilter
    public var sources: Set<WallpaperSource>
    public var category: String?
    public var minResolution: String?
    public var aspectRatio: String?
    public var sorting: CatalogSort
    public var page: Int

    public init(
        text: String = "",
        mediaType: WallpaperMediaFilter = .all,
        sources: Set<WallpaperSource> = Set(WallpaperSource.allCases),
        category: String? = nil,
        minResolution: String? = nil,
        aspectRatio: String? = nil,
        sorting: CatalogSort = .trending,
        page: Int = 1
    ) {
        self.text = text
        self.mediaType = mediaType
        self.sources = sources
        self.category = category
        self.minResolution = minResolution
        self.aspectRatio = aspectRatio
        self.sorting = sorting
        self.page = page
    }

    /// Always >= 1 (prevents Wallhaven HTTP 500 HTML on page <= 0).
    public var normalizedPage: Int {
        max(1, page)
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ProviderRateLimitInfo: Sendable, Equatable, Hashable {
    public let limit: Int?
    public let remaining: Int?
    public let resetSeconds: TimeInterval?
    public let retryAfterSeconds: TimeInterval?

    public init(
        limit: Int? = nil,
        remaining: Int? = nil,
        resetSeconds: TimeInterval? = nil,
        retryAfterSeconds: TimeInterval? = nil
    ) {
        self.limit = limit
        self.remaining = remaining
        self.resetSeconds = resetSeconds
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public struct ProviderResult: Sendable, Equatable {
    public let source: WallpaperSource
    public let items: [WallpaperItem]
    public let hasNextPage: Bool
    public let errorMessage: String?
    public let rateLimit: ProviderRateLimitInfo?

    public init(
        source: WallpaperSource,
        items: [WallpaperItem],
        hasNextPage: Bool = false,
        errorMessage: String? = nil,
        rateLimit: ProviderRateLimitInfo? = nil
    ) {
        self.source = source
        self.items = items
        self.hasNextPage = hasNextPage
        self.errorMessage = errorMessage
        self.rateLimit = rateLimit
    }
}

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case missingAPIKey(WallpaperSource)
    case unauthorized(source: WallpaperSource, message: String?)
    case rateLimited(source: WallpaperSource, retryAfter: TimeInterval?, message: String?)
    case httpError(statusCode: Int, snippet: String?)
    case invalidResponse
    case decodingFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let detail):
            return "Invalid feed or endpoint URL: \(detail)"
        case .missingAPIKey(let source):
            return "\(source.displayName) requires an API key in Settings."
        case .unauthorized(let source, let message):
            if let message, !message.isEmpty {
                return "\(source.displayName) authentication failed: \(message)"
            }
            return "\(source.displayName) authentication failed (check API key)."
        case .rateLimited(let source, let retryAfter, let message):
            if let retryAfter,
               retryAfter.isFinite,
               retryAfter >= 0 {
                let rounded = retryAfter == 0 ? 0.0 : ceil(retryAfter)
                if rounded < Double(Int.max), let seconds = Int(exactly: rounded) {
                    return "\(source.displayName) rate limit exceeded (retry after \(seconds)s)."
                }
            }
            if let message, !message.isEmpty {
                return "\(source.displayName) rate limit exceeded: \(message)"
            }
            return "\(source.displayName) rate limit exceeded."
        case .httpError(let statusCode, let snippet):
            if let snippet, !snippet.isEmpty {
                return "HTTP \(statusCode): \(snippet)"
            }
            return "HTTP request failed with status \(statusCode)."
        case .invalidResponse:
            return "Received a non-HTTP response from server."
        case .decodingFailed(let detail):
            return "Failed to decode provider response: \(detail)"
        case .networkError(let detail):
            return "Network error: \(detail)"
        }
    }
}

public protocol WallpaperSourceProvider: Sendable {
    var source: WallpaperSource { get }
    func fetch(query: WallpaperQuery, secrets: ApiSecrets, customFeedURL: URL?) async throws -> ProviderResult
}
