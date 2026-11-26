import AppKit
import Foundation
import Observation
import AuraWallCore

@Observable
@MainActor
final class AppCoordinator {
    enum NavTab: String, CaseIterable, Identifiable {
        case home = "Home"
        case explore = "Explore"
        case myMedia = "My Media"

        var id: String { rawValue }
    }

    static var supportedImportExtensions: Set<String> {
        LocalMediaImporter.supportedExtensions
    }

    static var videoImportExtensions: Set<String> {
        LocalMediaImporter.videoExtensions
    }

    // MARK: - Core Services
    let libraryStore: LibraryStore
    let secretStore: SecretStore
    let mediaCacheManager: MediaCacheManager
    let catalogService: CatalogService
    let powerMonitor: PowerMonitor
    let wallpaperEngine: WallpaperEngine

    // MARK: - Navigation & Chrome State
    var selectedTab: NavTab = .home
    var isMainWindowVisible: Bool = true
    var selectedDetailItem: WallpaperItem?
    var isShowingSettings: Bool = false
    var focusSearchTrigger: UUID = UUID()
    var errorBannerMessage: String?
    var statusBannerMessage: String?
    var selectedTargetDisplayID: UInt32?

    // MARK: - Home Shelves
    var heroItems: [WallpaperItem] = []
    var liveVideoShelf: [WallpaperItem] = []
    var trendingWallhavenShelf: [WallpaperItem] = []
    var recommendedShelf: [WallpaperItem] = []
    var pexelsPixabayShelf: [WallpaperItem] = []
    var isLoadingHome: Bool = false

    // MARK: - Explore State
    var exploreItems: [WallpaperItem] = []
    var exploreSearchText: String = ""
    var exploreSelectedSource: WallpaperSource? = nil
    var exploreMediaFilter: WallpaperMediaFilter = .all
    var exploreSort: CatalogSort = .trending
    var exploreCategory: String? = nil
    var exploreAspectRatio: String? = nil
    var exploreMinResolution: String? = nil
    var exploreSelectedTag: String? = nil
    var explorePage: Int = 1
    var exploreHasNextPage: Bool = false
    var isLoadingExplore: Bool = false
    var exploreProviderErrors: [WallpaperSource: String] = [:]

    // MARK: - Library & Engine State
    var favorites: [WallpaperItem] = []
    var localImports: [WallpaperItem] = []
    var recents: [WallpaperItem] = []
    var downloadedItems: [WallpaperItem] = []
    var displayConfig: DisplayConfig = DisplayConfig()
    var settings: AppSettings = AppSettings()
    var secrets: ApiSecrets = ApiSecrets()
    var connectedDisplays: [DisplayInfo] = []
    var powerInputs: PowerInputs = PowerInputs()
    var cacheSizeBytes: Int64 = 0

    // MARK: - Download Tracking
    var activeDownloadKey: String?
    var downloadProgress: [String: Double] = [:]
    private var activeDownloadItem: WallpaperItem?

    // MARK: - Private Tasks & Observers
    private var activeDownloadTask: Task<Void, Never>?
    private var homeLoadTask: Task<Void, Never>?
    private var exploreLoadTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?
    private var homeLoadGeneration: UInt64 = 0
    private var exploreLoadGeneration: UInt64 = 0
    private var applyDownloadGeneration: UInt64 = 0
    private var screenObserver: NSObjectProtocol?
    private var hasBootstrapped: Bool = false
    private var isShutDown: Bool = false

    init(
        libraryStore: LibraryStore = LibraryStore(),
        secretStore: SecretStore = SecretStore(),
        mediaCacheManager: MediaCacheManager = MediaCacheManager(),
        catalogService: CatalogService = CatalogService(),
        powerMonitor: PowerMonitor = PowerMonitor(),
        wallpaperEngine: WallpaperEngine = WallpaperEngine()
    ) {
        self.libraryStore = libraryStore
        self.secretStore = secretStore
        self.mediaCacheManager = mediaCacheManager
        self.catalogService = catalogService
        self.powerMonitor = powerMonitor
        self.wallpaperEngine = wallpaperEngine
        self.connectedDisplays = wallpaperEngine.displayManager.displays
        self.powerInputs = powerMonitor.inputs
        self.wallpaperEngine.updatePowerInputs(self.powerInputs)
    }

    // MARK: - Computed Properties

    var primaryDisplay: DisplayInfo? {
        connectedDisplays.first(where: \.isMain) ?? connectedDisplays.first
    }

    var primaryActiveWallpaper: WallpaperItem? {
        if let primaryID = primaryDisplay?.id,
           let live = wallpaperEngine.activeWallpapers[primaryID] {
            return live
        }
        if let firstLive = wallpaperEngine.activeWallpapers.values.first {
            return firstLive
        }
        if let primaryID = primaryDisplay?.id,
           let configured = displayConfig.assignment(for: primaryID)?.wallpaper {
            return configured
        }
        return displayConfig.activeWallpapers().first
    }

    var activePowerDecision: PowerDecision {
        PowerPolicyEvaluator.aggregateDecision(
            inputs: powerInputs,
            activeVideoDisplayIDs: wallpaperEngine.activeVideoDisplayIDs,
            fallbackDisplayIDs: connectedDisplays.map(\.id)
        )
    }

    var menuBarStatusLabel: String {
        PowerPolicyEvaluator.menuBarStatusLabel(
            inputs: powerInputs,
            activeVideoDisplayIDs: wallpaperEngine.activeVideoDisplayIDs,
            fallbackDisplayIDs: connectedDisplays.map(\.id),
            primaryMediaType: primaryActiveWallpaper?.mediaType
        )
    }

    var shouldPlayHeroPreview: Bool {
        isMainWindowVisible &&
        selectedTab == .home &&
        selectedDetailItem == nil &&
        !isShowingSettings
    }

    var hasPexelsOrPixabayKeys: Bool {
        secrets.normalizedPexelsKey != nil || secrets.normalizedPixabayKey != nil
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !hasBootstrapped, !isShutDown else { return }
        hasBootstrapped = true

        // Observe screen changes separately without overwriting WallpaperEngine's DisplayManager.onDisplaysChanged.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isShutDown else { return }
                self.wallpaperEngine.displayManager.refreshDisplays()
                self.connectedDisplays = self.wallpaperEngine.displayManager.displays
                self.pruneDisconnectedTargetDisplay()
            }
        }

        // Wire PowerMonitor -> AppCoordinator + WallpaperEngine
        powerMonitor.onInputsChanged = { [weak self] inputs in
            guard let self, !self.isShutDown else { return }
            self.powerInputs = inputs
            self.wallpaperEngine.updatePowerInputs(inputs)
        }

        do {
            let loadedState = try await libraryStore.load()
            self.favorites = loadedState.favorites
            self.localImports = loadedState.localImports
            self.recents = loadedState.recents
            self.displayConfig = loadedState.displayConfig
            self.settings = loadedState.settings

            if let warning = await libraryStore.lastLoadWarning {
                self.statusBannerMessage = warning
            }
        } catch {
            self.errorBannerMessage = "Unable to load saved library state: \(error.localizedDescription)"
        }

        do {
            self.secrets = try await secretStore.load()
        } catch {
            self.secrets = ApiSecrets()
        }

        wallpaperEngine.extractFirstFrameStill = settings.extractFirstFrameStill
        powerMonitor.applySettings(settings.power)
        powerInputs = powerMonitor.inputs
        wallpaperEngine.updatePowerInputs(powerInputs)
        powerMonitor.start()

        wallpaperEngine.displayManager.refreshDisplays()
        connectedDisplays = wallpaperEngine.displayManager.displays
        pruneDisconnectedTargetDisplay()

        // Restore previously applied wallpapers that have valid local files
        wallpaperEngine.apply(config: displayConfig)

        await refreshCacheMetrics()
        await refreshDownloadedItems()

        refreshHomeShelves()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true

        homeLoadTask?.cancel()
        homeLoadTask = nil
        homeLoadGeneration &+= 1
        isLoadingHome = false

        exploreLoadTask?.cancel()
        exploreLoadTask = nil
        exploreLoadGeneration &+= 1
        isLoadingExplore = false

        cancelActiveDownload()

        statusClearTask?.cancel()
        statusClearTask = nil

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        powerMonitor.onInputsChanged = nil
        powerMonitor.stop()
        wallpaperEngine.displayManager.stopMonitoring()
        wallpaperEngine.teardownAllWindows()
    }

    // MARK: - Home & Explore Catalog Loading

    func refreshHomeShelves() {
        guard !isShutDown else { return }
        homeLoadTask?.cancel()
        homeLoadGeneration &+= 1
        let generation = homeLoadGeneration
        isLoadingHome = true

        let currentSecrets = secrets
        let customFeedURL = settings.validatedCustomFeedURL
        let includePexelsPixabay = hasPexelsOrPixabayKeys

        homeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.homeLoadGeneration == generation {
                    self.isLoadingHome = false
                }
            }

            var starterSources: Set<WallpaperSource> = [.starter]
            if customFeedURL != nil {
                starterSources.insert(.customFeed)
            }

            async let starterFuture = catalogService.fetchCatalog(
                query: WallpaperQuery(
                    mediaType: .video,
                    sources: starterSources,
                    sorting: .trending,
                    page: 1
                ),
                secrets: currentSecrets,
                customFeedURL: customFeedURL
            )

            async let wallhavenFuture = catalogService.fetchCatalog(
                query: WallpaperQuery(
                    mediaType: .image,
                    sources: [.wallhaven],
                    sorting: .trending,
                    page: 1
                ),
                secrets: currentSecrets,
                customFeedURL: nil
            )

            let starterResult = await starterFuture
            guard !Task.isCancelled, self.homeLoadGeneration == generation else { return }

            let wallhavenResult = await wallhavenFuture
            guard !Task.isCancelled, self.homeLoadGeneration == generation else { return }

            var pexelsPixabayItems: [WallpaperItem] = []
            var optHasNextPage = false
            var combinedErrors = starterResult.errorsBySource
            for (source, msg) in wallhavenResult.errorsBySource {
                combinedErrors[source] = msg
            }

            if includePexelsPixabay {
                var optionalSources: Set<WallpaperSource> = []
                if currentSecrets.normalizedPexelsKey != nil { optionalSources.insert(.pexels) }
                if currentSecrets.normalizedPixabayKey != nil { optionalSources.insert(.pixabay) }
                let optResult = await catalogService.fetchCatalog(
                    query: WallpaperQuery(
                        mediaType: .all,
                        sources: optionalSources,
                        sorting: .trending,
                        page: 1
                    ),
                    secrets: currentSecrets,
                    customFeedURL: nil
                )
                guard !Task.isCancelled, self.homeLoadGeneration == generation else { return }
                pexelsPixabayItems = optResult.items
                optHasNextPage = optResult.hasNextPage
                for (source, msg) in optResult.errorsBySource {
                    combinedErrors[source] = msg
                }
            }

            let starterItems = starterResult.items
            let wallhavenItems = wallhavenResult.items

            // Build Hero Carousel (prefer live videos, mix top Wallhaven if needed)
            var hero: [WallpaperItem] = Array(starterItems.prefix(5))
            if hero.count < 5 {
                let extra = wallhavenItems.prefix(5 - hero.count)
                hero.append(contentsOf: extra)
            }
            self.heroItems = hero
            self.liveVideoShelf = starterItems
            self.trendingWallhavenShelf = wallhavenItems
            self.pexelsPixabayShelf = pexelsPixabayItems

            // Interleave starter + wallhaven + pexels/pixabay for Recommended shelf
            var recommended: [WallpaperItem] = []
            let maxCount = max(starterItems.count, wallhavenItems.count)
            for idx in 0..<min(maxCount, 12) {
                if idx < wallhavenItems.count {
                    recommended.append(wallhavenItems[idx])
                }
                if idx < starterItems.count {
                    recommended.append(starterItems[idx])
                }
                if idx < pexelsPixabayItems.count {
                    recommended.append(pexelsPixabayItems[idx])
                }
            }
            self.recommendedShelf = Self.deduplicate(recommended)

            if self.exploreItems.isEmpty && !self.isLoadingExplore && self.exploreLoadGeneration == 0 {
                self.exploreItems = Self.deduplicate(starterItems + wallhavenItems + pexelsPixabayItems)
                self.explorePage = 1
                self.exploreHasNextPage = starterResult.hasNextPage || wallhavenResult.hasNextPage || optHasNextPage
                self.exploreProviderErrors = combinedErrors
            }

            await self.refreshDownloadedItems()
        }
    }

    func openExplore(
        source: WallpaperSource? = nil,
        mediaFilter: WallpaperMediaFilter = .all,
        sort: CatalogSort = .trending,
        focusSearch: Bool = false
    ) {
        exploreSelectedSource = source
        exploreMediaFilter = mediaFilter
        exploreSort = sort
        selectedTab = .explore
        if focusSearch {
            focusSearchTrigger = UUID()
        }
        runExploreSearch(resetPage: true)
    }

    func triggerSearchFromPill() {
        selectedTab = .explore
        focusSearchTrigger = UUID()
        if exploreItems.isEmpty {
            runExploreSearch(resetPage: true)
        }
    }

    func runExploreSearch(resetPage: Bool = true) {
        guard !isShutDown else { return }
        exploreLoadTask?.cancel()
        exploreLoadGeneration &+= 1
        let generation = exploreLoadGeneration

        if resetPage {
            explorePage = 1
        } else {
            explorePage += 1
        }

        let targetPage = explorePage
        isLoadingExplore = true

        let selectedSources: Set<WallpaperSource>
        if let explicit = exploreSelectedSource {
            selectedSources = [explicit]
        } else {
            var defaultSources: Set<WallpaperSource> = [.starter, .wallhaven]
            if secrets.normalizedPexelsKey != nil { defaultSources.insert(.pexels) }
            if secrets.normalizedPixabayKey != nil { defaultSources.insert(.pixabay) }
            if settings.validatedCustomFeedURL != nil { defaultSources.insert(.customFeed) }
            selectedSources = defaultSources
        }

        let combinedText: String
        let trimmedSearch = exploreSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag = exploreSelectedTag, !tag.isEmpty {
            combinedText = trimmedSearch.isEmpty ? tag : "\(trimmedSearch) \(tag)"
        } else {
            combinedText = trimmedSearch
        }

        let query = WallpaperQuery(
            text: combinedText,
            mediaType: exploreMediaFilter,
            sources: selectedSources,
            category: exploreCategory,
            minResolution: exploreMinResolution,
            aspectRatio: exploreAspectRatio,
            sorting: exploreSort,
            page: targetPage
        )

        let currentSecrets = secrets
        let customFeedURL = settings.validatedCustomFeedURL

        exploreLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.exploreLoadGeneration == generation {
                    self.isLoadingExplore = false
                }
            }

            let result = await self.catalogService.fetchCatalog(
                query: query,
                secrets: currentSecrets,
                customFeedURL: customFeedURL
            )
            guard !Task.isCancelled, self.exploreLoadGeneration == generation else { return }

            self.exploreProviderErrors = result.errorsBySource
            self.exploreHasNextPage = result.hasNextPage

            if targetPage == 1 {
                self.exploreItems = result.items
            } else {
                self.exploreItems = Self.deduplicate(self.exploreItems + result.items)
            }

            await self.refreshDownloadedItems()
        }
    }

    // MARK: - Wallpaper Application

    func applyWallpaper(
        _ item: WallpaperItem,
        targetDisplayID: UInt32? = nil,
        displayMode: DisplayMode? = nil,
        scaling: WallpaperScalingMode? = nil
    ) {
        guard !isShutDown else { return }

        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        applyDownloadGeneration &+= 1
        let generation = applyDownloadGeneration

        let key = itemKey(item)
        if activeDownloadKey != key {
            clearDownloadTracking()
        }

        let effectiveMode = displayMode ?? displayConfig.mode
        let validSelectedTarget = selectedTargetDisplayID.flatMap { id in
            connectedDisplays.contains(where: { $0.id == id }) ? id : nil
        }
        let effectiveDisplayID = targetDisplayID ?? validSelectedTarget ?? primaryDisplay?.id
        let effectiveScaling = scaling ?? existingScaling(for: effectiveDisplayID, mode: effectiveMode) ?? .fill

        activeDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.applyDownloadGeneration == generation {
                    self.clearDownloadTracking(ifMatching: key)
                }
            }

            do {
                let localURL = try await self.resolveLocalMediaURL(
                    for: item,
                    downloadKey: key,
                    generation: generation
                )
                guard !Task.isCancelled, self.applyDownloadGeneration == generation else { return }

                var updatedItem = item
                if let localURL {
                    updatedItem.localPath = localURL
                }

                self.wallpaperEngine.apply(
                    wallpaper: updatedItem,
                    localURL: localURL,
                    to: effectiveDisplayID,
                    mode: effectiveMode,
                    scaling: effectiveScaling
                )

                if let engineError = self.wallpaperEngine.lastErrorMessage {
                    self.errorBannerMessage = engineError
                    return
                }

                if effectiveMode == .mirrorAll {
                    self.selectedTargetDisplayID = nil
                } else if let targetDisplayID {
                    self.selectedTargetDisplayID = targetDisplayID
                } else {
                    self.pruneDisconnectedTargetDisplay()
                }

                self.updateDisplayConfigState(
                    with: updatedItem,
                    targetDisplayID: effectiveDisplayID,
                    mode: effectiveMode,
                    scaling: effectiveScaling
                )

                await self.libraryStore.updateDisplayConfig(self.displayConfig)
                await self.libraryStore.recordRecent(updatedItem)
                try? await self.libraryStore.save()

                let latestState = await self.libraryStore.state
                self.recents = latestState.recents
                await self.refreshCacheMetrics()
                await self.refreshDownloadedItems()
                self.showTransientStatus("Applied \"\(updatedItem.title)\"")
            } catch is CancellationError {
                if self.applyDownloadGeneration == generation {
                    self.clearDownloadTracking(ifMatching: key)
                }
            } catch {
                if self.applyDownloadGeneration == generation {
                    self.clearDownloadTracking(ifMatching: key)
                    self.errorBannerMessage = "Failed to apply \"\(item.title)\": \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelActiveDownload() {
        applyDownloadGeneration &+= 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        clearDownloadTracking()
    }

    func applyRandomWallpaper() {
        let pool = Self.deduplicate(
            heroItems + liveVideoShelf + trendingWallhavenShelf + recommendedShelf +
            pexelsPixabayShelf + exploreItems + favorites + localImports
        )
        guard !pool.isEmpty else {
            refreshHomeShelves()
            return
        }

        let currentKey = primaryActiveWallpaper.map(itemKey)
        let candidates = pool.filter { itemKey($0) != currentKey }
        let chosen = (candidates.isEmpty ? pool : candidates).randomElement()
        if let chosen {
            applyWallpaper(chosen)
        }
    }

    // MARK: - Power & Display Controls

    func toggleManualPause() {
        powerMonitor.setManualPause(!powerInputs.manualPause)
    }

    func toggleBatteryOverride() {
        powerMonitor.setBatteryOverride(!powerInputs.batteryOverrideActive)
    }

    func toggleDisplayMode() {
        let nextMode: DisplayMode = (displayConfig.mode == .mirrorAll) ? .independent : .mirrorAll
        syncAssignmentsForModeTransition(to: nextMode)
        displayConfig.mode = nextMode

        wallpaperEngine.apply(config: displayConfig)
        Task {
            await libraryStore.updateDisplayConfig(displayConfig)
            try? await libraryStore.save()
        }
    }

    // MARK: - Favorites

    func isFavorite(_ item: WallpaperItem) -> Bool {
        favorites.contains { $0.source == item.source && $0.id == item.id }
    }

    func toggleFavorite(_ item: WallpaperItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.libraryStore.toggleFavorite(item)
            try? await self.libraryStore.save()
            let state = await self.libraryStore.state
            self.favorites = state.favorites
        }
    }

    // MARK: - Local Media Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .mpeg4Movie,
            .quickTimeMovie,
            .jpeg,
            .png,
            .heic
        ]
        panel.message = "Select video (.mp4, .mov, .m4v) or image (.jpg, .png, .heic) wallpapers to import."

        if panel.runModal() == .OK {
            importLocalFiles(panel.urls)
        }
    }

    func importLocalFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let importsDir = await self.libraryStore.baseDirectory.appendingPathComponent("Imports", isDirectory: true)
            let thumbsDir = importsDir.appendingPathComponent("Thumbnails", isDirectory: true)

            var importedCount = 0
            var rejectedReasons: [String] = []

            for url in urls {
                guard url.isFileURL else { continue }
                do {
                    let importedItem = try await LocalMediaImporter.importFile(
                        from: url,
                        importsDir: importsDir,
                        thumbsDir: thumbsDir
                    )
                    await self.libraryStore.addLocalImport(importedItem)
                    importedCount += 1
                } catch {
                    rejectedReasons.append("\(url.lastPathComponent) (\(error.localizedDescription))")
                }
            }

            if importedCount > 0 {
                try? await self.libraryStore.save()
                let state = await self.libraryStore.state
                self.localImports = state.localImports
                self.selectedTab = .myMedia
                self.showTransientStatus("Imported \(importedCount) wallpaper\(importedCount == 1 ? "" : "s")")
            }

            if !rejectedReasons.isEmpty {
                self.errorBannerMessage = "Skipped: " + rejectedReasons.joined(separator: "; ")
            }
        }
    }

    func removeLocalImport(_ item: WallpaperItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let importsDir = await self.libraryStore.baseDirectory.appendingPathComponent("Imports", isDirectory: true)
            let thumbsDir = importsDir.appendingPathComponent("Thumbnails", isDirectory: true)

            await self.libraryStore.removeLocalImport(item)
            await self.libraryStore.removeRecent(item)
            if await self.libraryStore.isFavorite(item) {
                _ = await self.libraryStore.toggleFavorite(item)
            }
            try? await self.libraryStore.save()
            let state = await self.libraryStore.state
            self.localImports = state.localImports
            self.favorites = state.favorites
            self.recents = state.recents

            let canonicalImportsPrefix = importsDir.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let canonicalThumbsPrefix = thumbsDir.standardizedFileURL.resolvingSymlinksInPath().path + "/"

            if let localPath = item.localPath,
               localPath.isFileURL {
                let canonicalLocal = localPath.standardizedFileURL.resolvingSymlinksInPath().path
                if canonicalLocal.hasPrefix(canonicalImportsPrefix),
                   !self.isURLActivelyDisplayed(localPath) {
                    try? FileManager.default.removeItem(at: localPath)
                }
            }

            if let previewURL = item.previewImageURL,
               previewURL.isFileURL {
                let canonicalPreview = previewURL.standardizedFileURL.resolvingSymlinksInPath().path
                let referencedByRemainingImport = self.localImports.contains {
                    $0.previewImageURL?.standardizedFileURL.resolvingSymlinksInPath().path == canonicalPreview
                }
                if canonicalPreview.hasPrefix(canonicalThumbsPrefix),
                   !referencedByRemainingImport,
                   !self.isURLActivelyDisplayed(previewURL) {
                    try? FileManager.default.removeItem(at: previewURL)
                }
            }
        }
    }

    // MARK: - Settings & Cache Management

    func saveSettings(_ newSettings: AppSettings, secrets newSecrets: ApiSecrets) async throws {
        let normalizedSecrets = newSecrets.normalized()
        let oldCustomFeed = settings.validatedCustomFeedURL
        let oldSecrets = secrets

        try await secretStore.save(normalizedSecrets)
        await libraryStore.updateSettings(newSettings)
        try await libraryStore.save()

        self.secrets = normalizedSecrets
        self.settings = newSettings
        self.wallpaperEngine.extractFirstFrameStill = newSettings.extractFirstFrameStill
        self.powerMonitor.applySettings(newSettings.power)

        if oldSecrets != normalizedSecrets || oldCustomFeed != newSettings.validatedCustomFeedURL {
            refreshHomeShelves()
        }
        showTransientStatus("Settings saved")
    }

    func clearUnusedCache() async throws -> Int64 {
        var preserved = await libraryStore.activeWallpaperLocalURLs()
        for item in wallpaperEngine.activeWallpapers.values {
            if let localPath = item.localPath, localPath.isFileURL {
                preserved.insert(localPath)
            }
        }
        for item in displayConfig.activeWallpapers() {
            if let localPath = item.localPath, localPath.isFileURL {
                preserved.insert(localPath)
            }
        }
        for item in localImports {
            if let localPath = item.localPath, localPath.isFileURL {
                preserved.insert(localPath)
            }
        }
        if let activeDownloadItem,
           let pendingURL = await mediaCacheManager.deterministicCacheURL(for: activeDownloadItem) {
            preserved.insert(pendingURL)
        }

        do {
            let freed = try await mediaCacheManager.clearCache(preserving: preserved)
            await refreshCacheMetrics()
            await refreshDownloadedItems()
            showTransientStatus("Cleared \(Theme.formatFileSize(freed)) of unused cache")
            return freed
        } catch {
            errorBannerMessage = "Failed to clear cache: \(error.localizedDescription)"
            throw error
        }
    }

    func refreshCacheMetrics() async {
        cacheSizeBytes = await mediaCacheManager.totalCacheSizeBytes()
    }

    func refreshDownloadedItems() async {
        let candidates = Self.deduplicate(
            recents + favorites + heroItems + liveVideoShelf +
            trendingWallhavenShelf + recommendedShelf + pexelsPixabayShelf +
            exploreItems + displayConfig.activeWallpapers()
        )
        var downloaded: [WallpaperItem] = []
        for var item in candidates where item.source != .localImport {
            if let localPath = item.localPath, Self.isReadableNonEmptyFile(localPath) {
                downloaded.append(item)
            } else if let cached = await mediaCacheManager.cachedFileURL(for: item) {
                item.localPath = cached
                downloaded.append(item)
            }
        }
        self.downloadedItems = downloaded
    }

    // MARK: - Helpers

    func itemKey(_ item: WallpaperItem) -> String {
        "\(item.source.rawValue)|\(item.id)"
    }

    func progress(for item: WallpaperItem) -> Double? {
        let key = itemKey(item)
        guard activeDownloadKey == key else { return nil }
        return downloadProgress[key]
    }

    func dismissError() {
        errorBannerMessage = nil
    }

    private func showTransientStatus(_ message: String) {
        statusBannerMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.0))
            guard !Task.isCancelled, let self else { return }
            if self.statusBannerMessage == message {
                self.statusBannerMessage = nil
            }
        }
    }

    private func clearDownloadTracking(ifMatching key: String? = nil) {
        if let key {
            downloadProgress.removeValue(forKey: key)
            if activeDownloadKey == key {
                activeDownloadKey = nil
                activeDownloadItem = nil
            }
        } else {
            activeDownloadKey = nil
            activeDownloadItem = nil
            downloadProgress.removeAll()
        }
    }

    private func pruneDisconnectedTargetDisplay() {
        if let targetID = selectedTargetDisplayID,
           !connectedDisplays.contains(where: { $0.id == targetID }) {
            selectedTargetDisplayID = nil
        }
    }

    private func resolveLocalMediaURL(
        for item: WallpaperItem,
        downloadKey: String,
        generation: UInt64
    ) async throws -> URL? {
        try Task.checkCancellation()
        guard applyDownloadGeneration == generation else {
            throw CancellationError()
        }

        if let localPath = item.localPath, Self.isReadableNonEmptyFile(localPath) {
            clearDownloadTracking(ifMatching: downloadKey)
            return localPath
        }
        let cached = await mediaCacheManager.cachedFileURL(for: item)
        try Task.checkCancellation()
        guard applyDownloadGeneration == generation else {
            throw CancellationError()
        }
        if let cached {
            clearDownloadTracking(ifMatching: downloadKey)
            return cached
        }
        guard item.fullAssetURL != nil else {
            clearDownloadTracking(ifMatching: downloadKey)
            return item.previewVideoURL
        }

        activeDownloadKey = downloadKey
        activeDownloadItem = item
        downloadProgress[downloadKey] = 0.0

        let downloadedURL = try await mediaCacheManager.download(item) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self,
                      self.applyDownloadGeneration == generation,
                      self.activeDownloadKey == downloadKey else { return }
                self.downloadProgress[downloadKey] = progress
            }
        }
        if self.applyDownloadGeneration == generation {
            clearDownloadTracking(ifMatching: downloadKey)
        }
        return downloadedURL
    }

    private func existingScaling(for displayID: UInt32?, mode: DisplayMode? = nil) -> WallpaperScalingMode? {
        let effectiveMode = mode ?? displayConfig.mode
        switch effectiveMode {
        case .mirrorAll:
            return displayConfig.assignments[DisplayConfig.mirrorAssignmentKey]?.scalingMode
        case .independent:
            guard let id = displayID ?? primaryDisplay?.id else { return nil }
            return displayConfig.assignments[DisplayConfig.key(for: id)]?.scalingMode
        }
    }

    private func syncAssignmentsForModeTransition(to nextMode: DisplayMode) {
        switch nextMode {
        case .independent:
            if let mirror = displayConfig.assignments[DisplayConfig.mirrorAssignmentKey]
                ?? displayConfig.assignments[DisplayConfig.primaryAssignmentKey],
               mirror.wallpaper != nil {
                let primaryID = primaryDisplay?.id
                for display in connectedDisplays {
                    let key = DisplayConfig.key(for: display.id)
                    if display.id == primaryID || displayConfig.assignments[key]?.wallpaper == nil {
                        displayConfig.assignments[key] = DisplayAssignment(
                            displayID: display.id,
                            displayName: display.name,
                            wallpaper: mirror.wallpaper,
                            scalingMode: mirror.scalingMode
                        )
                    }
                }
            }
        case .mirrorAll:
            let sourceAssignment: DisplayAssignment? = {
                if let primary = primaryDisplay,
                   let primaryAssignment = displayConfig.assignments[DisplayConfig.key(for: primary.id)],
                   primaryAssignment.wallpaper != nil {
                    return primaryAssignment
                }
                for display in connectedDisplays {
                    if let assignment = displayConfig.assignments[DisplayConfig.key(for: display.id)],
                       assignment.wallpaper != nil {
                        return assignment
                    }
                }
                return nil
            }()

            if let sourceAssignment {
                displayConfig.assignments[DisplayConfig.mirrorAssignmentKey] = DisplayAssignment(
                    displayID: 0,
                    displayName: "Mirror",
                    wallpaper: sourceAssignment.wallpaper,
                    scalingMode: sourceAssignment.scalingMode
                )
            }
        }
    }

    private func updateDisplayConfigState(
        with item: WallpaperItem,
        targetDisplayID: UInt32?,
        mode: DisplayMode,
        scaling: WallpaperScalingMode
    ) {
        if mode != displayConfig.mode {
            syncAssignmentsForModeTransition(to: mode)
            displayConfig.mode = mode
        }

        switch mode {
        case .mirrorAll:
            displayConfig.assignments[DisplayConfig.mirrorAssignmentKey] = DisplayAssignment(
                displayID: 0,
                displayName: "Mirror",
                wallpaper: item,
                scalingMode: scaling
            )
        case .independent:
            let resolvedID = targetDisplayID ?? primaryDisplay?.id ?? 0
            let name = connectedDisplays.first(where: { $0.id == resolvedID })?.name ?? "Display \(resolvedID)"
            displayConfig.assignments[DisplayConfig.key(for: resolvedID)] = DisplayAssignment(
                displayID: resolvedID,
                displayName: name,
                wallpaper: item,
                scalingMode: scaling
            )
        }
    }

    private func isURLActivelyDisplayed(_ url: URL) -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        for item in wallpaperEngine.activeWallpapers.values {
            if item.localPath?.standardizedFileURL.resolvingSymlinksInPath().path == canonical ||
               item.previewImageURL?.standardizedFileURL.resolvingSymlinksInPath().path == canonical {
                return true
            }
        }
        for item in displayConfig.activeWallpapers() {
            if item.localPath?.standardizedFileURL.resolvingSymlinksInPath().path == canonical ||
               item.previewImageURL?.standardizedFileURL.resolvingSymlinksInPath().path == canonical {
                return true
            }
        }
        return false
    }

    private static func isReadableNonEmptyFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func deduplicate(_ items: [WallpaperItem]) -> [WallpaperItem] {
        var seen = Set<String>()
        var output: [WallpaperItem] = []
        output.reserveCapacity(items.count)
        for item in items {
            let key = "\(item.source.rawValue)|\(item.id)"
            if seen.insert(key).inserted {
                output.append(item)
            }
        }
        return output
    }
}
