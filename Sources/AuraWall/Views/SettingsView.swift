import SwiftUI
import AuraWallCore

struct SettingsView: View {
    let coordinator: AppCoordinator

    @Environment(\.dismiss) private var dismiss

    @ViewState private var pexelsKey: String = ""
    @ViewState private var pixabayKey: String = ""
    @ViewState private var wallhavenKey: String = ""
    @ViewState private var showPexelsKey: Bool = false
    @ViewState private var showPixabayKey: Bool = false
    @ViewState private var showWallhavenKey: Bool = false

    @ViewState private var customFeedURL: String = ""
    @ViewState private var pauseOnBattery: Bool = true
    @ViewState private var pauseOnFullscreen: Bool = true
    @ViewState private var pauseOnScreenLockOrSleep: Bool = true
    @ViewState private var extractFirstFrameStill: Bool = true
    @ViewState private var launchInBackgroundOnClose: Bool = true
    @ViewState private var preferredResolution: String = ""

    @ViewState private var isSaving: Bool = false
    @ViewState private var isClearingCache: Bool = false
    @ViewState private var localMessage: String? = nil

    private let resolutionOptions = ["", "1920x1080", "2560x1440", "3840x2160"]

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Color.white.opacity(0.10))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    apiKeysSection
                    customFeedSection
                    powerSection
                    behaviorSection
                    cacheSection

                    if let localMessage {
                        Text(localMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(22)
            }

            Divider()
                .overlay(Color.white.opacity(0.10))

            footer
        }
        .frame(width: 580, height: 640)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .onAppear {
            loadFromCoordinator()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text("API keys are stored locally with strict owner-only (0600) permissions.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.subtleText)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Theme.glassFill, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var apiKeysSection: some View {
        settingsCard(title: "Provider API Keys", icon: "key.fill") {
            apiKeyRow(
                label: "Pexels API Key",
                placeholder: "Optional — unlocks Pexels 4K/HD videos & photos",
                text: $pexelsKey,
                revealed: $showPexelsKey
            )
            apiKeyRow(
                label: "Pixabay API Key",
                placeholder: "Optional — unlocks Pixabay video & photo catalogs",
                text: $pixabayKey,
                revealed: $showPixabayKey
            )
            apiKeyRow(
                label: "Wallhaven API Key",
                placeholder: "Optional — higher rate limit for Wallhaven searches",
                text: $wallhavenKey,
                revealed: $showWallhavenKey
            )
        }
    }

    private var customFeedSection: some View {
        settingsCard(title: "Custom JSON Feed", icon: "link") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Feed URL (HTTPS or local HTTP)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.subtleText)
                TextField("https://example.com/wallpapers.json", text: $customFeedURL)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var powerSection: some View {
        settingsCard(title: "Smart Power Saving", icon: "bolt.shield.fill") {
            Toggle("Pause live videos on battery power", isOn: $pauseOnBattery)
            Toggle("Pause when an app is fullscreen on that display", isOn: $pauseOnFullscreen)
            Toggle("Pause when screen is locked or display sleeps", isOn: $pauseOnScreenLockOrSleep)
        }
    }

    private var behaviorSection: some View {
        settingsCard(title: "Playback & Menu Bar", icon: "macwindow") {
            Toggle("Extract first-frame still for macOS menu bar tinting & smooth transitions", isOn: $extractFirstFrameStill)
            Toggle("Keep running in menu bar when main window is closed (hide Dock icon)", isOn: $launchInBackgroundOnClose)

            HStack {
                Text("Preferred Resolution")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Spacer()
                Picker("Preferred Resolution", selection: $preferredResolution) {
                    Text("Auto").tag("")
                    ForEach(resolutionOptions.dropFirst(), id: \.self) { res in
                        Text(res).tag(res)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }
    }

    private var cacheSection: some View {
        settingsCard(title: "Media Cache", icon: "internaldrive") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cached Media Size: \(Theme.formatFileSize(coordinator.cacheSizeBytes))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Clearing cache removes unused downloads while preserving active wallpapers.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.subtleText)
                }

                Spacer()

                Button {
                    isClearingCache = true
                    localMessage = nil
                    Task {
                        do {
                            let freed = try await coordinator.clearUnusedCache()
                            isClearingCache = false
                            localMessage = "Freed \(Theme.formatFileSize(freed)) of unused cache."
                        } catch {
                            isClearingCache = false
                            localMessage = "Failed to clear cache: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    if isClearingCache {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Clear Unused Cache")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isClearingCache)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.subtleText)
            .padding(.horizontal, 14)

            Button {
                saveAndClose()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                } else {
                    Text("Save Settings")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.white, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.75)
        )
    }

    private func apiKeyRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        revealed: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.subtleText)
            HStack(spacing: 8) {
                if revealed.wrappedValue {
                    TextField(placeholder, text: text)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(placeholder, text: text)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    revealed.wrappedValue.toggle()
                } label: {
                    Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
                        .foregroundStyle(Theme.subtleText)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loadFromCoordinator() {
        pexelsKey = coordinator.secrets.pexelsAPIKey ?? ""
        pixabayKey = coordinator.secrets.pixabayAPIKey ?? ""
        wallhavenKey = coordinator.secrets.wallhavenAPIKey ?? ""
        customFeedURL = coordinator.settings.customFeedURL ?? ""
        pauseOnBattery = coordinator.settings.power.pauseOnBattery
        pauseOnFullscreen = coordinator.settings.power.pauseOnFullscreen
        pauseOnScreenLockOrSleep = coordinator.settings.power.pauseOnScreenLockOrSleep
        extractFirstFrameStill = coordinator.settings.extractFirstFrameStill
        launchInBackgroundOnClose = coordinator.settings.launchInBackgroundOnClose
        preferredResolution = coordinator.settings.preferredResolution ?? ""
    }

    private func saveAndClose() {
        let trimmedFeed = customFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFeed.isEmpty {
            let probe = AppSettings(customFeedURL: trimmedFeed)
            if probe.validatedCustomFeedURL == nil {
                localMessage = "Custom Feed URL must be a valid http:// or https:// URL."
                return
            }
        }

        let newSettings = AppSettings(
            customFeedURL: trimmedFeed.isEmpty ? nil : trimmedFeed,
            extractFirstFrameStill: extractFirstFrameStill,
            launchInBackgroundOnClose: launchInBackgroundOnClose,
            power: PowerSettings(
                pauseOnBattery: pauseOnBattery,
                pauseOnFullscreen: pauseOnFullscreen,
                pauseOnScreenLockOrSleep: pauseOnScreenLockOrSleep
            ),
            preferredResolution: preferredResolution.isEmpty ? nil : preferredResolution
        )

        let newSecrets = ApiSecrets(
            pexelsAPIKey: pexelsKey,
            pixabayAPIKey: pixabayKey,
            wallhavenAPIKey: wallhavenKey
        )

        isSaving = true
        Task {
            do {
                try await coordinator.saveSettings(newSettings, secrets: newSecrets)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                localMessage = "Failed to save settings: \(error.localizedDescription)"
            }
        }
    }
}
