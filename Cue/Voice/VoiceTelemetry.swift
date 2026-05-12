import Foundation
import os

private let log = Logger(subsystem: "com.toug.cue", category: "VoiceTelemetry")

/// Buffers realtime data-channel events and batch-POSTs them to cue-server
/// at `/v1/voice/events` so the backend can thread them into LangSmith runs.
///
/// Lifecycle:
///   - `init(traceId:api:)` is called after `/v1/voice/session` mints a
///     traceId. If `traceId` is `nil` (tracing disabled server-side) all
///     `record(...)` calls become no-ops.
///   - `start()` kicks off the periodic flush loop.
///   - `record(direction:type:payload:)` is safe to call from anywhere;
///     the actor serialises access to the buffer.
///   - `stop()` cancels the loop and performs one final flush so the tail
///     of the session always lands in LangSmith.
///
/// Best-effort by design — every POST failure is logged but never throws
/// back to the caller, so a flaky network can't break a voice session.
actor VoiceTelemetry {
    enum Direction: String {
        case inbound
        case outbound
    }

    private let traceId: String
    private let api: CueAPI
    private var buffer: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?
    private var stopped = false

    /// Time between automatic flushes. The realtime UX is sub-second so
    /// 750 ms keeps LangSmith near-real-time without spamming the backend.
    private let flushIntervalNs: UInt64 = 750_000_000

    init(traceId: String, api: CueAPI) {
        self.traceId = traceId
        self.api = api
    }

    func start() {
        guard flushTask == nil, !stopped else { return }
        flushTask = Task { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        while !stopped {
            try? await Task.sleep(nanoseconds: flushIntervalNs)
            if Task.isCancelled { break }
            await flushLocked()
        }
    }

    func record(direction: Direction, type: String, payload: Any? = nil) {
        guard !stopped else { return }
        let event: [String: Any] = [
            "direction": direction.rawValue,
            "type": type,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "payload": payload ?? [String: Any](),
        ]
        buffer.append(event)
    }

    private func flushLocked() async {
        guard !buffer.isEmpty else { return }
        let toSend = buffer
        buffer.removeAll(keepingCapacity: true)
        do {
            try await api.postVoiceEvents(traceId: traceId, events: toSend)
        } catch {
            log.error("postVoiceEvents failed (\(toSend.count) events): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        stopped = true
        flushTask?.cancel()
        flushTask = nil
        await flushLocked()
    }
}
