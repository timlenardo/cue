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
    private var startCount: Int = 0   // simple ref count so multiple callers can request capture

    private init() {
        permission = currentPermission()
        installInterruptionObserver()
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

        // Rebuild the engine each start so it reflects the current
        // AVAudioSession state. See comment on the `engine` property.
        engine = AVAudioEngine()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Sample rate of 0 means no hardware available (eg simulator without mic permission).
        guard format.sampleRate > 0 else {
            print("[MicCapture] input bus has no usable format; not starting")
            startCount = 0
            return
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
            print("[MicCapture] started — \(Int(format.sampleRate))Hz, \(format.channelCount)ch, \(format.commonFormat)")
        } catch {
            print("[MicCapture] engine.start() failed: \(error)")
            input.removeTap(onBus: 0)
            currentFormat = nil
            startCount = 0
        }
    }

    /// Stop the input tap. Idempotent; honours the start ref-count.
    func stop(force: Bool = false) {
        if force { startCount = 0 } else { startCount = max(0, startCount - 1) }
        guard startCount == 0 else { return }
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        currentFormat = nil
        print("[MicCapture] stopped")
    }

    // MARK: - Interruptions

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
