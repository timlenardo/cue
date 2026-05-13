# Orbit — voice realtime branch setup

This branch (`ios-voice-realtime`) replaces the simulated `VoiceAgentView`
with a real OpenAI Realtime voice loop over WebRTC. It builds on the
on-device wake-word integration (say "Orbit" to open the
voice agent) that was already WIP on `main`.

> **Adding a realtime voice tool?** See [AGENTS.md](./AGENTS.md#adding-a-new-realtime-tool) for the end-to-end checklist across this repo + cue-server. Five touchpoints; skipping any one fails silently.

## What this branch adds

| | |
|---|---|
| **Backend dependency** | `cue-server` PR #1 — `POST /v1/voice/session` (ephemeral token + transcript context) and `POST /v1/voice/tools/search-transcript`. Already deployed to `cue-dev` on Heroku. |
| **Transport** | iOS ↔ OpenAI WebRTC, direct. cue-server only mints the ephemeral token. |
| **Voice tools** | `resume_playback` / `seek_to_timestamp` / `rewind_ten_seconds` run client-side (drive `AudioPlayer`). `search_transcript` proxies to cue-server. `search_internet` / `save_note` reply "not implemented" until their server handlers ship. |
| **New files** | `Cue/Voice/RealtimeVoiceSession.swift`, `Cue/Voice/RealtimeTools.swift` |
| **Modified files** | `Cue/CueAPI.swift` (DTOs + 2 methods), `Cue/AppState.swift` (session lifecycle hooks), `Cue/VoiceAgentView.swift` (replaces simulation), `Cue/PlayerView.swift` (drops `qaIndex` from the view init) |

## Prerequisites

- macOS with **Xcode 16+** (project tested on 16.2)
- An **Apple ID** signed into Xcode (Settings → Accounts) — a free personal team is enough for sideloading to your own phone
- A **physical iPhone running iOS 18+** (the wake word and voice loop both need real mic + speaker; the simulator works for the UI but not the conversation)
- USB cable for first install (wireless debugging works after)

## One-time setup

### 1. Open the worktree in Xcode

```sh
open /Users/douglasqian/ios-voice-realtime/Cue.xcodeproj
```

### 2. Add the WebRTC SwiftPM package

This is the only manual Xcode step required for the build to succeed. The Swift code already does `import WebRTC`; we just need to teach the project where that module lives.

1. In Xcode: **File → Add Package Dependencies…**
2. Paste this URL into the search field:
   ```
   https://github.com/stasel/WebRTC.git
   ```
3. Dependency Rule: **Up to Next Major Version** (the default for the latest release is fine — currently `137.x`).
4. Click **Add Package**.
5. Xcode shows a "Choose Package Products" sheet. Make sure `WebRTC` is checked and the target is `Cue`. Click **Add Package**.
6. Wait for SwiftPM resolution (~30s — it downloads an ~80 MB binary xcframework).

Verify: in the Project Navigator, expand `Cue → Frameworks, Libraries, and Embedded Content`. You should see `WebRTC` listed with embed type `Do Not Embed` (default for binary xcframeworks). If you see it under "Package Dependencies" at the top of the navigator but NOT in the Cue target's frameworks list, click **+** under "Frameworks, Libraries, and Embedded Content" and add it.

### 3. Configure signing for your Apple ID

1. Select the **Cue** project in the navigator → **Cue** target → **Signing & Capabilities** tab.
2. **Team**: pick your personal team (the one tied to your Apple ID).
3. **Bundle Identifier**: if Xcode complains that `com.dzq.cuepod` isn't available, change it to something unique like `com.<yourname>.cuepod`.
4. Make sure **Automatically manage signing** is checked.

## Running on your phone

1. Plug the iPhone in via USB. Unlock it. Trust the Mac if prompted.
2. In Xcode's run-destination dropdown (top-center), select your phone.
3. Hit **⌘R** (Run).
4. First install: iOS will refuse to launch because the developer cert isn't trusted yet.
   - On the phone: **Settings → General → VPN & Device Management → [your Apple ID] → Trust**.
   - Tap **Trust** in the confirmation sheet.
   - Back in Xcode, hit **⌘R** again.
5. Mic permission prompt: tap **Allow**.

After this, wireless debugging works: with the phone on the same Wi-Fi as the Mac and "Connect via network" enabled in **Window → Devices and Simulators**, you don't need the cable.

## Testing the voice loop end-to-end

You'll be hitting the deployed `cue-dev` Heroku app, so the phone needs internet — Wi-Fi or LTE.

### Sign in
1. Launch the app. You'll see the phone-auth screen.
2. Enter any phone number. Tap **Send code**.
3. Enter the bypass code **`123456`**. (Works regardless of phone; gated by code, not env.)
4. You're in.

### Load a live episode
1. On the home screen, paste a podcast episode URL (Spotify / Apple / RSS — anything `/v1/podcasts/resolve` can handle).
   - Recommended for fast testing: an episode that's already cached on the server. The NPR Up First episode `https://prfx.byspotify.com/e/play.podtrac.com/npr-510318/...default.mp3` has both the transcript cached and the audio served reliably.
2. Wait for resolve + transcribe (transcribe streams a progress bar; cached episodes finish in a second).
3. The player opens. Tap play, let it run for a minute or two, then tap pause (or just leave it playing — wake word still works).

### Talk to it
There are two ways to start a session:
- **Tap the mic button** (next to play/pause in the player UI), OR
- **Say the wake phrase** out loud — current triggers are `orbit`, `orbits`, `orbital`. On-device Whisper transcribes the mic continuously and fires `AppState.openMic()` on match. Extend the regex in `Cue/Wake/WakeWordEngine.swift` to add aliases.

What you should see:
1. Podcast pauses, voice agent sheet slides up.
2. Status shows **"Connecting…"** for ~500–1500ms (cue-server token mint + WebRTC SDP exchange).
3. Status flips to **"Listening"**.
4. Speak: "What's this episode about?"
5. **"Thinking"** → **"Speaking"** as the model streams audio + transcript back. Your transcribed question appears in the serif font, the model's reply in the sans font below.
6. Tap **Resume podcast** (or the X) to close — the podcast resumes from where it paused.

### Verify each tool
- **Resume**: say *"yeah resume"* → the model fires `resume_playback`, the sheet closes, podcast plays.
- **Seek**: say *"skip to the part about Hantavirus"* — model calls `search_transcript` (server hop), then `seek_to_timestamp` with a real timestamp, and the podcast jumps + resumes.
- **Rewind**: say *"back up ten seconds"* → `rewind_ten_seconds` fires.
- **Stub tools**: say *"save this"* → `save_note` fires but cue-server returns the not-implemented stub; model will say something like "I can't save notes yet — that's coming soon."

### See the logs
- On the Mac: open **Console.app** → select your phone in the sidebar → filter on subsystem `com.toug.cue`. You'll see `CueAPI`, `RealtimeVoice`, `RealtimeTools`, and `WakeWord` log streams in real time.
- Or run the app from Xcode and watch the debug console.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Build fails with `no such module 'WebRTC'` or `'WhisperKit'` | SwiftPM resolution didn't finish. File → Packages → Reset Package Caches, then Resolve Package Versions. Also confirm both products are linked to the Cue target (Target → General → Frameworks, Libraries, and Embedded Content). |
| Phone refuses to launch app ("Untrusted Developer") | Settings → General → VPN & Device Management → trust your Apple ID. |
| Wake word never fires | Check **Settings → Orbit → Microphone** is on; check Console for `wake` errors. First launch downloads the Whisper tiny.en model (~75 MB) from HuggingFace — needs internet once. |
| Voice session stuck on "Connecting…" | Check Console for `RealtimeVoice` and `CueAPI` errors. Usual causes: phone offline, JWT expired (sign out + back in), or cue-dev down (try `curl https://cue-dev-7bd3eabd5817.herokuapp.com/v1/health/`). |
| Voice session connects but you hear nothing | iOS audio session quirk — check the speaker isn't muted via the side switch, and make sure no other app held the mic. |
| "Load an episode to talk" empty state | You hit the mic without loading a live episode (canned-sample mode). Paste a podcast URL on the home screen first. |
| `404 No cached transcript for this audioUrl` from `/v1/voice/session` | The episode wasn't transcribed yet. Tap pause/replay flow to retrigger `/v1/podcasts/transcribe`, or pick an episode you've used before. |


Branch name: `ios-voice-realtime`. Remote not yet pushed.
