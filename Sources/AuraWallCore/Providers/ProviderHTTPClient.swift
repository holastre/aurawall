import Foundation

public enum ProviderURLValidator: Sendable {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// Allows HTTPS globally and HTTP strictly for loopback addresses (used by E2E local test servers).
    public static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }

        switch scheme {
        case "https":
            return true
        case "http":
            return loopbackHosts.contains(host)
        default:
            return false
        }
    }

    public static func validatedURL(from rawString: String?) -> URL? {
        guard let trimmed = rawString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              isAllowedRemoteURL(url) else {
            return nil
        }
        return url
    }
}

public struct ProviderHTTPClient: Sendable {
    public static let defaultUserAgent = "AuraWall/1.0"

    public struct HTTPResponse: Sendable {
        public let data: Data
        public let statusCode: Int
        public let headers: [String: String]
        public let rateLimit: ProviderRateLimitInfo?

        public init(
            data: Data,
            statusCode: Int,
            headers: [String: String],
            rateLimit: ProviderRateLimitInfo?
        ) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
            self.rateLimit = rateLimit
        }
    }

    public let urlSession: URLSession
    public let userAgent: String
    public let maxErrorSnippetBytes: Int

    public init(
        urlSession: URLSession = .shared,
        userAgent: String = ProviderHTTPClient.defaultUserAgent,
        maxErrorSnippetBytes: Int = 512
    ) {
        self.urlSession = urlSession
        self.userAgent = userAgent
        self.maxErrorSnippetBytes = max(64, maxErrorSnippetBytes)
    }

    public func get(
        _ url: URL,
        headers: [String: String] = [:],
        source: WallpaperSource? = nil,
        timeoutInterval: TimeInterval = 20
    ) async throws -> HTTPResponse {
        try await execute(
            method: "GET",
            url: url,
            headers: headers,
            source: source,
            timeoutInterval: timeoutInterval
        )
    }

    public func getJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        headers: [String: String] = [:],
        source: WallpaperSource? = nil,
        timeoutInterval: TimeInterval = 20,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> (value: T, response: HTTPResponse) {
        let response = try await get(
            url,
            headers: headers,
            source: source,
            timeoutInterval: timeoutInterval
        )
        do {
            let decoded = try decoder.decode(T.self, from: response.data)
            return (decoded, response)
        } catch {
            throw ProviderError.decodingFailed(error.localizedDescription)
        }
    }

    public func probeAvailability(
        _ url: URL,
        timeoutInterval: TimeInterval = 4
    ) async throws -> Bool {
        try Task.checkCancellation()

        guard ProviderURLValidator.isAllowedRemoteURL(url) else {
            return false
        }

        do {
            let headStatus = try await executeRawStatus(
                method: "HEAD",
                url: url,
                headers: [:],
                timeoutInterval: timeoutInterval
            )
            if headStatus == 200 || headStatus == 206 {
                return true
            }
            if headStatus != 405 && headStatus != 501 {
                return false
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall through to Range GET probe on non-cancellation HEAD failure.
        }

        try Task.checkCancellation()

        do {
            let rangeStatus = try await executeRawStatus(
                method: "GET",
                url: url,
                headers: ["Range": "bytes=0-0"],
                timeoutInterval: timeoutInterval
            )
            return rangeStatus == 200 || rangeStatus == 206
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private func execute(
        method: String,
        url: URL,
        headers: [String: String],
        source: WallpaperSource?,
        timeoutInterval: TimeInterval
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()

        let request = buildRequest(
            method: method,
            url: url,
            headers: headers,
            timeoutInterval: timeoutInterval
        )

        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProviderError.networkError(error.localizedDescription)
        }

        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        let normalizedHeaders = Self.normalizeHeaders(httpResponse.allHeaderFields)
        let rateLimit = Self.parseRateLimit(headers: normalizedHeaders)
        let statusCode = httpResponse.statusCode

        guard (200..<300).contains(statusCode) else {
            let snippet = Self.extractBoundedSnippet(from: data, maxBytes: maxErrorSnippetBytes)
            switch statusCode {
            case 401, 403:
                throw ProviderError.unauthorized(source: source ?? .starter, message: snippet)
            case 429:
                let retryAfter = rateLimit?.retryAfterSeconds ?? rateLimit?.resetSeconds
                throw ProviderError.rateLimited(
                    source: source ?? .starter,
                    retryAfter: retryAfter,
                    message: snippet
                )
            default:
                throw ProviderError.httpError(statusCode: statusCode, snippet: snippet)
            }
        }

        return HTTPResponse(
            data: data,
            statusCode: statusCode,
            headers: normalizedHeaders,
            rateLimit: rateLimit
        )
    }

    private func executeRawStatus(
        method: String,
        url: URL,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> Int {
        try Task.checkCancellation()

        let request = buildRequest(
            method: method,
            url: url,
            headers: headers,
            timeoutInterval: timeoutInterval
        )

        let rawResponse: URLResponse
        do {
            (_, rawResponse) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }
        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        return httpResponse.statusCode
    }

    private func buildRequest(
        method: String,
        url: URL,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutInterval
        )
        request.httpMethod = method

        // CRITICAL: Never overwrite `request.allHTTPHeaderFields` so session-level
        // `httpAdditionalHeaders` (e.g., MockURLProtocol test correlation headers) remain intact.
        let hasCustomUserAgent = headers.keys.contains { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }
        if !hasCustomUserAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    public static func normalizeHeaders(_ allHeaderFields: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(allHeaderFields.count)
        for (rawKey, rawValue) in allHeaderFields {
            let key = String(describing: rawKey).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(describing: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    public static func parseRateLimit(headers: [String: String], now: Date = Date()) -> ProviderRateLimitInfo? {
        let limit = headers["x-ratelimit-limit"].flatMap(Int.init)
        let remaining = headers["x-ratelimit-remaining"].flatMap(Int.init)
        let resetSeconds: TimeInterval? = headers["x-ratelimit-reset"]
            .flatMap { raw -> TimeInterval? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let value = TimeInterval(trimmed),
                      value.isFinite,
                      value >= 0,
                      value < Double(Int.max) else {
                    return nil
                }
                // Unix epoch timestamps (e.g. Pexels X-Ratelimit-Reset) are > 1_000_000_000;
                // convert them into relative delta seconds until reset.
                let delta: TimeInterval
                if value > 1_000_000_000 {
                    delta = max(0, value - now.timeIntervalSince1970)
                } else {
                    delta = value
                }
                guard delta.isFinite, delta >= 0, ceil(delta) < Double(Int.max) else {
                    return nil
                }
                return delta
            }
        let retryAfterSeconds = parseRetryAfter(headers["retry-after"], now: now)

        if limit == nil && remaining == nil && resetSeconds == nil && retryAfterSeconds == nil {
            return nil
        }
        return ProviderRateLimitInfo(
            limit: limit,
            remaining: remaining,
            resetSeconds: resetSeconds,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    public static func extractBoundedSnippet(
        from data: Data,
        maxBytes: Int = 512,
        maxCharacters: Int = 240
    ) -> String? {
        guard !data.isEmpty else { return nil }
        let slice = data.prefix(max(1, maxBytes))
        let decoded = String(decoding: slice, as: UTF8.self)
        let collapsed = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxCharacters {
            return collapsed
        }
        return String(collapsed.prefix(maxCharacters)) + "..."
    }

    private static func parseRetryAfter(_ rawValue: String?, now: Date = Date()) -> TimeInterval? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if let numeric = TimeInterval(trimmed) {
            guard numeric.isFinite,
                  numeric >= 0,
                  ceil(numeric) < Double(Int.max) else {
                return nil
            }
            return numeric
        }
        // Local DateFormatter instance per call (no global/static DateFormatter under Swift 6).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let delta = max(0, date.timeIntervalSince(now))
                guard delta.isFinite, ceil(delta) < Double(Int.max) else {
                    return nil
                }
                return delta
            }
        }
        return nil
    }
}
