import Foundation
import os

private let log = Logger(subsystem: "com.toug.cue", category: "VoiceTelemetry")

/// Buffers realtime data-channel events and batch-POSTs them to cue-server
/// at `/v1/voice/events` so the backend can thread them into Langfuse observations.
///
/// Lifecycle:
///   - `init(traceId:api:)` is called after `/v1/voice/session` mints a
///     traceId. If `traceId` is `nil` (tracing disabled server-side) all
///     `record(...)` calls become no-ops.
///   - `start()` kicks off the periodic flush loop.
///   - `record(direction:type:payload:)` is non-isolated and synchronous —
///     callers append directly to a lock-guarded buffer, which preserves
///     the order events were observed at the call site. Wrapping each call
///     in `Task { await tel.record(...) }` (the old shape) reordered events
///     non-deterministically before they reached the actor's mailbox, which
///     made `response.done` race past `audio_transcript.done` server-side
///     and left assistant transcripts null on the Langfuse observation.
///   - `stop()` cancels the loop and performs one final flush so the tail
///     of the session always lands in Langfuse.
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
    private var flushTask: Task<Void, Never>?

    // Buffer + stopped flag live outside actor isolation so `record` can be
    // a synchronous nonisolated call. Order is preserved by `bufferLock`.
    private nonisolated let bufferLock = NSLock()
    private nonisolated(unsafe) var pendingEvents: [[String: Any]] = []
    private nonisolated(unsafe) var stoppedFlag = false

    /// Time between automatic flushes. The realtime UX is sub-second so
    /// 750 ms keeps Langfuse near-real-time without spamming the backend.
    private let flushIntervalNs: UInt64 = 750_000_000

    init(traceId: String, api: CueAPI) {
        self.traceId = traceId
        self.api = api
    }

    func start() {
        guard flushTask == nil, !isStopped() else { return }
        flushTask = Task { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        while !isStopped() {
            try? await Task.sleep(nanoseconds: flushIntervalNs)
            if Task.isCancelled { break }
            await flushLocked()
        }
    }

    nonisolated func record(direction: Direction, type: String, payload: Any? = nil) {
        let event: [String: Any] = [
            "direction": direction.rawValue,
            "type": type,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "payload": payload ?? [String: Any](),
        ]
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard !stoppedFlag else { return }
        pendingEvents.append(event)
    }

    // Sync helpers — keep all NSLock calls out of async contexts so we don't
    // trip the Swift 6 'lock unavailable from asynchronous contexts' rule.
    private nonisolated func isStopped() -> Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return stoppedFlag
    }

    private nonisolated func markStopped() {
        bufferLock.lock()
        stoppedFlag = true
        bufferLock.unlock()
    }

    private nonisolated func drain() -> [[String: Any]] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let snapshot = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return snapshot
    }

    private func flushLocked() async {
        let toSend = drain()
        guard !toSend.isEmpty else { return }
        do {
            try await api.postVoiceEvents(traceId: traceId, events: toSend)
        } catch {
            log.error("postVoiceEvents failed (\(toSend.count) events): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        markStopped()
        flushTask?.cancel()
        flushTask = nil
        await flushLocked()
    }
}
