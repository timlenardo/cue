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
    private let kFramesPerChunk: Int = 480               // 10 ms at 48 kHz

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
    private var outputFormat: AVAudioFormat?

    // MARK: - Input pipeline state

    private var micHandlerToken: UUID?
    private var inputConverter: AVAudioConverter?
    private var inputTargetFormat: AVAudioFormat?
    private var inputRing: [Int16] = []

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
        return true
    }

    func terminateDevice() -> Bool {
        log.info("terminate")
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
            self.inputRing.removeAll(keepingCapacity: true)
            self.inputConverter = nil
            self.inputTargetFormat = nil
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
        outputFormat = format
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
        outputFormat = nil
        _isPlaying = false
        return true
    }

    // MARK: - Notifications + dispatch

    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}

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
        }
        guard let converter = inputConverter else { return }

        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * kSampleRate / buffer.format.sampleRate)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let int16Data = outBuffer.int16ChannelData else { return }

        let count = Int(outBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: int16Data[0], count: count))

        admQueue.async { [weak self] in
            guard let self else { return }
            guard self._isRecording else { return }
            self.inputRing.append(contentsOf: samples)
            while self.inputRing.count >= self.kFramesPerChunk {
                let chunk = Array(self.inputRing.prefix(self.kFramesPerChunk))
                self.inputRing.removeFirst(self.kFramesPerChunk)
                self.deliverChunk(chunk)
            }
        }
    }

    private func deliverChunk(_ samples: [Int16]) {
        guard let deliver = deliverRecordedData else { return }

        var mutableSamples = samples
        mutableSamples.withUnsafeMutableBufferPointer { ptr in
            var audioBuffer = AudioBuffer(
                mNumberChannels: UInt32(kChannels),
                mDataByteSize: UInt32(ptr.count * MemoryLayout<Int16>.size),
                mData: UnsafeMutableRawPointer(ptr.baseAddress)
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            var actionFlags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            timestamp.mFlags = .sampleTimeValid
            timestamp.mSampleTime = 0
            _ = deliver(&actionFlags, &timestamp, 0, UInt32(ptr.count), &bufferList, nil, nil)
        }
    }

    // MARK: - Output: WebRTC → AVAudioEngine source node

    /// Render callback on the audio render thread. Pull Int16 samples from
    /// WebRTC via `getPlayoutData`, convert to Float32, write into the
    /// engine's output buffer.
    nonisolated private func renderPlayout(
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafePointer<AudioBufferList>
    ) -> OSStatus {
        guard let getPlayout = getPlayoutData else {
            zeroFill(audioBufferList: audioBufferList)
            return noErr
        }

        let int16Count = Int(frameCount) * kChannels
        let int16Bytes = int16Count * MemoryLayout<Int16>.size

        // Reuse a persistent scratch buffer. Allocating + deallocating
        // every render tick on the audio thread is both wasteful and
        // non-realtime-safe — the allocator can block under pressure.
        let scratch = ensureRenderScratch(bytes: int16Bytes)
        memset(scratch, 0, int16Bytes)

        var audioBuffer = AudioBuffer(
            mNumberChannels: UInt32(kChannels),
            mDataByteSize: UInt32(int16Bytes),
            mData: scratch
        )
        var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        var actionFlags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid

        _ = getPlayout(&actionFlags, &timestamp, 0, frameCount, &inputList)

        let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        guard let outBuffer = ablPtr.first,
              let outData = outBuffer.mData?.assumingMemoryBound(to: Float32.self) else {
            return noErr
        }
        let int16Ptr = scratch.assumingMemoryBound(to: Int16.self)
        let scale: Float32 = 1.0 / 32768.0
        for i in 0..<Int(frameCount) {
            outData[i] = Float32(int16Ptr[i]) * scale
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
