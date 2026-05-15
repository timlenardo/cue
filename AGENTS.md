# AGENTS.md — cue (iOS)

Guidance for AI agents (and humans) working in this repo. Pair with [cue-server/AGENTS.md](https://github.com/timlenardo/cue-server/blob/main/AGENTS.md) when changes span both repos.

## Repo at a glance

SwiftUI iOS app. Targets iOS 18+. Key files:

- `Cue/CueApp.swift` / `RootView.swift` / `ContentView.swift` — root + tab routing
- `Cue/AppState.swift` — `@Observable` central state (live episode, library, notes, voice session, audio control)
- `Cue/CueAPI.swift` — networking client (DTOs + methods). Talks to cue-server.
- `Cue/AudioPlayer.swift` — AVPlayer wrapper
- `Cue/Voice/` — OpenAI Realtime WebRTC session
  - `RealtimeVoiceSession.swift` — data-channel event loop + WebRTC connection
  - `RealtimeTools.swift` — tool dispatch (the model's `function_call` → side effects)
- `Cue/Wake/` — on-device wake-word engine (WhisperKit)
- `Cue/PlayerView.swift`, `LibraryView.swift`, `NotesView.swift` — main screens

Server-side counterparts in the [cue-server](https://github.com/timlenardo/cue-server) repo.

## Realtime voice tools — how they fit together

The OpenAI Realtime model can call functions ("tools") mid-conversation to drive playback, fetch context, and persist user-pinned moments. Each tool has **5 touchpoints** across both repos. Missing any one breaks the chain silently and the model usually falls back to talking about the tool instead of calling it.

See [cue-server/AGENTS.md](https://github.com/timlenardo/cue-server/blob/main/AGENTS.md#realtime-voice-tools--how-they-fit-together) for the full architecture diagram. The iOS-side picture:

```
  OpenAI Realtime API (WebRTC)
            │
            │  function_call event
            ▼
  RealtimeVoiceSession.swift          ← reads data-channel events
    handleEvent("response.output_     ← extracts name, callId, args
                item.done")           ← dispatches to RealtimeTools
            │
            ▼
  RealtimeTools.swift                  ← (4) Dispatch case
    switch name {                      ← one branch per tool
      case "my_tool":
        // either run locally (playback)
        // or POST to cue-server (data)
        return .terminal / .nonTerminal
    }
            │
            ▼ (for server-backed tools)
  CueAPI.swift                         ← (5) API method + DTOs
    func myTool(...)                   ← POST /v1/voice/tools/<kebab-name>
            │
            ▼
       cue-server                      ← (3) Server handler
                                       ← writes JSON back to model as
                                          function_call_output
```

Tools 1 + 2 (schema + system prompt) live entirely in cue-server. iOS receives them implicitly via the OpenAI ephemeral token minted by `POST /v1/voice/session`.

### Terminal vs non-terminal

Every dispatch case returns one of two cases:

| Result | Behavior |
|---|---|
| `.terminal(outputJSON:)` | Send `function_call_output`, wait 100ms, close the voice agent. The user "committed" to going back to listening (resume / seek / rewind / forward / pause). |
| `.nonTerminal(outputJSON:)` | Send `function_call_output`, then send `response.create` to nudge the model to speak its follow-up. Mic stays open (search / save_note). |

Match this with what the cue-server system prompt says about the tool ("This ends the conversation" vs "This does NOT end the conversation"). Mismatches confuse the model into either talking after a commit-style call (annoying) or hanging after a data-fetch call (much worse — the model never speaks).

## Adding a new realtime tool

cue-server steps come first (schema + prompt + handler). See [cue-server/AGENTS.md](https://github.com/timlenardo/cue-server/blob/main/AGENTS.md#adding-a-new-realtime-tool). Below are the iOS steps.

### Step 4 — Dispatch case

Edit `Cue/Voice/RealtimeTools.swift`. Add a `case` inside the big `switch name` block, somewhere logically grouped with similar tools. Use `search_transcript` (server-backed, non-terminal) and `seek_to_timestamp` (local, terminal) as templates.

Pattern for a **server-backed non-terminal** tool:

```swift
case "my_tool":
    guard let live = state.live else {
        return .nonTerminal(outputJSON: #"{"ok":false,"error":"no episode loaded"}"#)
    }
    let arg = (args["my_arg"] as? String) ?? ""
    guard !arg.isEmpty else {
        return .nonTerminal(outputJSON: #"{"ok":false,"error":"empty arg"}"#)
    }
    do {
        let resp = try await api.myTool(
            audioUrl: live.episode.audioUrl,
            arg: arg,
            traceId: traceId,
            callId: callId
        )
        // Optimistically update local state if relevant.
        // Encode the server response as the function_call_output JSON.
        return .nonTerminal(outputJSON: <json>)
    } catch {
        let msg = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
        return .nonTerminal(outputJSON: #"{"ok":false,"error":"\#(msg)"}"#)
    }
```

Pattern for a **local terminal** tool (drives `AudioPlayer`):

```swift
case "my_action":
    state.audio.<...>  // do the playback thing
    state.audio.play()
    return .terminal(outputJSON: #"{"ok":true}"#)
```

The `traceId` + `callId` parameters are already plumbed into `RealtimeTools.dispatch(...)` from `RealtimeVoiceSession.dispatchFunctionCall`. Forward them to `api.*` so Langfuse ties the server-side observation to the voice session.

### Step 5 — API method + DTOs

Edit `Cue/CueAPI.swift`:

1. **DTOs** under the relevant `// MARK: -` section. `Encodable` for request bodies, `Decodable` for responses. Property names must be **identical** (camelCase) to the field names in the server controller's `serialize*` function — that's how Codable matches them.
2. **Method** in the `final class CueAPI` body, alongside the others. Use the existing `post`/`get`/`postRaw`/`delete` helpers — they handle auth, timing, and 401-clears-token automatically.

```swift
func myTool(
    audioUrl: String,
    arg: String,
    traceId: String? = nil,
    callId: String? = nil
) async throws -> MyToolResponse {
    try await post(
        "/v1/voice/tools/my-tool",
        body: MyToolRequest(audioUrl: audioUrl, arg: arg),
        headers: traceHeaders(traceId: traceId, callId: callId)
    )
}
```

URL path uses **kebab-case** (`/my-tool`). The tool name on the OpenAI side uses **snake_case** (`my_tool`). That asymmetry is intentional and matches existing tools — don't try to "normalize" it.

### Step 6+ — Optional persistence

If the tool persists data the user can browse later (like `save_note`):

- **AppState**: add a `@Observable` collection (`var allFoos: [ServerFoo] = []`), an `appendFoo(_:)` optimistic-update method, a `reloadAllFoos()` async method that fetches via `CueAPI`. Trigger reload on auth in `RootView.task` and on tab open in the relevant view's `.task`.
- **UI**: build the view and **mount it in `ContentView`'s `switch state.tab`** — easy step to forget. Tab enum lives in `AppState.swift`.

## Pre-merge checklist for a new tool

- [ ] Tool name in the iOS dispatch `case` **exactly matches** the schema name in cue-server (`grep -rn "my_tool" Cue/`). Case-sensitive.
- [ ] Dispatch case returns `.terminal` or `.nonTerminal` to match the cue-server prompt's "ends/doesn't end conversation" line.
- [ ] If server-backed: API method exists in `CueAPI.swift`, URL is kebab-case, DTOs match the server's `serialize*` shape field-for-field.
- [ ] `traceId` + `callId` forwarded into the API call so Langfuse threads the observation.
- [ ] If persisting: `AppState` collection is `@Observable`, optimistic update method exists, view reads from the collection and is mounted in `ContentView`.
- [ ] `xcodebuild -project Cue.xcodeproj -scheme Cue -destination 'generic/platform=iOS Simulator' -configuration Debug build` succeeds with no warnings you introduced.
- [ ] Manual test on simulator OR device: open a voice session, say the trigger phrase, watch Console.app for `RealtimeTools` log line, confirm the side effect.

## Common pitfalls

These have bitten us before — listed so future-you (or future-AI) can recognize them faster.

- **Built the view but never wired it into `ContentView`.** Burned a full debug cycle once: `NotesView` existed, `state.allNotes` populated correctly, but `ContentView.swift` still had `case .notes: ComingSoonView(title: "Notes")` from the placeholder phase. **Always grep `ContentView.swift` for the tab enum case when adding a new screen.**

- **DTO field-name drift.** Default `JSONDecoder` matches by exact property name. Server returns `episodeId`; iOS struct declares `episode_id` — silent decoding failure, empty array surfaces as "nothing happened". Use exact camelCase matching the server's `serialize*` function.

- **`JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`** is set on the shared decoder. This is a no-op on camelCase keys (no underscores → no transform), but if the server ever returned snake_case it would silently convert. Don't rely on it for new tools; just match camelCase to camelCase.

- **Returning the wrong terminal/non-terminal kind.** If your tool is data-fetching but you return `.terminal`, the session closes before the model speaks the follow-up. If your tool is a playback commit but you return `.nonTerminal`, the user hears nothing because the model thinks the conversation continues but the podcast didn't resume.

- **Schema drift between repos.** Tool exists in cue-server `defaultTools` and matching dispatch case in iOS, but the parameter name differs (`note` vs `text`, `seconds` vs `timestampSeconds`). Always read the schema definition before writing the dispatch — copy the property names verbatim.

- **`state.live?` is `nil` at dispatch time.** The voice agent can only open over a live episode, but defensive guards are still cheap. Use `guard let live = state.live else { ... }` to fail clearly instead of force-unwrapping.

## Worktree workflow (per @douglasqian/multi-agent-harness)

This repo is set up for sibling-worktree development. Don't run `git checkout` / `git switch` / `git stash` — those are blocked by a pre-tool-use hook. Use:

```sh
bash /Users/douglasqian/multi-agent-harness/scripts/create-worktree.sh \
    /Users/douglasqian/cue <feature-slug>
```

…then `cd` to the new sibling worktree and do all work there.

## See also

- [cue-server/AGENTS.md](https://github.com/timlenardo/cue-server/blob/main/AGENTS.md) — server-side guidance, schema + prompt + handler conventions.
- `Cue/Voice/RealtimeTools.swift` header comment — current tool list + terminal/non-terminal classification.
- `Cue/Voice/RealtimeVoiceSession.swift` lines around `dispatchFunctionCall` — exactly how the data-channel event becomes a dispatch call.
