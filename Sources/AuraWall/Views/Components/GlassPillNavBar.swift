import SwiftUI

struct GlassPillNavBar: View {
    @Binding var selectedTab: AppCoordinator.NavTab
    let onSearchTap: () -> Void
    let onImportTap: () -> Void
    let onSettingsTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Leave clear space for macOS top-left traffic lights
            Spacer()
                .frame(width: 78)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(Theme.glassFill, in: Circle())
                        .overlay(Circle().stroke(Theme.glassBorder, lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .help("Search wallpapers")

                HStack(spacing: 4) {
                    ForEach(AppCoordinator.NavTab.allCases) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .medium))
                                .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.75))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background {
                                    if selectedTab == tab {
                                        Capsule()
                                            .fill(Theme.glassSelectedFill)
                                            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.75))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Theme.glassFill, in: Capsule())
                .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Button(action: onImportTap) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.square.on.square")
                            .font(.system(size: 12, weight: .medium))
                        Text("Import")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.90))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .help("Import local video or image wallpapers")

                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 16)

                Button(action: onSettingsTap) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.90))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .help("Settings & API Keys")
            }
            .background(.ultraThinMaterial, in: Capsule())
            .background(Theme.glassFill, in: Capsule())
            .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }
}
