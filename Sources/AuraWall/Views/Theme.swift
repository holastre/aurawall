import AppKit
import SwiftUI
import AuraWallCore

enum Theme {
    static let canvas = Color(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0)
    static let elevatedSurface = Color(red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 22.0 / 255.0)
    static let cardSurface = Color(red: 22.0 / 255.0, green: 22.0 / 255.0, blue: 27.0 / 255.0)

    static let glassFill = Color.white.opacity(0.10)
    static let glassSelectedFill = Color.white.opacity(0.20)
    static let glassBorder = Color.white.opacity(0.16)
    static let subtleText = Color.white.opacity(0.68)
    static let mutedText = Color.white.opacity(0.48)

    static let auroraGradient = LinearGradient(
        colors: [
            Color(red: 0.28, green: 0.78, blue: 0.96),
            Color(red: 0.48, green: 0.44, blue: 0.98)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    static func metadataParts(for item: WallpaperItem) -> [String] {
        var parts: [String] = []
        if let resolution = item.resolutionLabel {
            parts.append(resolution)
        }
        if let fileSize = item.fileSize, fileSize > 0 {
            parts.append(formatFileSize(fileSize))
        }
        if let duration = item.duration, duration > 0 {
            parts.append("\(formatDuration(duration))s")
        }
        parts.append(item.source.displayName)
        return parts
    }

    static func metadataLine(for item: WallpaperItem) -> String {
        metadataParts(for: item).joined(separator: " • ")
    }

    static func colorFromHex(_ hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let intVal = UInt64(cleaned, radix: 16) else {
            return nil
        }
        let r = Double((intVal >> 16) & 0xFF) / 255.0
        let g = Double((intVal >> 8) & 0xFF) / 255.0
        let b = Double(intVal & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

struct WallpaperThumbnailView: View {
    let url: URL?
    let fallbackTitle: String
    var contentMode: ContentMode = .fill

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.16),
                    Color(red: 0.05, green: 0.05, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let url {
                if url.isFileURL {
                    LocalFileImageView(url: url, contentMode: contentMode)
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: contentMode)
                        case .failure:
                            placeholderArtwork
                        case .empty:
                            placeholderArtwork
                        @unknown default:
                            placeholderArtwork
                        }
                    }
                }
            } else {
                placeholderArtwork
            }
        }
    }

    private var placeholderArtwork: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.artframe")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.35))
            if !fallbackTitle.isEmpty {
                Text(fallbackTitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
        }
    }
}

@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        self.storage = SwiftUI.State(wrappedValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> {
        storage.projectedValue
    }
}

private struct LocalFileImageView: View {
    let url: URL
    let contentMode: ContentMode

    @ViewState private var nsImage: NSImage? = nil

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            nsImage = NSImage(contentsOf: url)
        }
    }
}
