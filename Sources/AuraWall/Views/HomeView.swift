import SwiftUI
import AuraWallCore

struct HomeView: View {
    let coordinator: AppCoordinator

    var body: some View {
        GeometryReader { geometry in
            let heroHeight = max(440, min(560, geometry.size.height * 0.68))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    HeroCarouselView(
                        items: coordinator.heroItems,
                        coordinator: coordinator,
                        height: heroHeight
                    )

                    shelfSection(
                        title: "Live Videos",
                        items: coordinator.liveVideoShelf,
                        seeAllAction: {
                            coordinator.openExplore(source: .starter, mediaFilter: .video, sort: .trending)
                        }
                    )

                    shelfSection(
                        title: "Trending Wallhaven",
                        items: coordinator.trendingWallhavenShelf,
                        seeAllAction: {
                            coordinator.openExplore(source: .wallhaven, mediaFilter: .image, sort: .trending)
                        }
                    )

                    shelfSection(
                        title: "Recommended For You",
                        items: coordinator.recommendedShelf,
                        seeAllAction: {
                            coordinator.openExplore(source: nil, mediaFilter: .all, sort: .trending)
                        }
                    )

                    if coordinator.hasPexelsOrPixabayKeys && !coordinator.pexelsPixabayShelf.isEmpty {
                        shelfSection(
                            title: "Pexels & Pixabay",
                            items: coordinator.pexelsPixabayShelf,
                            seeAllAction: {
                                let source: WallpaperSource = coordinator.secrets.normalizedPexelsKey != nil ? .pexels : .pixabay
                                coordinator.openExplore(source: source, mediaFilter: .all, sort: .trending)
                            }
                        )
                    }

                    Spacer()
                        .frame(height: 24)
                }
            }
            .background(Theme.canvas)
        }
    }

    @ViewBuilder
    private func shelfSection(
        title: String,
        items: [WallpaperItem],
        seeAllAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)

                Button(action: seeAllAction) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.10), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .help("Explore \(title)")

                Spacer()
            }
            .padding(.horizontal, 28)

            if items.isEmpty {
                if coordinator.isLoadingHome {
                    HStack(spacing: 14) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.cardSurface)
                                .frame(width: 248, height: 140)
                                .overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .padding(.horizontal, 28)
                } else {
                    Text("No wallpapers loaded for this shelf yet.")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedText)
                        .padding(.horizontal, 28)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { item in
                            WallpaperCardView(item: item, coordinator: coordinator)
                                .frame(width: 256)
                        }
                    }
                    .padding(.horizontal, 28)
                }
            }
        }
    }
}
