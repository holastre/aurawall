import Foundation

public struct PixabayDecodedPage: Sendable, Equatable {
    public let items: [WallpaperItem]
    public let hasNextPage: Bool
}

public struct PixabayProvider: WallpaperSourceProvider {
    public static let defaultBaseURL = URL(string: "https://pixabay.com")!

    private static let allowedCategories: Set<String> = [
        "backgrounds", "fashion", "nature", "science", "education", "feelings",
        "health", "people", "religion", "places", "animals", "industry",
        "computer", "food", "sports", "transportation", "travel", "buildings",
        "business", "music"
    ]

    public let source: WallpaperSource = .pixabay
    public let httpClient: ProviderHTTPClient
    public let baseURL: URL

    public init(
        httpClient: ProviderHTTPClient = ProviderHTTPClient(),
        baseURL: URL = PixabayProvider.defaultBaseURL
    ) {
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    public func fetch(
        query: WallpaperQuery,
        secrets: ApiSecrets,
        customFeedURL: URL?
    ) async throws -> ProviderResult {
        try Task.checkCancellation()

        guard let apiKey = secrets.normalizedPixabayKey else {
            throw ProviderError.missingAPIKey(.pixabay)
        }

        let normalizedPage = query.normalizedPage

        switch query.mediaType {
        case .video:
            let (page, rateLimit) = try await fetchVideos(query: query, apiKey: apiKey, page: normalizedPage)
            return ProviderResult(
                source: .pixabay,
                items: page.items,
                hasNextPage: page.hasNextPage,
                errorMessage: nil,
                rateLimit: rateLimit
            )

        case .image:
            let (page, rateLimit) = try await fetchPhotos(query: query, apiKey: apiKey, page: normalizedPage)
            return ProviderResult(
                source: .pixabay,
                items: page.items,
                hasNextPage: page.hasNextPage,
                errorMessage: nil,
                rateLimit: rateLimit
            )

        case .all:
            async let videosTask: Result<(PixabayDecodedPage, ProviderRateLimitInfo?), Error> = {
                do {
                    return .success(try await fetchVideos(query: query, apiKey: apiKey, page: normalizedPage))
                } catch {
                    return .failure(error)
                }
            }()
            async let photosTask: Result<(PixabayDecodedPage, ProviderRateLimitInfo?), Error> = {
                do {
                    return .success(try await fetchPhotos(query: query, apiKey: apiKey, page: normalizedPage))
                } catch {
                    return .failure(error)
                }
            }()

            let (videosOutcome, photosOutcome) = await (videosTask, photosTask)
            try Task.checkCancellation()
            switch (videosOutcome, photosOutcome) {
            case (.success(let v), .success(let p)):
                return ProviderResult(
                    source: .pixabay,
                    items: v.0.items + p.0.items,
                    hasNextPage: v.0.hasNextPage || p.0.hasNextPage,
                    errorMessage: nil,
                    rateLimit: p.1 ?? v.1
                )
            case (.success(let v), .failure(let photoError)):
                if photoError is CancellationError {
                    throw photoError
                }
                try Task.checkCancellation()
                return ProviderResult(
                    source: .pixabay,
                    items: v.0.items,
                    hasNextPage: v.0.hasNextPage,
                    errorMessage: "Partial results (photos failed: \(photoError.localizedDescription))",
                    rateLimit: v.1
                )
            case (.failure(let videoError), .success(let p)):
                if videoError is CancellationError {
                    throw videoError
                }
                try Task.checkCancellation()
                return ProviderResult(
                    source: .pixabay,
                    items: p.0.items,
                    hasNextPage: p.0.hasNextPage,
                    errorMessage: "Partial results (videos failed: \(videoError.localizedDescription))",
                    rateLimit: p.1
                )
            case (.failure(let firstError), .failure(let secondError)):
                if firstError is CancellationError {
                    throw firstError
                }
                if secondError is CancellationError {
                    throw secondError
                }
                throw firstError
            }
        }
    }

    private func fetchVideos(
        query: WallpaperQuery,
        apiKey: String,
        page: Int
    ) async throws -> (PixabayDecodedPage, ProviderRateLimitInfo?) {
        let url = try buildURL(path: "api/videos/", isPhotos: false, query: query, apiKey: apiKey, page: page)
        do {
            let response = try await httpClient.get(url, source: .pixabay)
            let decoded = try Self.parseVideosResponse(data: response.data, page: page)
            return (decoded, response.rateLimit)
        } catch ProviderError.httpError(let statusCode, let snippet) where statusCode == 400 {
            if Self.isAuthenticationErrorSnippet(snippet) {
                throw ProviderError.unauthorized(source: .pixabay, message: snippet)
            }
            throw ProviderError.httpError(statusCode: statusCode, snippet: snippet)
        }
    }

    private func fetchPhotos(
        query: WallpaperQuery,
        apiKey: String,
        page: Int
    ) async throws -> (PixabayDecodedPage, ProviderRateLimitInfo?) {
        let url = try buildURL(path: "api/", isPhotos: true, query: query, apiKey: apiKey, page: page)
        do {
            let response = try await httpClient.get(url, source: .pixabay)
            let decoded = try Self.parsePhotosResponse(data: response.data, page: page)
            return (decoded, response.rateLimit)
        } catch ProviderError.httpError(let statusCode, let snippet) where statusCode == 400 {
            if Self.isAuthenticationErrorSnippet(snippet) {
                throw ProviderError.unauthorized(source: .pixabay, message: snippet)
            }
            throw ProviderError.httpError(statusCode: statusCode, snippet: snippet)
        }
    }

    private static func isAuthenticationErrorSnippet(_ snippet: String?) -> Bool {
        guard let snippet else { return false }
        return snippet.localizedCaseInsensitiveContains("api key")
            || snippet.localizedCaseInsensitiveContains("apikey")
            || snippet.localizedCaseInsensitiveContains("unauthorized")
    }

    public func buildURL(
        path: String,
        isPhotos: Bool,
        query: WallpaperQuery,
        apiKey: String,
        page: Int
    ) throws -> URL {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointURL = normalizedPath.isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(normalizedPath, isDirectory: true)
        guard var components = URLComponents(
            url: endpointURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderError.invalidURL(baseURL.absoluteString)
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "safesearch", value: "true"),
            URLQueryItem(name: "order", value: query.sorting == .latest ? "latest" : "popular"),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "per_page", value: "20")
        ]

        let trimmedText = query.trimmedText
        if !trimmedText.isEmpty {
            items.append(URLQueryItem(name: "q", value: String(trimmedText.prefix(100))))
        }

        if isPhotos {
            items.append(URLQueryItem(name: "image_type", value: "photo"))
            items.append(URLQueryItem(name: "orientation", value: "horizontal"))
        }

        if let category = query.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           Self.allowedCategories.contains(category) {
            items.append(URLQueryItem(name: "category", value: category))
        }

        if let (minW, minH) = Self.parseDimensions(query.minResolution) {
            items.append(URLQueryItem(name: "min_width", value: String(minW)))
            items.append(URLQueryItem(name: "min_height", value: String(minH)))
        }

        components.queryItems = items
        guard let finalURL = components.url else {
            throw ProviderError.invalidURL(components.string ?? baseURL.absoluteString)
        }
        return finalURL
    }

    public static func parseVideosResponse(data: Data, page: Int = 1) throws -> PixabayDecodedPage {
        let dto: PixabayVideosResponseDTO
        do {
            dto = try JSONDecoder().decode(PixabayVideosResponseDTO.self, from: data)
        } catch {
            throw ProviderError.decodingFailed(error.localizedDescription)
        }

        var items: [WallpaperItem] = []
        items.reserveCapacity(dto.hits.count)

        for hit in dto.hits {
            let candidates = [hit.videos.large, hit.videos.medium, hit.videos.small, hit.videos.tiny]
            guard let fullVariant = candidates.compactMap(validatedVariant).first else {
                continue
            }

            let previewCandidates = [hit.videos.small, hit.videos.tiny, hit.videos.medium]
            let previewVariant = previewCandidates.compactMap(validatedVariant).first ?? fullVariant

            let thumbnailURL = [
                fullVariant.thumbnailURL,
                ProviderURLValidator.validatedURL(from: hit.videos.medium?.thumbnail),
                ProviderURLValidator.validatedURL(from: hit.videos.small?.thumbnail),
                ProviderURLValidator.validatedURL(from: hit.videos.tiny?.thumbnail)
            ]
            .compactMap { $0 }
            .first
                ?? hit.pictureID
                    .flatMap { trimmedNonEmpty($0) }
                    .flatMap { URL(string: "https://i.vimeocdn.com/video/\($0)_640x360.jpg") }

            let tags = parseTags(hit.tags)
            let title = deriveTitle(from: tags, fallback: "Pixabay Video #\(hit.id)")
            let category = tags.first?.capitalized ?? "Video"

            items.append(
                WallpaperItem(
                    id: "pixabay-video-\(hit.id)",
                    title: title,
                    category: category,
                    source: .pixabay,
                    mediaType: .video,
                    width: fullVariant.width > 0 ? fullVariant.width : nil,
                    height: fullVariant.height > 0 ? fullVariant.height : nil,
                    fileSize: fullVariant.size > 0 ? fullVariant.size : nil,
                    duration: hit.duration.map(Double.init),
                    previewImageURL: thumbnailURL,
                    previewVideoURL: previewVariant.url,
                    fullAssetURL: fullVariant.url,
                    tags: tags
                )
            )
        }

        let hasNextPage = (max(1, page) * 20) < min(dto.totalHits, 500)
        return PixabayDecodedPage(items: items, hasNextPage: hasNextPage)
    }

    public static func parsePhotosResponse(data: Data, page: Int = 1) throws -> PixabayDecodedPage {
        let dto: PixabayPhotosResponseDTO
        do {
            dto = try JSONDecoder().decode(PixabayPhotosResponseDTO.self, from: data)
        } catch {
            throw ProviderError.decodingFailed(error.localizedDescription)
        }

        var items: [WallpaperItem] = []
        items.reserveCapacity(dto.hits.count)

        for hit in dto.hits {
            let fullAssetURL = [
                hit.imageURL,
                hit.fullHDURL,
                hit.largeImageURL,
                hit.webformatURL
            ]
            .compactMap(ProviderURLValidator.validatedURL)
            .first

            guard let fullAssetURL else {
                continue
            }

            let previewImageURL = [
                hit.webformatURL,
                hit.previewURL,
                hit.largeImageURL
            ]
            .compactMap(ProviderURLValidator.validatedURL)
            .first

            let tags = parseTags(hit.tags)
            let title = deriveTitle(from: tags, fallback: "Pixabay Photo #\(hit.id)")
            let category = tags.first?.capitalized ?? "Photography"

            items.append(
                WallpaperItem(
                    id: "pixabay-photo-\(hit.id)",
                    title: title,
                    category: category,
                    source: .pixabay,
                    mediaType: .image,
                    width: hit.imageWidth,
                    height: hit.imageHeight,
                    fileSize: hit.imageSize,
                    previewImageURL: previewImageURL,
                    previewVideoURL: nil,
                    fullAssetURL: fullAssetURL,
                    tags: tags
                )
            )
        }

        let hasNextPage = (max(1, page) * 20) < min(dto.totalHits, 500)
        return PixabayDecodedPage(items: items, hasNextPage: hasNextPage)
    }

    private struct ValidVideoVariant {
        let url: URL
        let width: Int
        let height: Int
        let size: Int64
        let thumbnailURL: URL?
    }

    private static func validatedVariant(_ variant: PixabayVideoVariantDTO?) -> ValidVideoVariant? {
        guard let variant,
              let size = variant.size,
              size > 0,
              let url = ProviderURLValidator.validatedURL(from: variant.url) else {
            return nil
        }
        return ValidVideoVariant(
            url: url,
            width: variant.width ?? 0,
            height: variant.height ?? 0,
            size: size,
            thumbnailURL: ProviderURLValidator.validatedURL(from: variant.thumbnail)
        )
    }

    private static func parseTags(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func deriveTitle(from tags: [String], fallback: String) -> String {
        let top = tags.prefix(3).map(\.capitalized)
        return top.isEmpty ? fallback : top.joined(separator: " ")
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func parseDimensions(_ raw: String?) -> (Int, Int)? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        switch trimmed {
        case "4k", "2160p":
            return (3840, 2160)
        case "1440p", "2k":
            return (2560, 1440)
        case "1080p", "fhd":
            return (1920, 1080)
        default:
            let parts = trimmed.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                return (w, h)
            }
            return nil
        }
    }
}

// MARK: - Pixabay DTOs

private struct PixabayVideosResponseDTO: Decodable {
    let total: Int?
    let totalHits: Int
    let hits: [PixabayVideoHitDTO]
}

private struct PixabayVideoHitDTO: Decodable {
    let id: Int
    let pageURL: String?
    let type: String?
    let tags: String?
    let duration: Int?
    let pictureID: String?
    let videos: PixabayVideoStreamsDTO
    let user: String?
    let userImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case pageURL
        case type
        case tags
        case duration
        case pictureID = "picture_id"
        case videos
        case user
        case userImageURL
    }
}

private struct PixabayVideoStreamsDTO: Decodable {
    let large: PixabayVideoVariantDTO?
    let medium: PixabayVideoVariantDTO?
    let small: PixabayVideoVariantDTO?
    let tiny: PixabayVideoVariantDTO?
}

private struct PixabayVideoVariantDTO: Decodable {
    let url: String?
    let width: Int?
    let height: Int?
    let size: Int64?
    let thumbnail: String?
}

private struct PixabayPhotosResponseDTO: Decodable {
    let total: Int?
    let totalHits: Int
    let hits: [PixabayPhotoHitDTO]
}

private struct PixabayPhotoHitDTO: Decodable {
    let id: Int
    let pageURL: String?
    let type: String?
    let tags: String?
    let previewURL: String?
    let webformatURL: String?
    let largeImageURL: String?
    let fullHDURL: String?
    let imageURL: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let imageSize: Int64?
    let user: String?
    let userImageURL: String?
}
