# Wake-Word Engine — Whisper Forced-Decode Port

Implementation plan for replacing Cue's WhisperKit-transcription wake engine
with a CoreML forced-decode keyword spotter ported from onit-beacon
(`macos/Onit/Transcription/CustomDictionary/WhisperKwsService.swift`).

**Source-of-truth references:**
- `~/Documents/Harold/Onit/lenardo-kws-research/EXPLORATION-2026-04-29.md`
  — algorithm rationale (sliding-window-max forced-decode, why it beats
  whole-clip forced-decode and free-decode).
- `~/Documents/Apps/onit-beacon/macos/Onit/Transcription/CustomDictionary/WhisperKwsService.swift`
  — the production Swift implementation (1020 lines, all optimizations
  battle-tested).
- `~/Documents/Apps/onit-beacon/macos/Onit/Resources/WhisperKWS/LATENCY-HANDOFF.md`
  — perf trail and what NOT to change.

---

## Goal & non-goals

**Goal.** Replace the WhisperKit "transcribe a rolling window, regex-match
the transcript" wake-word detector with a Whisper-tiny CoreML forced-decode
scorer that asks "how confidently would Whisper emit 'orbit' given this
audio?" — and threshold the answer. Ship behind a runtime toggle.

**Non-goals (intentional scope cuts).**
- No NLL perplexity gate (Onit-specific for transcript rescore; wake-word
  doesn't have surrounding-context disambiguation).
- No per-keyword threshold UI (one keyword, one threshold).
- No multi-language support (English only, matching current behavior).
- No streaming whisper / mid-utterance scoring (we score the rolling
  window as a whole, same cadence as today).
- No Sherpa cleanup (Cue doesn't ship Sherpa).
- No model auto-download (assets ship in-bundle; first-launch download is
  WhisperKit's complication, we don't repeat it).

---

## Decisions captured from this session

1. **Assets:** Copy onit-beacon's existing `.mlpackage` / `.mlmodelc` files
   into the Cue repo and verify they load on iOS 18+. If the macOS-targeted
   .mlpackage fails on iOS, fall back to re-running the converter script
   with `--target ios17`.
2. **Rollout:** Behind a `UserDefaults` toggle
   (`cue.forceDecodeWakeEnabled`). Default OFF for the first build; can be
   flipped per-device. Old `WakeWordEngine` keeps working unchanged.
3. **Plan first, then code.** This document gates implementation.

---

## Risks & unknowns (called out up front)

| Risk | Likelihood | Mitigation |
|---|---|---|
| onit-beacon's `.mlpackage` was compiled with macOS15 deployment target — may not load on iOS 18 | **high** | Phase 0 step: try loading on simulator + device. If it fails, re-run `convert_whisper_decoder_parallel.py` with `--minimum-deployment-target iOS17`. The script is in onit-beacon's `python-server/scripts/`. |
| `.mlpackage` artifacts may need to be `coremlcompiler compile`'d at build time, or Xcode does this automatically | medium | Xcode compiles `.mlpackage` to `.mlmodelc` during build for both macOS and iOS targets — verify by checking the .app bundle after first build. If not, add a build phase. |
| iOS A-series Neural Engine routing may differ from Apple Silicon — `cpuAndNeuralEngine` for decoder may regress on iPhone | medium | Phase 3 step: measure on real device. If ANE underperforms, try `cpuAndGPU` or `all`. The onit-beacon LATENCY-HANDOFF documents that this routing was tested only on M3 Pro. |
| Asset size (~84 MB tiny variant) inflates the IPA | low | Acceptable — within typical wake-word model budget. App Store IPA compression usually halves CoreML weights. If it's a problem, ship the encoder/decoder asset over CDN on first launch (Phase 4, optional). |
| Mic resampling cost — Cue's MicCapture is 48 kHz; we need 16 kHz | low | Cue's `WakeWordEngine.resample` already does this on the render thread. Reuse the same code path verbatim. |
| Wake-word use case has shorter audio than transcript rescore — may need re-calibrated threshold | high | Default onit-beacon threshold is `-8.0` (very permissive). Calibrate on Cue's own `orbit-aurora-chime.wav` fixture + recorded "orbit" utterances. Expect to land between −7 and −5. |
| "Orbit" is a more common English word than "Lenardo" — higher base FP rate expected | medium | Wake-word debounce + 1.5s `lastFireAt` gate (already present) absorbs most FP bursts. If FP rate becomes an issue, raise threshold and tighten variant list. |

**One open question for after Phase 0:** does the encoder need to run on
the full 2-second rolling buffer (Cue's current window) or should we widen
the rolling window? The onit-beacon algorithm expects up to 30 s of audio
padded to a 30s mel; for a 2 s window the sliding-window count is small
(~7 windows at 0.8s/0.2s stride). Latency budget shrinks proportionally;
should be a clean win.

---

## Acceptance criteria (the bar for shipping the toggle ON by default)

These mirror the spirit of onit-beacon's Phase 5 gates but are
wake-word-specific and **don't use AUC**.

1. **Recall:** ≥ 95% on a hand-recorded set of 20 "orbit" utterances
   (varied prosody, distance, background noise).
2. **False-fire rate:** ≤ 1 / hour during normal podcast listening (use
   the existing `wakeTrackingEnabled` toast-stack to count hits during
   30 min of dogfooding with no wake intent).
3. **Latency:** p95 inference < 80 ms per rolling-window evaluation on
   iPhone 15 Pro. (Onit's macOS budget is ~177 ms for 22 windows × 50
   keywords; we expect ~50 ms for 7 windows × 3 variants on A17.)
4. **No regressions:** the existing AppState wake hooks (`onDetect`,
   `onTranscript`, `wakePaused`, `wakeTrackingEnabled`,
   `audioLevelsDebugEnabled`) keep working unchanged.
5. **Toggle off path:** with `cue.forceDecodeWakeEnabled = false`, the
   old `WakeWordEngine` runs as today — no behavior change.

Gating criterion **before any code merges**: phase 0 (model loads on
device) and phase 5 (real-device sanity) must pass.

---

## File inventory

**New files (Cue/Wake/):**

| File | Source | Notes |
|---|---|---|
| `WhisperBPETokenizer.swift` | port verbatim from onit-beacon | byte-level GPT-2 BPE, ~250 lines. No adaptation needed; the leading-space convention applies to wake-word too. |
| `WhisperKwsEngine.swift` | adapt onit-beacon's `WhisperKwsService.swift` | actor; single-keyword variant; exposes `start()`/`stop()`/`onDetect`/`onTranscript` matching the existing `WakeWordEngine` interface, so AppState wiring doesn't change. |
| `WakeWordEngineFactory.swift` (or simple inline switch in AppState) | new | Reads `cue.forceDecodeWakeEnabled` from UserDefaults and returns either the existing `WakeWordEngine` or the new `WhisperKwsEngine`. Both conform to a common `WakeEngine` protocol that wraps the existing public surface. |

**New protocol (defines the shared surface so AppState is engine-agnostic):**

```swift
// Cue/Wake/WakeEngine.swift  (new, ~30 lines)
protocol WakeEngine: AnyObject {
    var onDetect: (@MainActor () -> Void)? { get set }
    var onTranscript: (@MainActor (_ text: String, _ isHit: Bool,
                                   _ levels: AudioLevelStats?) -> Void)? { get set }
    @MainActor func start()
    @MainActor func stop()
}
```

`WakeWordEngine` already implements this surface — adopting the protocol
is a one-liner.

**New bundled resources (Cue/Resources/WhisperKWS/):**

| File | Size | Source |
|---|---|---|
| `MelSpectrogram.mlmodelc/` | 370 KB | copy from onit-beacon |
| `AudioEncoderTiny.mlpackage/` | 33 MB | copy from onit-beacon |
| `TextDecoderParallelTiny.mlpackage/` | 51 MB | copy from onit-beacon |
| `vocab.json` | 816 KB | copy from onit-beacon |
| `merges.txt` | 484 KB | copy from onit-beacon |

**Total bundled: ~85 MB.** All gitignored (mirror onit-beacon's `.gitignore`
block), with copy instructions in a `Cue/Resources/WhisperKWS/README.md`
crib note (1 paragraph + the `cp -R` commands).

**Modified files:**

| File | Change |
|---|---|
| `Cue/AppState.swift` | Add `forceDecodeWakeEnabled: Bool` toggle (lines ~240). Change `let wake = WakeWordEngine()` to `let wake: WakeEngine = ...` with factory selection. Wiring sites for `onDetect`, `onTranscript`, `start`, `stop` unchanged because both conform to `WakeEngine`. |
| `Cue/Wake/WakeWordEngine.swift` | Add `: WakeEngine` conformance. Zero behavior change. |
| `.gitignore` | New block for `Cue/Resources/WhisperKWS/*.mlpackage` and `*.mlmodelc`. |
| `Cue.xcodeproj/project.pbxproj` | Add `CoreML` and `Accelerate` to linked frameworks. The synchronized root group at `Cue/` means no `.swift` files need pbxproj edits, but framework links do. |

**Tests:**

| File | Purpose |
|---|---|
| `CueTests/WhisperKwsEngineTests.swift` | Two tests: (1) `testOrbitFixtureFires` — load the existing `Cue/Resources/orbit-aurora-chime.wav` fixture, run through engine, assert score > threshold. (2) `testSilenceDoesNotFire` — feed zero buffer, assert no detection. |

No XCTPerformance test for latency — we measure on-device by hand via
`OSLog`. Adding a CI latency gate is overkill for an iOS app and the
simulator timing is not representative anyway.

---

## Phases

### Phase 0: model assets load on iOS (~1 hour)

**Goal:** confirm onit-beacon's macOS-built `.mlpackage` artifacts load
and predict on iPhone simulator and on a real device.

Steps:
1. Copy the five resource files from
   `~/Documents/Apps/onit-beacon/macos/Onit/Resources/WhisperKWS/`
   into `Cue/Resources/WhisperKWS/`.
2. Write a one-off `print()`-only test: `MLModel(contentsOf: …)` on each
   of the three models, then `try prediction(from: dummyInput)` on each.
   Run on iOS simulator (iPhone 15 Pro) AND on a real device (whatever's
   plugged in).
3. **Pass:** no exceptions, predictions return arrays of the expected
   shape.
4. **Fail:** re-export with iOS deployment target. Steps to do this:
   - `cd ~/Documents/Apps/onit-beacon`
   - Edit `python-server/scripts/convert_whisper_decoder_parallel.py` and
     change `minimum_deployment_target=ct.target.macOS15` to
     `ct.target.iOS17`.
   - Re-run the script; copy the new .mlpackage to Cue.

**Definitely needs the user.** Real-device testing requires the user's
hardware.

### Phase 1: tokenizer + service port (~2 hours)

1. Copy `WhisperBPETokenizer.swift` from onit-beacon to `Cue/Wake/`. The
   tokenizer doesn't depend on anything wake-specific.
2. Copy `WhisperKwsService.swift` to `Cue/Wake/WhisperKwsEngine.swift`.
   Strip out:
   - Detection peak-walking + `KWSDetection` struct (we just need a
     boolean fire / no-fire).
   - Per-keyword threshold dictionary (replace with a single
     `static let threshold: Float = -7.0` constant — tunable later).
   - `loadIfNeeded(keywords:thresholds:)` complexity — replace with a
     simple `loadIfNeeded()` that bakes the keyword list in.
   - `detectKeywords*` and `computeMaxScores` — replace with one
     `score(audio: [Float]) async throws -> Float` returning the max
     over windows and over phrase variants.
3. Adapt the keyword list: hardcode `["orbit", "orbital", "orbits"]`
   (the variants from Cue's current trigger regex).
4. Wire the engine to the same interface as `WakeWordEngine`: rolling
   ring buffer, throttled inference, debounce. Steal the mic plumbing
   (`addBufferHandler`, `RingBuffer`, `AVAudioConverter`, level stats)
   from `WakeWordEngine.swift` — these don't change between engines.
5. Define `WakeEngine` protocol; add conformance to both engines.

### Phase 2: feature-flag wiring (~30 min)

1. Add `forceDecodeWakeEnabled: Bool` to `AppState` following the
   `wakePaused` pattern (lines 240–254). Key: `cue.forceDecodeWakeEnabled`.
   Default: `false`.
2. Change `AppState.wake` declaration from `WakeWordEngine` to
   `WakeEngine`. Construct in `init()` via:
   ```swift
   self.wake = UserDefaults.standard.bool(forKey: "cue.forceDecodeWakeEnabled")
       ? WhisperKwsEngine() : WakeWordEngine()
   ```
3. Add a settings-pane toggle so we can flip it in the running app
   (mirror an existing settings toggle).
4. Add a `forceRestartWake()` method called when the toggle flips — must
   call `wake.stop()`, recreate the engine, re-bind callbacks, call
   `wake.start()` if armed.

### Phase 3: device latency measurement (~30 min)

1. Add `os_signpost` around the per-window mel/encoder/decoder calls in
   `WhisperKwsEngine`.
2. Run on iPhone 15 Pro for 60 seconds during playback. Read Instruments
   timing.
3. **Pass:** p95 < 80 ms per evaluation. **Fail:** profile and tune
   compute-unit routing per the LATENCY-HANDOFF table.

### Phase 4: recall + FP calibration (~1-2 hours, manual)

1. Use the `orbit-aurora-chime.wav` fixture + record 10–20 "orbit"
   utterances. Run them through the engine via a debug command.
2. Inspect scores. Pick a threshold where all utterances score above.
3. Dogfood for 30 min with `wakeTrackingEnabled = true`; count
   false-fires from podcast audio.
4. **Pass:** ≥ 95% recall AND ≤ 1 FP / hour. Adjust threshold or variant
   list if not.

### Phase 5: ship the toggle (≤ 30 min)

1. Verify toggle-off path is byte-identical to today's behavior.
2. Verify toggle-on path on real device for at least one wake → voice
   open cycle.
3. Commit + PR.

---

## What to NOT do (lessons from onit-beacon)

These are foot-guns the onit-beacon team already paid for. Don't repeat.

- **Don't use `useSingleEncoder = true`.** Encoder self-attention
  propagates across frames; slicing post-encode breaks recall by ~0.6
  log-prob units. Per-window encoding is mandatory.
- **Don't use stride > 0.2s.** Stride 0.3s missed real Lenardo
  placements; 0.4s missed entirely. The window must catch the keyword's
  onset alignment.
- **Don't use `EnumeratedShapes` on the decoder.** Pins the whole
  CoreML graph to CPU and runs ~25× slower. Use static `(B=64, T=8)`.
- **Don't move MelSpectrogram off CPU.** Sharing ANE with the decoder
  serializes both. CPU mel is ~1 ms; ANE decoder needs the bandwidth.
- **Don't use `cpuOnly` log-softmax.** Vectorize via
  `vImageConvert_Planar16FtoPlanarF + vDSP_maxv + vvexpf + vDSP_sve`.
  Scalar loops over 51865-wide rows are ~60× slower.
- **Don't write AUC numbers in PR descriptions.** The repo's stated
  metric policy bans them. Use recall, FP-rate, FA/h instead.
- **Don't try whisper-base instead of tiny.** Tiny was chosen after
  full regression-testing — 2× faster, no measurable recall regression
  on the dictation suite at threshold −8.0.

---

## Open decisions (defer until Phase 0 evidence)

1. **Whether to keep the old `WakeWordEngine` in the tree post-Phase 5.**
   Argues for keeping: clean A/B for a few weeks, low cost to leave.
   Argues for deleting: dead code rots. Decide after 2 weeks of
   real-device data on the toggle-on path.
2. **Whether to widen the rolling window from 2 s to ~3 s.** The
   forced-decode primitive is happy with longer windows (just more
   sliding positions); 3 s gives more onset context. Decide if recall
   regresses on quiet-speech "orbit" cases.
3. **Whether to introduce a separate `orbital` / `orbits` threshold.**
   Phase 4 may show that "orbits" tokenizes oddly. If so, split.
4. **Whether to expose a "calibrate wake" setting.** Onit-beacon's
   product surface includes calibration UX; Cue doesn't yet. Probably
   YAGNI until users complain.

---

## Total estimated time

| Phase | Effort |
|---|---|
| 0. Asset load on iOS | 1 hour (incl. user-driven device test) |
| 1. Tokenizer + service port | 2 hours |
| 2. Feature-flag wiring | 30 min |
| 3. Device latency measure | 30 min |
| 4. Calibration | 1–2 hours (manual, mostly waiting) |
| 5. Ship toggle | ≤ 30 min |
| **Total active engineering** | **~6 hours over 1–2 sessions** |
