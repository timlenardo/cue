import Foundation
import AVFAudio
import AudioToolbox
import WebRTC
import os

private let log = Logger(subsystem: "com.toug.cue", category: "AudioDevice")

/// Custom WebRTC audio device that runs on top of Doug's MicCapture +
/// VPIO setup. POC — exercises the routing end-to-end so we can confirm
/// AI TTS plays back through MicCapture's engine (and through VPIO when
/// it's active, getting proper AEC).
///
/// **Input path**: subscribes to `MicCapture.addBufferHandler` for the
/// already-AEC'd mic samples. Converts Float32 → Int16, chunks into
/// 10 ms (480-sample) frames, calls WebRTC's `deliverRecordedData` block.
/// MicCapture's lifecycle is driven by `AppState.updateWakeArmed`; we
/// just gate forwarding on whether WebRTC has called `startRecording`.
///
/// **Output path**: registers an `AVAudioSourceNode` with MicCapture so
/// it's attached to `engine.mainMixerNode` on the current engine and
/// re-attached on every engine rebuild. The render callback pulls
/// samples from WebRTC's `getPlayoutData` block and writes Float32 into
/// the engine's output buffer. The signal then flows through the
/// VPIO unit (when active) to the speaker — and VPIO's AEC sees this
/// audio as part of its reference, so the mic input doesn't pick it up.
@objc final class CueAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {

    // MARK: - Format

    private let kSampleRate: Double = 48_000
    private let kChannels: Int = 1
    private let kIOBufferDuration: TimeInterval = 0.01   // 10 ms
    /// Derived from sample rate × buffer duration so the two constants
    /// can't drift independently (changing sample rate without updating
    /// the frame count would silently break the 10 ms chunking).
    private var kFramesPerChunk: Int { Int(kSampleRate * kIOBufferDuration) }

    var deviceInputSampleRate: Double { kSampleRate }
    var inputIOBufferDuration: TimeInterval { kIOBufferDuration }
    var inputNumberOfChannels: Int { kChannels }
    var inputLatency: TimeInterval { 0.01 }

    var deviceOutputSampleRate: Double { kSampleRate }
    var outputIOBufferDuration: TimeInterval { kIOBufferDuration }
    var outputNumberOfChannels: Int { kChannels }
    var outputLatency: TimeInterval { 0.01 }

    // MARK: - WebRTC-visible state

    private var _isInitialized: Bool = false
    private var _isPlayoutInitialized: Bool = false
    private var _isRecordingInitialized: Bool = false
    private var _isPlaying: Bool = false
    private var _isRecording: Bool = false

    var isInitialized: Bool { _isInitialized }
    var isPlayoutInitialized: Bool { _isPlayoutInitialized }
    var isRecordingInitialized: Bool { _isRecordingInitialized }
    var isPlaying: Bool { _isPlaying }
    var isRecording: Bool { _isRecording }

    // MARK: - ADM thread

    private let admQueue = DispatchQueue(label: "com.cue.adm", qos: .userInteractive)
    private let admQueueKey = DispatchSpecificKey<Bool>()

    private var isOnAdmQueue: Bool {
        DispatchQueue.getSpecific(key: admQueueKey) ?? false
    }

    // MARK: - Delegate / cached blocks

    private weak var delegate: RTCAudioDeviceDelegate?
    private var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock?
    private var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock?

    // MARK: - Engine wiring

    /// Source node attached to MicCapture's engine for AI TTS playback.
    /// Lifecycle: created in `startPlayout`, registered with MicCapture,
    /// unregistered + nilled in `stopPlayout`.
    private var outputSourceNode: AVAudioSourceNode?

    /// AVAudioSourceNode asks for arbitrary `frameCount` per render tick
    /// (often 1024 on built-in speaker, varies on Bluetooth/AirPlay).
    /// WebRTC's `getPlayoutData` is contracted to return 10 ms chunks
    /// (480 frames at 48 kHz). We bridge the two with a small Int16
    /// backlog: each render tick pulls 480-frame chunks from WebRTC into
    /// the backlog until there's enough to satisfy the engine's request,
    /// then drains the requested count. Touched only from the render
    /// thread, so no synchronization needed.
    private var playoutBacklog: [Int16] = []
    /// Monotonic frame counter passed to WebRTC's `getPlayoutData` so its
    /// NetEQ can compute play-out timing. Touched only on render thread.
    private var outputSampleClock: Int64 = 0

    // MARK: - Input pipeline state

    private var micHandlerToken: UUID?
    private var inputConverter: AVAudioConverter?
    private var inputTargetFormat: AVAudioFormat?
    /// Mic FIFO drained in 10 ms chunks for WebRTC. Touched only on
    /// `admQueue`. Capacity tracks the worst-case backlog when WebRTC's
    /// downstream queue stalls — ~340 ms at 48 kHz, generous since the
    /// realistic peak is ~30 ms.
    private var inputRing = RingBuffer<Int16>(capacity: 16_384, fill: 0)
    /// Pre-allocated scratch for draining one 480-frame chunk out of
    /// `inputRing` into WebRTC's deliver callback. Sized once; reused
    /// per chunk so the admQueue path stays allocation-free.
    private var inputDeliverScratch: [Int16] = []
    /// Monotonic sample-frame counter passed to WebRTC's `deliverRecordedData`
    /// as `AudioTimeStamp.mSampleTime`. Increments by exactly
    /// `kFramesPerChunk` per delivered chunk. WebRTC's APM (AEC delay
    /// estimator, NetEQ jitter buffer) is driven off this — passing 0
    /// every call makes them think every chunk is concurrent and breaks
    /// delay alignment. Touched only on `admQueue`.
    private var inputSampleClock: Int64 = 0
    /// Pooled output buffer for AVAudioConverter — sized once on first
    /// use and reused for every mic buffer to keep the audio render thread
    /// allocation-free. The converter overwrites `frameLength` on each call.
    private var inputConvertBuffer: AVAudioPCMBuffer?

    // MARK: - Init

    /// Pre-allocated scratch buffer for renderPlayout — sized once on
    /// first use and reused thereafter. Avoids per-render allocations
    /// on the audio render thread.
    private var renderScratch: UnsafeMutableRawPointer?
    private var renderScratchBytes: Int = 0
    private let renderScratchLock = NSLock()

    override init() {
        super.init()
        admQueue.setSpecific(key: admQueueKey, value: true)
    }

    deinit {
        // Belt-and-suspenders cleanup: WebRTC's ADM lifecycle SHOULD call
        // stopPlayout on teardown, which unregisters the source node. But
        // if the framework drops that call (or this object is deallocated
        // before stopPlayout fires), the node accumulates in MicCapture's
        // dictionary across voice sessions — visible as growing memory
        // and growing engine input-bus count.
        if let source = outputSourceNode {
            // Hop to main since MicCapture is @MainActor. The dict lookup
            // is by ObjectIdentifier so it's safe to call from any thread
            // as long as we hop first.
            let nodeRef = source
            Task { @MainActor in
                MicCapture.shared.unregisterOutputSource(nodeRef)
            }
        }
        if let scratch = renderScratch {
            scratch.deallocate()
        }
    }

    // MARK: - RTCAudioDevice — lifecycle

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        log.info("initialize")
        self.delegate = delegate
        self.deliverRecordedData = delegate.deliverRecordedData
        self.getPlayoutData = delegate.getPlayoutData
        _isInitialized = true
        // Subscribe to MicCapture engine rebuilds (route change, interruption
        // recovery). WebRTC's ADM expects its consumer thread to be stable
        // until notifyAudioInputInterrupted fires — every engine rebuild
        // creates a fresh audio render thread, so we notify the framework.
        Task { @MainActor in
            MicCapture.shared.onEngineRebuild = { [weak self] in
                self?.handleEngineRebuild()
            }
        }
        return true
    }

    func terminateDevice() -> Bool {
        log.info("terminate")
        // Belt-and-suspenders cleanup: if WebRTC drops `stopPlayout` and
        // jumps straight to `terminateDevice`, the source node would stay
        // registered in MicCapture's dict until our deinit fires later.
        // Symmetric cleanup here keeps the dict tidy regardless of order.
        if let source = outputSourceNode {
            let nodeRef = source
            Task { @MainActor in
                MicCapture.shared.unregisterOutputSource(nodeRef)
                MicCapture.shared.onEngineRebuild = nil
            }
            outputSourceNode = nil
        } else {
            Task { @MainActor in
                MicCapture.shared.onEngineRebuild = nil
            }
        }
        delegate = nil
        deliverRecordedData = nil
        getPlayoutData = nil
        _isInitialized = false
        _isPlayoutInitialized = false
        _isRecordingInitialized = false
        _isPlaying = false
        _isRecording = false
        return true
    }

    // MARK: - RTCAudioDevice — recording (mic → WebRTC)

    func initializeRecording() -> Bool {
        log.info("initializeRecording")
        _isRecordingInitialized = true
        return true
    }

    func startRecording() -> Bool {
        log.info("startRecording (thread=\(Thread.current.description, privacy: .public))")
        let token = MicCapture.shared.addBufferHandler { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }
        admQueue.async { [weak self] in
            self?.micHandlerToken = token
            self?.inputSampleClock = 0
        }
        _isRecording = true
        return true
    }

    func stopRecording() -> Bool {
        log.warning("stopRecording (thread=\(Thread.current.description, privacy: .public)) — WebRTC asked us to stop feeding mic samples")
        admQueue.sync {
            if let token = self.micHandlerToken {
                MicCapture.shared.removeBufferHandler(token)
                self.micHandlerToken = nil
            }
            self.inputRing.removeAll()
            self.inputConverter = nil
            self.inputTargetFormat = nil
            self.inputConvertBuffer = nil
            self.inputSampleClock = 0
        }
        _isRecording = false
        return true
    }

    // MARK: - RTCAudioDevice — playout (WebRTC → speaker)

    func initializePlayout() -> Bool {
        log.info("initializePlayout")
        _isPlayoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        log.info("startPlayout (thread=\(Thread.current.description, privacy: .public))")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: kSampleRate,
            channels: AVAudioChannelCount(kChannels),
            interleaved: false
        ) else {
            log.error("startPlayout: failed to build playback format")
            return false
        }
        // Reset playout state before the source node is registered. After
        // attach, the render callback may fire before we'd otherwise get a
        // chance to clear stale backlog from a prior session.
        playoutBacklog.removeAll(keepingCapacity: true)
        outputSampleClock = 0
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            return self?.renderPlayout(frameCount: frameCount, audioBufferList: audioBufferList) ?? noErr
        }
        outputSourceNode = source
        // Hand to MicCapture — it handles attach + re-attach on engine
        // rebuilds (route change, interruption recovery).
        Task { @MainActor in
            MicCapture.shared.registerOutputSource(source, format: format)
        }
        _isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        log.warning("stopPlayout (thread=\(Thread.current.description, privacy: .public)) — WebRTC stopped pulling AI audio")
        if let source = outputSourceNode {
            Task { @MainActor in
                MicCapture.shared.unregisterOutputSource(source)
            }
        }
        outputSourceNode = nil
        _isPlaying = false
        return true
    }

    // MARK: - Notifications + dispatch

    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}

    /// Called on the main actor by MicCapture every time `bringUpEngine`
    /// succeeds. Forwards a thread-shift notification to WebRTC's ADM
    /// delegate per its "same-thread until notifyAudioInterrupted" rule.
    /// The notify calls themselves must run inside a dispatchAsync block,
    /// per the RTCAudioDeviceDelegate contract.
    @MainActor
    private func handleEngineRebuild() {
        log.info("handleEngineRebuild — notifying WebRTC ADM that audio thread may have shifted")
        dispatchAsync { [weak self] in
            guard let self else { return }
            self.delegate?.notifyAudioInputInterrupted()
            self.delegate?.notifyAudioOutputInterrupted()
        }
    }

    func dispatchAsync(_ block: @escaping () -> Void) {
        admQueue.async(execute: block)
    }

    func dispatchSync(_ block: @escaping () -> Void) {
        if isOnAdmQueue {
            block()
        } else {
            admQueue.sync(execute: block)
        }
    }

    // MARK: - Input: AVAudioEngine tap → WebRTC

    /// Called on the audio render thread from MicCapture's input tap.
    nonisolated private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard _isRecording, deliverRecordedData != nil else { return }

        if inputTargetFormat == nil {
            inputTargetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: kSampleRate,
                channels: AVAudioChannelCount(kChannels),
                interleaved: true
            )
        }
        guard let targetFormat = inputTargetFormat else { return }

        if inputConverter == nil || inputConverter?.inputFormat != buffer.format {
            inputConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            inputConvertBuffer = nil   // re-pool with the new target format
        }
        guard let converter = inputConverter else { return }

        // Pool the conversion buffer to avoid allocating on the render thread.
        // Size for the worst-case upsample (e.g. 8 kHz Bluetooth HFP input → 48 kHz
        // target = 6x), plus a safety margin. MicCapture's tap is 4096 frames.
        let upsampleRatio = max(1.0, kSampleRate / max(buffer.format.sampleRate, 1.0))
        let requiredCapacity = AVAudioFrameCount(Double(buffer.frameLength) * upsampleRatio) + 256
        if inputConvertBuffer == nil || (inputConvertBuffer?.frameCapacity ?? 0) < requiredCapacity {
            inputConvertBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: requiredCapacity)
        }
        guard let outBuffer = inputConvertBuffer else { return }

        var error: NSError?
        // The converter input block may be called more than once if the
        // converter wants more packets than we have. Return the buffer once,
        // then signal `.noDataNow` — otherwise the same buffer gets consumed
        // repeatedly and WebRTC receives duplicated mic audio. Same pattern
        // as WakeWordEngine.resample.
        var fed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let int16Data = outBuffer.int16ChannelData else { return }

        let count = Int(outBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: int16Data[0], count: count))

        admQueue.async { [weak self] in
            guard let self else { return }
            guard self._isRecording else { return }
            samples.withUnsafeBufferPointer { self.inputRing.pushBack($0) }
            if self.inputDeliverScratch.count < self.kFramesPerChunk {
                self.inputDeliverScratch = [Int16](repeating: 0, count: self.kFramesPerChunk)
            }
            self.inputDeliverScratch.withUnsafeMutableBufferPointer { scratchPtr in
                while self.inputRing.count >= self.kFramesPerChunk {
                    _ = self.inputRing.popFront(
                        into: scratchPtr.baseAddress!,
                        count: self.kFramesPerChunk
                    )
                    self.deliverChunk(buffer: scratchPtr.baseAddress!, count: self.kFramesPerChunk)
                }
            }
        }
    }

    /// Called on `admQueue` only — `inputSampleClock` mutation is safe.
    /// Takes a raw pointer + count so the caller can drain straight from
    /// the ring buffer scratch without re-wrapping into an Array.
    private func deliverChunk(buffer: UnsafePointer<Int16>, count: Int) {
        guard let deliver = deliverRecordedData else { return }
        let clock = inputSampleClock
        var audioBuffer = AudioBuffer(
            mNumberChannels: UInt32(kChannels),
            mDataByteSize: UInt32(count * MemoryLayout<Int16>.size),
            mData: UnsafeMutableRawPointer(mutating: buffer)
        )
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        var actionFlags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        timestamp.mSampleTime = Float64(clock)
        _ = deliver(&actionFlags, &timestamp, 0, UInt32(count), &bufferList, nil, nil)
        inputSampleClock += Int64(count)
    }

    // MARK: - Output: WebRTC → AVAudioEngine source node

    /// Render callback on the audio render thread.
    ///
    /// The engine asks for `frameCount` samples per call (often 1024 on
    /// the built-in speaker, varies elsewhere). WebRTC's `getPlayoutData`
    /// only returns 10 ms (`kFramesPerChunk` = 480) at a time. We pull
    /// 480-frame chunks into `playoutBacklog` until we have enough to
    /// satisfy the engine, then drain `frameCount` into the output buffer.
    nonisolated private func renderPlayout(
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafePointer<AudioBufferList>
    ) -> OSStatus {
        guard let getPlayout = getPlayoutData else {
            zeroFill(audioBufferList: audioBufferList)
            return noErr
        }

        let needed = Int(frameCount) * kChannels
        let chunkSamples = kFramesPerChunk * kChannels
        let chunkBytes = chunkSamples * MemoryLayout<Int16>.size

        // Pull from WebRTC in 480-frame chunks until backlog can satisfy
        // the engine's request. Cap iterations to defend against pathological
        // cases (e.g. WebRTC starvation with frameCount many multiples of 480).
        let maxIterations = (needed / chunkSamples) + 2
        var iterations = 0
        while playoutBacklog.count < needed && iterations < maxIterations {
            iterations += 1
            let scratch = ensureRenderScratch(bytes: chunkBytes)
            memset(scratch, 0, chunkBytes)

            var audioBuffer = AudioBuffer(
                mNumberChannels: UInt32(kChannels),
                mDataByteSize: UInt32(chunkBytes),
                mData: scratch
            )
            var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            var actionFlags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            timestamp.mFlags = .sampleTimeValid
            timestamp.mSampleTime = Float64(outputSampleClock)

            _ = getPlayout(&actionFlags, &timestamp, 0, AVAudioFrameCount(kFramesPerChunk), &inputList)
            outputSampleClock += Int64(kFramesPerChunk)

            // Append chunk to backlog (zero-padded if WebRTC short-read).
            let int16Ptr = scratch.assumingMemoryBound(to: Int16.self)
            playoutBacklog.reserveCapacity(playoutBacklog.count + chunkSamples)
            for i in 0..<chunkSamples {
                playoutBacklog.append(int16Ptr[i])
            }
        }

        // Drain `needed` samples into the engine's output buffer.
        let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        guard let outBuffer = ablPtr.first,
              let outData = outBuffer.mData?.assumingMemoryBound(to: Float32.self) else {
            return noErr
        }
        let scale: Float32 = 1.0 / 32768.0
        let available = min(playoutBacklog.count, needed)
        for i in 0..<available {
            outData[i] = Float32(playoutBacklog[i]) * scale
        }
        // Zero-pad if backlog couldn't satisfy the request (WebRTC starved).
        for i in available..<needed {
            outData[i] = 0
        }
        if available > 0 {
            playoutBacklog.removeFirst(available)
        }
        return noErr
    }

    nonisolated private func zeroFill(audioBufferList: UnsafePointer<AudioBufferList>) {
        let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        for buffer in ablPtr {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    /// Lazy-grow scratch buffer. Allocation only happens on first call or
    /// when the requested size exceeds the current allocation — typically
    /// once per session.
    nonisolated private func ensureRenderScratch(bytes: Int) -> UnsafeMutableRawPointer {
        renderScratchLock.lock()
        defer { renderScratchLock.unlock() }
        if let scratch = renderScratch, renderScratchBytes >= bytes {
            return scratch
        }
        if let old = renderScratch {
            old.deallocate()
        }
        let alignment = MemoryLayout<Int16>.alignment
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: alignment)
        renderScratch = scratch
        renderScratchBytes = bytes
        return scratch
    }
}
