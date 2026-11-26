import SwiftUI
import AuraWallCore

struct MyMediaView: View {
    enum MediaTab: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case downloaded = "Downloaded"
        case imported = "Imported"

        var id: String { rawValue }
    }

    let coordinator: AppCoordinator
    @ViewState private var selectedSection: MediaTab = .favorites

    private let gridColumns = [
        GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 16)
    ]

    private var displayedItems: [WallpaperItem] {
        switch selectedSection {
        case .favorites:
            return coordinator.favorites
        case .downloaded:
            return coordinator.downloadedItems
        case .imported:
            return coordinator.localImports
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Spacer()
                    .frame(height: 68)

                headerRow

                if selectedSection == .imported {
                    importDropBanner
                }

                if displayedItems.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(displayedItems) { item in
                            WallpaperCardView(
                                item: item,
                                coordinator: coordinator,
                                onRemoveImport: selectedSection == .imported ? {
                                    coordinator.removeLocalImport(item)
                                } : nil
                            )
                        }
                    }
                }

                Spacer()
                    .frame(height: 24)
            }
            .padding(.horizontal, 28)
        }
        .background(Theme.canvas)
        .onAppear {
            Task {
                await coordinator.refreshDownloadedItems()
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(MediaTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedSection = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(tab.rawValue)
                            Text("\(count(for: tab))")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(selectedSection == tab ? .black.opacity(0.65) : Theme.mutedText)
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selectedSection == tab ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(selectedSection == tab ? Color.white : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Theme.elevatedSurface, in: Capsule())
            .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 0.75))

            Spacer()

            Button {
                coordinator.presentImportPanel()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("Import Media...")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var importDropBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Drag & Drop Local Wallpapers Here")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Supported formats: .mp4, .mov, .m4v, .jpg, .jpeg, .png, .heic")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtleText)
            }

            Spacer()

            Button("Choose Files") {
                coordinator.presentImportPanel()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(Color.white.opacity(0.22))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyIcon)
                .font(.system(size: 34))
                .foregroundStyle(Theme.mutedText)
            Text(emptyTitle)
                .font(.headline)
                .foregroundStyle(.white)
            Text(emptySubtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.subtleText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private func count(for tab: MediaTab) -> Int {
        switch tab {
        case .favorites: return coordinator.favorites.count
        case .downloaded: return coordinator.downloadedItems.count
        case .imported: return coordinator.localImports.count
        }
    }

    private var emptyIcon: String {
        switch selectedSection {
        case .favorites: return "heart"
        case .downloaded: return "arrow.down.circle"
        case .imported: return "folder.badge.plus"
        }
    }

    private var emptyTitle: String {
        switch selectedSection {
        case .favorites: return "No Favorites Yet"
        case .downloaded: return "No Downloaded Wallpapers"
        case .imported: return "No Imported Media"
        }
    }

    private var emptySubtitle: String {
        switch selectedSection {
        case .favorites: return "Click the heart button on any wallpaper to save it to your favorites."
        case .downloaded: return "Applied remote wallpapers are cached locally for instant offline playback."
        case .imported: return "Import your own .mp4, .mov, .jpg, .png, or .heic files using the button above or drag-and-drop."
        }
    }
}
