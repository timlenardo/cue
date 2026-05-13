#if os(iOS)
import Foundation
import AVFoundation
import AVFAudio
import Combine

/// Always-on microphone capture for the wake-word listener.
///
/// **Design**
/// - Singleton because there's exactly one input bus on the device and
///   multiple consumers may want to read from it.
/// - Multiple handlers can register; each receives every buffer.
/// - Handlers are invoked on the AVAudioEngine input thread — *not* the
///   main thread. Do NOT touch UIKit/SwiftUI state directly from a handler;
///   hop to the main actor first.
///
/// **Buffer format**
/// The buffers delivered are in the format AVAudioEngine assigns to the
/// input node's `outputFormat(forBus: 0)`. On real hardware this is
/// typically:
///   - sampleRate: 48000 Hz
///   - channelCount: 1
///   - commonFormat: .pcmFormatFloat32 (non-interleaved)
/// On the iOS Simulator it mirrors the host Mac's selected input device.
/// Inspect `currentFormat` (set after `start()` succeeds) to confirm at
/// runtime.
///
/// Most wake-word engines want 16 kHz Int16 PCM mono. The consumer is
/// expected to resample if needed (e.g. via `AVAudioConverter` or by
/// installing a tap with their target format).
///
/// **Lifecycle**
/// - Call `requestPermission()` once. Returns `.granted` or `.denied`.
/// - Call `start()` to begin recording. Idempotent.
/// - Call `stop()` to release the input. Idempotent.
/// - Audio session is owned by `AudioPlayer.configureAudioSession`. This
///   class assumes the session is already in `.playAndRecord`.
///
/// **Interruptions** (phone call, alarm, Siri):
/// - AVAudioSession posts `AVAudioSession.interruptionNotification`.
/// - We auto-pause the engine on `.began`, attempt to resume on `.ended`.
/// - Handlers see no buffers during interruption.
@MainActor
final class MicCapture {
    static let shared = MicCapture()

    enum Permission: Equatable { case undetermined, granted, denied }

    @Published private(set) var permission: Permission = .undetermined
    @Published private(set) var isCapturing: Bool = false
    /// Set after `start()` succeeds. Inspect to learn the buffer format
    /// being delivered to handlers.
    @Published private(set) var currentFormat: AVAudioFormat?

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    // Recreated on every start() — AVAudioEngine caches the input bus
    // format at construction time, so an engine instance that lived
    // through an AVAudioSession category change (e.g. WebRTC's .videoChat
    // for the realtime voice session) will throw "Input HW format and
    // tap format not matching" when its tap is reinstalled. A fresh
    // engine reads the current hardware format cleanly.
    private var engine = AVAudioEngine()
    private let handlerStore = BufferHandlerStore()
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var startCount: Int = 0   // simple ref count so multiple callers can request capture
    /// Reflects whether hardware voice processing (AEC/NS/AGC) is active
    /// on the input node. We only turn it on when audio is routed to the
    /// built-in speaker (the only route with an acoustic echo path).
    private var voiceProcessingActive: Bool = false

    /// Output sources (e.g. WebRTC's playback path) waiting to be attached
    /// to `engine.mainMixerNode`. Survives engine rebuilds — every time
    /// the engine is recreated, we re-attach each entry. Kept as a dict
    /// keyed by ObjectIdentifier so callers can detach by node reference.
    private var registeredOutputSources: [ObjectIdentifier: (node: AVAudioSourceNode, format: AVAudioFormat)] = [:]

    private init() {
        permission = currentPermission()
        installInterruptionObserver()
        installRouteChangeObserver()
    }

    // MARK: - Permission

    /// Returns the current state without prompting.
    func currentPermission() -> Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:   return .granted
        case .denied:    return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Prompt for permission if needed. Safe to call repeatedly.
    @discardableResult
    func requestPermission() async -> Permission {
        let granted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        self.permission = granted ? .granted : .denied
        return self.permission
    }

    // MARK: - Handlers

    /// Register a handler. Returns a token used to unregister. Safe to call
    /// from any thread.
    @discardableResult
    nonisolated func addBufferHandler(_ handler: @escaping BufferHandler) -> UUID {
        handlerStore.add(handler)
    }

    /// Unregister a handler by token. Safe to call from any thread.
    nonisolated func removeBufferHandler(_ id: UUID) {
        handlerStore.remove(id)
    }

    // MARK: - Lifecycle

    /// Start the input tap. Idempotent; ref-counted so multiple consumers
    /// can request capture and we only stop when all of them call `stop()`.
    func start() {
        startCount += 1
        guard !isCapturing else { return }
        guard permission == .granted else {
            // Not granted yet — caller should `await requestPermission()` first.
            // We don't throw because the call sites are best-effort during
            // playback; mic just stays off until permission resolves.
            startCount = max(1, startCount)
            return
        }
        bringUpEngine()
        if !isCapturing { startCount = 0 }
    }

    /// Stop the input tap. Idempotent; honours the start ref-count.
    func stop(force: Bool = false) {
        if force { startCount = 0 } else { startCount = max(0, startCount - 1) }
        guard startCount == 0 else { return }
        guard isCapturing else { return }
        tearDownEngine()
        // Restore the session mode AudioPlayer expects for normal podcast
        // playback (`.spokenAudio`) when we're no longer holding it in
        // `.voiceChat` for VPIO.
        try? AVAudioSession.sharedInstance().setMode(.spokenAudio)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        print("[MicCapture] stopped")
    }

    // MARK: - Engine bring-up / tear-down

    /// Build a fresh engine, configure voice processing for the current
    /// route, install the tap, and start the engine. Sets `isCapturing`
    /// on success.
    ///
    /// Production wake-word AEC path: when the output route is the
    /// built-in speaker (the only route with an acoustic echo loop),
    /// switch the session to `.voiceChat` mode and enable VPIO on the
    /// input node. This is the iOS-canonical AEC config. We accept the
    /// known volume-headroom side effect — that's the tradeoff for
    /// having the mic not hear the podcast.
    private func bringUpEngine() {
        print("[MicCapture] bringUpEngine — registeredOutputSources count = \(registeredOutputSources.count)")
        // Detach any previously-registered output sources from the current
        // engine BEFORE we replace it. AVAudioEngine treats a node attached
        // to two engine instances as undefined behavior — typically a crash
        // on the next render tick — and just letting the old engine fall
        // out of scope doesn't reliably detach in time.
        for entry in registeredOutputSources.values {
            engine.disconnectNodeOutput(entry.node)
            engine.detach(entry.node)
        }

        let wantVP = shouldUseVoiceProcessing()

        // Session: switch to `.voiceChat` when we want AEC; force speaker
        // explicitly because `.voiceChat` ignores `.defaultToSpeaker` and
        // would route to the earpiece otherwise.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: wantVP ? .voiceChat : .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
            )
            if wantVP {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            print("[MicCapture] session config failed: \(error)")
        }

        engine = AVAudioEngine()
        let input = engine.inputNode

        if wantVP {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingActive = true
                print("[MicCapture] VPIO + .voiceChat enabled — output route is built-in speaker")
            } catch {
                print("[MicCapture] setVoiceProcessingEnabled failed: \(error)")
                voiceProcessingActive = false
            }
        } else {
            voiceProcessingActive = false
            print("[MicCapture] VPIO skipped — output route is \(routeDescription())")
        }

        // When VPIO is active, format negotiation across the I/O AU is
        // strict — match Apple's WWDC 2019 sample by using one canonical
        // 48 kHz mono Float32 format. Also explicitly wire the output side
        // so the VPIO unit has both halves of its I/O configured.
        let format: AVAudioFormat
        if wantVP, let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) {
            format = canonical
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        } else {
            let queried = input.outputFormat(forBus: 0)
            guard queried.sampleRate > 0 else {
                print("[MicCapture] input bus has no usable format; not starting")
                return
            }
            format = queried
            // Wire mainMixer → output even when VPIO is off so any
            // registered output source (e.g. WebRTC TTS playback) has a
            // path to the speaker. AVAudioEngine doesn't auto-wire this
            // unless mainMixerNode is touched, and even then the timing
            // is fragile.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        }

        // Re-attach any output sources registered before this engine was
        // built (e.g. CueAudioDevice's WebRTC playback node). Each engine
        // rebuild — initial start, route change, interruption recovery —
        // discards prior node attachments, so we re-wire them here.
        for entry in registeredOutputSources.values {
            engine.attach(entry.node)
            engine.connect(entry.node, to: engine.mainMixerNode, format: entry.format)
        }

        currentFormat = format
        let store = handlerStore  // capture the Sendable store, not self
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            // CALLED ON AUDIO RENDER THREAD. Keep work minimal here.
            // We read handlers via a lock-protected store — no actor hop,
            // no allocation in the hot path beyond the snapshot array.
            for handler in store.snapshot() {
                handler(buffer, when)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
            print("[MicCapture] started — \(Int(format.sampleRate))Hz, \(format.channelCount)ch, vp=\(voiceProcessingActive)")
        } catch {
            print("[MicCapture] engine.start() failed: \(error)")
            input.removeTap(onBus: 0)
            currentFormat = nil
        }
    }

    private func tearDownEngine() {
        print("[MicCapture] tearDownEngine — isCapturing=\(isCapturing), registeredOutputSources count=\(registeredOutputSources.count)")
        if isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isCapturing = false
        }
        currentFormat = nil
        voiceProcessingActive = false
    }

    // MARK: - Output sources (WebRTC TTS playback)

    /// Register an output source node to be mixed into `mainMixerNode` and
    /// driven through the engine's output (incl. VPIO when active).
    /// Idempotent: re-registering the same node is a no-op.
    ///
    /// If the engine is currently running, the node is attached + connected
    /// immediately. If not, it's stored and attached on the next engine
    /// rebuild (start/route-change/interruption recovery).
    func registerOutputSource(_ node: AVAudioSourceNode, format: AVAudioFormat) {
        registeredOutputSources[ObjectIdentifier(node)] = (node, format)
        if isCapturing {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
    }

    /// Unregister and disconnect a previously-registered output source.
    func unregisterOutputSource(_ node: AVAudioSourceNode) {
        registeredOutputSources.removeValue(forKey: ObjectIdentifier(node))
        if isCapturing {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
    }

    private func shouldUseVoiceProcessing() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    private func routeDescription() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
    }

    // MARK: - Interruptions

    /// Watch for route changes (headphones plugged/unplugged, Bluetooth
    /// connect, AirPlay handoff). If the desired voice-processing state
    /// no longer matches what's live on the engine, rebuild it.
    private func installRouteChangeObserver() {
        let nc = NotificationCenter.default
        routeChangeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileForRouteChange()
            }
        }
    }

    private func reconcileForRouteChange() {
        guard isCapturing else { return }
        let desired = shouldUseVoiceProcessing()
        guard desired != voiceProcessingActive else { return }
        print("[MicCapture] route changed; rebuilding engine (vp: \(voiceProcessingActive) -> \(desired))")
        tearDownEngine()
        bringUpEngine()
    }

    private func installInterruptionObserver() {
        let nc = NotificationCenter.default
        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract everything we need from the Notification synchronously
            // (it isn't Sendable, so we can't pass it into a Task).
            guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            let shouldResume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }?
                .contains(.shouldResume) ?? false

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    if self.engine.isRunning { self.engine.pause() }
                case .ended:
                    if shouldResume, self.isCapturing {
                        do { try self.engine.start() }
                        catch { print("[MicCapture] resume after interruption failed: \(error)") }
                    }
                @unknown default:
                    break
                }
            }
        }
    }
}

// MARK: - AsyncStream convenience

extension MicCapture {
    /// Convenience for consumers who'd rather `for await buffer in stream`.
    /// Cancelling the consuming task automatically removes the handler.
    nonisolated func bufferStream() -> AsyncStream<(AVAudioPCMBuffer, AVAudioTime)> {
        AsyncStream { continuation in
            let token = self.addBufferHandler { buffer, when in
                continuation.yield((buffer, when))
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeBufferHandler(token)
            }
        }
    }
}

// MARK: - Lock-protected handler store
//
// The audio render thread cannot hop to the main actor (it's a real-time
// thread; `MainActor.assumeIsolated` would crash with EXC_BREAKPOINT). So
// the handler dictionary lives in this @unchecked Sendable class with an
// NSLock protecting the dictionary itself.
//
// `snapshot()` returns a value-typed Array so the tap callback can iterate
// without holding the lock during user code.

private final class BufferHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var handlers: [UUID: MicCapture.BufferHandler] = [:]

    nonisolated func add(_ handler: @escaping MicCapture.BufferHandler) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    nonisolated func remove(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    nonisolated func snapshot() -> [MicCapture.BufferHandler] {
        lock.lock()
        let result = Array(handlers.values)
        lock.unlock()
        return result
    }
}
#endif
