import AppKit
import AVFoundation
import Darwin
import Foundation
import os
import Testing
import AuraWallCore

// MARK: - Concurrency Helper

final class LockedBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ initial: Value) {
        self.lock = OSAllocatedUnfairLock(initialState: initial)
    }

    func withValue<T: Sendable>(_ body: @Sendable (inout Value) -> T) -> T {
        lock.withLock(body)
    }

    var value: Value {
        lock.withLock { $0 }
    }
}

// MARK: - Environment & Fixtures

enum E2EEnvironment {
    static var mockBaseURLFromEnv: URL? {
        guard let raw = ProcessInfo.processInfo.environment["AURAWALL_E2E_MOCK_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    static var noLive: Bool {
        guard let raw = ProcessInfo.processInfo.environment["AURAWALL_E2E_NO_LIVE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static var fixturesDirectory: URL {
        if let raw = ProcessInfo.processInfo.environment["AURAWALL_E2E_FIXTURES_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        // Resolve ../../../Tests/E2E/fixtures relative to this source file
        // (.../Tests/E2E/SwiftE2E/Tests/AuraWallE2ETests/E2EHelpers.swift -> .../Tests/E2E/fixtures)
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures", isDirectory: true)
    }
}

// MARK: - Loopback Fallback HTTP Server (used only when AURAWALL_E2E_MOCK_URL is unset)

final class LoopbackMockHTTPServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    let baseURL: URL
    private let stopFlag = LockedBox(false)
    private let queue = DispatchQueue(label: "com.aurawall.e2e.loopback", attributes: .concurrent)

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var reuse: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 16) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &addrLen)
            }
        }
        guard nameResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.baseURL = URL(string: "http://127.0.0.1:\(self.port)")!

        startAcceptLoop()
    }

    func stop() {
        stopFlag.withValue { $0 = true }
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    private func startAcceptLoop() {
        let fd = listenFD
        let base = baseURL.absoluteString
        let flag = stopFlag
        queue.async {
            while !flag.value {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(fd, $0, &clientLen)
                    }
                }
                if clientFD < 0 {
                    if flag.value || errno == EBADF || errno == EINVAL {
                        break
                    }
                    continue
                }
                self.queue.async {
                    Self.handleClient(clientFD: clientFD, baseURLString: base)
                }
            }
        }
    }

    private static func handleClient(clientFD: Int32, baseURLString: String) {
        defer { Darwin.close(clientFD) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = Darwin.recv(clientFD, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let rawRequest = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        let lines = rawRequest.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]).uppercased() : "GET"
        let fullPath = parts.count > 1 ? String(parts[1]) : "/"
        let pathAndQuery = fullPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pathAndQuery.first ?? "/")
        let rawQuery = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : ""
        var queryParams: [String: String] = [:]
        for pair in rawQuery.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if let rawKey = kv.first {
                let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
                let rawVal = kv.count > 1 ? String(kv[1]).replacingOccurrences(of: "+", with: " ") : ""
                queryParams[key] = rawVal.removingPercentEncoding ?? rawVal
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[name] = value
            }
        }
        let rangeHeader = headers["range"]

        var (status, statusText, contentType, body, routeHeaders) = route(
            path: path,
            query: queryParams,
            headers: headers,
            baseURLString: baseURLString
        )
        var extraHeaders = ""
        for (k, v) in routeHeaders.sorted(by: { $0.key < $1.key }) {
            extraHeaders += "\(k): \(v)\r\n"
        }

        if status == 200, path.hasPrefix("/media/"), !body.isEmpty {
            extraHeaders += "Accept-Ranges: bytes\r\n"
            if let rangeHeader {
                let total = body.count
                if let sliceRange = parseByteRange(rangeHeader, totalLength: total) {
                    let sliced = Data(body[sliceRange])
                    status = 206
                    statusText = "Partial Content"
                    body = sliced
                    extraHeaders += "Content-Range: bytes \(sliceRange.lowerBound)-\(sliceRange.upperBound)/\(total)\r\n"
                } else {
                    status = 416
                    statusText = "Range Not Satisfiable"
                    contentType = "text/plain; charset=utf-8"
                    body = Data("Range Not Satisfiable".utf8)
                    extraHeaders += "Content-Range: bytes */\(total)\r\n"
                }
            }
        }

        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\(extraHeaders)Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        if method != "HEAD" {
            payload.append(body)
        }
        payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < ptr.count {
                let n = Darwin.send(clientFD, base.advanced(by: sent), ptr.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private static func parseByteRange(_ headerValue: String, totalLength: Int) -> ClosedRange<Int>? {
        guard totalLength > 0 else { return nil }
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst("bytes=".count))
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }

        let startPart = String(bounds[0]).trimmingCharacters(in: .whitespaces)
        let endPart = String(bounds[1]).trimmingCharacters(in: .whitespaces)
        guard !startPart.isEmpty || !endPart.isEmpty else { return nil }

        let start: Int
        let end: Int
        if startPart.isEmpty {
            guard let suffixLen = Int(endPart), suffixLen > 0 else { return nil }
            start = max(0, totalLength - suffixLen)
            end = totalLength - 1
        } else {
            guard let parsedStart = Int(startPart), parsedStart >= 0 else { return nil }
            start = parsedStart
            if endPart.isEmpty {
                end = totalLength - 1
            } else {
                guard let parsedEnd = Int(endPart) else { return nil }
                end = min(parsedEnd, totalLength - 1)
            }
        }

        guard start <= end, start < totalLength else { return nil }
        return start...end
    }

    private static func loadFixtureText(named filename: String, baseURLString: String) -> String? {
        let fixtureURL = E2EEnvironment.fixturesDirectory.appendingPathComponent(filename, isDirectory: false)
        guard let text = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
            return nil
        }
        return text.replacingOccurrences(of: "https://mock.aurawall.local", with: baseURLString)
    }

    private static func buildPOSIXTar(files: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        for file in files {
            var header = [UInt8](repeating: 0, count: 512)
            let nameBytes = Array(file.name.utf8.prefix(100))
            header.replaceSubrange(0..<nameBytes.count, with: nameBytes)

            let modeBytes = Array("0000644\0".utf8)
            header.replaceSubrange(100..<(100 + modeBytes.count), with: modeBytes)

            let uidBytes = Array("0000000\0".utf8)
            header.replaceSubrange(108..<(108 + uidBytes.count), with: uidBytes)
            header.replaceSubrange(116..<(116 + uidBytes.count), with: uidBytes)

            let sizeStr = String(format: "%011o\0", file.data.count)
            let sizeBytes = Array(sizeStr.utf8)
            header.replaceSubrange(124..<(124 + sizeBytes.count), with: sizeBytes)

            let mtimeBytes = Array("14524317400\0".utf8)
            header.replaceSubrange(136..<(136 + mtimeBytes.count), with: mtimeBytes)

            for idx in 148..<156 {
                header[idx] = 0x20
            }
            header[156] = 0x30 // '0' regular file

            let magicBytes = Array("ustar\0".utf8)
            header.replaceSubrange(257..<(257 + magicBytes.count), with: magicBytes)
            let versionBytes = Array("00".utf8)
            header.replaceSubrange(263..<(263 + versionBytes.count), with: versionBytes)

            let checksum = header.reduce(0) { $0 + Int($1) }
            let checksumStr = String(format: "%06o\0 ", checksum)
            let checksumBytes = Array(checksumStr.utf8)
            header.replaceSubrange(148..<(148 + checksumBytes.count), with: checksumBytes)

            archive.append(contentsOf: header)
            archive.append(file.data)
            let rem = file.data.count % 512
            if rem != 0 {
                archive.append(contentsOf: [UInt8](repeating: 0, count: 512 - rem))
            }
        }
        archive.append(contentsOf: [UInt8](repeating: 0, count: 1024))
        return archive
    }

    private static func patchWallhavenSearchJSON(
        _ jsonText: String,
        queryParam: String?,
        sorting: String?,
        page: Int
    ) -> Data {
        guard let rawData = jsonText.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
              var meta = object["meta"] as? [String: Any] else {
            return Data(jsonText.utf8)
        }
        meta["current_page"] = page
        if let queryParam {
            meta["query"] = queryParam
        } else {
            meta["query"] = NSNull()
        }
        if sorting == "random" {
            meta["seed"] = "uwn0FK"
        }
        object["meta"] = meta
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data(jsonText.utf8)
    }

    private static func route(
        path: String,
        query: [String: String],
        headers: [String: String],
        baseURLString: String
    ) -> (Int, String, String, Data, [String: String]) {
        if path.hasPrefix("/aerials/missing/") {
            return (
                404,
                "Not Found",
                "application/json",
                Data(#"{"httpStatusCode":404,"traceKey":"e2e-missing-asset"}"#.utf8),
                [:]
            )
        }

        switch path {
        case "/aerials/2x/entries.json":
            if let json = loadFixtureText(named: "aerial_2x_entries.json", baseURLString: baseURLString) {
                return (200, "OK", "application/json", Data(json.utf8), [:])
            }
            var assetsJSON: [String] = []
            for idx in 1...12 {
                assetsJSON.append("""
                {"accessibilityLabel":"Missing \(idx)","id":"A2E1B1F0-000\(idx)","url-4K-SDR":"\(baseURLString)/aerials/missing/M_\(idx).mov"}
                """)
            }
            assetsJSON.append("""
            {"accessibilityLabel":"Hong Kong Harbor","id":"FE8E1171-C013-4000-8000-000000000013","url-4K-SDR":"\(baseURLString)/media/sample_aerial_4k.mov","url-1080-SDR":"\(baseURLString)/media/sample_video.mov"}
            """)
            let fallback = "{\"version\":1,\"assets\":[\(assetsJSON.joined(separator: ","))]}"
            return (200, "OK", "application/json", Data(fallback.utf8), [:])

        case "/aerials/resources-16.tar":
            let entriesText = loadFixtureText(named: "aerial_r16_entries.json", baseURLString: baseURLString)
                ?? """
                {"version":1,"categories":[{"id":"cat-1","localizedNameKey":"AerialCategoryUnderwater"}],"assets":[{"id":"r16-1","accessibilityLabel":"Seals Underwater","categories":["cat-1"],"url-4K-SDR":"\(baseURLString)/media/sample_aerial_4k.mov","url-1080-SDR":"\(baseURLString)/media/sample_video.mov"}]}
                """
            let tarData = buildPOSIXTar(files: [(name: "entries.json", data: Data(entriesText.utf8))])
            return (200, "OK", "application/octet-stream", tarData, [:])

        case "/aerials/phobos/entries.json":
            if let json = loadFixtureText(named: "aerial_phobos_array.json", baseURLString: baseURLString) {
                return (200, "OK", "application/json", Data(json.utf8), [:])
            }
            return (404, "Not Found", "application/json", Data(#"{"error":"Not Found"}"#.utf8), [:])

        case "/wallhaven/api/v1/search":
            let qVal = query["q"]
            if (query["page"].flatMap { Int($0) ?? -1 } ?? 1) <= 0 || qVal == "error500" {
                return (
                    500,
                    "Internal Server Error",
                    "text/html; charset=UTF-8",
                    Data("<html><head><title>500</title></head><body><h1>It broke - wallhaven.cc</h1></body></html>".utf8),
                    [:]
                )
            }
            let apiKey = query["apikey"] ?? headers["x-api-key"] ?? ""
            if apiKey == "invalid_key_123" {
                return (401, "Unauthorized", "application/json", Data(#"{"error":"Unauthorized"}"#.utf8), [:])
            }
            if qVal == "ratelimit" {
                return (
                    429,
                    "Too Many Requests",
                    "text/plain; charset=utf-8",
                    Data("Too Many Requests".utf8),
                    [
                        "Retry-After": "60",
                        "x-ratelimit-limit": "45",
                        "x-ratelimit-remaining": "0"
                    ]
                )
            }
            let pageNum = max(1, Int(query["page"] ?? "1") ?? 1)
            if query["purity"] == "001" && apiKey.isEmpty {
                let queryJSON: String
                if let qVal,
                   let encoded = try? JSONEncoder().encode(qVal),
                   let str = String(data: encoded, encoding: .utf8) {
                    queryJSON = str
                } else {
                    queryJSON = "null"
                }
                let emptyPayload = """
                {
                  "data": [],
                  "meta": {
                    "current_page": \(pageNum),
                    "last_page": 1,
                    "per_page": 24,
                    "total": 0,
                    "query": \(queryJSON),
                    "seed": null
                  }
                }
                """
                return (
                    200,
                    "OK",
                    "application/json",
                    Data(emptyPayload.utf8),
                    ["x-ratelimit-limit": "45", "x-ratelimit-remaining": "44"]
                )
            }
            if qVal == "id:37" {
                if let json = loadFixtureText(named: "wallhaven_tag_object_query.json", baseURLString: baseURLString) {
                    return (
                        200,
                        "OK",
                        "application/json",
                        Data(json.utf8),
                        ["x-ratelimit-limit": "45", "x-ratelimit-remaining": "44"]
                    )
                }
                let tagFallback = """
                {
                  "data": [
                    {
                      "id": "37tag1",
                      "url": "https://wallhaven.cc/w/37tag1",
                      "source": "",
                      "purity": "sfw",
                      "category": "general",
                      "dimension_x": 2560,
                      "dimension_y": 1440,
                      "file_size": 1984320,
                      "file_type": "image/jpeg",
                      "created_at": "2026-11-10 14:20:00",
                      "colors": ["#294122"],
                      "path": "\(baseURLString)/media/sample_image.jpg",
                      "thumbs": {
                        "large": "\(baseURLString)/media/sample_image.jpg",
                        "original": "\(baseURLString)/media/sample_image.jpg",
                        "small": "\(baseURLString)/media/sample_image.jpg"
                      }
                    }
                  ],
                  "meta": {
                    "current_page": \(pageNum),
                    "last_page": 5,
                    "per_page": 24,
                    "total": 102,
                    "query": {"id": 37, "tag": "nature"},
                    "seed": "uwn0FK"
                  }
                }
                """
                return (
                    200,
                    "OK",
                    "application/json",
                    Data(tagFallback.utf8),
                    ["x-ratelimit-limit": "45", "x-ratelimit-remaining": "44"]
                )
            }
            if let json = loadFixtureText(named: "wallhaven_string_query.json", baseURLString: baseURLString) {
                let patched = patchWallhavenSearchJSON(
                    json,
                    queryParam: qVal,
                    sorting: query["sorting"],
                    page: pageNum
                )
                return (
                    200,
                    "OK",
                    "application/json",
                    patched,
                    ["x-ratelimit-limit": "45", "x-ratelimit-remaining": "44"]
                )
            }
            let fallback = """
            {
              "data": [
                {
                  "id": "9oe8yd",
                  "url": "https://wallhaven.cc/w/9oe8yd",
                  "source": "",
                  "purity": "sfw",
                  "category": "general",
                  "dimension_x": 3840,
                  "dimension_y": 1634,
                  "file_size": 2814332,
                  "file_type": "image/jpeg",
                  "created_at": "2026-11-14 10:41:46",
                  "colors": ["#000000", "#663300"],
                  "path": "\(baseURLString)/media/sample_image.jpg",
                  "thumbs": {
                    "large": "\(baseURLString)/media/sample_image.jpg",
                    "original": "\(baseURLString)/media/sample_image.jpg",
                    "small": "\(baseURLString)/media/sample_image.jpg"
                  }
                },
                {
                  "id": "k7m2x9",
                  "url": "https://wallhaven.cc/w/k7m2x9",
                  "source": "https://example.com/alpine-ridge",
                  "purity": "sfw",
                  "category": "general",
                  "dimension_x": 3840,
                  "dimension_y": 2160,
                  "file_size": 3451200,
                  "file_type": "image/png",
                  "created_at": "2026-11-12 08:15:00",
                  "colors": ["#003366"],
                  "path": "\(baseURLString)/media/sample_image.png",
                  "thumbs": {
                    "large": "\(baseURLString)/media/sample_image.jpg",
                    "original": "\(baseURLString)/media/sample_image.png",
                    "small": "\(baseURLString)/media/sample_image.jpg"
                  }
                }
              ],
              "meta": {
                "current_page": 1,
                "last_page": 13,
                "per_page": 24,
                "total": 310,
                "query": "landscape",
                "seed": null
              }
            }
            """
            let patchedFallback = patchWallhavenSearchJSON(
                fallback,
                queryParam: qVal,
                sorting: query["sorting"],
                page: pageNum
            )
            return (
                200,
                "OK",
                "application/json",
                patchedFallback,
                ["x-ratelimit-limit": "45", "x-ratelimit-remaining": "44"]
            )

        case "/pexels/v1/videos/search", "/pexels/v1/videos/popular", "/pexels/v1/search", "/pexels/v1/curated":
            let auth = headers["authorization"] ?? ""
            if auth.isEmpty || auth.hasPrefix("Bearer ") || auth == "invalid_key_123" {
                let errJSON = loadFixtureText(named: "pexels_401.json", baseURLString: baseURLString)
                    ?? #"{"status":401,"code":"Unauthorized","message":"Invalid API key"}"#
                return (401, "Unauthorized", "application/json; charset=utf-8", Data(errJSON.utf8), [:])
            }
            if query["query"] == "ratelimit" {
                return (
                    429,
                    "Too Many Requests",
                    "application/json",
                    Data(#"{"status":429,"code":"Too Many Requests","message":"Rate limit exceeded"}"#.utf8),
                    [
                        "X-Ratelimit-Limit": "200",
                        "X-Ratelimit-Remaining": "0",
                        "Retry-After": "60"
                    ]
                )
            }
            let pexelsHeaders = [
                "X-Ratelimit-Limit": "200",
                "X-Ratelimit-Remaining": "199",
                "X-Ratelimit-Reset": "1795644000"
            ]
            let isVideos = path.contains("videos")
            let fixtureName = isVideos ? "pexels_videos_search.json" : "pexels_photos_curated.json"
            if let json = loadFixtureText(named: fixtureName, baseURLString: baseURLString) {
                return (200, "OK", "application/json", Data(json.utf8), pexelsHeaders)
            }
            if isVideos {
                let fallback = """
                {
                  "page": 1,
                  "per_page": 15,
                  "total_results": 1200,
                  "next_page": "\(baseURLString)/pexels/v1/videos/search?page=2&per_page=15&query=waves",
                  "videos": [
                    {
                      "id": 855675,
                      "width": 3840,
                      "height": 2160,
                      "url": "https://www.pexels.com/video/aerial-view-of-ocean-waves-855675/",
                      "image": "\(baseURLString)/media/sample_image.jpg",
                      "duration": 15,
                      "user": { "id": 293393, "name": "Kelly" },
                      "video_files": [
                        { "id": 14750, "quality": null, "file_type": "application/x-mpegURL", "width": null, "height": null, "fps": null, "link": "\(baseURLString)/media/stream.m3u8" },
                        { "id": 14751, "quality": "hd", "file_type": "video/mp4", "width": 1080, "height": 1920, "fps": 30.0, "link": "\(baseURLString)/media/sample_video.mp4" },
                        { "id": 14752, "quality": "sd", "file_type": "video/mp4", "width": 640, "height": 360, "fps": 30.0, "link": "\(baseURLString)/media/sample_video.mp4" },
                        { "id": 14755, "quality": "uhd", "file_type": "video/mp4", "width": 3840, "height": 2160, "fps": 30.0, "link": "\(baseURLString)/media/sample_video.mp4" }
                      ]
                    }
                  ]
                }
                """
                return (200, "OK", "application/json", Data(fallback.utf8), pexelsHeaders)
            } else {
                let fallback = """
                {
                  "page": 1,
                  "per_page": 15,
                  "total_results": 8000,
                  "next_page": "\(baseURLString)/pexels/v1/curated?page=2&per_page=15",
                  "photos": [
                    {
                      "id": 2014422,
                      "width": 3840,
                      "height": 2160,
                      "photographer": "Joey Farina",
                      "avg_color": "#978E82",
                      "alt": "Brown Rocks During Golden Hour",
                      "src": {
                        "original": "\(baseURLString)/media/sample_image.jpg",
                        "large2x": "\(baseURLString)/media/sample_image.jpg",
                        "large": "\(baseURLString)/media/sample_image.jpg",
                        "medium": "\(baseURLString)/media/sample_image.jpg"
                      }
                    },
                    {
                      "id": 2014423,
                      "width": 2560,
                      "height": 1440,
                      "photographer": "Alex Rivera",
                      "src": {
                        "original": "\(baseURLString)/media/sample_image.png",
                        "large": "\(baseURLString)/media/sample_image.jpg"
                      }
                    }
                  ]
                }
                """
                return (200, "OK", "application/json", Data(fallback.utf8), pexelsHeaders)
            }

        case "/pixabay/api/videos/", "/pixabay/api/videos", "/pixabay/api/", "/pixabay/api":
            let key = query["key"] ?? ""
            if key.isEmpty || key == "invalid_key_123" {
                return (
                    400,
                    "Bad Request",
                    "text/html; charset=utf-8",
                    Data("[ERROR 400] Invalid or missing API key (https://pixabay.com/api/docs/).".utf8),
                    [:]
                )
            }
            if query["q"] == "ratelimit" {
                return (
                    429,
                    "Too Many Requests",
                    "text/html; charset=utf-8",
                    Data("API rate limit exceeded".utf8),
                    [
                        "X-RateLimit-Limit": "100",
                        "X-RateLimit-Remaining": "0",
                        "Retry-After": "60"
                    ]
                )
            }
            let pixabayHeaders = [
                "X-RateLimit-Limit": "100",
                "X-RateLimit-Remaining": "99",
                "X-RateLimit-Reset": "60"
            ]
            let isVideos = path.contains("videos")
            let fixtureName = isVideos ? "pixabay_videos.json" : "pixabay_photos.json"
            if let json = loadFixtureText(named: fixtureName, baseURLString: baseURLString) {
                return (200, "OK", "application/json", Data(json.utf8), pixabayHeaders)
            }
            if isVideos {
                let fallback = """
                {
                  "total": 2,
                  "totalHits": 2,
                  "hits": [
                    {
                      "id": 12573,
                      "tags": "ocean, waves, aerial",
                      "duration": 18,
                      "videos": {
                        "large": { "url": "\(baseURLString)/media/sample_video.mp4", "width": 3840, "height": 2160, "size": 12450000, "thumbnail": "\(baseURLString)/media/sample_image.jpg" },
                        "medium": { "url": "\(baseURLString)/media/sample_video.mp4", "width": 1920, "height": 1080, "size": 4520000, "thumbnail": "\(baseURLString)/media/sample_image.jpg" },
                        "small": { "url": "\(baseURLString)/media/sample_video.mp4", "width": 1280, "height": 720, "size": 2100000, "thumbnail": "\(baseURLString)/media/sample_image.jpg" }
                      }
                    },
                    {
                      "id": 24891,
                      "tags": "forest, mist, morning",
                      "duration": 12,
                      "videos": {
                        "large": { "url": "", "width": 0, "height": 0, "size": 0, "thumbnail": "\(baseURLString)/media/sample_image.jpg" },
                        "medium": { "url": "\(baseURLString)/media/sample_video.mp4", "width": 1920, "height": 1080, "size": 3180000, "thumbnail": "\(baseURLString)/media/sample_image.jpg" },
                        "small": { "url": "\(baseURLString)/media/sample_video.mp4", "width": 1280, "height": 720, "size": 1540000, "thumbnail": "\(baseURLString)/media/sample_image.jpg" }
                      }
                    }
                  ]
                }
                """
                return (200, "OK", "application/json", Data(fallback.utf8), pixabayHeaders)
            } else {
                let fallback = """
                {
                  "total": 2,
                  "totalHits": 2,
                  "hits": [
                    {
                      "id": 736885,
                      "tags": "tree, sunset, clouds",
                      "webformatURL": "\(baseURLString)/media/sample_image.jpg",
                      "largeImageURL": "\(baseURLString)/media/sample_image.jpg",
                      "imageWidth": 3840,
                      "imageHeight": 2160,
                      "imageSize": 1840000
                    },
                    {
                      "id": 736886,
                      "tags": "mountain, snow, dawn",
                      "webformatURL": "\(baseURLString)/media/sample_image.png",
                      "largeImageURL": "\(baseURLString)/media/sample_image.png",
                      "imageWidth": 2560,
                      "imageHeight": 1440,
                      "imageSize": 1240000
                    }
                  ]
                }
                """
                return (200, "OK", "application/json", Data(fallback.utf8), pixabayHeaders)
            }

        case "/custom/wrapped.json":
            let json = """
            {
              "version": 1,
              "title": "AuraWall E2E Custom Feed",
              "items": [
                {
                  "id": "custom-ocean-01",
                  "title": "Pacific Dawn",
                  "mediaType": "video",
                  "url": "\(baseURLString)/media/sample_video.mp4",
                  "previewUrl": "\(baseURLString)/media/sample_image.jpg",
                  "previewVideoUrl": "\(baseURLString)/media/sample_video.mp4",
                  "category": "Nature",
                  "width": 3840,
                  "height": 2160,
                  "duration": 18.5,
                  "fileSize": 1834,
                  "tags": ["ocean", "dawn", "4k"],
                  "colors": ["#0F2C3F", "#E68A5C"]
                },
                {
                  "id": "custom-aerial-02",
                  "title": "Harbor Dusk Loop",
                  "mediaType": "video",
                  "url": "\(baseURLString)/media/sample_aerial_4k.mov",
                  "previewUrl": "\(baseURLString)/media/seal.jpg",
                  "previewVideoUrl": "\(baseURLString)/media/sample_video.mov",
                  "category": "Cities",
                  "width": 3840,
                  "height": 2160,
                  "duration": 12.0,
                  "fileSize": 2898,
                  "tags": ["harbor", "aerial", "dusk"],
                  "colors": ["#1A2238", "#FF6A3D"]
                },
                {
                  "id": "custom-ridge-03",
                  "title": "Blue Ridge Still",
                  "mediaType": "image",
                  "url": "\(baseURLString)/media/sample_image.jpg",
                  "previewUrl": "\(baseURLString)/media/sample_image.jpg",
                  "category": "Landscapes",
                  "width": 320,
                  "height": 180,
                  "fileSize": 2996,
                  "tags": ["mountain", "still"],
                  "colors": ["#1E4E79", "#E5B84B"]
                }
              ]
            }
            """
            return (200, "OK", "application/json", Data(json.utf8), [:])

        case "/custom/array.json":
            let json = """
            [
              {
                "url": "\(baseURLString)/media/sample_video.mp4",
                "previewUrl": "",
                "category": "Abstract",
                "tags": ["minimal", "loop"]
              },
              {
                "url": "\(baseURLString)/media/sample_image.png",
                "previewUrl": "\(baseURLString)/media/sample_image.png",
                "width": 320,
                "height": 180
              }
            ]
            """
            return (200, "OK", "application/json", Data(json.utf8), [:])

        case "/custom/empty.json":
            let json = """
            {
              "version": 1,
              "title": "Empty Feed",
              "items": []
            }
            """
            return (200, "OK", "application/json", Data(json.utf8), [:])

        case "/custom/malformed.json":
            return (200, "OK", "application/json", Data(#"{"version": 1, "items": [{"id": "broken""#.utf8), [:])

        case "/custom/error500.html":
            return (500, "Internal Server Error", "text/html; charset=utf-8", Data("<html><body><h1>500 Internal Server Error</h1></body></html>".utf8), [:])

        case "/media/broken_500.mp4":
            return (500, "Internal Server Error", "text/plain; charset=utf-8", Data("Internal Server Error".utf8), [:])

        case "/media/sample_video.mp4", "/media/sample_aerial_4k.mov", "/media/sample_video.mov":
            let filename = String(path.dropFirst("/media/".count))
            let data = E2EHelpers.fixtureMediaBytes(named: filename) ?? E2EHelpers.fallbackValidMP4Data()
            let mime = path.hasSuffix(".mov") ? "video/quicktime" : "video/mp4"
            return (200, "OK", mime, data, [:])

        case "/media/sample_image.jpg", "/media/sample_still.jpg", "/media/seal.jpg":
            let filename = String(path.dropFirst("/media/".count))
            let data = E2EHelpers.fixtureMediaBytes(named: filename) ?? E2EHelpers.fallbackValidJPEGData()
            return (200, "OK", "image/jpeg", data, [:])

        case "/media/sample_image.png":
            let data = E2EHelpers.fixtureMediaBytes(named: "sample_image.png") ?? E2EHelpers.fallbackValidPNGData()
            return (200, "OK", "image/png", data, [:])

        case "/media/sample_image.heic":
            let data = E2EHelpers.fixtureMediaBytes(named: "sample_image.heic") ?? E2EHelpers.fallbackValidPNGData()
            return (200, "OK", "image/heic", data, [:])

        default:
            return (404, "Not Found", "text/plain", Data("Not Found".utf8), [:])
        }
    }
}

// MARK: - Observed Wallpaper Engine Helpers

struct RecordedDesktopImageCall: Sendable, Equatable {
    let imageURL: URL
    let displayID: UInt32
    let allowClipping: Bool?
    let hasFillColor: Bool
}

final class E2EMockScreen: NSScreen, @unchecked Sendable {
    private let mockID: UInt32
    private let mockFrame: NSRect
    private let mockName: String

    init(id: UInt32, frame: NSRect, name: String) {
        self.mockID = id
        self.mockFrame = frame
        self.mockName = name
        super.init()
    }

    override var frame: NSRect { mockFrame }
    override var localizedName: String { mockName }
    override var backingScaleFactor: CGFloat { 2.0 }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: mockID)]
    }
}

// MARK: - E2E Helpers

enum E2EHelpers {
    // Valid 64x64 H.264 MP4 generated via AVAssetWriter (2466 bytes)
    private static let minimalMP4Base64 =
        "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"

    static func makeTempDirectory(prefix: String = "AuraWallE2E") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func withIsolatedWorkspace(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> Void
    ) async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    static func withMockBaseURL(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (URL) async throws -> Void
    ) async throws {
        if let envURL = E2EEnvironment.mockBaseURLFromEnv {
            try await body(envURL)
            return
        }
        let server = try LoopbackMockHTTPServer()
        defer { server.stop() }
        try await body(server.baseURL)
    }

    static func makeLibraryStore(in tempDir: URL) -> LibraryStore {
        LibraryStore(baseDirectory: tempDir.appendingPathComponent("library", isDirectory: true))
    }

    static func makeSecretStore(in tempDir: URL) -> SecretStore {
        SecretStore(fileURL: tempDir.appendingPathComponent("secrets/secrets.json", isDirectory: false))
    }

    static func makeCacheManager(in tempDir: URL) -> MediaCacheManager {
        MediaCacheManager(cacheDirectory: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    static func makeCatalogService() -> CatalogService {
        CatalogService()
    }

    static func makeMockCatalogService(baseURL: URL) -> CatalogService {
        CatalogService(providers: [
            StarterVideoProvider(
                resources16TarURL: baseURL.appendingPathComponent("aerials/resources-16.tar"),
                aerials2xURL: baseURL.appendingPathComponent("aerials/2x/entries.json"),
                probeURLsIn2xFallback: true
            ),
            WallhavenProvider(baseURL: baseURL.appendingPathComponent("wallhaven")),
            PexelsProvider(baseURL: baseURL.appendingPathComponent("pexels")),
            PixabayProvider(baseURL: baseURL.appendingPathComponent("pixabay")),
            CustomFeedProvider()
        ])
    }

    static func makeQuery(
        text: String = "",
        mediaType: WallpaperMediaFilter = .all,
        sources: Set<WallpaperSource> = Set(WallpaperSource.allCases),
        category: String? = nil,
        minResolution: String? = nil,
        aspectRatio: String? = nil,
        sorting: CatalogSort = .trending,
        page: Int = 1
    ) -> WallpaperQuery {
        WallpaperQuery(
            text: text,
            mediaType: mediaType,
            sources: sources,
            category: category,
            minResolution: minResolution,
            aspectRatio: aspectRatio,
            sorting: sorting,
            page: page
        )
    }

    @MainActor
    static func makeObservedWallpaperEngine(
        in tempDir: URL,
        extractFirstFrameStill: Bool = false,
        mockDisplays: [(id: UInt32, frame: NSRect, name: String)]? = nil,
        screensProvider: (@MainActor () -> [NSScreen])? = nil
    ) -> (engine: WallpaperEngine, desktopCalls: LockedBox<[RecordedDesktopImageCall]>) {
        let desktopCalls = LockedBox<[RecordedDesktopImageCall]>([])
        let displayManager: DisplayManager
        if let screensProvider {
            displayManager = DisplayManager(screensProvider: screensProvider)
        } else if let mockDisplays {
            displayManager = DisplayManager(screensProvider: {
                mockDisplays.map { E2EMockScreen(id: $0.id, frame: $0.frame, name: $0.name) }
            })
        } else if NSScreen.screens.isEmpty {
            displayManager = DisplayManager(screensProvider: {
                [E2EMockScreen(id: 1, frame: NSRect(x: 0, y: 0, width: 1280, height: 720), name: "E2E-Headless-1")]
            })
        } else {
            displayManager = DisplayManager()
        }

        let stillsDir = tempDir.appendingPathComponent("Stills", isDirectory: true)
        let engine = WallpaperEngine(
            displayManager: displayManager,
            extractFirstFrameStill: extractFirstFrameStill,
            desktopImageSetter: { url, screen, options in
                let displayID = DisplayManager.displayID(for: screen) ?? 0
                let allowClipping = options[.allowClipping] as? Bool
                let hasFillColor = options[.fillColor] != nil
                desktopCalls.withValue {
                    $0.append(
                        RecordedDesktopImageCall(
                            imageURL: url,
                            displayID: displayID,
                            allowClipping: allowClipping,
                            hasFillColor: hasFillColor
                        )
                    )
                }
            },
            stillCacheDirectory: stillsDir
        )
        return (engine, desktopCalls)
    }

    static func extractItems(from aggregate: CatalogAggregateResult) -> [WallpaperItem] {
        aggregate.items
    }

    static func extractProviderResults(from aggregate: CatalogAggregateResult) -> [ProviderResult] {
        aggregate.providerResults
    }

    static func posixPermissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attrs[.posixPermissions] as? Int)
    }

    static func menuBarStatusLabel(
        for decision: PowerDecision,
        activeMediaType: WallpaperMediaType?
    ) -> String {
        decision.menuBarStatusLabel(for: activeMediaType)
    }

    // MARK: - Media Fixture Resolution & Fallback Generation

    static func fallbackValidMP4Data() -> Data {
        Data(base64Encoded: minimalMP4Base64) ?? Data()
    }

    static func fallbackValidJPEGData() -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return Data()
        }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) ?? Data()
    }

    static func fallbackValidPNGData() -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return Data()
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    static func resolveMediaFixture(extension ext: String, in tempDir: URL) throws -> URL {
        let normalizedExt = ext.lowercased()
        let mediaDir = E2EEnvironment.fixturesDirectory.appendingPathComponent("media", isDirectory: true)

        if FileManager.default.fileExists(atPath: mediaDir.path),
           let entries = try? FileManager.default.contentsOfDirectory(
               at: mediaDir,
               includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
           ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent.lowercased()
                guard entry.pathExtension.lowercased() == normalizedExt,
                      !name.contains("corrupt"),
                      !name.contains("zero"),
                      !name.contains("empty") else {
                    continue
                }
                if let vals = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   vals.isRegularFile == true,
                   (vals.fileSize ?? 0) > 0 {
                    return entry
                }
            }
        }

        let targetURL = tempDir.appendingPathComponent("generated-\(UUID().uuidString).\(normalizedExt)", isDirectory: false)
        switch normalizedExt {
        case "mp4", "mov":
            try fallbackValidMP4Data().write(to: targetURL, options: [.atomic])
        case "jpg", "jpeg":
            try fallbackValidJPEGData().write(to: targetURL, options: [.atomic])
        case "png":
            try fallbackValidPNGData().write(to: targetURL, options: [.atomic])
        case "heic":
            // Try ImageIO HEIC destination first; fallback to PNG bytes at .heic path if encoder unavailable
            if let rep = NSBitmapImageRep(data: fallbackValidPNGData()),
               let cgImage = rep.cgImage,
               let dest = CGImageDestinationCreateWithURL(targetURL as CFURL, "public.heic" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, nil)
                if !CGImageDestinationFinalize(dest) {
                    try fallbackValidPNGData().write(to: targetURL, options: [.atomic])
                }
            } else {
                try fallbackValidPNGData().write(to: targetURL, options: [.atomic])
            }
        default:
            try fallbackValidPNGData().write(to: targetURL, options: [.atomic])
        }
        return targetURL
    }

    static func fixtureMediaBytes(named filename: String) -> Data? {
        let candidate = E2EEnvironment.fixturesDirectory
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidate.path),
              let data = try? Data(contentsOf: candidate),
              !data.isEmpty else {
            return nil
        }
        return data
    }

    static func resolveCorruptZeroMP4(in tempDir: URL) throws -> URL {
        let mediaDir = E2EEnvironment.fixturesDirectory.appendingPathComponent("media", isDirectory: true)
        for filename in ["corrupt_empty.mp4", "corrupt_zero.mp4"] {
            let candidate = mediaDir.appendingPathComponent(filename, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let target = tempDir.appendingPathComponent("corrupt_empty_\(UUID().uuidString).mp4", isDirectory: false)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        return target
    }

    static func resolveCorruptZeroJPG(in tempDir: URL) throws -> URL {
        let mediaDir = E2EEnvironment.fixturesDirectory.appendingPathComponent("media", isDirectory: true)
        for filename in ["corrupt_empty.jpg", "corrupt_zero.jpg"] {
            let candidate = mediaDir.appendingPathComponent(filename, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let target = tempDir.appendingPathComponent("corrupt_empty_\(UUID().uuidString).jpg", isDirectory: false)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        return target
    }

    static func resolveNegativeMediaFixture(named filename: String, in tempDir: URL, fallbackContent: Data) throws -> URL {
        let candidate = E2EEnvironment.fixturesDirectory
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let target = tempDir.appendingPathComponent(filename, isDirectory: false)
        try fallbackContent.write(to: target, options: [.atomic])
        return target
    }

    static func loadFixtureJSONObjectIfPresent(named filename: String) throws -> [String: Any]? {
        let fixtureURL = E2EEnvironment.fixturesDirectory.appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fixtureURL)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func fetchCustomFeedItems(
        from mockBaseURL: URL,
        path: String = "/custom/wrapped.json"
    ) async throws -> [WallpaperItem] {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let feedURL = mockBaseURL.appendingPathComponent(trimmed)
        let service = makeCatalogService()
        let result = await service.fetchCatalog(
            query: makeQuery(sources: [.customFeed]),
            secrets: ApiSecrets(),
            customFeedURL: feedURL
        )
        return extractItems(from: result)
    }

    static func firstVideoURL(from mockBaseURL: URL) async throws -> URL {
        let items = try await fetchCustomFeedItems(from: mockBaseURL, path: "/custom/wrapped.json")
        if let videoURL = items.first(where: { $0.mediaType == .video })?.fullAssetURL {
            return videoURL
        }
        return mockBaseURL.appendingPathComponent("media/sample_video.mp4")
    }

    static func firstImageURL(from mockBaseURL: URL) async throws -> URL {
        let items = try await fetchCustomFeedItems(from: mockBaseURL, path: "/custom/wrapped.json")
        if let imageURL = items.first(where: { $0.mediaType == .image })?.fullAssetURL {
            return imageURL
        }
        return mockBaseURL.appendingPathComponent("media/sample_image.jpg")
    }
}
