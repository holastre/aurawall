import Foundation

public struct CatalogAggregateResult: Sendable, Equatable {
    public let items: [WallpaperItem]
    public let providerResults: [ProviderResult]

    public var errorsBySource: [WallpaperSource: String] {
        var errors: [WallpaperSource: String] = [:]
        for result in providerResults {
            if let message = result.errorMessage, !message.isEmpty {
                errors[result.source] = message
            }
        }
        return errors
    }

    public var hasNextPage: Bool {
        providerResults.contains(where: \.hasNextPage)
    }

    public init(items: [WallpaperItem], providerResults: [ProviderResult]) {
        self.items = items
        self.providerResults = providerResults
    }
}

public actor CatalogService {
    private let providers: [any WallpaperSourceProvider]

    public init(
        providers: [any WallpaperSourceProvider]? = nil,
        httpClient: ProviderHTTPClient = ProviderHTTPClient()
    ) {
        if let providers {
            self.providers = providers
        } else {
            self.providers = [
                StarterVideoProvider(httpClient: httpClient),
                WallhavenProvider(httpClient: httpClient),
                PexelsProvider(httpClient: httpClient),
                PixabayProvider(httpClient: httpClient),
                CustomFeedProvider(httpClient: httpClient)
            ]
        }
    }

    public func fetchCatalog(
        query: WallpaperQuery,
        secrets: ApiSecrets,
        customFeedURL: URL?
    ) async -> CatalogAggregateResult {
        var immediateResults: [(Int, ProviderResult)] = []
        var activeProviders: [(Int, any WallpaperSourceProvider)] = []

        for (idx, provider) in providers.enumerated() {
            let source = provider.source
            guard query.sources.contains(source) else {
                continue
            }

            if source == .localImport {
                continue
            }

            if source == .wallhaven && query.mediaType == .video {
                continue
            }

            if source == .starter && query.mediaType == .image {
                continue
            }

            if source == .customFeed && customFeedURL == nil {
                continue
            }

            if source.requiresAPIKey && !hasAPIKey(for: source, in: secrets) {
                if query.sources.count == 1 {
                    immediateResults.append((
                        idx,
                        ProviderResult(
                            source: source,
                            items: [],
                            hasNextPage: false,
                            errorMessage: ProviderError.missingAPIKey(source).localizedDescription
                        )
                    ))
                }
                continue
            }

            activeProviders.append((idx, provider))
        }

        var collectedResults = immediateResults

        if !activeProviders.isEmpty {
            let taskResults = await withTaskGroup(of: (Int, ProviderResult).self) { group in
                for (idx, provider) in activeProviders {
                    group.addTask {
                        do {
                            let result = try await provider.fetch(
                                query: query,
                                secrets: secrets,
                                customFeedURL: customFeedURL
                            )
                            let filteredItems = result.items.filter { query.mediaType.matches($0.mediaType) }
                            return (
                                idx,
                                ProviderResult(
                                    source: result.source,
                                    items: filteredItems,
                                    hasNextPage: result.hasNextPage,
                                    errorMessage: result.errorMessage,
                                    rateLimit: result.rateLimit
                                )
                            )
                        } catch is CancellationError {
                            return (
                                idx,
                                ProviderResult(
                                    source: provider.source,
                                    items: [],
                                    hasNextPage: false,
                                    errorMessage: nil
                                )
                            )
                        } catch {
                            return (
                                idx,
                                ProviderResult(
                                    source: provider.source,
                                    items: [],
                                    hasNextPage: false,
                                    errorMessage: error.localizedDescription
                                )
                            )
                        }
                    }
                }

                var gathered: [(Int, ProviderResult)] = []
                gathered.reserveCapacity(activeProviders.count)
                for await pair in group {
                    gathered.append(pair)
                }
                return gathered
            }
            collectedResults.append(contentsOf: taskResults)
        }

        let orderedResults = collectedResults
            .sorted(by: { $0.0 < $1.0 })
            .map(\.1)

        var mergedItems: [WallpaperItem] = []
        var seenKeys = Set<String>()

        for result in orderedResults {
            for item in result.items {
                let dedupKey = "\(item.source.rawValue)|\(item.id)"
                if seenKeys.insert(dedupKey).inserted {
                    mergedItems.append(item)
                }
            }
        }

        return CatalogAggregateResult(
            items: mergedItems,
            providerResults: orderedResults
        )
    }

    private func hasAPIKey(for source: WallpaperSource, in secrets: ApiSecrets) -> Bool {
        switch source {
        case .pexels:
            return secrets.normalizedPexelsKey != nil
        case .pixabay:
            return secrets.normalizedPixabayKey != nil
        case .wallhaven, .starter, .customFeed, .localImport:
            return true
        }
    }
}
