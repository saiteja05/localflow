# LocalFlow

**Hold a key, speak, release — polished text appears wherever your cursor is.**

100% local voice dictation for macOS. No cloud, no account, no subscription:
your voice never leaves your Mac.

## How it works

1. Hold **Fn**, talk naturally ("um so we should uh no wait we should definitely ship friday")
2. Release.
3. Clean text appears at your cursor: *"We should definitely ship Friday."*

- **Fast**: ~0.6–1.4s from release to inserted text on Apple Silicon
- **Speech-to-text**: NVIDIA Parakeet v3 on the Neural Engine (25 languages, auto-detected)
- **AI cleanup**: Apple's on-device foundation model removes fillers, fixes punctuation,
  applies self-corrections — with Ollama as an optional alternative and a rules-only fallback
- **Hands-free mode**: double-tap Fn; tap again to finish
- **Personal dictionary**: your jargon, names, and exact replacements
- **Private by construction**: the only network traffic ever is the one-time model download

## Install

Requirements: Apple Silicon Mac, macOS 26 (Tahoe) or later.

1. Download `LocalFlow.zip` from [Releases], unzip, drag to Applications.
2. Unsigned build for now: `xattr -dr com.apple.quarantine /Applications/LocalFlow.app`
   (or right-click → Open).
3. Launch. Grant **Microphone** and **Accessibility** when the onboarding asks.
4. The speech model (~600 MB) downloads once in the background — you can dictate
   immediately via Apple's built-in model while it does.

## Build from source

```sh
brew install xcodegen
git clone <repo> && cd localflow
swift test                                   # core library tests
cd App && xcodegen && cd ..
xcodebuild -project App/LocalFlow.xcodeproj -scheme LocalFlow -configuration Release build
```

Dev harness (no app/permissions needed): `swift run localflow-cli transcribe path/to.wav`

## Privacy

Everything — audio capture, transcription, AI cleanup, history — happens on-device.
History is optional and stored only in `~/Library/Application Support/LocalFlow/`.
Verify with Little Snitch: zero connections after the model download.

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) — CoreML ASR runtime
- NVIDIA Parakeet TDT 0.6b-v3 weights (CC-BY-4.0)
- Apple FoundationModels & SpeechAnalyzer frameworks

## License

MIT — see [LICENSE](LICENSE).
