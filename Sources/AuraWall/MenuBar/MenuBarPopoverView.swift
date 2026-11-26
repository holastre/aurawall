import SwiftUI
import AuraWallCore

struct MenuBarPopoverView: View {
    let coordinator: AppCoordinator
    let onOpenMainWindow: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            activeWallpaperCard

            controlsRow

            if shouldShowBatteryOverride {
                batteryOverrideButton
            }

            displayModeToggle

            favoritesStrip

            Divider()
                .overlay(Color.white.opacity(0.12))

            footerActions
        }
        .padding(14)
        .frame(width: 336)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("AuraWall")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(coordinator.settings.launchInBackgroundOnClose ? Color.green : Color.white.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(coordinator.settings.launchInBackgroundOnClose ? "Works in background" : "Menu bar active")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
        }
    }

    private var activeWallpaperCard: some View {
        let active = coordinator.primaryActiveWallpaper
        return HStack(spacing: 10) {
            WallpaperThumbnailView(
                url: active?.preferredThumbnailURL,
                fallbackTitle: active?.title ?? ""
            )
            .frame(width: 84, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(active?.title ?? "No Active Wallpaper")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                    Text(coordinator.menuBarStatusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.80))
                        .lineLimit(1)
                }

                if let active, let res = active.resolutionLabel {
                    Text("\(res) • \(active.source.displayName)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.75)
        )
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.toggleManualPause()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.powerInputs.manualPause ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(coordinator.powerInputs.manualPause ? "Resume" : "Pause")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                coordinator.applyRandomWallpaper()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Next / Random")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var shouldShowBatteryOverride: Bool {
        coordinator.activePowerDecision == .pause(.onBattery) ||
        coordinator.powerInputs.batteryOverrideActive
    }

    private var batteryOverrideButton: some View {
        Button {
            coordinator.toggleBatteryOverride()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: coordinator.powerInputs.batteryOverrideActive ? "battery.100.bolt" : "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(
                    coordinator.powerInputs.batteryOverrideActive
                        ? "Restore Battery Power Saving"
                        : "Play on Battery Anyway (Override)"
                )
                .font(.system(size: 11.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6.5)
            .background(Color.orange.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.45), lineWidth: 0.75)
            )
            .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
    }

    private var displayModeToggle: some View {
        HStack(spacing: 8) {
            Label("Displays", systemImage: "display.2")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.subtleText)

            Spacer()

            Button {
                coordinator.toggleDisplayMode()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: coordinator.displayConfig.mode == .mirrorAll ? "rectangle.on.rectangle" : "rectangle.split.2x1")
                        .font(.system(size: 10.5))
                    Text(coordinator.displayConfig.mode == .mirrorAll ? "Mirror All" : "Independent")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var favoritesStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Favorites")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.subtleText)
                Spacer()
                Text("\(coordinator.favorites.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.mutedText)
            }

            if coordinator.favorites.isEmpty {
                Text("Heart a wallpaper to pin it here for one-click switching.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(coordinator.favorites.prefix(10)) { item in
                            Button {
                                coordinator.applyWallpaper(item)
                            } label: {
                                ZStack(alignment: .bottomTrailing) {
                                    WallpaperThumbnailView(
                                        url: item.preferredThumbnailURL,
                                        fallbackTitle: item.title
                                    )
                                    .frame(width: 76, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 0.75)
                                    )

                                    if item.mediaType == .video {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 7))
                                            .foregroundStyle(.white)
                                            .padding(3)
                                            .background(Color.black.opacity(0.65), in: Circle())
                                            .padding(3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(item.title)
                        }
                    }
                }
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button {
                onOpenMainWindow()
            } label: {
                Text("Open AuraWall")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)

            Button {
                onQuit()
            } label: {
                Text("Quit")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
    }

    private var statusDotColor: Color {
        if !coordinator.wallpaperEngine.activeVideoDisplayIDs.isEmpty {
            return coordinator.activePowerDecision.isPlaying ? .green : .orange
        }
        guard let active = coordinator.primaryActiveWallpaper else {
            return .gray
        }
        if active.mediaType == .image {
            return .blue
        }
        return coordinator.activePowerDecision.isPlaying ? .green : .orange
    }
}
