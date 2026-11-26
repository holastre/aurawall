import SwiftUI
import AuraWallCore

struct WallpaperDetailSheet: View {
    let item: WallpaperItem
    let coordinator: AppCoordinator

    @Environment(\.dismiss) private var dismiss
    @ViewState private var selectedScaling: WallpaperScalingMode = .fill
    @ViewState private var targetDisplayID: UInt32? = nil
    @ViewState private var targetDisplayMode: DisplayMode = .mirrorAll

    var body: some View {
        VStack(spacing: 0) {
            previewArea

            VStack(alignment: .leading, spacing: 16) {
                headerSection

                metadataSection

                if !item.tags.isEmpty || !item.dominantColors.isEmpty {
                    tagsAndColorsSection
                }

                Divider()
                    .overlay(Color.white.opacity(0.12))

                optionsSection

                if let progress = coordinator.progress(for: item) {
                    downloadProgressSection(progress: progress)
                }

                actionButtons
            }
            .padding(22)
        }
        .frame(width: 720)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .onAppear {
            targetDisplayMode = coordinator.displayConfig.mode
            let validSelected = coordinator.selectedTargetDisplayID.flatMap { id in
                coordinator.connectedDisplays.contains(where: { $0.id == id }) ? id : nil
            }
            targetDisplayID = validSelected ?? coordinator.primaryDisplay?.id
            if targetDisplayMode == .mirrorAll {
                selectedScaling = coordinator.displayConfig.assignments[DisplayConfig.mirrorAssignmentKey]?.scalingMode ?? .fill
            } else if let id = targetDisplayID {
                selectedScaling = coordinator.displayConfig.assignments[DisplayConfig.key(for: id)]?.scalingMode ?? .fill
            }
        }
        .onChange(of: coordinator.connectedDisplays) { _, newDisplays in
            if let currentID = targetDisplayID {
                if !newDisplays.contains(where: { $0.id == currentID }) {
                    targetDisplayID = coordinator.primaryDisplay?.id
                }
            } else {
                targetDisplayID = coordinator.primaryDisplay?.id
            }
        }
    }

    private var previewArea: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                WallpaperThumbnailView(
                    url: item.preferredThumbnailURL ?? item.fullAssetURL,
                    fallbackTitle: item.title,
                    contentMode: selectedScaling == .fill ? .fill : .fit
                )

                if item.mediaType == .video,
                   let videoURL = item.localPath ?? item.previewVideoURL ?? item.fullAssetURL {
                    VideoPreviewPlayerView(
                        url: videoURL,
                        isPlaying: coordinator.isMainWindowVisible,
                        videoGravity: selectedScaling == .fill ? .resizeAspectFill : .resizeAspect
                    )
                }
            }
            .frame(height: 360)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipped()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(Theme.glassBorder, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.category.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.subtleText)
                Text(item.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 6) {
                Text(item.mediaType.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())

                Text(item.source.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var metadataSection: some View {
        Text(Theme.metadataLine(for: item))
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.subtleText)
    }

    private var tagsAndColorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.dominantColors.isEmpty {
                HStack(spacing: 6) {
                    Text("Palette")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.mutedText)
                    ForEach(item.dominantColors.prefix(6), id: \.self) { hex in
                        if let color = Theme.colorFromHex(hex) {
                            Circle()
                                .fill(color)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.75))
                                .help(hex)
                        }
                    }
                }
            }

            if !item.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(item.tags.prefix(10), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.78))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.elevatedSurface, in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private var optionsSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scaling")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.subtleText)
                Picker("Scaling", selection: $selectedScaling) {
                    ForEach(WallpaperScalingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Target Display")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.subtleText)

                HStack(spacing: 8) {
                    Menu {
                        Button {
                            targetDisplayMode = .mirrorAll
                        } label: {
                            Label("Mirror All Displays", systemImage: targetDisplayMode == .mirrorAll ? "checkmark" : "rectangle.on.rectangle")
                        }

                        Divider()

                        ForEach(coordinator.connectedDisplays) { display in
                            Button {
                                targetDisplayMode = .independent
                                targetDisplayID = display.id
                            } label: {
                                let isSelected = targetDisplayMode == .independent &&
                                    targetDisplayID == display.id
                                Label(display.name, systemImage: isSelected ? "checkmark" : "display")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: targetDisplayMode == .mirrorAll ? "rectangle.on.rectangle" : "display")
                            Text(selectedDisplayLabel)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.glassBorder, lineWidth: 0.75)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Spacer()
        }
    }

    private func downloadProgressSection(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading wallpaper...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.subtleText)
                Button("Cancel") {
                    coordinator.cancelActiveDownload()
                }
                .font(.system(size: 11.5, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(.white)
        }
        .padding(10)
        .background(Theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.toggleFavorite(item)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.isFavorite(item) ? "heart.fill" : "heart")
                        .foregroundStyle(coordinator.isFavorite(item) ? .pink : .white)
                    Text(coordinator.isFavorite(item) ? "Favorited" : "Favorite")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.glassFill, in: Capsule())
                .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 0.75))
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.subtleText)
            .padding(.horizontal, 12)

            let isDownloading = coordinator.progress(for: item) != nil
            Button {
                coordinator.applyWallpaper(
                    item,
                    targetDisplayID: targetDisplayMode == .independent ? (targetDisplayID ?? coordinator.primaryDisplay?.id) : nil,
                    displayMode: targetDisplayMode,
                    scaling: selectedScaling
                )
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isDownloading ? "arrow.down.circle" : "play.fill")
                        .font(.system(size: 11.5))
                    Text(isDownloading ? "Downloading..." : "Apply Wallpaper")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(isDownloading ? .white.opacity(0.6) : .black)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(isDownloading ? Color.white.opacity(0.18) : Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
        }
    }

    private var selectedDisplayLabel: String {
        if targetDisplayMode == .mirrorAll {
            return "Mirror All Displays"
        }
        let id = targetDisplayID ?? coordinator.primaryDisplay?.id
        return coordinator.connectedDisplays.first(where: { $0.id == id })?.name ?? "Primary Display"
    }
}
