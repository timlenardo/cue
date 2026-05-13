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
    @MainActor
    static func dispatch(
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
