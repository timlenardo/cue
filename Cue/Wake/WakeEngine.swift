#if os(iOS)
import Foundation

enum WakeReadiness: Equatable, Sendable {
    case inactive
    case warmingUp
    case ready
    case unavailable(String)
}

/// Common surface for any wake-word engine. Lets `AppState` swap engines at
/// runtime (via the dev `forceDecodeWakeEnabled` toggle) without changing
/// any of the wiring sites — both `WakeWordEngine` (WhisperKit free-decode +
/// regex) and `WhisperKwsEngine` (CoreML whisper-tiny forced-decode) conform.
///
/// The protocol intentionally does NOT pin the conforming type to @MainActor.
/// Callbacks are typed as @MainActor closures so the engine can invoke them
/// from any background context without an extra hop; assigning to those
/// properties is unisolated (matches `WakeWordEngine`'s existing pattern of
/// being `@unchecked Sendable` with no actor isolation).
protocol WakeEngine: AnyObject {
    /// Fires when the wake phrase is recognised. Already on @MainActor.
    /// Debounced by the engine.
    var onDetect: (@MainActor () -> Void)? { get set }

    /// Current user-facing readiness state for always-on wake detection.
    /// `ready` means saying the wake phrase can fire `onDetect`; `warmingUp`
    /// covers model/tokenizer load and Core ML first-prediction warm-up.
    var readiness: WakeReadiness { get }

    /// Fires when `readiness` changes. Used by AppState to drive the player
    /// wake pill without coupling UI code to either concrete wake engine.
    var onReadinessChange: (@MainActor (_ readiness: WakeReadiness) -> Void)? { get set }

    /// Fires per inference round, regardless of trigger match. Used by the
    /// dev "wake word tracking" toggle to surface what the engine is hearing
    /// (or scoring) in real time. `isHit` is true iff this round passes the
    /// engine's detection + debounce gates and would fire `onDetect`.
    /// Debounced repeats can still surface as non-hit debug rows so the
    /// audio-level HUD keeps updating without implying another wake open.
    /// `levels` carries peak amplitudes for the audio window that drove the
    /// inference, surfaced behind the dev "audio levels" toggle.
    var onTranscript: (@MainActor (_ text: String, _ isHit: Bool, _ levels: AudioLevelStats?) -> Void)? { get set }

    @MainActor func start()
    @MainActor func stop()
}
#endif
