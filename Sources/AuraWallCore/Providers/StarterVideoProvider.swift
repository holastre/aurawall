import CryptoKit
import Foundation

// MARK: - Pure-Swift 512-Byte POSIX Tar Extractor

public enum TarExtractionError: Error, Sendable, Equatable {
    case malformedHeader
    case invalidChecksum
    case truncatedArchive
    case fileNotFound(String)
}

public enum PosixTarExtractor: Sendable {
    public static func extractFile(named targetName: String, from tarData: Data) throws -> Data {
        let normalizedTarget = normalizeTarPath(targetName)
        guard !normalizedTarget.isEmpty else {
            throw TarExtractionError.fileNotFound(targetName)
        }

        let baseIndex = tarData.startIndex
        let totalCount = tarData.count
        var offset = 0
        var sawZeroBlock = false

        var pendingPAXPath: String?
        var pendingPAXSize: Int?
        var pendingGNULongName: String?

        while offset + 512 <= totalCount {
            let headerSlice = tarData[(baseIndex + offset)..<(baseIndex + offset + 512)]
            let header = [UInt8](headerSlice)

            if header.allSatisfy({ $0 == 0 }) {
                sawZeroBlock = true
                break
            }

            try verifyChecksum(header: header)

            let name = readNullTerminatedUTF8(header[0..<100])
            let headerSize = try parseSize(header[124..<136])
            let typeflag = header[156]

            let isUStar = header[257..<262] == [0x75, 0x73, 0x74, 0x61, 0x72] // "ustar"
            let prefix = isUStar ? readNullTerminatedUTF8(header[345..<500]) : ""

            let payloadStart = offset + 512
            // Metadata headers ('x', 'g', 'L') must always read their own headerSize;
            // pending PAX overrides apply only to the subsequent target/file entry.
            let isMetadataHeader = (typeflag == 0x78 || typeflag == 0x67 || typeflag == 0x4C)
            let effectiveSize = isMetadataHeader ? headerSize : (pendingPAXSize ?? headerSize)
            guard effectiveSize >= 0, effectiveSize <= totalCount - payloadStart else {
                throw TarExtractionError.truncatedArchive
            }

            let remainder = effectiveSize % 512
            let padding = remainder == 0 ? 0 : (512 - remainder)
            let (paddedSize, padOverflow) = effectiveSize.addingReportingOverflow(padding)
            guard !padOverflow else {
                throw TarExtractionError.truncatedArchive
            }
            let (nextOffset, nextOverflow) = payloadStart.addingReportingOverflow(paddedSize)
            guard !nextOverflow, nextOffset <= totalCount else {
                throw TarExtractionError.truncatedArchive
            }

            let payloadSlice = tarData[(baseIndex + payloadStart)..<(baseIndex + payloadStart + effectiveSize)]

            switch typeflag {
            case 0x78: // 'x' PAX per-file extended header
                let paxRecords = parsePAXRecords(Data(payloadSlice))
                if let paxPath = paxRecords["path"] {
                    pendingPAXPath = paxPath
                }
                if let paxSizeStr = paxRecords["size"] {
                    guard let paxSize = Int(paxSizeStr), paxSize >= 0 else {
                        throw TarExtractionError.malformedHeader
                    }
                    pendingPAXSize = paxSize
                }
                offset = nextOffset
                continue

            case 0x67: // 'g' PAX global extended header
                offset = nextOffset
                continue

            case 0x4C: // 'L' GNU long filename
                let bytes = [UInt8](payloadSlice)
                pendingGNULongName = readNullTerminatedUTF8(bytes[...])
                offset = nextOffset
                continue

            default:
                let combinedPath: String
                if let paxPath = pendingPAXPath {
                    combinedPath = paxPath
                } else if let gnuName = pendingGNULongName {
                    combinedPath = gnuName
                } else if prefix.isEmpty {
                    combinedPath = name
                } else if name.isEmpty {
                    combinedPath = prefix
                } else {
                    combinedPath = "\(prefix)/\(name)"
                }

                pendingPAXPath = nil
                pendingPAXSize = nil
                pendingGNULongName = nil

                let normalizedEntryPath = normalizeTarPath(combinedPath)
                if (typeflag == 0x00 || typeflag == 0x30) && normalizedEntryPath == normalizedTarget {
                    return Data(payloadSlice)
                }
            }

            offset = nextOffset
        }

        if !sawZeroBlock && offset < totalCount {
            throw TarExtractionError.truncatedArchive
        }

        throw TarExtractionError.fileNotFound(targetName)
    }

    private static func verifyChecksum(header: [UInt8]) throws {
        let checksumBytes = header[148..<156]
        let trimmed = trimOctalField(checksumBytes)
        guard !trimmed.isEmpty else {
            throw TarExtractionError.invalidChecksum
        }
        guard let expected = Int(trimmed, radix: 8) else {
            throw TarExtractionError.invalidChecksum
        }

        var unsignedSum = 0
        var signedSum = 0
        for index in 0..<512 {
            let byte: UInt8 = (148..<156).contains(index) ? 0x20 : header[index]
            unsignedSum += Int(byte)
            signedSum += Int(Int8(bitPattern: byte))
        }

        guard expected == unsignedSum || expected == signedSum else {
            throw TarExtractionError.invalidChecksum
        }
    }

    private static func parseSize(_ bytes: ArraySlice<UInt8>) throws -> Int {
        guard let first = bytes.first else {
            throw TarExtractionError.malformedHeader
        }

        // GNU base-256 size extension
        if first & 0x80 != 0 {
            if first & 0x40 != 0 {
                throw TarExtractionError.malformedHeader
            }
            var value = Int(first & 0x3F)
            for byte in bytes.dropFirst() {
                let (shifted, mulOverflow) = value.multipliedReportingOverflow(by: 256)
                guard !mulOverflow else {
                    throw TarExtractionError.malformedHeader
                }
                let (sum, addOverflow) = shifted.addingReportingOverflow(Int(byte))
                guard !addOverflow else {
                    throw TarExtractionError.malformedHeader
                }
                value = sum
            }
            return value
        }

        let octal = trimOctalField(bytes)
        if octal.isEmpty {
            return 0
        }
        guard let parsed = Int(octal, radix: 8), parsed >= 0 else {
            throw TarExtractionError.malformedHeader
        }
        return parsed
    }

    private static func trimOctalField(_ bytes: ArraySlice<UInt8>) -> String {
        var slice = bytes
        while let first = slice.first, first == 0x20 || first == 0x00 {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == 0x20 || last == 0x00 {
            slice = slice.dropLast()
        }
        if let nulIndex = slice.firstIndex(of: 0x00) {
            slice = slice[..<nulIndex]
        }
        return String(decoding: slice, as: UTF8.self)
    }

    private static func readNullTerminatedUTF8(_ bytes: ArraySlice<UInt8>) -> String {
        let endIndex = bytes.firstIndex(of: 0x00) ?? bytes.endIndex
        return String(decoding: bytes[bytes.startIndex..<endIndex], as: UTF8.self)
    }

    private static func normalizeTarPath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix("./") {
            result.removeFirst(2)
        }
        while result.hasPrefix("/") {
            result.removeFirst(1)
        }
        while result.hasPrefix("./") {
            result.removeFirst(2)
        }
        return result
    }

    private static func parsePAXRecords(_ data: Data) -> [String: String] {
        var records: [String: String] = [:]
        let bytes = [UInt8](data)
        var cursor = 0

        while cursor < bytes.count {
            guard let spaceIdx = bytes[cursor...].firstIndex(of: 0x20),
                  let len = Int(String(decoding: bytes[cursor..<spaceIdx], as: UTF8.self)),
                  len > 0,
                  cursor + len <= bytes.count else {
                break
            }

            let recordStart = spaceIdx + 1
            var recordEnd = cursor + len
            if recordEnd > recordStart && bytes[recordEnd - 1] == 0x0A {
                recordEnd -= 1
            }

            if recordStart < recordEnd,
               let eqIdx = bytes[recordStart..<recordEnd].firstIndex(of: 0x3D) {
                let key = String(decoding: bytes[recordStart..<eqIdx], as: UTF8.self)
                let val = String(decoding: bytes[(eqIdx + 1)..<recordEnd], as: UTF8.self)
                records[key] = val
            }

            cursor += len
        }

        return records
    }
}

// MARK: - Apple Aerials & Starter Video Provider

public struct StarterVideoProvider: WallpaperSourceProvider {
    public static let defaultResources16TarURL = URL(string: "https://sylvan.apple.com/Aerials/resources-16.tar")!
    public static let defaultAerials2xURL = URL(string: "https://sylvan.apple.com/Aerials/2x/entries.json")!

    public let source: WallpaperSource = .starter
    public let httpClient: ProviderHTTPClient
    public let resources16TarURL: URL
    public let aerials2xURL: URL
    public let probeURLsIn2xFallback: Bool

    public init(
        httpClient: ProviderHTTPClient = ProviderHTTPClient(),
        resources16TarURL: URL = StarterVideoProvider.defaultResources16TarURL,
        aerials2xURL: URL = StarterVideoProvider.defaultAerials2xURL,
        probeURLsIn2xFallback: Bool = true
    ) {
        self.httpClient = httpClient
        self.resources16TarURL = resources16TarURL
        self.aerials2xURL = aerials2xURL
        self.probeURLsIn2xFallback = probeURLsIn2xFallback
    }

    public static let curatedFallbackVideos: [WallpaperItem] = [
        WallpaperItem(
            id: "starter-curated-hk",
            title: "Hong Kong Aerial (4K)",
            category: "Cities",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 677_174_817,
            previewImageURL: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/N003_C006.jpg"),
            previewVideoURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/HK_H004_C013_2K_SDR_HEVC.mov"),
            fullAssetURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/HK_H004_C013_4K_SDR_HEVC.mov"),
            tags: ["aerial", "cities", "hong kong", "4k"]
        ),
        WallpaperItem(
            id: "starter-curated-seals",
            title: "Seals Underwater (4K)",
            category: "Underwater",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 346_649_491,
            previewImageURL: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/SE_A016_C009.jpg"),
            previewVideoURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/SE_A016_C009_SDR_20190717_SDR_2K_HEVC.mov"),
            fullAssetURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/SE_A016_C009_SDR_20190717_SDR_4K_HEVC.mov"),
            tags: ["aerial", "underwater", "seals", "ocean", "4k"]
        ),
        WallpaperItem(
            id: "starter-curated-kelp",
            title: "Kelp Forest (4K)",
            category: "Underwater",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 372_872_516,
            previewImageURL: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/SE_A016_C009.jpg"),
            previewVideoURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/KP_A010_C002_SDR_20190717_SDR_2K_HEVC.mov"),
            fullAssetURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/KP_A010_C002_SDR_20190717_SDR_4K_HEVC.mov"),
            tags: ["aerial", "underwater", "kelp", "ocean", "4k"]
        ),
        WallpaperItem(
            id: "starter-curated-yosemite",
            title: "Yosemite (4K)",
            category: "Landscapes",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 355_119_829,
            previewImageURL: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/GL_G010_C006.jpg"),
            previewVideoURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/Y004_C015_SDR_2K_HEVC.mov"),
            fullAssetURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/Y004_C015_SDR_4K_HEVC.mov"),
            tags: ["aerial", "landscapes", "yosemite", "mountains", "4k"]
        ),
        WallpaperItem(
            id: "starter-curated-scotland",
            title: "Scotland Highlands (4K)",
            category: "Landscapes",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 593_429_379,
            previewImageURL: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/GL_G010_C006.jpg"),
            previewVideoURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/S005_C015_SDR_2K_HEVC.mov"),
            fullAssetURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/S005_C015_SDR_4K_HEVC.mov"),
            tags: ["aerial", "landscapes", "scotland", "4k"]
        ),
        WallpaperItem(
            id: "starter-curated-hawaii",
            title: "Hawaii Coast (4K)",
            category: "Landscapes",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 346_128_944,
            previewImageURL: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/GL_G010_C006.jpg"),
            previewVideoURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/comp_H005_C012_PS_v01_SDR_PS_20180925_SDR_2K_HEVC.mov"),
            fullAssetURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/comp_H005_C012_PS_v01_SDR_PS_20180925_SDR_4K_HEVC.mov"),
            tags: ["aerial", "landscapes", "hawaii", "coast", "4k"]
        ),
        WallpaperItem(
            id: "starter-curated-dubai",
            title: "Dubai Skyline (4K)",
            category: "Cities",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 491_634_874,
            previewImageURL: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/N003_C006.jpg"),
            previewVideoURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/comp_DB_D001_C001_PSNK_v06_SDR_PS_20180824_SDR_2K_HEVC.mov"),
            fullAssetURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/comp_DB_D001_C001_PSNK_v06_SDR_PS_20180824_SDR_4K_HEVC.mov"),
            tags: ["aerial", "cities", "dubai", "skyline", "4k"]
        ),
        WallpaperItem(
            id: "starter-curated-caribbean",
            title: "Caribbean Day Orbit (4K)",
            category: "Space",
            source: .starter,
            mediaType: .video,
            width: 3840,
            height: 2160,
            fileSize: 367_734_365,
            previewImageURL: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/GMT329_2_113NC_396B_1105.jpg"),
            previewVideoURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/comp_GMT308_139K_142NC_CARIBBEAN_DAY_v09_SDR_FINAL_22062018_SDR_2K_HEVC.mov"),
            fullAssetURL: URL(string: "https://sylvan.apple.com/Aerials/2x/Videos/comp_GMT308_139K_142NC_CARIBBEAN_DAY_v09_SDR_FINAL_22062018_SDR_4K_HEVC.mov"),
            tags: ["aerial", "space", "earth", "caribbean", "4k"]
        ),
        WallpaperItem(
            id: "starter-curated-jellyfish",
            title: "Jellyfish Loop (1080p Fast)",
            category: "Underwater",
            source: .starter,
            mediaType: .video,
            width: 1920,
            height: 1080,
            fileSize: 5_242_409,
            previewImageURL: nil,
            previewVideoURL: URL(string: "https://test-videos.co.uk/vids/jellyfish/mp4/h264/1080/Jellyfish_1080_10s_5MB.mp4"),
            fullAssetURL: URL(string: "https://test-videos.co.uk/vids/jellyfish/mp4/h264/1080/Jellyfish_1080_10s_5MB.mp4"),
            tags: ["underwater", "jellyfish", "1080p", "loop"]
        ),
        WallpaperItem(
            id: "starter-curated-scenic",
            title: "Sample Scenic Loop (720p Fast)",
            category: "Nature",
            source: .starter,
            mediaType: .video,
            width: 1280,
            height: 720,
            fileSize: 5_253_880,
            previewImageURL: nil,
            previewVideoURL: URL(string: "https://archive.org/download/SampleVideo1280x7205mb/SampleVideo_1280x720_5mb.mp4"),
            fullAssetURL: URL(string: "https://archive.org/download/SampleVideo1280x7205mb/SampleVideo_1280x720_5mb.mp4"),
            tags: ["nature", "scenic", "720p", "loop"]
        )
    ]

    public func fetch(
        query: WallpaperQuery,
        secrets: ApiSecrets,
        customFeedURL: URL?
    ) async throws -> ProviderResult {
        try Task.checkCancellation()

        if query.mediaType == .image {
            return ProviderResult(source: .starter, items: [], hasNextPage: false, errorMessage: nil)
        }

        if query.normalizedPage > 1 {
            return ProviderResult(source: .starter, items: [], hasNextPage: false, errorMessage: nil)
        }

        let catalogItems = try await loadResilientStarterCatalog()
        let filtered = StarterQueryFilter.apply(query: query, to: catalogItems)

        return ProviderResult(
            source: .starter,
            items: filtered,
            hasNextPage: false,
            errorMessage: nil
        )
    }

    private func loadResilientStarterCatalog() async throws -> [WallpaperItem] {
        try Task.checkCancellation()

        // 1. Primary: resources-16.tar -> entries.json
        do {
            let tarResponse = try await httpClient.get(
                resources16TarURL,
                source: .starter,
                timeoutInterval: 8
            )
            if let entriesData = try? PosixTarExtractor.extractFile(named: "entries.json", from: tarResponse.data),
               let parsedR16 = try? Self.parseAerialCatalog(data: entriesData) {
                let validR16 = parsedR16.filter { item in
                    guard let url = item.fullAssetURL else { return false }
                    return ProviderURLValidator.isAllowedRemoteURL(url)
                }
                if !validR16.isEmpty {
                    return validR16
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall through to 2x/entries.json on non-cancellation failures.
        }

        try Task.checkCancellation()

        // 2. Secondary: 2x/entries.json with 404 resilience probe
        var healthy2xItems: [WallpaperItem] = []
        do {
            let jsonResponse = try await httpClient.get(
                aerials2xURL,
                source: .starter,
                timeoutInterval: 5
            )
            if let parsed2x = try? Self.parseAerialCatalog(data: jsonResponse.data) {
                let candidates = parsed2x.filter { item in
                    guard let url = item.fullAssetURL else { return false }
                    return ProviderURLValidator.isAllowedRemoteURL(url)
                }

                if probeURLsIn2xFallback {
                    healthy2xItems = try await filterHealthyItems(candidates)
                } else {
                    healthy2xItems = candidates
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall through to curated fallback list on non-cancellation failures.
        }

        try Task.checkCancellation()

        if healthy2xItems.count >= 5 {
            return healthy2xItems
        }

        // 3. Curated fallback merge (always returns >= 10 verified HTTPS videos, never dead 404s)
        return mergeCuratedFallback(with: healthy2xItems)
    }

    private func filterHealthyItems(_ candidates: [WallpaperItem]) async throws -> [WallpaperItem] {
        guard !candidates.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (Int, WallpaperItem?).self) { group in
            for (index, item) in candidates.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    guard let url = item.fullAssetURL else { return (index, nil) }
                    let ok = try await httpClient.probeAvailability(url, timeoutInterval: 4)
                    return (index, ok ? item : nil)
                }
            }

            var indexed: [(Int, WallpaperItem)] = []
            for try await (index, maybeItem) in group {
                if let item = maybeItem {
                    indexed.append((index, item))
                }
            }
            return indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    private func mergeCuratedFallback(with survivingItems: [WallpaperItem]) -> [WallpaperItem] {
        var merged: [WallpaperItem] = []
        var seenURLs = Set<String>()

        for item in survivingItems + Self.curatedFallbackVideos {
            if let key = item.fullAssetURL?.absoluteString {
                if seenURLs.insert(key).inserted {
                    merged.append(item)
                }
            }
        }
        return merged
    }

    // MARK: - Apple Aerials Superset + Legacy Array Parsing

    public static func parseAerialCatalog(data: Data) throws -> [WallpaperItem] {
        guard let firstByte = firstNonWhitespaceByte(in: data) else {
            throw ProviderError.decodingFailed("Empty Aerial catalog payload.")
        }

        let decoder = JSONDecoder()
        if firstByte == 0x5B { // '[' legacy batch array format
            do {
                let batches = try decoder.decode([AerialPhobosBatchDTO].self, from: data)
                return mapPhobosBatches(batches)
            } catch {
                throw ProviderError.decodingFailed(error.localizedDescription)
            }
        }

        do {
            let catalog = try decoder.decode(AerialCatalogDTO.self, from: data)
            return mapAerialCatalog(catalog)
        } catch {
            throw ProviderError.decodingFailed(error.localizedDescription)
        }
    }

    private static func mapAerialCatalog(_ catalog: AerialCatalogDTO) -> [WallpaperItem] {
        var categoryByID: [String: AerialCategoryDTO] = [:]
        for cat in catalog.categories ?? [] {
            categoryByID[cat.id] = cat
        }

        var items: [WallpaperItem] = []
        items.reserveCapacity(catalog.assets.count)

        for asset in catalog.assets {
            let candidates4K = [
                (asset.url4KSDR, 3840, 2160),
                (asset.url4KSDR240FPS, 3840, 2160),
                (asset.url1080SDR, 1920, 1080),
                (asset.url1080H264, 1920, 1080),
                (asset.url4KHDR, 3840, 2160),
                (asset.url1080HDR, 1920, 1080)
            ]

            var selectedFullURL: URL?
            var selectedWidth: Int?
            var selectedHeight: Int?
            for (rawURL, w, h) in candidates4K {
                if let url = ProviderURLValidator.validatedURL(from: rawURL) {
                    selectedFullURL = url
                    selectedWidth = w
                    selectedHeight = h
                    break
                }
            }

            guard let fullAssetURL = selectedFullURL else {
                continue
            }

            let previewVideoURL = [asset.url1080SDR, asset.url1080H264, asset.url4KSDR]
                .compactMap(ProviderURLValidator.validatedURL(from:))
                .first ?? fullAssetURL

            let firstCategoryID = asset.categories?.first
            let categoryDTO = firstCategoryID.flatMap { categoryByID[$0] }
            let categoryName = deriveAerialCategoryName(from: categoryDTO?.localizedNameKey)

            let previewImageURL = ProviderURLValidator.validatedURL(from: asset.previewImage)
                ?? ProviderURLValidator.validatedURL(from: categoryDTO?.previewImage)

            let title = [asset.accessibilityLabel, asset.shotID]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Aerial Video"

            var tags: [String] = []
            if let shotID = asset.shotID?.trimmingCharacters(in: .whitespacesAndNewlines), !shotID.isEmpty {
                tags.append(shotID)
            }
            let lowerCat = categoryName.lowercased()
            if !lowerCat.isEmpty && !tags.contains(lowerCat) {
                tags.append(lowerCat)
            }
            if !tags.contains("aerial") {
                tags.append("aerial")
            }

            items.append(
                WallpaperItem(
                    id: asset.id,
                    title: title,
                    category: categoryName,
                    source: .starter,
                    mediaType: .video,
                    width: selectedWidth,
                    height: selectedHeight,
                    previewImageURL: previewImageURL,
                    previewVideoURL: previewVideoURL,
                    fullAssetURL: fullAssetURL,
                    tags: tags
                )
            )
        }

        return items
    }

    private static func mapPhobosBatches(_ batches: [AerialPhobosBatchDTO]) -> [WallpaperItem] {
        var items: [WallpaperItem] = []

        for batch in batches {
            for (index, asset) in batch.assets.enumerated() {
                if let type = asset.type?.lowercased(), type != "video" {
                    continue
                }
                guard let url = ProviderURLValidator.validatedURL(from: asset.url) else {
                    continue
                }
                let id = asset.id?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedID = (id?.isEmpty == false) ? id! : "\(batch.id)-\(index)"
                let title = asset.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedTitle = (title?.isEmpty == false) ? title! : "Aerial Video"
                let category = asset.timeOfDay?.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
                let resolvedCategory = (category?.isEmpty == false) ? category! : "Aerial"

                var tags = ["aerial"]
                if let timeOfDay = asset.timeOfDay?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   !timeOfDay.isEmpty {
                    tags.append(timeOfDay)
                }

                items.append(
                    WallpaperItem(
                        id: resolvedID,
                        title: resolvedTitle,
                        category: resolvedCategory,
                        source: .starter,
                        mediaType: .video,
                        previewVideoURL: url,
                        fullAssetURL: url,
                        tags: tags
                    )
                )
            }
        }

        return items
    }

    private static func deriveAerialCategoryName(from localizedKey: String?) -> String {
        guard let raw = localizedKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "Aerial"
        }
        let prefix = "AerialCategory"
        if raw.hasPrefix(prefix) {
            let stripped = String(raw.dropFirst(prefix.count))
            return stripped.isEmpty ? "Aerial" : stripped
        }
        return raw
    }
}

// MARK: - Custom JSON Feed Provider

public struct CustomFeedProvider: WallpaperSourceProvider {
    public let source: WallpaperSource = .customFeed
    public let httpClient: ProviderHTTPClient

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient()) {
        self.httpClient = httpClient
    }

    public func fetch(
        query: WallpaperQuery,
        secrets: ApiSecrets,
        customFeedURL: URL?
    ) async throws -> ProviderResult {
        try Task.checkCancellation()

        guard let feedURL = customFeedURL else {
            return ProviderResult(source: .customFeed, items: [], hasNextPage: false, errorMessage: nil)
        }

        guard ProviderURLValidator.isAllowedRemoteURL(feedURL) else {
            throw ProviderError.invalidURL(feedURL.absoluteString)
        }

        if query.normalizedPage > 1 {
            return ProviderResult(source: .customFeed, items: [], hasNextPage: false, errorMessage: nil)
        }

        let response = try await httpClient.get(feedURL, source: .customFeed)
        let parsedItems = try Self.parseCustomFeed(data: response.data)
        let filtered = StarterQueryFilter.apply(query: query, to: parsedItems)

        return ProviderResult(
            source: .customFeed,
            items: filtered,
            hasNextPage: false,
            errorMessage: nil,
            rateLimit: response.rateLimit
        )
    }

    public static func parseCustomFeed(data: Data) throws -> [WallpaperItem] {
        guard let firstByte = firstNonWhitespaceByte(in: data) else {
            throw ProviderError.decodingFailed("Empty custom feed JSON payload.")
        }

        let decoder = JSONDecoder()
        let rawItems: [CustomFeedItemDTO]
        do {
            if firstByte == 0x5B { // '[' bare array
                rawItems = try decoder.decode([CustomFeedItemDTO].self, from: data)
            } else if firstByte == 0x7B { // '{' wrapped object
                let envelope = try decoder.decode(CustomFeedEnvelopeDTO.self, from: data)
                rawItems = envelope.items
            } else {
                throw ProviderError.decodingFailed("Custom feed JSON must be an object or array.")
            }
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.decodingFailed(error.localizedDescription)
        }

        var mapped: [WallpaperItem] = []
        mapped.reserveCapacity(rawItems.count)

        for dto in rawItems {
            guard let assetURL = ProviderURLValidator.validatedURL(from: dto.url) else {
                continue
            }

            let previewImageURL = ProviderURLValidator.validatedURL(from: dto.previewUrl)
            let previewVideoURL = ProviderURLValidator.validatedURL(from: dto.previewVideoUrl)

            let mediaType = inferMediaType(
                explicit: dto.mediaType,
                assetURL: assetURL,
                previewVideoURL: previewVideoURL
            )

            let id: String
            if let rawID = dto.id?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty {
                id = rawID
            } else {
                id = "custom-\(sha256HexPrefix(assetURL.absoluteString, length: 16))"
            }

            let title: String
            if let rawTitle = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty {
                title = rawTitle
            } else {
                let filename = assetURL.deletingPathExtension().lastPathComponent
                title = filename.isEmpty ? "Custom Wallpaper" : filename
            }

            let category: String
            if let rawCategory = dto.category?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCategory.isEmpty {
                category = rawCategory
            } else {
                category = "Custom"
            }

            mapped.append(
                WallpaperItem(
                    id: id,
                    title: title,
                    category: category,
                    source: .customFeed,
                    mediaType: mediaType,
                    width: dto.width,
                    height: dto.height,
                    fileSize: dto.fileSize,
                    duration: dto.duration,
                    previewImageURL: previewImageURL,
                    previewVideoURL: previewVideoURL,
                    fullAssetURL: assetURL,
                    tags: dto.tags ?? [],
                    dominantColors: dto.colors ?? []
                )
            )
        }

        return mapped
    }

    private static func inferMediaType(
        explicit: String?,
        assetURL: URL,
        previewVideoURL: URL?
    ) -> WallpaperMediaType {
        if let normalized = explicit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if normalized == "video" {
                return .video
            }
            if normalized == "image" {
                return .image
            }
        }

        let ext = assetURL.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "webm"].contains(ext) {
            return .video
        }
        if ["jpg", "jpeg", "png", "heic", "webp"].contains(ext) {
            return .image
        }
        if previewVideoURL != nil {
            return .video
        }
        return .image
    }

    private static func sha256HexPrefix(_ input: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
}

// MARK: - Shared Filtering & DTOs

private enum StarterQueryFilter {
    static func apply(query: WallpaperQuery, to items: [WallpaperItem]) -> [WallpaperItem] {
        let needle = query.trimmedText.lowercased()
        let categoryNeedle = query.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var filtered = items.filter { item in
            guard query.mediaType.matches(item.mediaType) else {
                return false
            }

            if let categoryNeedle, !categoryNeedle.isEmpty {
                let itemCat = item.category.lowercased()
                let matchesCat = itemCat.contains(categoryNeedle)
                    || item.tags.contains(where: { $0.lowercased() == categoryNeedle })
                if !matchesCat {
                    return false
                }
            }

            if !needle.isEmpty {
                let inTitle = item.title.lowercased().contains(needle)
                let inCategory = item.category.lowercased().contains(needle)
                let inTags = item.tags.contains { $0.lowercased().contains(needle) }
                if !inTitle && !inCategory && !inTags {
                    return false
                }
            }

            return true
        }

        if query.sorting == .random {
            filtered.shuffle()
        }

        return filtered
    }
}

private func firstNonWhitespaceByte(in data: Data) -> UInt8? {
    for byte in data {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D:
            continue
        default:
            return byte
        }
    }
    return nil
}

private struct AerialCatalogDTO: Decodable {
    let version: Int?
    let initialAssetCount: Int?
    let localizationVersion: String?
    let categories: [AerialCategoryDTO]?
    let assets: [AerialAssetDTO]
}

private struct AerialCategoryDTO: Decodable {
    let id: String
    let localizedNameKey: String?
    let localizedDescriptionKey: String?
    let preferredOrder: Int?
    let previewImage: String?
    let representativeAssetID: String?
}

private struct AerialAssetDTO: Decodable {
    let id: String
    let accessibilityLabel: String?
    let localizedNameKey: String?
    let shotID: String?
    let group: String?
    let categories: [String]?
    let subcategories: [String]?
    let pointsOfInterest: [String: String]?
    let previewImage: String?
    let url4KSDR240FPS: String?
    let url4KSDR: String?
    let url4KHDR: String?
    let url1080SDR: String?
    let url1080HDR: String?
    let url1080H264: String?

    enum CodingKeys: String, CodingKey {
        case id
        case accessibilityLabel
        case localizedNameKey
        case shotID
        case group
        case categories
        case subcategories
        case pointsOfInterest
        case previewImage
        case url4KSDR240FPS = "url-4K-SDR-240FPS"
        case url4KSDR = "url-4K-SDR"
        case url4KHDR = "url-4K-HDR"
        case url1080SDR = "url-1080-SDR"
        case url1080HDR = "url-1080-HDR"
        case url1080H264 = "url-1080-H264"
    }
}

private struct AerialPhobosBatchDTO: Decodable {
    let id: String
    let assets: [AerialPhobosAssetDTO]
}

private struct AerialPhobosAssetDTO: Decodable {
    let id: String?
    let url: String
    let accessibilityLabel: String?
    let type: String?
    let timeOfDay: String?
}

private struct CustomFeedEnvelopeDTO: Decodable {
    let version: Int?
    let title: String?
    let items: [CustomFeedItemDTO]
}

private struct CustomFeedItemDTO: Decodable {
    let id: String?
    let title: String?
    let mediaType: String?
    let url: String?
    let previewUrl: String?
    let previewVideoUrl: String?
    let category: String?
    let width: Int?
    let height: Int?
    let duration: Double?
    let fileSize: Int64?
    let tags: [String]?
    let colors: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case mediaType
        case url
        case fullAssetURL
        case previewUrl
        case previewImageURL
        case previewVideoUrl
        case previewVideoURL
        case category
        case width
        case height
        case duration
        case fileSize
        case tags
        case colors
        case dominantColors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        self.url = try Self.decodeNonEmptyString(
            from: container,
            primaryKey: .url,
            fallbackKey: .fullAssetURL
        )
        self.previewUrl = try Self.decodeNonEmptyString(
            from: container,
            primaryKey: .previewUrl,
            fallbackKey: .previewImageURL
        )
        self.previewVideoUrl = try Self.decodeNonEmptyString(
            from: container,
            primaryKey: .previewVideoUrl,
            fallbackKey: .previewVideoURL
        )
        self.category = try container.decodeIfPresent(String.self, forKey: .category)
        self.width = try container.decodeIfPresent(Int.self, forKey: .width)
        self.height = try container.decodeIfPresent(Int.self, forKey: .height)
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        self.fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags)
        self.colors = try Self.decodeNonEmptyStringArray(
            from: container,
            primaryKey: .colors,
            fallbackKey: .dominantColors
        )
    }

    private static func decodeNonEmptyString(
        from container: KeyedDecodingContainer<CodingKeys>,
        primaryKey: CodingKeys,
        fallbackKey: CodingKeys
    ) throws -> String? {
        if let primary = try container.decodeIfPresent(String.self, forKey: primaryKey) {
            let trimmed = primary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let fallback = try container.decodeIfPresent(String.self, forKey: fallbackKey) {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func decodeNonEmptyStringArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        primaryKey: CodingKeys,
        fallbackKey: CodingKeys
    ) throws -> [String]? {
        if let primary = try container.decodeIfPresent([String].self, forKey: primaryKey) {
            let cleaned = primary
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        if let fallback = try container.decodeIfPresent([String].self, forKey: fallbackKey) {
            let cleaned = fallback
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }
}
