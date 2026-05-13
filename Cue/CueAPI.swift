import Foundation
import Combine
import Observation
import Security
import os

// MARK: - Logging

private let log = Logger(subsystem: "com.toug.cue", category: "CueAPI")

private func logBody(_ label: String, _ data: Data?, max: Int = 4000) {
    guard let data, !data.isEmpty else {
        log.debug("\(label, privacy: .public): <empty>")
        return
    }
    let s = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, non-utf8>"
    if s.count > max {
        log.debug("\(label, privacy: .public) [\(data.count) bytes, truncated]: \(s.prefix(max), privacy: .public)…")
    } else {
        log.debug("\(label, privacy: .public) [\(data.count) bytes]: \(s, privacy: .public)")
    }
}

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

// MARK: - Voice realtime DTOs

struct VoiceSessionRequest: Encodable {
    let audioUrl: String
    let pausedAtSeconds: Double
    let totalDurationSeconds: Double?
    let episodeTitle: String
    let showTitle: String
}

/// Response from `POST /v1/voice/session`. `value` is the short-lived
/// OpenAI Realtime ephemeral token; the iOS client uses it as the Bearer
/// for the WebRTC SDP exchange against `https://api.openai.com/v1/realtime/calls`.
/// `contextMessage` is the "[Episode context — last 5 min …]" user-role
/// message we send into the conversation once the data channel opens.
/// `traceId` is the LangSmith root run id — present only when tracing is
/// enabled server-side. iOS echoes it back on `/v1/voice/events` POSTs and
/// on `/v1/voice/tools/*` calls (via the `x-cue-trace-id` header).
struct VoiceSessionResponse: Decodable {
    let value: String
    let expiresAt: Int?
    let contextMessage: String?
    let traceId: String?
}

struct SearchTranscriptRequest: Encodable {
    let audioUrl: String
    let query: String
    let limit: Int?
}

struct TranscriptHit: Codable {
    let fullText: String
    let matchText: String
    let matchPositionInSegment: Int
    let timestampSeconds: Int
    let timestampLabel: String
}

struct SearchTranscriptResponse: Codable {
    let results: [TranscriptHit]
}

struct SearchInternetRequest: Encodable {
    let query: String
    let limit: Int?
}

struct InternetHit: Codable {
    let title: String
    let url: String
    let description: String
}

struct SearchInternetResponse: Codable {
    let results: [InternetHit]
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
@Observable
final class CueAPI {
    static let shared = CueAPI()

    /// Cue's own backend (github.com/timlenardo/cue-server).
    /// cue-dev is the auto-deployed staging app; cue-prod is promoted manually.
    static let baseURL = URL(string: "https://cue-dev-7bd3eabd5817.herokuapp.com")!

    private(set) var token: String?
    private(set) var account: CueAccount?

    @ObservationIgnored private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    @ObservationIgnored private let encoder = JSONEncoder()

    init() {
        self.token = TokenStore.load()
        log.info("CueAPI init — baseURL=\(Self.baseURL.absoluteString, privacy: .public) hasToken=\(self.token != nil)")
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
        log.info("signOut")
        TokenStore.clear()
        token = nil
        account = nil
    }

    // MARK: - Podcasts

    func resolvePodcast(url: String) async throws -> ResolvedPodcast {
        try await post("/v1/podcasts/resolve", body: ["url": url])
    }

    // MARK: - Voice realtime

    /// Mints an OpenAI Realtime ephemeral token and bundles the rolling
    /// 5-min transcript context for the iOS client to feed in as the
    /// first conversation item.
    func requestVoiceSession(
        audioUrl: String,
        pausedAtSeconds: Double,
        totalDurationSeconds: Double?,
        episodeTitle: String,
        showTitle: String
    ) async throws -> VoiceSessionResponse {
        try await post("/v1/voice/session", body: VoiceSessionRequest(
            audioUrl: audioUrl,
            pausedAtSeconds: pausedAtSeconds,
            totalDurationSeconds: totalDurationSeconds,
            episodeTitle: episodeTitle,
            showTitle: showTitle
        ))
    }

    /// Server-side handler for the `search_transcript` realtime tool —
    /// dispatched by the iOS client when it receives that function_call
    /// event over the WebRTC data channel.
    ///
    /// `traceId` + `callId` flow through `x-cue-trace-id` / `x-cue-call-id`
    /// headers so cue-server can emit a `server_tool:search_transcript`
    /// LangSmith run that ties back to the originating session + call.
    func searchTranscript(
        audioUrl: String,
        query: String,
        limit: Int? = nil,
        traceId: String? = nil,
        callId: String? = nil
    ) async throws -> SearchTranscriptResponse {
        try await post(
            "/v1/voice/tools/search-transcript",
            body: SearchTranscriptRequest(
                audioUrl: audioUrl,
                query: query,
                limit: limit
            ),
            headers: traceHeaders(traceId: traceId, callId: callId)
        )
    }

    /// Server-side handler for the `search_internet` realtime tool. Same
    /// dispatch pattern as `searchTranscript`.
    func searchInternet(
        query: String,
        limit: Int? = nil,
        traceId: String? = nil,
        callId: String? = nil
    ) async throws -> SearchInternetResponse {
        try await post(
            "/v1/voice/tools/search-internet",
            body: SearchInternetRequest(
                query: query,
                limit: limit
            ),
            headers: traceHeaders(traceId: traceId, callId: callId)
        )
    }

    private func traceHeaders(traceId: String?, callId: String?) -> [String: String] {
        var h: [String: String] = [:]
        if let t = traceId { h["x-cue-trace-id"] = t }
        if let c = callId { h["x-cue-call-id"] = c }
        return h
    }

    /// Forwards a batch of OpenAI Realtime data-channel events to
    /// cue-server for LangSmith tracing. Best-effort: the response is
    /// ignored unless it fails, in which case the caller decides whether
    /// to surface the error (typically: log + drop).
    struct VoiceEventsResponse: Decodable {
        let ok: Bool
        let traced: Int?
    }
    func postVoiceEvents(traceId: String, events: [[String: Any]]) async throws {
        let body: [String: Any] = ["traceId": traceId, "events": events]
        let _: VoiceEventsResponse = try await postRaw("/v1/voice/events", body: body)
    }

    /// Streams transcribe progress + result as NDJSON events.
    /// The stream completes when the server emits .result or .error.
    func transcribePodcastStream(audioUrl: String, durationSeconds: Double?) -> AsyncThrowingStream<TranscribeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let started = Date()
                do {
                    var body: [String: Any] = ["audioUrl": audioUrl]
                    if let durationSeconds { body["durationSeconds"] = durationSeconds }
                    let data = try JSONSerialization.data(withJSONObject: body)

                    let url = URL(string: "/v1/podcasts/transcribe", relativeTo: Self.baseURL)!
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                    if let token = self.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    req.httpBody = data
                    req.timeoutInterval = 60 * 30   // long-running responses; bytes(for:) holds open.

                    log.info("→ POST /v1/podcasts/transcribe audioUrl=\(audioUrl, privacy: .public) duration=\(durationSeconds ?? -1)")
                    logBody("→ transcribe req body", data)

                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        log.error("transcribe: non-HTTP response")
                        throw CueAPIError.invalidResponse
                    }
                    log.info("← \(http.statusCode) /v1/podcasts/transcribe (\(String(format: "%.2f", Date().timeIntervalSince(started)))s to first byte)")

                    if http.statusCode == 401 {
                        log.error("transcribe: 401 — clearing token")
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
                        log.error("transcribe error body: \(dump, privacy: .public)")
                        throw CueAPIError.server(status: http.statusCode, message: dump.isEmpty ? "Server error" : dump)
                    }

                    var eventCount = 0
                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        log.debug("← ndjson line: \(line.prefix(500), privacy: .public)")
                        if let event = parseEvent(line) {
                            eventCount += 1
                            switch event {
                            case .status(let stage, let n, let bytes, let dur):
                                log.info("event #\(eventCount) status stage=\(stage, privacy: .public) chunks=\(n ?? -1) bytes=\(bytes ?? -1) dur=\(dur ?? -1)")
                            case .chunkDone(let i, let n):
                                log.info("event #\(eventCount) chunk_done \(i + 1)/\(n)")
                            case .heartbeat:
                                log.debug("event #\(eventCount) heartbeat")
                            case .result(let r):
                                log.info("event #\(eventCount) result words=\(r.words.count) segments=\(r.segments.count) cached=\(r.cached)")
                            case .error(let m):
                                log.error("event #\(eventCount) error: \(m, privacy: .public)")
                            }
                            continuation.yield(event)
                            if case .result = event { break }
                            if case .error = event  { break }
                        } else {
                            log.error("transcribe: unparseable ndjson line: \(line, privacy: .public)")
                        }
                    }
                    log.info("transcribe stream finished — \(eventCount) events, total \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                    continuation.finish()
                } catch {
                    log.error("transcribe stream error after \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                log.debug("transcribe stream terminated")
                task.cancel()
            }
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

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, headers: [String: String] = [:]) async throws -> T {
        let data = try encoder.encode(body)
        return try await send(path: path, method: "POST", bodyData: data, headers: headers)
    }

    private func postRaw<T: Decodable>(_ path: String, body: [String: Any], headers: [String: String] = [:]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(path: path, method: "POST", bodyData: data, headers: headers)
    }

    private func patchRaw<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(path: path, method: "PATCH", bodyData: data)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "DELETE", bodyData: nil)
    }

    private func send<T: Decodable>(path: String, method: String, bodyData: Data?, headers: [String: String] = [:]) async throws -> T {
        let started = Date()
        guard let url = URL(string: path, relativeTo: Self.baseURL) else {
            log.error("invalid URL for path=\(path, privacy: .public)")
            throw CueAPIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = bodyData

        log.info("→ \(method, privacy: .public) \(path, privacy: .public) (auth=\(self.token != nil))")
        if method != "GET" { logBody("→ req body", bodyData) }

        // Run URLSession on a detached task so the network completion isn't
        // gated on the main actor being free. We measure the wall-clock
        // network time inside the detached task, then compare it to the
        // total elapsed (which is measured on main and includes time the
        // continuation spent queued waiting for the main actor). The
        // difference is `mainWait` — main-actor contention.
        let sessionRef = session
        let reqCopy = req
        let networkResult: (data: Data, response: URLResponse, networkSeconds: TimeInterval)
        do {
            networkResult = try await Task.detached(priority: .userInitiated) {
                let netStart = Date()
                let (data, response) = try await sessionRef.data(for: reqCopy)
                return (data, response, Date().timeIntervalSince(netStart))
            }.value
        } catch {
            log.error("✗ \(method, privacy: .public) \(path, privacy: .public) transport error after \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let data = networkResult.data
        let response = networkResult.response
        let totalSeconds = Date().timeIntervalSince(started)
        let mainWait = max(0, totalSeconds - networkResult.networkSeconds)

        guard let http = response as? HTTPURLResponse else {
            log.error("✗ \(method, privacy: .public) \(path, privacy: .public) non-HTTP response")
            throw CueAPIError.invalidResponse
        }

        log.info("← \(http.statusCode) \(method, privacy: .public) \(path, privacy: .public) [\(data.count) bytes, \(String(format: "%.2f", totalSeconds))s = net \(String(format: "%.2f", networkResult.networkSeconds))s + main-wait \(String(format: "%.2f", mainWait))s]")
        logBody("← resp body", data)

        if http.statusCode == 401 {
            log.error("← 401 — clearing token")
            TokenStore.clear()
            token = nil
            account = nil
            throw CueAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                   ?? String(data: data, encoding: .utf8)
                   ?? "Server error"
            log.error("← server error \(http.statusCode): \(msg, privacy: .public)")
            throw CueAPIError.server(status: http.statusCode, message: msg)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            log.error("← decoding error for \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
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
