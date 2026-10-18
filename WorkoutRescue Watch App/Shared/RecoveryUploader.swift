import Foundation
import CryptoKit

/// Direct HTTPS upload from the watch to the owner's receiver (see `receiver/`).
///
/// Protocol (all `/api` routes require `Authorization: Bearer <token>`):
/// - `GET  /api/ping`                       → `{"ok": true, ...}` (connection + token test, no health data)
/// - `POST /api/workouts/{uuid}/metadata`   body: workout.json (`application/json`)
/// - `POST /api/workouts/{uuid}/route`      body: route.gpx (`application/gpx+xml`)
/// Every upload sends `X-WorkoutRescue-SHA256`. The server rejects a body whose digest differs
/// (truncated/interrupted upload), stores it atomically without ever overwriting an existing file,
/// and answers with the digest it stored. An upload is reported successful only when that digest
/// and byte count match what the watch sent.
nonisolated struct RecoveryEndpoint: Equatable, Sendable {
    enum ParseError: LocalizedError, Equatable {
        case empty, invalid, insecureScheme
        var errorDescription: String? {
            switch self {
            case .empty: return "Enter the receiver address."
            case .invalid: return "The receiver address is not a valid URL."
            case .insecureScheme: return "The receiver must use HTTPS."
            }
        }
    }

    let baseURL: URL

    /// Accepts `host.example`, `https://host.example`, `https://host.example/prefix/`.
    /// A missing scheme defaults to HTTPS. Plain HTTP is refused, except loopback when
    /// `allowInsecureLoopback` is set (tests only; the app never sets it).
    static func parse(_ raw: String, allowInsecureLoopback: Bool = false) throws -> RecoveryEndpoint {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { throw ParseError.invalid }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        switch scheme {
        case "https": break
        case "http" where allowInsecureLoopback && loopback: break
        case "http": throw ParseError.insecureScheme
        default: throw ParseError.invalid
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw ParseError.invalid }
        return RecoveryEndpoint(baseURL: url)
    }

    func url(_ path: String) -> URL { URL(string: baseURL.absoluteString + path)! }
}

nonisolated enum UploadKind: String, Codable, Sendable, CaseIterable {
    case metadata, route
    var contentType: String { self == .metadata ? "application/json" : "application/gpx+xml" }
    var fileName: String { self == .metadata ? "workout.json" : "route.gpx" }
}

/// Server confirmation for one stored file.
nonisolated struct UploadReceipt: Codable, Equatable, Sendable {
    /// `stored` (new file), `duplicate` (identical file already present), `stored_revision`
    /// (a different file already existed; the new one was stored next to it, nothing overwritten).
    let status: String
    let uuid: String
    let kind: String
    let sha256: String
    let bytes: Int
    let path: String?
}

nonisolated struct PingResult: Codable, Equatable, Sendable {
    let ok: Bool
    let service: String?
    let protocolVersion: Int?
    let maxBytes: Int?

    enum CodingKeys: String, CodingKey { case ok, service, protocolVersion = "protocol_version", maxBytes = "max_bytes" }
}

nonisolated enum UploadError: LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case payloadTooLarge
    case rateLimited
    case integrityMismatch
    case badRequest(String)
    case server(status: Int)
    case unexpectedStatus(Int)
    case invalidResponse
    case network(code: Int, description: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token refused by the receiver (HTTP 401). Check the token in Settings."
        case .forbidden: return "Access forbidden by the receiver (HTTP 403)."
        case .payloadTooLarge: return "The receiver refused the file size (HTTP 413)."
        case .rateLimited: return "Too many attempts; the receiver asked to wait (HTTP 429)."
        case .integrityMismatch: return "The receiver did not confirm the same SHA-256; the transfer is NOT considered successful."
        case .badRequest(let message): return "The receiver rejected the request: \(message)"
        case .server(let status): return "Receiver error (HTTP \(status))."
        case .unexpectedStatus(let status): return "Unexpected receiver response (HTTP \(status))."
        case .invalidResponse: return "The receiver answer could not be read."
        case .network(_, let description): return "Network error: \(description)"
        case .cancelled: return "Transfer cancelled."
        }
    }

    /// Transient errors are retried; authentication/size/protocol errors are not.
    var isRetryable: Bool {
        switch self {
        case .server, .integrityMismatch: return true
        case .badRequest(let message): return message.contains("sha256_mismatch") || message.contains("incomplete_body")
        case .network(let code, _):
            let permanent: [URLError.Code] = [.badURL, .unsupportedURL, .cannotFindHost, .serverCertificateUntrusted,
                                              .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                                              .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                                              .appTransportSecurityRequiresSecureConnection, .userAuthenticationRequired]
            return !permanent.map(\.rawValue).contains(code)
        default: return false
        }
    }
}

nonisolated struct RetryPolicy: Sendable {
    var maxAttempts = 4
    var baseDelay: Duration = .seconds(1)
    var maxDelay: Duration = .seconds(8)

    func delay(beforeAttempt attempt: Int) -> Duration {
        let factor = 1 << min(max(attempt - 2, 0), 10)
        return min(baseDelay * factor, maxDelay)
    }
}

nonisolated struct UploadProgress: Sendable {
    let attempt: Int
    let maxAttempts: Int
    let lastError: String?
}

nonisolated final class RecoveryUploader: Sendable {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    let endpoint: RecoveryEndpoint
    private let token: String
    private let session: URLSession
    private let retry: RetryPolicy
    private let sleeper: Sleeper

    init(endpoint: RecoveryEndpoint, token: String, session: URLSession = RecoveryUploader.makeSession(),
         retry: RetryPolicy = RetryPolicy(), sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.endpoint = endpoint
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.retry = retry
        self.sleeper = sleeper
    }

    /// Ephemeral: no cookie, no cache, no credential persistence. Fails fast when offline so the
    /// user sees the problem instead of a silent wait.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func ping() async throws -> PingResult {
        var request = URLRequest(url: endpoint.url("/api/ping"))
        request.httpMethod = "GET"
        authorize(&request)
        let pingRequest = request
        let (data, response) = try await perform { try await self.session.data(for: pingRequest) }
        try Self.check(response, data: data)
        guard let result = try? JSONDecoder().decode(PingResult.self, from: data), result.ok else { throw UploadError.invalidResponse }
        return result
    }

    /// Uploads one file with retries. Returns only after the server confirmed the same SHA-256 and size.
    func upload(_ data: Data, kind: UploadKind, workoutUUID: UUID,
                progress: (@Sendable (UploadProgress) -> Void)? = nil) async throws -> UploadReceipt {
        let digest = Self.sha256Hex(data)
        var request = URLRequest(url: endpoint.url("/api/workouts/\(workoutUUID.uuidString)/\(kind.rawValue)"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue(kind.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(digest, forHTTPHeaderField: "X-WorkoutRescue-SHA256")
        request.setValue(String(WorkoutArchive.currentSchemaVersion), forHTTPHeaderField: "X-WorkoutRescue-Schema")

        let uploadRequest = request
        var lastError: UploadError?
        for attempt in 1...max(1, retry.maxAttempts) {
            try Task.checkCancellation()
            if attempt > 1 { try await sleeper(retry.delay(beforeAttempt: attempt)) }
            progress?(UploadProgress(attempt: attempt, maxAttempts: retry.maxAttempts, lastError: lastError?.localizedDescription))
            do {
                let (body, response) = try await perform { try await self.session.upload(for: uploadRequest, from: data) }
                try Self.check(response, data: body)
                guard let receipt = try? JSONDecoder().decode(UploadReceipt.self, from: body) else { throw UploadError.invalidResponse }
                guard receipt.sha256.lowercased() == digest, receipt.bytes == data.count,
                      receipt.uuid.uppercased() == workoutUUID.uuidString, receipt.kind == kind.rawValue else {
                    throw UploadError.integrityMismatch
                }
                return receipt
            } catch let error as UploadError {
                lastError = error
                guard error.isRetryable, attempt < retry.maxAttempts else { throw error }
            }
        }
        throw lastError ?? UploadError.invalidResponse
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("WorkoutRescue/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func perform(_ operation: @Sendable () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        do {
            return try await operation()
        } catch is CancellationError {
            throw UploadError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw UploadError.cancelled }
            throw UploadError.network(code: error.code.rawValue, description: error.localizedDescription)
        }
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        switch http.statusCode {
        case 200...299: return
        case 400:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "bad_request"
            throw UploadError.badRequest(message)
        case 401: throw UploadError.unauthorized
        case 403: throw UploadError.forbidden
        case 413: throw UploadError.payloadTooLarge
        case 429: throw UploadError.rateLimited
        case 500...599: throw UploadError.server(status: http.statusCode)
        default: throw UploadError.unexpectedStatus(http.statusCode)
        }
    }
}
