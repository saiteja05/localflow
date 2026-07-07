# LocalFlow

**Hold a key, speak, release — polished text appears wherever your cursor is.**

100% local voice dictation for macOS. No cloud, no account, no subscription:
your voice never leaves your Mac.

## How it works

1. Hold the dictation key (**Fn** by default), talk naturally
   ("um so we should uh no wait we should definitely ship friday")
2. Release.
3. Clean text appears at your cursor: *"We should definitely ship Friday."*

- **Fast** (measured, M3 Pro, warm): 0.08–0.12 s speech-to-text for a ~3 s
  utterance + 0.35–0.7 s Apple Intelligence cleanup — ~0.8–1.2 s perceived
  from key-release to inserted text
- **Speech-to-text**: NVIDIA Parakeet v3 on the Neural Engine (25 languages,
  auto-detected), with Apple's built-in SpeechAnalyzer covering the gap while
  Parakeet downloads
- **AI cleanup**: removes fillers, fixes punctuation, applies self-corrections
  ("no wait, I meant…") — see [AI cleanup providers](#ai-cleanup-providers)
- **Hands-free mode**: double-tap the dictation key; tap again to finish;
  **Esc** cancels any recording
- **Personal dictionary**: your jargon, names, and exact text replacements
- **Per-app tone**: casual in Slack, formal in Mail — set a default tone and
  per-app overrides in Settings → AI Cleanup
- **Live preview**: your words stream into the HUD pill as you speak
  (display-only; the polished text lands on release)
- **Edit mode**: select any text, hold **Right ⌥**, speak an instruction
  ("make this more concise") — the selection is replaced by the edited text
- **Always know the state**: the menu-bar item shows a live status line —
  "● Ready", "● Recording…", "● Processing…", or a warning naming exactly
  what's wrong and how to fix it
- **Private by construction**: the only network traffic ever is model downloads

## Install

Requirements: Apple Silicon Mac, macOS 26 (Tahoe) or later.

1. Download `LocalFlow.zip` from [Releases](https://github.com/saiteja05/localflow/releases), unzip, drag to Applications.
2. Unsigned build for now: `xattr -dr com.apple.quarantine /Applications/LocalFlow.app`
   (or right-click → Open).
3. Launch. Grant **Microphone** and **Accessibility** when the onboarding asks
   (those are the only two permissions; Accessibility is what lets the app see
   the hotkey and type into other apps).
4. The speech model (~600 MB) downloads once in the background — you can dictate
   immediately via Apple's built-in model while it does.

## Hotkeys

| Gesture | Action |
|---|---|
| Hold **Fn** (default), speak, release | Dictate |
| Double-tap, speak, tap again | Hands-free dictation |
| **Esc** while recording | Cancel, insert nothing |
| Select text + hold **Right ⌥**, speak, release | Edit the selection by voice |

Settings → General offers **Right ⌘** or a custom modifier+key combo instead of
Fn. Tip: set System Settings → Keyboard → "Press 🌐 key" to **Do Nothing** so
the emoji picker never fights the Fn hold.

## AI cleanup providers

Cleanup runs as a fall-through chain — the first available provider wins, and
insertion is **never** blocked by AI failure (worst case you get the instant
rules-cleaned text):

1. **Apple Intelligence** (best: zero install, zero extra memory) — requires the
   Apple Intelligence toggle in System Settings → Apple Intelligence & Siri.
   After enabling, macOS downloads the on-device model; the Cleanup tab shows
   the live state ("downloading — available soon" → "Available").
2. **Ollama** (optional) — if [Ollama](https://ollama.com) is installed with
   *any* chat-capable model, LocalFlow uses it automatically: when the
   configured model isn't installed, it falls back to whatever is (embedding
   models excluded) and says so in Settings → AI Cleanup. That tab can also
   **start Ollama** for you and **download the recommended model**
   (`qwen3:4b-instruct`, ~2.5 GB) in-app with a progress bar — no terminal needed.
3. **Rules** (always on) — instant filler-stripping, stutter collapse,
   capitalization. Also the offline/failure fallback and the "Light" level.

Cleanup intensity (Settings → AI Cleanup): **Off** (raw transcript), **Light**
(rules only), **Standard** (AI: fillers, punctuation, self-corrections),
**Heavy** (AI: also grammar, run-ons, spoken lists → real lists).

**Tone** is resolved per dictation from the app you're speaking into: a
per-app override if you set one, else the default (Casual / Neutral / Formal).
Neutral adds no styling directive at all.

## Troubleshooting

- **Menu says "⚠︎ Hotkey inactive — grant Accessibility"** — the event tap
  can't start. Toggle LocalFlow in System Settings → Privacy & Security →
  Accessibility (if the toggle looks on but dictation is dead, remove the
  entry with **−** and re-add). The app retries every 3 seconds and recovers
  by itself the moment the grant lands — no relaunch needed.
- **Menu says "⚠︎ Secure input active (AppName)"** — a password field holds
  secure keyboard entry; macOS blocks all dictation tools during it. Click out
  of the password field and the state clears itself.
- **Apple Intelligence row won't say "Available"** — the row shows the real
  reason: device not supported, the toggle genuinely off (Siri alone doesn't
  count), or the on-device model still downloading after you enabled it.
- **Nothing inserts in one specific app** — the transcript is also left on the
  clipboard whenever insertion fails; paste it manually and please file an
  issue naming the app.
- **Dictation ignores you entirely** — check the menu status line first; it
  names the actual state (including which hotkey it's listening for).

## Build from source

```sh
brew install xcodegen
git clone https://github.com/saiteja05/localflow.git && cd localflow
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 151 tests
cd App && xcodegen && cd ..
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project App/LocalFlow.xcodeproj -scheme LocalFlow -configuration Release build
```

Requires full Xcode 26+ (Command Line Tools alone lack the Swift Testing
runtime). Dev harness (no app or permissions needed):
`swift run localflow-cli transcribe path/to.wav` — also `record`, `hotkey`,
and `insert` subcommands.

**Contributor tip — stop TCC grants dying on rebuild:** ad-hoc signing gives
every build a new identity, which invalidates the Accessibility grant. Create
a self-signed *code signing* certificate (Keychain Access → Certificate
Assistant, or openssl with a codeSigning EKU + `-legacy` p12 export) named
e.g. `LocalFlow Dev`, and set `CODE_SIGN_IDENTITY` in `App/project.yml` to it.
Grants then survive rebuilds.

## Privacy

Everything — audio capture, transcription, AI cleanup, history — happens
on-device. Audio is processed in memory and discarded after each dictation.
History is optional (Settings → History) and stored only in
`~/Library/Application Support/LocalFlow/`. Ollama traffic never leaves
`127.0.0.1`. Verify with Little Snitch: zero connections after model downloads.

## Known issues

See [docs/known-issues.md](docs/known-issues.md) for tracked follow-ups and
[docs/manual-test-matrix.md](docs/manual-test-matrix.md) for the release
verification checklist.

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) — CoreML ASR runtime
- NVIDIA Parakeet TDT 0.6b-v3 weights (CC-BY-4.0)
- Apple FoundationModels & SpeechAnalyzer frameworks
- [Ollama](https://ollama.com) (optional cleanup provider)

## License

MIT — see [LICENSE](LICENSE).
