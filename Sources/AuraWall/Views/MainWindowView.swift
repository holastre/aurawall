import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @Bindable var coordinator: AppCoordinator
    let onWindowResolved: (NSWindow) -> Void

    @ViewState private var isDropTargeted: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.canvas
                .ignoresSafeArea()

            WindowAccessor(onWindowResolved: onWindowResolved)
                .frame(width: 0, height: 0)

            Group {
                switch coordinator.selectedTab {
                case .home:
                    HomeView(coordinator: coordinator)
                case .explore:
                    ExploreView(coordinator: coordinator)
                case .myMedia:
                    MyMediaView(coordinator: coordinator)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GlassPillNavBar(
                selectedTab: $coordinator.selectedTab,
                onSearchTap: {
                    coordinator.triggerSearchFromPill()
                },
                onImportTap: {
                    coordinator.presentImportPanel()
                },
                onSettingsTap: {
                    coordinator.isShowingSettings = true
                }
            )

            VStack(spacing: 8) {
                Spacer()
                    .frame(height: 62)

                if let errorMessage = coordinator.errorBannerMessage {
                    bannerView(
                        message: errorMessage,
                        icon: "exclamationmark.triangle.fill",
                        tint: .orange,
                        dismissAction: { coordinator.dismissError() }
                    )
                }

                if let statusMessage = coordinator.statusBannerMessage {
                    bannerView(
                        message: statusMessage,
                        icon: "checkmark.circle.fill",
                        tint: .green,
                        dismissAction: { coordinator.statusBannerMessage = nil }
                    )
                }
            }
            .padding(.horizontal, 24)
            .allowsHitTesting(coordinator.errorBannerMessage != nil || coordinator.statusBannerMessage != nil)

            if isDropTargeted {
                dropOverlay
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .sheet(item: $coordinator.selectedDetailItem) { item in
            WallpaperDetailSheet(item: item, coordinator: coordinator)
        }
        .sheet(isPresented: $coordinator.isShowingSettings) {
            SettingsView(coordinator: coordinator)
        }
    }

    private func bannerView(
        message: String,
        icon: String,
        tint: Color,
        dismissAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: dismissAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 1)
        )
        .frame(maxWidth: 680)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                Text("Drop Video or Image Wallpapers to Import")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text("Supports .mp4, .mov, .m4v, .jpg, .png, .heic")
                    .font(.subheadline)
                    .foregroundStyle(Theme.subtleText)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(.white.opacity(0.6))
            )
        }
        .allowsHitTesting(false)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let validProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !validProviders.isEmpty else { return false }

        Task { @MainActor in
            var urls: [URL] = []
            for provider in validProviders {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                coordinator.importLocalFiles(urls)
            }
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let str = item as? String, let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindowResolved: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverNSView {
        let view = WindowObserverNSView()
        view.onWindowResolved = onWindowResolved
        return view
    }

    func updateNSView(_ nsView: WindowObserverNSView, context: Context) {
        nsView.onWindowResolved = onWindowResolved
        if let window = nsView.window {
            configure(window: window)
            onWindowResolved(window)
        }
    }

    private func configure(window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
    }
}

private final class WindowObserverNSView: NSView {
    var onWindowResolved: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
        onWindowResolved?(window)
    }
}
