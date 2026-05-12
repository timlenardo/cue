import Foundation
import os

private let log = Logger(subsystem: "com.toug.cue", category: "RealtimeTools")

/// Result of dispatching a realtime function_call.
///
/// - `terminal`: a playback-control tool fired (resume / seek / rewind).
///   After sending `function_call_output` we tear the session down and
///   resume the podcast — the user committed to going back to listening.
/// - `nonTerminal`: a data tool fired (search_transcript) or a tool
///   whose server handler isn't built yet. We send `function_call_output`
///   and a `response.create` so the model speaks its follow-up; the
///   session stays open.
enum ToolDispatchResult {
    case terminal(outputJSON: String)
    case nonTerminal(outputJSON: String)
}

enum RealtimeTools {
    /// Dispatch a function_call by name. Runs on the main actor because
    /// playback tools mutate AppState / AudioPlayer.
    @MainActor
    static func dispatch(
        name: String,
        args: [String: Any],
        state: AppState,
        api: CueAPI
    ) async -> ToolDispatchResult {
        log.info("dispatch tool=\(name, privacy: .public)")

        switch name {
        case "resume_playback":
            state.audio.play()
            state.audio.setRate(Float(state.speed))
            return .terminal(outputJSON: #"{"ok":true}"#)

        case "seek_to_timestamp":
            let seconds = (args["seconds"] as? Double) ?? Double((args["seconds"] as? Int) ?? 0)
            let target = max(0, seconds)
            state.audio.seek(to: target)
            state.audio.play()
            state.audio.setRate(Float(state.speed))
            return .terminal(outputJSON: #"{"ok":true,"seekedTo":\#(target)}"#)

        case "rewind_ten_seconds":
            let current = state.audio.currentTime
            let target = max(0, current - 10)
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
            do {
                let resp = try await api.searchTranscript(audioUrl: audioUrl, query: query)
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
            do {
                let resp = try await api.searchInternet(query: query)
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

        case "save_note":
            log.notice("tool \(name, privacy: .public) called but handler not implemented yet")
            return .nonTerminal(outputJSON: #"{"error":"not implemented yet"}"#)

        default:
            log.warning("unknown tool: \(name, privacy: .public)")
            return .nonTerminal(outputJSON: #"{"error":"unknown tool"}"#)
        }
    }
}
