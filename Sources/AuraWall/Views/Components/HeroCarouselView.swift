import SwiftUI
import AuraWallCore

struct HeroCarouselView: View {
    private enum TargetDisplaySelection: Equatable {
        case mirrorAll
        case display(UInt32)
    }

    let items: [WallpaperItem]
    let coordinator: AppCoordinator
    let height: CGFloat

    @ViewState private var currentIndex: Int = 0
    @ViewState private var selectedTarget: TargetDisplaySelection? = nil

    private var currentItem: WallpaperItem? {
        guard !items.isEmpty else { return nil }
        let safeIndex = ((currentIndex % items.count) + items.count) % items.count
        return items[safeIndex]
    }

    var body: some View {
        ZStack {
            Theme.canvas

            if let item = currentItem {
                heroArtwork(for: item)
                heroGradients
                navigationChevrons
                heroOverlayContent(for: item)
            } else {
                emptyHeroPlaceholder
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .onChange(of: items.count) { _, newCount in
            if newCount > 0 && currentIndex >= newCount {
                currentIndex = 0
            }
        }
        .onChange(of: coordinator.displayConfig.mode) { _, _ in
            selectedTarget = nil
        }
        .onChange(of: coordinator.connectedDisplays) { _, newDisplays in
            if case .display(let id) = selectedTarget,
               !newDisplays.contains(where: { $0.id == id }) {
                selectedTarget = nil
            }
        }
        .onChange(of: coordinator.selectedTargetDisplayID) { _, newTargetID in
            if let newTargetID {
                if coordinator.connectedDisplays.contains(where: { $0.id == newTargetID }) {
                    selectedTarget = .display(newTargetID)
                } else {
                    selectedTarget = nil
                }
            } else if case .display = selectedTarget {
                selectedTarget = nil
            }
        }
    }

    @ViewBuilder
    private func heroArtwork(for item: WallpaperItem) -> some View {
        ZStack {
            WallpaperThumbnailView(
                url: item.preferredThumbnailURL,
                fallbackTitle: item.title
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if item.mediaType == .video, let videoURL = item.previewVideoURL ?? item.localPath ?? item.fullAssetURL {
                VideoPreviewPlayerView(
                    url: videoURL,
                    isPlaying: coordinator.shouldPlayHeroPreview
                )
                .id(coordinator.itemKey(item))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var heroGradients: some View {
        ZStack {
            // Top subtle vignette for floating glass nav bar contrast
            LinearGradient(
                colors: [
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .center
            )

            // Left vignette for title and metadata contrast
            LinearGradient(
                colors: [
                    Theme.canvas.opacity(0.68),
                    Theme.canvas.opacity(0.22),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            // Bottom seamless fade into obsidian canvas
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: Theme.canvas.opacity(0.55), location: 0.72),
                    .init(color: Theme.canvas.opacity(0.92), location: 0.90),
                    .init(color: Theme.canvas, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var navigationChevrons: some View {
        if items.count > 1 {
            HStack {
                Button {
                    stepCarousel(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(Color.black.opacity(0.25), in: Circle())
                        .overlay(Circle().stroke(Theme.glassBorder, lineWidth: 0.75))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    stepCarousel(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(Color.black.opacity(0.25), in: Circle())
                        .overlay(Circle().stroke(Theme.glassBorder, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
        }
    }

    private func heroOverlayContent(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(item.category.uppercased())
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.76))

                    if item.mediaType == .video {
                        Label("LIVE", systemImage: "play.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                }

                Text(item.title)
                    .font(.system(size: 36, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

                Text(Theme.metadataLine(for: item))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))

                HStack(spacing: 10) {
                    applyButton(for: item)

                    if coordinator.connectedDisplays.count > 1 || effectiveDisplayMode == .independent {
                        displayPickerMenu
                    }

                    Button {
                        coordinator.toggleFavorite(item)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: coordinator.isFavorite(item) ? "heart.fill" : "heart")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(coordinator.isFavorite(item) ? Color.pink : .white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Theme.glassFill, in: Capsule())
                        .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .help(coordinator.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites")

                    Button {
                        coordinator.selectedDetailItem = item
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .background(Theme.glassFill, in: Circle())
                            .overlay(Circle().stroke(Theme.glassBorder, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Wallpaper details & scaling")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 56)
            .padding(.bottom, 18)

            if items.count > 1 {
                HStack(spacing: 7) {
                    ForEach(0..<items.count, id: \.self) { index in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentIndex = index
                            }
                        } label: {
                            Circle()
                                .fill(index == safeCurrentIndex ? Color.white : Color.white.opacity(0.32))
                                .frame(width: index == safeCurrentIndex ? 7 : 6, height: index == safeCurrentIndex ? 7 : 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder
    private func applyButton(for item: WallpaperItem) -> some View {
        if let progress = coordinator.progress(for: item) {
            HStack(spacing: 8) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 72)
                    .tint(.white)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Button {
                    coordinator.cancelActiveDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.white.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.75))
        } else {
            let isApplied = isCurrentlyApplied(item)
            Button {
                switch selectedTarget {
                case .mirrorAll:
                    coordinator.applyWallpaper(item, targetDisplayID: nil, displayMode: .mirrorAll)
                case .display(let id):
                    coordinator.applyWallpaper(item, targetDisplayID: id, displayMode: .independent)
                case nil:
                    coordinator.applyWallpaper(item)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isApplied ? "checkmark.circle.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(isApplied ? "Applied" : "Apply Wallpaper")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .background(isApplied ? Color.green.opacity(0.28) : Color.white.opacity(0.18), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
    }

    private var displayPickerMenu: some View {
        Menu {
            Button {
                selectedTarget = .mirrorAll
            } label: {
                Label("Mirror All Displays", systemImage: effectiveDisplayMode == .mirrorAll ? "checkmark" : "rectangle.on.rectangle")
            }

            Divider()

            ForEach(coordinator.connectedDisplays) { display in
                Button {
                    selectedTarget = .display(display.id)
                } label: {
                    let isSelected = effectiveDisplayMode == .independent &&
                        effectiveTargetDisplayID == display.id
                    Label(display.name, systemImage: isSelected ? "checkmark" : "display")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: effectiveDisplayMode == .mirrorAll ? "rectangle.on.rectangle" : "display")
                    .font(.system(size: 12))
                Text(displayTargetLabel)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Theme.glassFill, in: Capsule())
            .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 0.75))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var effectiveDisplayMode: DisplayMode {
        switch selectedTarget {
        case .mirrorAll:
            return .mirrorAll
        case .display:
            return .independent
        case nil:
            return coordinator.displayConfig.mode
        }
    }

    private var effectiveTargetDisplayID: UInt32? {
        switch selectedTarget {
        case .mirrorAll:
            return nil
        case .display(let id):
            return coordinator.connectedDisplays.contains(where: { $0.id == id }) ? id : coordinator.primaryDisplay?.id
        case nil:
            if let targetID = coordinator.selectedTargetDisplayID,
               coordinator.connectedDisplays.contains(where: { $0.id == targetID }) {
                return targetID
            }
            return coordinator.primaryDisplay?.id
        }
    }

    private var displayTargetLabel: String {
        if effectiveDisplayMode == .mirrorAll {
            return "All Displays"
        }
        let targetID = effectiveTargetDisplayID
        return coordinator.connectedDisplays.first(where: { $0.id == targetID })?.name ?? "Primary Display"
    }

    private var emptyHeroPlaceholder: some View {
        VStack(spacing: 12) {
            if coordinator.isLoadingHome {
                ProgressView()
                    .controlSize(.large)
                Text("Loading live & curated wallpapers...")
                    .font(.subheadline)
                    .foregroundStyle(Theme.subtleText)
            } else {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.subtleText)
                Text("Explore Wallpapers")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Button("Retry Catalog") {
                    coordinator.refreshHomeShelves()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var safeCurrentIndex: Int {
        guard !items.isEmpty else { return 0 }
        return ((currentIndex % items.count) + items.count) % items.count
    }

    private func stepCarousel(by delta: Int) {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            currentIndex = ((currentIndex + delta) % items.count + items.count) % items.count
        }
    }

    private func isCurrentlyApplied(_ item: WallpaperItem) -> Bool {
        let active: WallpaperItem?
        if effectiveDisplayMode == .independent, let targetID = effectiveTargetDisplayID {
            active = coordinator.wallpaperEngine.activeWallpapers[targetID]
                ?? coordinator.displayConfig.assignment(for: targetID)?.wallpaper
        } else {
            active = coordinator.primaryActiveWallpaper
        }
        guard let active else { return false }
        return active.source == item.source && active.id == item.id
    }
}
