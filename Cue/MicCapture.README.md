# MicCapture — integration notes for the wake-word listener

## What this gives you

A singleton, `MicCapture.shared`, that hands you raw `AVAudioPCMBuffer`
chunks from the device microphone as long as a podcast is playing. It runs
in the foreground, the background, and while the device is locked. iOS
shows the orange mic indicator continuously while it's active.

The lifecycle is wired into `AppState`:
- Episode loads and starts playing → `MicCapture.start()`
- Episode pauses → `MicCapture.stop()`
- Episode ends or user closes the player → `MicCapture.stop(force: true)`

So you do not need to manage start/stop — just register your handler.

## API surface

```swift
@MainActor
final class MicCapture {
    static let shared: MicCapture

    enum Permission: Equatable { case undetermined, granted, denied }

    @Published private(set) var permission: Permission
    @Published private(set) var isCapturing: Bool
    @Published private(set) var currentFormat: AVAudioFormat?

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    func currentPermission() -> Permission
    @discardableResult func requestPermission() async -> Permission

    @discardableResult func addBufferHandler(_ handler: @escaping BufferHandler) -> UUID
    func removeBufferHandler(_ id: UUID)

    func start()
    func stop(force: Bool = false)
}

extension MicCapture {
    func bufferStream() -> AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>
}
```

## Minimal integration

```swift
// Somewhere in your wake-word controller's init:
let token = MicCapture.shared.addBufferHandler { buffer, when in
    // CALLED ON AUDIO THREAD. Do not touch UIKit/SwiftUI directly here.
    // buffer.floatChannelData[0] points at sample data.
    wakeWord.process(buffer)
}

// When you tear down:
MicCapture.shared.removeBufferHandler(token)
```

Or the async version:

```swift
Task {
    for await (buffer, when) in MicCapture.shared.bufferStream() {
        wakeWord.process(buffer)
    }
}
// Cancelling the Task automatically unregisters the handler.
```

## Buffer format

Whatever `AVAudioEngine.inputNode.outputFormat(forBus: 0)` returns. On
real hardware this is typically:

- sampleRate: **48000 Hz**
- channelCount: **1**
- commonFormat: **`.pcmFormatFloat32`**, non-interleaved
- Buffer size hint: **4096 frames**, but iOS may deliver smaller

Inspect `MicCapture.shared.currentFormat` after `start()` succeeds if you
want to verify at runtime. The format is fixed for the duration of one
capture session; if iOS changes the input (e.g. AirPods plugged in mid-
session), `stop()` and `start()` again will pick up the new format.

Most wake-word engines (Porcupine, Snowboy, custom CoreML) want
**16 kHz Int16 PCM mono**. You'll need an `AVAudioConverter` for that;
keep it long-lived in your wake-word controller. Sample:

```swift
let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
let converter = AVAudioConverter(from: source, to: target)!  // `source` = MicCapture.shared.currentFormat
```

## Audio session

`AudioPlayer.configureAudioSession` sets the session to
`.playAndRecord` with mode `.spokenAudio` and these options:

- `.defaultToSpeaker` — loudspeaker output when no headphones
- `.allowBluetoothHFP` — accept BT mic via the HFP profile
- `.allowBluetoothA2DP` — high-quality stereo output when no mic needed
- `.allowAirPlay` — route output through AirPlay if selected

You don't need to touch the audio session yourself.

**Trade-off to know**: when the mic is active on AirPods/BT headphones, iOS
forces the entire route to HFP (mono, telephone-quality). Output volume
and quality drop visibly during this. There's no way around it short of
turning the mic off; that's the cost of always-on listening on iOS.

## Permissions

`Info.plist` already has `NSMicrophoneUsageDescription`. The first time
`MicCapture.start()` would actually start the engine, `AppState` calls
`requestPermission()` for you. You can also call it eagerly:

```swift
let result = await MicCapture.shared.requestPermission()
guard result == .granted else { /* surface UX */ }
```

## Background

The app already declares `audio` background mode. Combined with an active
audio session, the engine keeps capturing while:

- the app is in the background
- the device is on the lock screen
- the screen is off

The orange mic indicator is shown by iOS in the status bar / Dynamic
Island for the entire time. There's no way to suppress it.

## Interruptions

`AVAudioSession.interruptionNotification` is observed inside MicCapture.
On `.began` (phone call, alarm, Siri activation), the engine is paused;
on `.ended` with `shouldResume`, it tries to restart. Your handler will
just see a gap in buffers during the interruption.

## Multiple consumers

Handlers fan out — every registered handler receives every buffer. The
start/stop is ref-counted: each `start()` increments the count, each
`stop()` decrements; the engine only actually stops when the count
hits zero. `stop(force: true)` resets the count to zero and stops
immediately (used by `endPlayback`).

## Things this does NOT do

- No wake-word detection (your job)
- No STT, no LLM, no TTS
- No persistence of audio anywhere — buffers live in memory only
- No format conversion — you resample if you need 16 kHz Int16
- No latency tuning — buffer size is the default ~85 ms at 48 kHz
