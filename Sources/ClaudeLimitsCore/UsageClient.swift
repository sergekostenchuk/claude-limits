import Foundation
import Security
import OSLog

public struct ClaudeCredential {
    public let token: String

    public static func decode(_ data: Data, now: Date = Date()) throws -> ClaudeCredential {
        guard data.count <= 131_072,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw UsageError.loginRequired }
        if let expires = oauth["expiresAt"] as? Double, expires > 0,
           expires <= now.timeIntervalSince1970 * 1000 { throw UsageError.loginRequired }
        return ClaudeCredential(token: token)
    }

    public static func read(interactive: Bool = false) throws -> ClaudeCredential {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try decode(data) }
        // A locked/denied keychain is not permission to read an obsolete account from a file.
        guard status == errSecItemNotFound else { throw UsageError.keychainAccess }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: file) else { throw UsageError.loginRequired }
        return try decode(data)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct UsageClient: UsageFetching {
    private let session: URLSession
    private let credential: () async throws -> ClaudeCredential
    private let debug: Bool
    private let log = Logger(subsystem: "com.kostenchuksergey.ClaudeLimits", category: "usage")

    public init(session: URLSession? = nil, debug: Bool = false,
                credential: @escaping () async throws -> ClaudeCredential = {
                    try await Task.detached { try ClaudeCredential.read() }.value
                }) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        self.credential = credential; self.debug = debug
    }

    public func fetch() async throws -> UsageSnapshot {
        let auth = try await credential()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeLimits/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw UsageError.network }
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        if debug { log.info("usage response HTTP \(http.statusCode)") }
        switch http.statusCode {
        case 200: return try UsageParser.parse(data)
        case 401, 403: throw UsageError.loginRequired
        case 429:
            let retry = Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After"))
            throw UsageError.rateLimited(retry)
        default: throw UsageError.unavailable(http.statusCode)
        }
    }

    public static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
        guard let value else { return 300 }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return max(120, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(120, $0.timeIntervalSince(now)) } ?? 300
    }
}
