import Foundation

public struct PexelsDecodedPage: Sendable, Equatable {
    public let items: [WallpaperItem]
    public let hasNextPage: Bool
}

public struct PexelsProvider: WallpaperSourceProvider {
    public static let defaultBaseURL = URL(string: "https://api.pexels.com")!

    public let source: WallpaperSource = .pexels
    public let httpClient: ProviderHTTPClient
    public let baseURL: URL

    public init(
        httpClient: ProviderHTTPClient = ProviderHTTPClient(),
        baseURL: URL = PexelsProvider.defaultBaseURL
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

        guard let apiKey = secrets.normalizedPexelsKey else {
            throw ProviderError.missingAPIKey(.pexels)
        }

        // Pexels uses `Authorization: <KEY>` WITHOUT any "Bearer " prefix.
        let headers = ["Authorization": apiKey]

        switch query.mediaType {
        case .video:
            let (page, rateLimit) = try await fetchVideos(query: query, headers: headers)
            return ProviderResult(
                source: .pexels,
                items: page.items,
                hasNextPage: page.hasNextPage,
                errorMessage: nil,
                rateLimit: rateLimit
            )

        case .image:
            let (page, rateLimit) = try await fetchPhotos(query: query, headers: headers)
            return ProviderResult(
                source: .pexels,
                items: page.items,
                hasNextPage: page.hasNextPage,
                errorMessage: nil,
                rateLimit: rateLimit
            )

        case .all:
            async let videosTask: Result<(PexelsDecodedPage, ProviderRateLimitInfo?), Error> = {
                do {
                    return .success(try await fetchVideos(query: query, headers: headers))
                } catch {
                    return .failure(error)
                }
            }()
            async let photosTask: Result<(PexelsDecodedPage, ProviderRateLimitInfo?), Error> = {
                do {
                    return .success(try await fetchPhotos(query: query, headers: headers))
                } catch {
                    return .failure(error)
                }
            }()

            let (videosOutcome, photosOutcome) = await (videosTask, photosTask)
            try Task.checkCancellation()
            switch (videosOutcome, photosOutcome) {
            case (.success(let v), .success(let p)):
                return ProviderResult(
                    source: .pexels,
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
                    source: .pexels,
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
                    source: .pexels,
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
        headers: [String: String]
    ) async throws -> (PexelsDecodedPage, ProviderRateLimitInfo?) {
        let url = try buildVideosURL(query: query)
        do {
            let response = try await httpClient.get(url, headers: headers, source: .pexels)
            let page = try Self.parseVideosResponse(data: response.data)
            return (page, response.rateLimit)
        } catch ProviderError.unauthorized(let src, let message) {
            throw ProviderError.unauthorized(
                source: src,
                message: Self.extractPexelsErrorMessage(from: message) ?? message
            )
        }
    }

    private func fetchPhotos(
        query: WallpaperQuery,
        headers: [String: String]
    ) async throws -> (PexelsDecodedPage, ProviderRateLimitInfo?) {
        let url = try buildPhotosURL(query: query)
        do {
            let response = try await httpClient.get(url, headers: headers, source: .pexels)
            let page = try Self.parsePhotosResponse(data: response.data)
            return (page, response.rateLimit)
        } catch ProviderError.unauthorized(let src, let message) {
            throw ProviderError.unauthorized(
                source: src,
                message: Self.extractPexelsErrorMessage(from: message) ?? message
            )
        }
    }

    public func buildVideosURL(query: WallpaperQuery) throws -> URL {
        let trimmedText = query.trimmedText
        let path = trimmedText.isEmpty ? "v1/videos/popular" : "v1/videos/search"

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderError.invalidURL(baseURL.absoluteString)
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(query.normalizedPage)),
            URLQueryItem(name: "per_page", value: "15")
        ]

        if !trimmedText.isEmpty {
            items.append(URLQueryItem(name: "query", value: trimmedText))
            items.append(URLQueryItem(name: "orientation", value: "landscape"))
        } else if let (minW, minH) = Self.parseDimensions(query.minResolution) {
            items.append(URLQueryItem(name: "min_width", value: String(minW)))
            items.append(URLQueryItem(name: "min_height", value: String(minH)))
        }

        components.queryItems = items
        guard let url = components.url else {
            throw ProviderError.invalidURL(components.string ?? baseURL.absoluteString)
        }
        return url
    }

    public func buildPhotosURL(query: WallpaperQuery) throws -> URL {
        let trimmedText = query.trimmedText
        let path = trimmedText.isEmpty ? "v1/curated" : "v1/search"

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderError.invalidURL(baseURL.absoluteString)
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(query.normalizedPage)),
            URLQueryItem(name: "per_page", value: "15")
        ]

        if !trimmedText.isEmpty {
            items.append(URLQueryItem(name: "query", value: trimmedText))
            items.append(URLQueryItem(name: "orientation", value: "landscape"))
        }

        components.queryItems = items
        guard let url = components.url else {
            throw ProviderError.invalidURL(components.string ?? baseURL.absoluteString)
        }
        return url
    }

    public static func parseVideosResponse(data: Data) throws -> PexelsDecodedPage {
        let dto: PexelsVideosResponseDTO
        do {
            dto = try JSONDecoder().decode(PexelsVideosResponseDTO.self, from: data)
        } catch {
            throw ProviderError.decodingFailed(error.localizedDescription)
        }

        var items: [WallpaperItem] = []
        items.reserveCapacity(dto.videos.count)

        for video in dto.videos {
            guard let selection = selectVideoStreams(from: video.videoFiles) else {
                continue
            }

            let previewImageURL = ProviderURLValidator.validatedURL(from: video.image)
                ?? video.videoPictures?.compactMap { ProviderURLValidator.validatedURL(from: $0.picture) }.first

            let title = deriveVideoTitle(from: video.url, userName: video.user?.name, id: video.id)

            items.append(
                WallpaperItem(
                    id: "pexels-video-\(video.id)",
                    title: title,
                    category: "Video",
                    source: .pexels,
                    mediaType: .video,
                    width: selection.fullWidth,
                    height: selection.fullHeight,
                    duration: video.duration.map(Double.init),
                    previewImageURL: previewImageURL,
                    previewVideoURL: selection.previewURL,
                    fullAssetURL: selection.fullURL,
                    tags: ["pexels", "video"]
                )
            )
        }

        let hasNextPage = dto.nextPage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return PexelsDecodedPage(items: items, hasNextPage: hasNextPage)
    }

    public static func parsePhotosResponse(data: Data) throws -> PexelsDecodedPage {
        let dto: PexelsPhotosResponseDTO
        do {
            dto = try JSONDecoder().decode(PexelsPhotosResponseDTO.self, from: data)
        } catch {
            throw ProviderError.decodingFailed(error.localizedDescription)
        }

        var items: [WallpaperItem] = []
        items.reserveCapacity(dto.photos.count)

        for photo in dto.photos {
            let fullAssetURL = [photo.src.original, photo.src.large2x, photo.src.large]
                .compactMap(ProviderURLValidator.validatedURL)
                .first
            guard let fullAssetURL else {
                continue
            }

            let previewImageURL = [
                photo.src.large,
                photo.src.medium,
                photo.src.landscape,
                photo.src.small
            ]
            .compactMap(ProviderURLValidator.validatedURL)
            .first

            let altText = photo.alt?.trimmingCharacters(in: .whitespacesAndNewlines)
            let photographer = photo.photographer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let altText, !altText.isEmpty {
                title = altText
            } else if let photographer, !photographer.isEmpty {
                title = "Photo by \(photographer)"
            } else {
                title = "Pexels Photo #\(photo.id)"
            }

            var dominantColors: [String] = []
            if let avg = photo.avgColor?.trimmingCharacters(in: .whitespacesAndNewlines), !avg.isEmpty {
                dominantColors.append(avg)
            }

            items.append(
                WallpaperItem(
                    id: "pexels-photo-\(photo.id)",
                    title: title,
                    category: "Photography",
                    source: .pexels,
                    mediaType: .image,
                    width: photo.width,
                    height: photo.height,
                    previewImageURL: previewImageURL,
                    previewVideoURL: nil,
                    fullAssetURL: fullAssetURL,
                    tags: ["pexels", "photo"],
                    dominantColors: dominantColors
                )
            )
        }

        let hasNextPage = dto.nextPage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return PexelsDecodedPage(items: items, hasNextPage: hasNextPage)
    }

    private struct VideoSelection {
        let fullURL: URL
        let fullWidth: Int
        let fullHeight: Int
        let previewURL: URL
    }

    private struct ValidVideoFile {
        let url: URL
        let width: Int
        let height: Int
        let quality: String
        let fps: Double
    }

    private static func selectVideoStreams(from files: [PexelsVideoFileDTO]) -> VideoSelection? {
        let validFiles: [ValidVideoFile] = files.compactMap { file in
            guard file.fileType?.lowercased() == "video/mp4",
                  file.quality?.lowercased() != "hls",
                  let width = file.width,
                  let height = file.height,
                  width > 0,
                  height > 0,
                  let url = ProviderURLValidator.validatedURL(from: file.link) else {
                return nil
            }
            return ValidVideoFile(
                url: url,
                width: width,
                height: height,
                quality: file.quality?.lowercased() ?? "",
                fps: file.fps ?? 0
            )
        }

        guard !validFiles.isEmpty else {
            return nil
        }

        let landscapeFiles = validFiles.filter { $0.width >= $0.height }
        let pool = landscapeFiles.isEmpty ? validFiles : landscapeFiles

        let rankedFull = pool.sorted { lhs, rhs in
            let lhsTier = qualityTier(lhs)
            let rhsTier = qualityTier(rhs)
            if lhsTier != rhsTier { return lhsTier > rhsTier }

            let lhsArea = lhs.width * lhs.height
            let rhsArea = rhs.width * rhs.height
            if lhsArea != rhsArea { return lhsArea > rhsArea }

            return lhs.fps > rhs.fps
        }

        guard let bestFull = rankedFull.first else {
            return nil
        }

        let previewFile: ValidVideoFile
        let sdFiles = pool.filter { $0.quality == "sd" }
        if !sdFiles.isEmpty {
            let preferredSD = sdFiles.filter { $0.width <= 1280 }
            if !preferredSD.isEmpty {
                previewFile = preferredSD.max(by: { $0.width * $0.height < $1.width * $1.height })!
            } else {
                previewFile = sdFiles.min(by: { $0.width * $0.height < $1.width * $1.height })!
            }
        } else if let smallest480 = pool
            .filter({ $0.width >= 480 })
            .min(by: { $0.width * $0.height < $1.width * $1.height }) {
            previewFile = smallest480
        } else {
            previewFile = pool.min(by: { $0.width * $0.height < $1.width * $1.height })!
        }

        return VideoSelection(
            fullURL: bestFull.url,
            fullWidth: bestFull.width,
            fullHeight: bestFull.height,
            previewURL: previewFile.url
        )
    }

    private static func qualityTier(_ file: ValidVideoFile) -> Int {
        if file.quality == "uhd" || file.width >= 3840 {
            return 3
        }
        if file.quality == "hd" || file.width >= 1920 {
            return 2
        }
        if file.quality == "sd" {
            return 1
        }
        return 0
    }

    private static func deriveVideoTitle(from pageURLString: String?, userName: String?, id: Int) -> String {
        if let raw = pageURLString,
           let url = URL(string: raw) {
            let slug = url.lastPathComponent
            if !slug.isEmpty && slug != "/" {
                let idSuffix = "-\(id)"
                let stripped = slug.hasSuffix(idSuffix) ? String(slug.dropLast(idSuffix.count)) : slug
                let words = stripped
                    .split(separator: "-")
                    .map { $0.capitalized }
                    .joined(separator: " ")
                if !words.isEmpty {
                    return words
                }
            }
        }
        if let userName = userName?.trimmingCharacters(in: .whitespacesAndNewlines), !userName.isEmpty {
            return "Video by \(userName)"
        }
        return "Pexels Video #\(id)"
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

    private static func extractPexelsErrorMessage(from snippet: String?) -> String? {
        guard let snippet,
              let data = snippet.data(using: .utf8),
              let dto = try? JSONDecoder().decode(PexelsErrorDTO.self, from: data) else {
            return nil
        }
        if let msg = dto.message, !msg.isEmpty {
            return msg
        }
        return dto.code
    }
}

// MARK: - Pexels DTOs

private struct PexelsErrorDTO: Decodable {
    let status: Int?
    let code: String?
    let message: String?
}

private struct PexelsVideosResponseDTO: Decodable {
    let page: Int?
    let perPage: Int?
    let totalResults: Int?
    let nextPage: String?
    let videos: [PexelsVideoDTO]

    enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case totalResults = "total_results"
        case nextPage = "next_page"
        case videos
    }
}

private struct PexelsVideoDTO: Decodable {
    let id: Int
    let width: Int?
    let height: Int?
    let url: String?
    let image: String?
    let duration: Int?
    let user: PexelsUserDTO?
    let videoFiles: [PexelsVideoFileDTO]
    let videoPictures: [PexelsVideoPictureDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case width
        case height
        case url
        case image
        case duration
        case user
        case videoFiles = "video_files"
        case videoPictures = "video_pictures"
    }
}

private struct PexelsUserDTO: Decodable {
    let id: Int?
    let name: String?
    let url: String?
}

private struct PexelsVideoFileDTO: Decodable {
    let id: Int?
    let quality: String?
    let fileType: String?
    let width: Int?
    let height: Int?
    let fps: Double?
    let link: String?

    enum CodingKeys: String, CodingKey {
        case id
        case quality
        case fileType = "file_type"
        case width
        case height
        case fps
        case link
    }
}

private struct PexelsVideoPictureDTO: Decodable {
    let id: Int?
    let picture: String?
    let nr: Int?
}

private struct PexelsPhotosResponseDTO: Decodable {
    let page: Int?
    let perPage: Int?
    let totalResults: Int?
    let nextPage: String?
    let photos: [PexelsPhotoDTO]

    enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case totalResults = "total_results"
        case nextPage = "next_page"
        case photos
    }
}

private struct PexelsPhotoDTO: Decodable {
    let id: Int
    let width: Int?
    let height: Int?
    let url: String?
    let photographer: String?
    let avgColor: String?
    let alt: String?
    let src: PexelsPhotoSrcDTO

    enum CodingKeys: String, CodingKey {
        case id
        case width
        case height
        case url
        case photographer
        case avgColor = "avg_color"
        case alt
        case src
    }
}

private struct PexelsPhotoSrcDTO: Decodable {
    let original: String?
    let large2x: String?
    let large: String?
    let medium: String?
    let small: String?
    let portrait: String?
    let landscape: String?
    let tiny: String?
}
