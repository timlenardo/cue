# vendor/

Prebuilt sherpa-onnx iOS binaries. These are large (~360 MB) and not
checked into git — see `.gitignore`. To recreate on a fresh checkout:

```bash
bash /Users/douglasqian/cue/vendor/bootstrap.sh
```

Pinned to **sherpa-onnx v1.13.1** (ios-no-tts variant; we don't need
the TTS components for wake-word detection).

Contents after bootstrap:

- `sherpa-onnx.xcframework` — main library, iOS device + simulator
- `onnxruntime.xcframework` — ONNX Runtime 1.17.1 dependency

The Swift wrapper (`SherpaOnnx.swift`) and bridging header
(`SherpaOnnx-Bridging-Header.h`) live in `Cue/Wake/` and ARE checked in.
