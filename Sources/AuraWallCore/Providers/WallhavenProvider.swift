import Foundation

public enum WallhavenQueryMeta: Codable, Sendable, Equatable, Hashable {
    case none
    case text(String)
    case tag(id: Int, tag: String)

    private struct TagQueryObject: Codable {
        let id: Int
        let tag: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
            return
        }
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        if let tagObject = try? container.decode(TagQueryObject.self) {
            self = .tag(id: tagObject.id, tag: tagObject.tag)
            return
        }
        throw DecodingError.typeMismatch(
            WallhavenQueryMeta.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected null, String, or {id, tag} object for Wallhaven meta.query."
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encodeNil()
        case .text(let value):
            try container.encode(value)
        case .tag(let id, let tag):
            try container.encode(TagQueryObject(id: id, tag: tag))
        }
    }
}

public struct WallhavenSearchPayload: Sendable, Equatable {
    public let items: [WallpaperItem]
    public let hasNextPage: Bool
    public let currentPage: Int
    public let lastPage: Int
    public let queryMeta: WallhavenQueryMeta?
    public let seed: String?
}

public struct WallhavenProvider: WallpaperSourceProvider {
    public static let defaultBaseURL = URL(string: "https://wallhaven.cc")!

    public let source: WallpaperSource = .wallhaven
    public let httpClient: ProviderHTTPClient
    public let baseURL: URL

    public init(
        httpClient: ProviderHTTPClient = ProviderHTTPClient(),
        baseURL: URL = WallhavenProvider.defaultBaseURL
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

        if query.mediaType == .video {
            return ProviderResult(source: .wallhaven, items: [], hasNextPage: false, errorMessage: nil)
        }

        let url = try buildSearchURL(query: query)
        var headers: [String: String] = [:]
        if let apiKey = secrets.normalizedWallhavenKey {
            headers["X-API-Key"] = apiKey
        }

        do {
            let response = try await httpClient.get(url, headers: headers, source: .wallhaven)
            let payload = try Self.decodeSearchResponse(data: response.data)
            return ProviderResult(
                source: .wallhaven,
                items: payload.items,
                hasNextPage: payload.hasNextPage,
                errorMessage: nil,
                rateLimit: response.rateLimit
            )
        } catch ProviderError.unauthorized(let src, let message) {
            throw ProviderError.unauthorized(
                source: src,
                message: Self.extractJSONErrorField(from: message) ?? message
            )
        }
    }

    public func buildSearchURL(query: WallpaperQuery) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/search"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ProviderError.invalidURL(baseURL.absoluteString)
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "purity", value: "100"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "page", value: String(query.normalizedPage))
        ]

        let rawCategory = query.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowerCategory = rawCategory.lowercased()
        let categoriesMask: String
        var extraQueryTerm: String?

        switch lowerCategory {
        case "general":
            categoriesMask = "100"
        case "anime":
            categoriesMask = "010"
        case "people":
            categoriesMask = "001"
        case "":
            categoriesMask = "111"
        default:
            categoriesMask = "111"
            extraQueryTerm = rawCategory
        }
        queryItems.append(URLQueryItem(name: "categories", value: categoriesMask))

        var searchTerms: [String] = []
        let trimmedText = query.trimmedText
        if !trimmedText.isEmpty {
            searchTerms.append(trimmedText)
        }
        if let extraQueryTerm,
           !trimmedText.localizedCaseInsensitiveContains(extraQueryTerm) {
            searchTerms.append(extraQueryTerm)
        }
        if !searchTerms.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: searchTerms.joined(separator: " ")))
        }

        switch query.sorting {
        case .trending:
            queryItems.append(URLQueryItem(name: "sorting", value: "toplist"))
            queryItems.append(URLQueryItem(name: "topRange", value: "1M"))
        case .top:
            queryItems.append(URLQueryItem(name: "sorting", value: "toplist"))
            queryItems.append(URLQueryItem(name: "topRange", value: "1y"))
        case .latest:
            queryItems.append(URLQueryItem(name: "sorting", value: "date_added"))
        case .random:
            queryItems.append(URLQueryItem(name: "sorting", value: "random"))
        }

        if let atleast = Self.normalizeMinimumResolution(query.minResolution) {
            queryItems.append(URLQueryItem(name: "atleast", value: atleast))
        }

        if let ratio = Self.normalizeAspectRatio(query.aspectRatio) {
            queryItems.append(URLQueryItem(name: "ratios", value: ratio))
        }

        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw ProviderError.invalidURL(components.string ?? baseURL.absoluteString)
        }
        return finalURL
    }

    public static func decodeSearchResponse(data: Data) throws -> WallhavenSearchPayload {
        let dto: WallhavenSearchResponseDTO
        do {
            dto = try JSONDecoder().decode(WallhavenSearchResponseDTO.self, from: data)
        } catch {
            throw ProviderError.decodingFailed(error.localizedDescription)
        }

        var items: [WallpaperItem] = []
        items.reserveCapacity(dto.data.count)

        for entry in dto.data {
            guard let fullAssetURL = ProviderURLValidator.validatedURL(from: entry.path) else {
                continue
            }

            let previewImageURL = [
                entry.thumbs?.large,
                entry.thumbs?.original,
                entry.thumbs?.small
            ]
            .compactMap(ProviderURLValidator.validatedURL)
            .first

            let categoryLabel = entry.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedCategory = (categoryLabel?.isEmpty == false) ? categoryLabel!.capitalized : "General"

            var tags: [String] = []
            if let cat = categoryLabel, !cat.isEmpty {
                tags.append(cat.lowercased())
            }
            if let purity = entry.purity?.trimmingCharacters(in: .whitespacesAndNewlines), !purity.isEmpty {
                tags.append(purity.lowercased())
            }

            let colors = (entry.colors ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            items.append(
                WallpaperItem(
                    id: entry.id,
                    title: "Wallhaven \(resolvedCategory) #\(entry.id)",
                    category: resolvedCategory,
                    source: .wallhaven,
                    mediaType: .image,
                    width: entry.dimensionX,
                    height: entry.dimensionY,
                    fileSize: entry.fileSize,
                    previewImageURL: previewImageURL,
                    previewVideoURL: nil,
                    fullAssetURL: fullAssetURL,
                    tags: tags,
                    dominantColors: colors,
                    createdAt: parseWallhavenDate(entry.createdAt)
                )
            )
        }

        let currentPage = dto.meta.currentPage.value
        let lastPage = dto.meta.lastPage.value
        return WallhavenSearchPayload(
            items: items,
            hasNextPage: currentPage < lastPage,
            currentPage: currentPage,
            lastPage: lastPage,
            queryMeta: dto.meta.query,
            seed: dto.meta.seed
        )
    }

    private static func normalizeMinimumResolution(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        switch trimmed {
        case "4k", "2160p":
            return "3840x2160"
        case "1440p", "2k":
            return "2560x1440"
        case "1080p", "fhd":
            return "1920x1080"
        default:
            let parts = trimmed.split(separator: "x", omittingEmptySubsequences: false)
            if parts.count == 2,
               let w = Int(parts[0]),
               let h = Int(parts[1]),
               w > 0,
               h > 0 {
                return "\(w)x\(h)"
            }
            return nil
        }
    }

    private static func normalizeAspectRatio(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.replacingOccurrences(of: ":", with: "x")
    }

    private static func parseWallhavenDate(_ raw: String?) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        // Local DateFormatter instance per call (no global/static DateFormatter under Swift 6).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: trimmed)
    }

    private static func extractJSONErrorField(from snippet: String?) -> String? {
        guard let snippet,
              let data = snippet.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorText = object["error"] as? String,
              !errorText.isEmpty else {
            return nil
        }
        return errorText
    }
}

// MARK: - Wallhaven DTOs

private struct WallhavenSearchResponseDTO: Decodable {
    let data: [WallhavenItemDTO]
    let meta: WallhavenMetaDTO
}

private struct WallhavenMetaDTO: Decodable {
    let currentPage: LossyInt
    let lastPage: LossyInt
    let perPage: LossyInt
    let total: LossyInt
    let query: WallhavenQueryMeta?
    let seed: String?

    enum CodingKeys: String, CodingKey {
        case currentPage = "current_page"
        case lastPage = "last_page"
        case perPage = "per_page"
        case total
        case query
        case seed
    }
}

private struct LossyInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self.value = intValue
            return
        }
        if let stringValue = try? container.decode(String.self),
           let parsed = Int(stringValue) {
            self.value = parsed
            return
        }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected Int or numeric String."
            )
        )
    }
}

private struct WallhavenItemDTO: Decodable {
    let id: String
    let url: String?
    let source: String?
    let purity: String?
    let category: String?
    let dimensionX: Int?
    let dimensionY: Int?
    let fileSize: Int64?
    let fileType: String?
    let createdAt: String?
    let colors: [String]?
    let path: String
    let thumbs: WallhavenThumbsDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case source
        case purity
        case category
        case dimensionX = "dimension_x"
        case dimensionY = "dimension_y"
        case fileSize = "file_size"
        case fileType = "file_type"
        case createdAt = "created_at"
        case colors
        case path
        case thumbs
    }
}

private struct WallhavenThumbsDTO: Decodable {
    let large: String?
    let original: String?
    let small: String?
}
