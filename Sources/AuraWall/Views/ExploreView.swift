import SwiftUI
import AuraWallCore

struct ExploreView: View {
    @Bindable var coordinator: AppCoordinator
    @FocusState private var isSearchFocused: Bool

    private let gridColumns = [
        GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 16)
    ]

    private let quickTags = ["nature", "space", "ocean", "mountain", "abstract", "minimal", "city", "rain"]
    private let aspectRatios = ["16:9", "21:9", "16:10"]
    private let minResolutions = ["1920x1080", "2560x1440", "3840x2160"]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                    .frame(height: 68)

                searchHeader

                filterControls

                if !coordinator.exploreProviderErrors.isEmpty {
                    providerErrorsStrip
                }

                resultsSection

                if coordinator.exploreHasNextPage {
                    HStack {
                        Spacer()
                        Button {
                            coordinator.runExploreSearch(resetPage: false)
                        } label: {
                            HStack(spacing: 8) {
                                if coordinator.isLoadingExplore {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Load More")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Theme.glassFill, in: Capsule())
                            .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                        .disabled(coordinator.isLoadingExplore)
                        Spacer()
                    }
                    .padding(.top, 6)
                }

                Spacer()
                    .frame(height: 24)
            }
            .padding(.horizontal, 28)
        }
        .background(Theme.canvas)
        .onChange(of: coordinator.focusSearchTrigger) { _, _ in
            isSearchFocused = true
        }
        .onAppear {
            if coordinator.exploreItems.isEmpty && !coordinator.isLoadingExplore {
                coordinator.runExploreSearch(resetPage: true)
            }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.subtleText)
                TextField("Search Wallhaven, Starter Aerials, Pexels, Pixabay...", text: $coordinator.exploreSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .focused($isSearchFocused)
                    .onSubmit {
                        coordinator.runExploreSearch(resetPage: true)
                    }

                if !coordinator.exploreSearchText.isEmpty {
                    Button {
                        coordinator.exploreSearchText = ""
                        coordinator.runExploreSearch(resetPage: true)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.mutedText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.glassBorder, lineWidth: 0.75)
            )

            Button {
                coordinator.runExploreSearch(resetPage: true)
            } label: {
                Text("Search")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Source & Media Type row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(
                        title: "All Sources",
                        isSelected: coordinator.exploreSelectedSource == nil
                    ) {
                        coordinator.exploreSelectedSource = nil
                        coordinator.runExploreSearch(resetPage: true)
                    }

                    ForEach([WallpaperSource.starter, .wallhaven, .pexels, .pixabay, .customFeed], id: \.self) { source in
                        if source != .customFeed || coordinator.settings.validatedCustomFeedURL != nil {
                            filterChip(
                                title: source.displayName,
                                isSelected: coordinator.exploreSelectedSource == source
                            ) {
                                coordinator.exploreSelectedSource = source
                                coordinator.runExploreSearch(resetPage: true)
                            }
                        }
                    }

                    Divider()
                        .frame(height: 18)
                        .overlay(Color.white.opacity(0.15))
                        .padding(.horizontal, 4)

                    ForEach(WallpaperMediaFilter.allCases, id: \.self) { filter in
                        filterChip(
                            title: filter.displayName,
                            isSelected: coordinator.exploreMediaFilter == filter
                        ) {
                            coordinator.exploreMediaFilter = filter
                            coordinator.runExploreSearch(resetPage: true)
                        }
                    }
                }
            }

            // Sort, Ratio, Resolution & Quick Tags row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(CatalogSort.allCases, id: \.self) { sort in
                            Button {
                                coordinator.exploreSort = sort
                                coordinator.runExploreSearch(resetPage: true)
                            } label: {
                                Label(sort.displayName, systemImage: coordinator.exploreSort == sort ? "checkmark" : "")
                            }
                        }
                    } label: {
                        menuPillLabel(title: "Sort: \(coordinator.exploreSort.displayName)", icon: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Menu {
                        Button("Any Ratio") {
                            coordinator.exploreAspectRatio = nil
                            coordinator.runExploreSearch(resetPage: true)
                        }
                        ForEach(aspectRatios, id: \.self) { ratio in
                            Button(ratio) {
                                coordinator.exploreAspectRatio = ratio
                                coordinator.runExploreSearch(resetPage: true)
                            }
                        }
                    } label: {
                        menuPillLabel(
                            title: coordinator.exploreAspectRatio ?? "Ratio: Any",
                            icon: "aspectratio"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Menu {
                        Button("Any Resolution") {
                            coordinator.exploreMinResolution = nil
                            coordinator.runExploreSearch(resetPage: true)
                        }
                        ForEach(minResolutions, id: \.self) { res in
                            Button("\(res)+") {
                                coordinator.exploreMinResolution = res
                                coordinator.runExploreSearch(resetPage: true)
                            }
                        }
                    } label: {
                        menuPillLabel(
                            title: coordinator.exploreMinResolution.map { "\($0)+" } ?? "Min Res: Any",
                            icon: "4k.tv"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Divider()
                        .frame(height: 18)
                        .overlay(Color.white.opacity(0.15))
                        .padding(.horizontal, 4)

                    ForEach(quickTags, id: \.self) { tag in
                        filterChip(
                            title: "#\(tag)",
                            isSelected: coordinator.exploreSelectedTag == tag
                        ) {
                            if coordinator.exploreSelectedTag == tag {
                                coordinator.exploreSelectedTag = nil
                            } else {
                                coordinator.exploreSelectedTag = tag
                            }
                            coordinator.runExploreSearch(resetPage: true)
                        }
                    }
                }
            }
        }
    }

    private var providerErrorsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(coordinator.exploreProviderErrors.keys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                if let message = coordinator.exploreProviderErrors[source] {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.orange)
                        Text("\(source.displayName): \(message)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.88))
                        Spacer()
                        if source.requiresAPIKey {
                            Button("Open Settings") {
                                coordinator.isShowingSettings = true
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 0.75)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if coordinator.isLoadingExplore && coordinator.exploreItems.isEmpty {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(0..<8, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.cardSurface)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
        } else if coordinator.exploreItems.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.mutedText)
                Text("No matching wallpapers found")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Try clearing filters, changing source, or searching another keyword.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.subtleText)
                Button("Reset Filters") {
                    coordinator.exploreSearchText = ""
                    coordinator.exploreSelectedSource = nil
                    coordinator.exploreMediaFilter = .all
                    coordinator.exploreSelectedTag = nil
                    coordinator.exploreAspectRatio = nil
                    coordinator.exploreMinResolution = nil
                    coordinator.runExploreSearch(resetPage: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(coordinator.exploreItems) { item in
                    WallpaperCardView(item: item, coordinator: coordinator)
                }
            }
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .black : .white.opacity(0.86))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.white : Theme.glassFill,
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : Theme.glassBorder, lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
    }

    private func menuPillLabel(title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 9))
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Theme.glassFill, in: Capsule())
        .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 0.75))
    }
}
