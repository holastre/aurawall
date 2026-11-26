import Foundation

public enum WallpaperMediaType: String, Codable, Hashable, Sendable, CaseIterable {
    case video
    case image

    public var displayName: String {
        switch self {
        case .video: "Live Video"
        case .image: "Static Image"
        }
    }
}

public enum WallpaperSource: String, Codable, Hashable, Sendable, CaseIterable {
    case starter
    case wallhaven
    case pexels
    case pixabay
    case customFeed
    case localImport

    public var displayName: String {
        switch self {
        case .starter: "Starter"
        case .wallhaven: "Wallhaven"
        case .pexels: "Pexels"
        case .pixabay: "Pixabay"
        case .customFeed: "Custom Feed"
        case .localImport: "Local Import"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .pexels, .pixabay: true
        case .starter, .wallhaven, .customFeed, .localImport: false
        }
    }
}

public struct WallpaperItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var category: String
    public var source: WallpaperSource
    public var mediaType: WallpaperMediaType
    public var width: Int?
    public var height: Int?
    public var fileSize: Int64?
    public var duration: Double?
    public var previewImageURL: URL?
    public var previewVideoURL: URL?
    public var fullAssetURL: URL?
    public var localPath: URL?
    public var tags: [String]
    public var dominantColors: [String]
    public var createdAt: Date?

    public enum CodingKeys: String, CodingKey {
        case id
        case title
        case category
        case source
        case mediaType
        case width
        case height
        case fileSize
        case duration
        case previewImageURL
        case previewVideoURL
        case fullAssetURL
        case localPath
        case tags
        case dominantColors
        case createdAt
    }

    public init(
        id: String,
        title: String,
        category: String = "General",
        source: WallpaperSource,
        mediaType: WallpaperMediaType,
        width: Int? = nil,
        height: Int? = nil,
        fileSize: Int64? = nil,
        duration: Double? = nil,
        previewImageURL: URL? = nil,
        previewVideoURL: URL? = nil,
        fullAssetURL: URL? = nil,
        localPath: URL? = nil,
        tags: [String] = [],
        dominantColors: [String] = [],
        createdAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.source = source
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.duration = duration
        self.previewImageURL = previewImageURL
        self.previewVideoURL = previewVideoURL
        self.fullAssetURL = fullAssetURL
        self.localPath = localPath
        self.tags = tags
        self.dominantColors = dominantColors
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.category = try container.decodeIfPresent(String.self, forKey: .category) ?? "General"
        self.source = try container.decode(WallpaperSource.self, forKey: .source)
        self.mediaType = try container.decode(WallpaperMediaType.self, forKey: .mediaType)
        self.width = try container.decodeIfPresent(Int.self, forKey: .width)
        self.height = try container.decodeIfPresent(Int.self, forKey: .height)
        self.fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        self.previewImageURL = try container.decodeIfPresent(URL.self, forKey: .previewImageURL)
        self.previewVideoURL = try container.decodeIfPresent(URL.self, forKey: .previewVideoURL)
        self.fullAssetURL = try container.decodeIfPresent(URL.self, forKey: .fullAssetURL)
        self.localPath = try container.decodeIfPresent(URL.self, forKey: .localPath)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.dominantColors = try container.decodeIfPresent([String].self, forKey: .dominantColors) ?? []
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public var resolutionLabel: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    public var preferredPlaybackURL: URL? {
        localPath ?? fullAssetURL ?? previewVideoURL
    }

    public var preferredThumbnailURL: URL? {
        if let previewImageURL { return previewImageURL }
        return mediaType == .image ? (localPath ?? fullAssetURL) : nil
    }
}
