import Foundation
import os

private let log = Logger(subsystem: "com.toug.cue", category: "RealtimeTools")

/// Result of dispatching a realtime function_call.
///
/// - `terminal`: a commitment playback-control tool fired (resume / seek
///   / rewind / forward). After sending `function_call_output` we tear
///   the session down and resume the podcast — the user committed to
///   going back to listening.
/// - `nonTerminal`: a data tool fired (search_transcript, search_internet)
///   or pause_playback. We send `function_call_output` and a
///   `response.create` so the model speaks its follow-up; the session
///   stays open.
enum ToolDispatchResult {
    case terminal(outputJSON: String)
    case nonTerminal(outputJSON: String)
}

enum RealtimeTools {
    /// Default rewind/forward step when the model omits `seconds`.
    static let defaultStepSeconds: Double = 15
    /// Clamp range for the rewind/forward `seconds` argument. Matches the
    /// min/max declared in the server-side tool schema.
    static let minStepSeconds: Double = 1
    static let maxStepSeconds: Double = 300

    /// Dispatch a function_call by name. Runs on the main actor because
    /// playback tools mutate AppState / AudioPlayer.
    ///
    /// PostHog event emission is centralized here (not duplicated at each
    /// return) so adding a new tool case can't accidentally drop telemetry.
    @MainActor
    static func dispatch(
        name: String,
        args: [String: Any],
        state: AppState,
        api: CueAPI,
        traceId: String? = nil,
        callId: String? = nil
    ) async -> ToolDispatchResult {
        let t0 = Date()
        let result = await dispatchInner(
            name: name,
            args: args,
            state: state,
            api: api,
            traceId: traceId,
            callId: callId
        )
        let outputJSON: String
        switch result {
        case .terminal(let s), .nonTerminal(let s): outputJSON = s
        }
        // Heuristic: any tool result containing `"error"` or `"ok":false` is
        // a failure. The dispatch cases below construct these strings by
        // hand, so the substring match is reliable. If we add structured
        // return types later, this should switch to checking those.
        let ok = !outputJSON.contains("\"error\"") && !outputJSON.contains("\"ok\":false")
        state.recordVoiceToolCall()
        Analytics.shared.track(
            "voice_tool_fired",
            properties: [
                "tool_name": name,
                "ok": ok,
                "ms": Int(Date().timeIntervalSince(t0) * 1000),
                "trace_id": traceId,
            ]
        )
        return result
    }

    @MainActor
    private static func dispatchInner(
        name: String,
        args: [String: Any],
        state: AppState,
        api: CueAPI,
        traceId: String? = nil,
        callId: String? = nil
    ) async -> ToolDispatchResult {
        log.info("dispatch tool=\(name, privacy: .public)")

        switch name {
        case "resume_playback":
            state.audio.play()
            state.audio.setRate(Float(state.speed))
            return .terminal(outputJSON: #"{"ok":true}"#)

        case "pause_playback":
            state.audio.pause()
            return .nonTerminal(outputJSON: #"{"ok":true}"#)

        case "seek_to_timestamp":
            let raw = readDouble(args["timestampSeconds"]) ?? 0
            let target = max(0, raw)
            state.audio.seek(to: target)
            state.audio.play()
            state.audio.setRate(Float(state.speed))
            return .terminal(outputJSON: #"{"ok":true,"seekedTo":\#(target)}"#)

        case "rewind":
            let step = clampedStep(readDouble(args["seconds"]))
            let current = state.audio.currentTime
            let target = max(0, current - step)
            state.audio.seek(to: target)
            state.audio.play()
            state.audio.setRate(Float(state.speed))
            return .terminal(outputJSON: #"{"ok":true,"seekedTo":\#(target)}"#)

        case "forward":
            let step = clampedStep(readDouble(args["seconds"]))
            let current = state.audio.currentTime
            let target = max(0, current + step)
            state.audio.seek(to: target)
            state.audio.play()
            state.audio.setRate(Float(state.speed))
            return .terminal(outputJSON: #"{"ok":true,"seekedTo":\#(target)}"#)

        case "search_transcript":
            guard let audioUrl = state.live?.episode.audioUrl else {
                return .nonTerminal(outputJSON: #"{"error":"no episode loaded"}"#)
            }
            let query = (args["query"] as? String) ?? ""
            guard !query.isEmpty else {
                return .nonTerminal(outputJSON: #"{"error":"empty query"}"#)
            }
            let limit = readInt(args["limit"])
            do {
                let resp = try await api.searchTranscript(
                    audioUrl: audioUrl,
                    query: query,
                    limit: limit,
                    traceId: traceId,
                    callId: callId
                )
                let encoder = JSONEncoder()
                let data = try encoder.encode(resp)
                let outputJSON = String(data: data, encoding: .utf8) ?? #"{"results":[]}"#
                log.info("search_transcript \(resp.results.count) hits for query=\(query, privacy: .public)")
                return .nonTerminal(outputJSON: outputJSON)
            } catch {
                log.error("search_transcript failed: \(error.localizedDescription, privacy: .public)")
                let msg = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
                return .nonTerminal(outputJSON: #"{"error":"\#(msg)"}"#)
            }

        case "save_note":
            guard let live = state.live else {
                return .nonTerminal(outputJSON: #"{"ok":false,"error":"no episode loaded"}"#)
            }
            let rawNote = (args["note"] as? String) ?? ""
            let text = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .nonTerminal(outputJSON: #"{"ok":false,"error":"empty note"}"#)
            }
            let positionSeconds = state.audio.currentTime
            do {
                let resp = try await api.saveNote(
                    audioUrl: live.episode.audioUrl,
                    positionSeconds: positionSeconds,
                    text: text,
                    traceId: traceId,
                    callId: callId
                )
                if let note = resp.note {
                    state.appendNote(note)
                    log.info("save_note saved id=\(note.id) at \(positionSeconds)s chars=\(text.count)")
                    return .nonTerminal(outputJSON: #"{"ok":true,"id":\#(note.id),"savedAtSeconds":\#(positionSeconds)}"#)
                } else {
                    let msg = resp.error ?? "save failed"
                    log.error("save_note rejected: \(msg, privacy: .public)")
                    let safe = msg.replacingOccurrences(of: "\"", with: "'")
                    return .nonTerminal(outputJSON: #"{"ok":false,"error":"\#(safe)"}"#)
                }
            } catch {
                log.error("save_note failed: \(error.localizedDescription, privacy: .public)")
                let msg = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
                return .nonTerminal(outputJSON: #"{"ok":false,"error":"\#(msg)"}"#)
            }

        case "search_internet":
            let query = (args["query"] as? String) ?? ""
            guard !query.isEmpty else {
                return .nonTerminal(outputJSON: #"{"error":"empty query"}"#)
            }
            let limit = readInt(args["limit"])
            do {
                let resp = try await api.searchInternet(
                    query: query,
                    limit: limit,
                    traceId: traceId,
                    callId: callId
                )
                let encoder = JSONEncoder()
                let data = try encoder.encode(resp)
                let outputJSON = String(data: data, encoding: .utf8) ?? #"{"results":[]}"#
                log.info("search_internet \(resp.results.count) hits for query=\(query, privacy: .public)")
                return .nonTerminal(outputJSON: outputJSON)
            } catch {
                log.error("search_internet failed: \(error.localizedDescription, privacy: .public)")
                let msg = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
                return .nonTerminal(outputJSON: #"{"error":"\#(msg)"}"#)
            }

        default:
            log.warning("unknown tool: \(name, privacy: .public)")
            return .nonTerminal(outputJSON: #"{"error":"unknown tool"}"#)
        }
    }

    private static func readDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private static func readInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    private static func clampedStep(_ requested: Double?) -> Double {
        guard let r = requested else { return defaultStepSeconds }
        return min(maxStepSeconds, max(minStepSeconds, r))
    }
}
