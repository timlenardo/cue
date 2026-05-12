import Foundation
import Combine
import Security

// MARK: - DTOs

struct CueAccount: Codable {
    let id: Int
    let phoneNumber: String
    let name: String?
    let preferredVoiceId: String?
}

struct VerifyCodeResponse: Codable {
    let token: String
    let account: CueAccount
    let isNewUser: Bool
}

struct ResolvedShow: Codable {
    let title: String
    let author: String?
    let feedUrl: String
    let artworkUrl: String?
}

struct ResolvedEpisode: Codable {
    let title: String
    let audioUrl: String
    let durationSeconds: Double?
    let pubDate: String?
    let guid: String
    let description: String?
}

struct ResolvedPodcast: Codable {
    let source: String       // "spotify" | "apple" | "rss"
    let type: String         // "episode" | "show"
    let show: ResolvedShow
    let episode: ResolvedEpisode?
}

struct TranscribeWord: Codable {
    let text: String
    let startMs: Int
    let endMs: Int
}

struct TranscribeSegment: Codable {
    let speaker: String
    let startMs: Int
    let endMs: Int
    let text: String
}

struct TranscribeResponse: Codable {
    let provider: String     // "openai"
    let text: String
    let words: [TranscribeWord]
    let segments: [TranscribeSegment]
    let cached: Bool
    let durationSeconds: Double?
}

/// One episode in a user's library, including the resolved metadata.
struct ServerEpisode: Codable, Equatable {
    let id: Int
    let audioUrl: String
    let source: String
    let showTitle: String
    let showAuthor: String?
    let showFeedUrl: String?
    let showArtworkUrl: String?
    let episodeTitle: String
    let episodeGuid: String?
    let episodePubDate: String?
    let episodeDescription: String?
    let durationSeconds: Double?
}

struct LibraryItem: Codable, Identifiable, Equatable {
    let id: Int
    let addedAt: String
    let lastPlayedAt: String?
    let completedAt: String?
    let positionSeconds: Double
    let episode: ServerEpisode
}

private struct LibraryListResponse: Codable {
    let items: [LibraryItem]
}

/// Streaming event emitted by `/v1/podcasts/transcribe` (NDJSON).
enum TranscribeEvent {
    /// Server-side stage label.
    case status(stage: String, chunkCount: Int?, sizeBytes: Int?, durationSeconds: Double?)
    /// One Whisper chunk finished transcribing.
    case chunkDone(index: Int, chunkCount: Int)
    /// Keep-alive while a long step is in flight. UI can ignore.
    case heartbeat
    /// Terminal: the full transcript.
    case result(TranscribeResponse)
    /// Terminal: server reported an error.
    case error(String)
}

// MARK: - Errors

enum CueAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(status: Int, message: String)
    case unauthorized
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .server(_, let m): return m
        case .unauthorized: return "Not authorized"
        case .decoding(let e): return "Couldn't decode response: \(e.localizedDescription)"
        }
    }
}

// MARK: - Client

@MainActor
final class CueAPI: ObservableObject {
    static let shared = CueAPI()

    /// Cue's own backend (github.com/timlenardo/cue-server).
    /// cue-dev is the auto-deployed staging app; cue-prod is promoted manually.
    static let baseURL = URL(string: "https://cue-dev-7bd3eabd5817.herokuapp.com")!

    @Published private(set) var token: String?
    @Published private(set) var account: CueAccount?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private let encoder = JSONEncoder()

    init() {
        self.token = TokenStore.load()
    }

    var isAuthenticated: Bool { token != nil }

    // MARK: - Auth

    func sendCode(phoneNumber: String) async throws {
        struct Response: Decodable { let success: Bool }
        let _: Response = try await post("/v1/auth/send-code", body: ["phoneNumber": phoneNumber])
    }

    func verifyCode(phoneNumber: String, code: String) async throws -> VerifyCodeResponse {
        let resp: VerifyCodeResponse = try await post(
            "/v1/auth/verify-code",
            body: ["phoneNumber": phoneNumber, "code": code]
        )
        TokenStore.save(resp.token)
        token = resp.token
        account = resp.account
        return resp
    }

    func getAccount() async throws -> CueAccount {
        let resp: CueAccount = try await get("/v1/auth/account")
        account = resp
        return resp
    }

    func signOut() {
        TokenStore.clear()
        token = nil
        account = nil
    }

    // MARK: - Podcasts

    func resolvePodcast(url: String) async throws -> ResolvedPodcast {
        try await post("/v1/podcasts/resolve", body: ["url": url])
    }

    /// Streams transcribe progress + result as NDJSON events.
    /// The stream completes when the server emits .result or .error.
    func transcribePodcastStream(audioUrl: String, durationSeconds: Double?) -> AsyncThrowingStream<TranscribeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = ["audioUrl": audioUrl]
                    if let durationSeconds { body["durationSeconds"] = durationSeconds }
                    let data = try JSONSerialization.data(withJSONObject: body)

                    var req = URLRequest(url: URL(string: "/v1/podcasts/transcribe", relativeTo: Self.baseURL)!)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                    if let token = self.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    req.httpBody = data
                    req.timeoutInterval = 60 * 30   // long-running responses; bytes(for:) holds open.

                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw CueAPIError.invalidResponse
                    }
                    if http.statusCode == 401 {
                        TokenStore.clear()
                        await MainActor.run {
                            self.token = nil
                            self.account = nil
                        }
                        throw CueAPIError.unauthorized
                    }
                    if !(200..<300).contains(http.statusCode) {
                        var dump = ""
                        for try await line in bytes.lines { dump += line; if dump.count > 500 { break } }
                        throw CueAPIError.server(status: http.statusCode, message: dump.isEmpty ? "Server error" : dump)
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        if let event = parseEvent(line) {
                            continuation.yield(event)
                            if case .result = event { break }
                            if case .error = event  { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Library

    func getLibrary() async throws -> [LibraryItem] {
        let resp: LibraryListResponse = try await get("/v1/library")
        return resp.items
    }

    func upsertLibrary(episode: ResolvedEpisode, show: ResolvedShow, source: String) async throws -> LibraryItem {
        let body: [String: Any] = [
            "audioUrl": episode.audioUrl,
            "source": source,
            "showTitle": show.title,
            "showAuthor": show.author as Any,
            "showFeedUrl": show.feedUrl as Any,
            "showArtworkUrl": show.artworkUrl as Any,
            "episodeTitle": episode.title,
            "episodeGuid": episode.guid,
            "episodePubDate": episode.pubDate as Any,
            "episodeDescription": episode.description as Any,
            "durationSeconds": episode.durationSeconds as Any,
        ].compactMapValues { v in
            if v is NSNull { return nil }
            return v
        }
        return try await postRaw("/v1/library", body: body)
    }

    func updateProgress(episodeId: Int, positionSeconds: Double) async throws -> LibraryItem {
        return try await patchRaw("/v1/library/\(episodeId)/progress", body: ["positionSeconds": positionSeconds])
    }

    func removeFromLibrary(episodeId: Int) async throws {
        struct Empty: Decodable { let success: Bool }
        let _: Empty = try await delete("/v1/library/\(episodeId)")
    }

    // MARK: - Request helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "GET", bodyData: nil)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let data = try encoder.encode(body)
        return try await send(path: path, method: "POST", bodyData: data)
    }

    private func postRaw<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(path: path, method: "POST", bodyData: data)
    }

    private func patchRaw<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(path: path, method: "PATCH", bodyData: data)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "DELETE", bodyData: nil)
    }

    private func send<T: Decodable>(path: String, method: String, bodyData: Data?) async throws -> T {
        guard let url = URL(string: path, relativeTo: Self.baseURL) else {
            throw CueAPIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = bodyData

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CueAPIError.invalidResponse }

        if http.statusCode == 401 {
            TokenStore.clear()
            token = nil
            account = nil
            throw CueAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                   ?? String(data: data, encoding: .utf8)
                   ?? "Server error"
            throw CueAPIError.server(status: http.statusCode, message: msg)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CueAPIError.decoding(error)
        }
    }
}

// MARK: - NDJSON event parsing

private func parseEvent(_ line: String) -> TranscribeEvent? {
    guard let data = line.data(using: .utf8) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let type = obj["type"] as? String else { return nil }

    switch type {
    case "heartbeat":
        return .heartbeat
    case "status":
        let stage = (obj["stage"] as? String) ?? "unknown"
        return .status(
            stage: stage,
            chunkCount: obj["chunkCount"] as? Int,
            sizeBytes: obj["sizeBytes"] as? Int,
            durationSeconds: obj["durationSeconds"] as? Double
        )
    case "chunk_done":
        let idx = (obj["index"] as? Int) ?? 0
        let n = (obj["chunkCount"] as? Int) ?? 1
        return .chunkDone(index: idx, chunkCount: n)
    case "error":
        return .error((obj["message"] as? String) ?? "Server error")
    case "result":
        // Re-encode the dict (sans "type") back to JSON so JSONDecoder with
        // snake-case conversion can build a TranscribeResponse.
        var copy = obj
        copy.removeValue(forKey: "type")
        guard let resultData = try? JSONSerialization.data(withJSONObject: copy) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let parsed = try? decoder.decode(TranscribeResponse.self, from: resultData) else { return nil }
        return .result(parsed)
    default:
        return nil
    }
}

// MARK: - Token storage (Keychain)

enum TokenStore {
    private static let service = "com.toug.cue.auth"
    private static let account = "jwt"

    static func save(_ token: String) {
        let data = token.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
