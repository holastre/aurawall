import SwiftUI
import AuraWallCore

struct WallpaperCardView: View {
    let item: WallpaperItem
    let coordinator: AppCoordinator
    var onRemoveImport: (() -> Void)? = nil

    @ViewState private var isHovered: Bool = false

    private var isApplied: Bool {
        guard let active = coordinator.primaryActiveWallpaper else { return false }
        return active.source == item.source && active.id == item.id
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WallpaperThumbnailView(
                url: item.preferredThumbnailURL,
                fallbackTitle: item.title
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovered)

            // Top badges
            VStack {
                HStack(spacing: 6) {
                    if item.mediaType == .video {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text("LIVE")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.62), in: Capsule())
                    }

                    if let qualityBadge {
                        Text(qualityBadge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.62), in: Capsule())
                    }

                    Spacer()

                    if isApplied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                            .background(Color.black.opacity(0.5), in: Circle())
                    } else if isHovered {
                        Text(item.source.displayName)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.65), in: Capsule())
                    }
                }
                .padding(8)

                Spacer()
            }

            // Bottom hover gradient + quick actions
            if isHovered || coordinator.progress(for: item) != nil {
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.84)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let res = item.resolutionLabel {
                            Text(res)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    Spacer(minLength: 4)

                    if let progress = coordinator.progress(for: item) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Button {
                            coordinator.applyWallpaper(item)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Apply Wallpaper")

                        Button {
                            coordinator.toggleFavorite(item)
                        } label: {
                            Image(systemName: coordinator.isFavorite(item) ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(coordinator.isFavorite(item) ? .pink : .white)
                                .padding(5)
                                .background(Color.white.opacity(0.16), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Toggle Favorite")

                        if let onRemoveImport {
                            Button(action: onRemoveImport) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.red.opacity(0.95))
                                    .padding(5)
                                    .background(Color.white.opacity(0.16), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove Imported Wallpaper")
                        }
                    }
                }
                .padding(10)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isApplied ? Color.green.opacity(0.75) : Color.white.opacity(isHovered ? 0.30 : 0.10),
                    lineWidth: isApplied ? 1.5 : 0.75
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            coordinator.selectedDetailItem = item
        }
    }

    private var qualityBadge: String? {
        guard let width = item.width else { return nil }
        if width >= 3840 { return "4K" }
        if width >= 2560 { return "2K" }
        if width >= 1920 { return "HD" }
        return nil
    }
}
