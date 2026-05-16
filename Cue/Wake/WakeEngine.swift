#if os(iOS)
import Foundation

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

    /// Fires per inference round, regardless of trigger match. Used by the
    /// dev "wake word tracking" toggle to surface what the engine is hearing
    /// (or scoring) in real time. `isHit` is true iff this round would have
    /// fired `onDetect`. `levels` carries peak amplitudes for the audio
    /// window that drove the inference, surfaced behind the dev
    /// "audio levels" toggle.
    var onTranscript: (@MainActor (_ text: String, _ isHit: Bool, _ levels: AudioLevelStats?) -> Void)? { get set }

    @MainActor func start()
    @MainActor func stop()
}
#endif
