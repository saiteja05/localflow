# LocalFlow — Design Spec

**Date:** 2026-07-06
**Status:** Approved (design review with project owner)
**One-liner:** A 100% local Wispr Flow for macOS — hold a key, speak, release, and polished text appears wherever the cursor is. No cloud, no accounts, no external installs.

---

## 1. Goals & Non-Goals

### Goals (v1)

1. **Core loop:** global-hotkey push-to-talk dictation into any focused text field, system-wide.
2. **AI cleanup:** output reads like written text, not a transcript — filler removal, punctuation, capitalization, applied self-corrections ("no wait, I meant…"), spoken-list formatting.
3. **Custom dictionary:** user-managed vocabulary (proper nouns, jargon) and exact text replacements.
4. **Fast:** total perceived latency (key-release → text inserted) of ~0.6–1.4s on M-series Macs. Latency above ~2s is a failure; it is the thing reviewers punish hardest in competing apps.
5. **Private:** all audio and text processing on-device. The only network traffic is the one-time model download.
6. **Production-ready for strangers:** a real `.app` someone can download, grant two permissions to, and use — no Python, no Ollama requirement, no config files.

### Non-Goals (deferred to v2+)

- Per-app tone profiles (casual in Slack, formal in Mail)
- Voice command/edit mode ("make this more concise")
- Streaming text-as-you-speak with final-pass correction
- Auto-learning dictionary (mining unknown words from usage)
- Languages beyond Parakeet v3's 25 (would add whisper.cpp large-v3-turbo as a selectable engine)
- Snippets, usage insights, scratchpad
- Sparkle auto-update
- Windows/Linux (macOS-native by deliberate choice)

### Platform floor

**Apple Silicon, macOS 26 (Tahoe) or later.** Rationale: Apple Foundation Models (on-device LLM) and SpeechAnalyzer ship with macOS 26, giving zero-install AI cleanup and instant first-launch transcription. No OS-version conditionals in the codebase.

---

## 2. Verified Technical Foundations

These decisions come from researched, fact-checked findings (July 2026):

| Decision | Evidence |
|---|---|
| **STT: NVIDIA Parakeet TDT 0.6b-v3 via FluidAudio (Swift/CoreML)** | Fastest measured engine on Apple Silicon (~0.2s short utterances, ~110x real-time on M4 Pro, Neural Engine); ~6% avg WER beats whisper-large-v3-turbo (~7.8%); 25 European languages with auto language ID; Apache-2.0 (FluidAudio) + CC-BY-4.0 (model, attribution required) |
| **Instant-start STT: Apple SpeechAnalyzer/SpeechTranscriber** | Ships with macOS 26; on-device, fast, punctuation-aware; weaker on jargon than Parakeet — used only while Parakeet downloads or if download fails |
| **Do NOT use faster-whisper/CTranslate2** | CPU-only on Macs (no Metal/ANE); benchmarked 10–35x slower than CoreML/MLX engines |
| **Cleanup layer 1: rules pass** | Whisper/Parakeet already emit punctuation and omit most fillers, but residue is unpredictable — a word-list + stutter-collapse pass is instant and reliable for the unambiguous cases |
| **Cleanup layer 2: Apple Foundation Models** | ~3B on-device model, system-managed (near-zero incremental memory next to the STT model); `LanguageModelSession` with `prewarm()` gives <200ms first token; guided generation (`@Generable`) prevents chatty preambles. Failure modes to handle: availability gating (Apple Intelligence toggle off, model downloading) and `guardrailViolation` refusals on ordinary text |
| **Cleanup layer 3: Ollama** | Auto-detected at `localhost:11434`; recommended model `qwen3:4b-instruct` (strongest instruction-following at its size; thinking mode disabled); never required |
| **Hotkey: CGEventTap (active tap)** | Fn/Globe arrives as `flagsChanged` with keyCode 63 (`kVK_Function`) + `maskSecondaryFn`; an active tap can swallow the Fn press so the emoji picker doesn't open. Active taps need Accessibility — which text insertion needs anyway, so no extra permission. Must handle `kCGEventTapDisabledByTimeout` re-enable; taps can break when the binary's code signature changes between dev builds |
| **Insertion: per-app strategy chain** | Clipboard-swap + synthetic ⌘V is the universal default (works in browsers/Electron/terminals); AX `kAXSelectedTextAttribute` for known-good native apps (no clipboard touch, but desyncs React controlled inputs in Chromium/Electron and fails in terminals); chunked `CGEventPost` unicode typing as last resort (truncates at ~20 UTF-16 units/event) |
| **Secure input** | `IsSecureEventInputEnabled()` — event taps and hotkeys stop working system-wide when a password field holds secure input; must detect, suspend, and tell the user which app holds it |
| **Audio: pre-warmed engine + ring buffer** | First-word clipping and 1–2s Bluetooth mic wake latency are the top complaints against competing apps; an always-running `AVAudioEngine` with a ~0.5s rolling pre-buffer eliminates both |
| **Permissions footprint: Microphone + Accessibility only** | Identical to Wispr Flow's own setup; listen-only taps would add Input Monitoring, so we use an active tap under the Accessibility grant |
| **Memory budget** | Parakeet ~1.5–2GB resident + Apple FM ~0 incremental = comfortable even on 16GB machines |

---

## 3. Architecture

Native Swift menu-bar agent app (`LSUIElement = YES`, no Dock icon). One Xcode project; logic in local Swift packages (SPM) so every module is testable without the app shell or TCC permissions.

```
LocalFlowApp (app target: SwiftUI MenuBarExtra, NSPanel HUD, onboarding, settings)
└── FlowCore (session state machine, orchestration)
    ├── HotkeyKit      (CGEventTap, Fn detection, double-tap, secure-input watch)
    ├── CaptureKit     (AVAudioEngine, ring pre-buffer, 16kHz mono, device changes)
    ├── TranscribeKit  (Transcriber protocol; FluidAudio/Parakeet + SpeechAnalyzer;
    │                   model download manager; VAD trim)
    ├── CleanupKit     (CleanupProvider protocol; Rules / AppleFM / Ollama;
    │                   fallback pipeline; dictionary application)
    ├── InsertKit      (strategy chain, per-bundle-ID table, clipboard hygiene)
    └── Persistence    (settings, dictionary, history — JSON in Application Support)
```

### Module contracts

- **`FlowCore`** owns a single state machine:
  `idle → recording (hotkey down) → transcribing (hotkey up) → cleaning → inserting → idle`
  - Cancel: Esc during recording → discard, back to `idle`.
  - Short-press guard: hold <0.3s → treat as accidental, discard.
  - Hands-free: double-tap Fn (within ~400ms) → `recording` until next Fn tap.
  - Session cap: 10 minutes; at cap, auto-stop and process.
  - `@MainActor`-observable for UI; pipeline work runs off-main in structured tasks.
- **`HotkeyKit`** exposes `HotkeyEvent` stream (`pressed`, `released`, `doubleTapped`, `cancelled`). Config: Fn-hold (default), right-⌘-hold, or custom modifier+key combo (for external keyboards whose Fn never reaches macOS). Cancels a hold if another key arrives mid-hold (user meant Fn+arrow). Onboarding tells users to set System Settings → Keyboard → "Press Globe key to: Do Nothing."
- **`CaptureKit`** runs the engine continuously (input tap installed, negligible CPU), maintains a rolling ~0.5s pre-buffer; `startCapture()` splices pre-buffer + live audio; `stopCapture()` returns 16kHz mono Float32 samples. Handles `AVAudioEngineConfigurationChange` (AirPods connect/disconnect, default-device changes) by rebuilding the tap without dropping state.
- **`TranscribeKit`**: `protocol Transcriber { func transcribe(_ audio: AudioBuffer) async throws -> Transcript }` where `Transcript = (text, detectedLanguage, confidence)`. Implementations: `ParakeetTranscriber` (FluidAudio, primary), `SystemTranscriber` (SpeechAnalyzer, used while Parakeet unavailable). `ModelManager` downloads Parakeet (~600MB) to Application Support with progress reporting, checksum validation, and resume. VAD (FluidAudio's) trims leading/trailing silence pre-transcription. Models load once and stay resident.
- **`CleanupKit`**: `protocol CleanupProvider { func clean(_ transcript: String, options: CleanupOptions) async throws -> String }`. `CleanupOptions` carries the level, dictionary vocabulary, and detected language. Providers: `RulesCleaner` (synchronous, ~0ms: word-list filler strip at clause boundaries, immediate-repetition collapse, whitespace/casing normalization), `AppleFMCleaner` (prewarmed `LanguageModelSession`, guided generation into a single string field, temperature 0.2, ≤4s timeout), `OllamaCleaner` (HTTP to `localhost:11434`, `keep_alive=-1`, same prompt contract). The pipeline: rules always run; then the LLM provider per level; any LLM failure falls through to the next provider and ultimately returns the rules-cleaned text. **Insertion is never blocked by AI failure.**
- **`InsertKit`**: `insert(text, into frontmostApp) → InsertionResult`. Strategy table keyed by bundle ID with three strategies: `axSelectedText` (native Cocoa apps), `pasteSwap` (default: snapshot all pasteboard items → write transcript with `org.nspasteboard.TransientType` → post ⌘V → restore after ~300ms), `typedUnicode` (chunked ≤20 UTF-16 units per event, last resort). Ships with a small curated table (e.g., Terminal/iTerm → pasteSwap; TextEdit/Notes → axSelectedText); everything unknown → pasteSwap. On total failure: leave text on clipboard, notify.
- **`Persistence`**: JSON files in `~/Library/Application Support/LocalFlow/` — `settings.json`, `dictionary.json`, `history.jsonl` (capped at retention setting, default 100 entries, can be disabled entirely). Settings mirrored through `@AppStorage`-compatible layer for SwiftUI.

### Cleanup prompt contract

Single-turn instruction, kept short (cached system prompt):

> Rewrite this dictated text: fix punctuation and capitalization, remove filler words and false starts, apply self-corrections (if the speaker says "no wait" / "I mean", keep only the corrected version), preserve wording and meaning otherwise. Keep the same language as the input. [Heavy adds: fix grammar, split run-on sentences, format spoken enumerations as lists.] Vocabulary that may appear (use exact spelling): {dictionary terms}. Output only the cleaned text.

### Cleanup levels

| Level | What runs | Latency added |
|---|---|---|
| Off | nothing — raw STT output | 0 |
| Light | rules pass only | ~0 |
| Standard *(default)* | rules + LLM (fillers, punctuation, self-corrections; preserve wording) | ~0.3–0.8s |
| Heavy | rules + LLM (Standard + grammar, run-ons, list formatting) | ~0.4–1s |

---

## 4. The Pipeline (happy path)

1. **Fn down** → HUD pill appears bottom-center; `CaptureKit.startCapture()` splices in the ring pre-buffer (~0.5s of audio before the press — no clipped first words, even on slow-waking Bluetooth mics).
2. **Fn up** → capture stops → VAD trims silence → `Transcriber.transcribe()` (~0.2–0.5s) → raw text + detected language. HUD switches to processing.
3. **Cleanup** per level: rules pass, then prewarmed Apple FM with guided generation; dictionary vocabulary in prompt; 4s hard timeout with fall-through (AppleFM → Ollama → rules-only).
4. **Dictionary replacements** applied deterministically after the LLM (exact "spoken form → written form" substitutions — the LLM must not be trusted to apply these).
5. **Insert** via strategy for the frontmost bundle ID. HUD flashes ✓ and fades. History entry saved (raw + cleaned + app + timestamp).

Latency budget (M-series): STT 0.2–0.5s + LLM 0.3–0.8s + insert ~0.1s ≈ **0.6–1.4s perceived**.

---

## 5. Error Handling

Governing rule: **never lose the user's words; never block insertion on AI failure.**

| Failure | Behavior |
|---|---|
| Apple FM unavailable (Apple Intelligence off / model downloading) or `guardrailViolation` or timeout | Fall through: AppleFM → Ollama (if reachable) → rules-only. Silent; logged; provider status visible in Settings |
| Insertion finds no writable target / fails | Transcript left on clipboard + user notification: "Couldn't insert — it's on your clipboard" |
| Secure Event Input active (password field, some terminals) | Hotkey suspended; menu-bar icon shows warning state naming the app holding secure input (via `kCGSSessionSecureInputPID`) |
| Event tap disabled (`kCGEventTapDisabledByTimeout` / `ByUserInput`) | Auto re-enable in the tap callback |
| Accessibility or Microphone permission revoked | Menu-bar error state; onboarding reopens with deep links (`x-apple.systempreferences:…Privacy_Accessibility`); permissions re-checked on every launch (`AXIsProcessTrustedWithOptions`, `AVCaptureDevice.authorizationStatus`) |
| Empty transcript (silence, mic muted) | HUD: "didn't catch that"; nothing inserted; no history entry |
| Parakeet not yet downloaded / download failed | `SystemTranscriber` (SpeechAnalyzer) serves transcription; Settings shows model status + retry |
| Mic device changes mid-recording | `CaptureKit` rebuilds tap; if audio was lost, treat as cancel + notify |
| Session hits 10-min cap | Auto-stop, process normally, HUD notes the cap |

---

## 6. UI Surfaces

- **Menu bar** (`MenuBarExtra`): icon reflects state (idle / recording / processing / error-warning). Menu: Enable/Disable dictation, Copy Last Transcript, Recent Dictations (submenu, last 5), Settings…, About, Quit. Launch-at-login via `SMAppService`.
- **HUD**: non-activating floating `NSPanel` (`.nonactivatingPanel`, `.floating` level, `.canJoinAllSpaces` + `.fullScreenAuxiliary`) — a small bottom-center pill that **never steals focus** from the target app. States: recording (live audio-level waveform), processing (spinner), done (✓, fades out ~0.8s), error (brief message).
- **Onboarding window** (first launch or missing permissions): welcome → mic permission → accessibility permission (deep links, live-updating grant status) → model download progress (dictation already works via SpeechAnalyzer) → "try it: hold Fn and say hi" live test.
- **Settings window** (SwiftUI, standard window):
  - *General:* hotkey picker (Fn-hold default / right-⌘-hold / custom), hands-free double-tap toggle, launch at login.
  - *Transcription:* language (auto / pin one of 25), microphone (auto / specific device), model status + re-download.
  - *AI Cleanup:* level (Off/Light/Standard/Heavy), provider status rows (Apple Intelligence: available/off; Ollama: detected/not running + model picker when detected).
  - *Dictionary:* vocabulary list (add/remove terms), replacements table (spoken → written), import/export JSON.
  - *History:* toggle, retention count, list with copy buttons, clear all.
  - *About:* version, licenses (FluidAudio Apache-2.0, Parakeet CC-BY-4.0 attribution), privacy statement ("audio never leaves this Mac").

---

## 7. Testing

- **Unit (CI-runnable, no permissions):** `RulesCleaner` golden-file tests (fixtures of dictated-style text → expected); dictionary replacement engine; `FlowCore` state-machine transitions (incl. cancel, short-press, double-tap, cap); insertion strategy selection from bundle-ID table; prompt builder (levels × dictionary).
- **Integration (local, skippable on CI):** `ParakeetTranscriber` against fixture WAVs of scripted phrases (assert key-phrase presence, not exact WER); `AppleFMCleaner`/`OllamaCleaner` smoke tests behind availability checks.
- **Dev harness:** `localflow-cli` target — runs the full pipeline on a WAV file, prints raw/cleaned text and timings. No TCC permissions needed; primary tool while iterating (avoids the dev-build code-signature/tap-permission churn).
- **Manual matrix (documented checklist in repo):** insertion into TextEdit, Notes, Mail, Safari, Chrome, Slack, VS Code, Terminal, iTerm2; password field (secure-input handling); find-in-page fields; AirPods cold wake; mic switch mid-recording; Fn+arrow not misfiring; Globe-key emoji picker suppressed; clipboard manager (e.g., Raycast) ignores transient paste; two rapid dictations back-to-back.

---

## 8. Distribution

- **Repo:** GitHub, MIT license. `README` with a 30-second demo GIF, feature list, install + build-from-source instructions. Attribution section for FluidAudio (Apache-2.0) and Parakeet weights (CC-BY-4.0).
- **Releases:** v1 path is a GitHub Release `.app` zip + Homebrew cask. If/when an Apple Developer ID ($99/yr) is available: Developer ID signing + notarization + DMG (removes the right-click-to-open friction). Hardened runtime + `com.apple.security.device.audio-input` entitlement either way.
- **CI:** GitHub Actions on macOS runner — build + unit tests on every push; release workflow archives and uploads the app.

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Apple FM guardrail refuses benign dictation | Fall-through chain ends at rules-cleaned text; never blocks insertion |
| FluidAudio API churn (young library) | `Transcriber` protocol isolates it; SpeechAnalyzer is a working fallback |
| Dev-build event-tap permission churn (signature changes reset TCC grants) | Stable dev signing identity; `localflow-cli` for permission-free iteration |
| Paste-swap races with aggressive clipboard managers | TransientType marking + 300ms restore; documented limitation |
| macOS 26+ floor excludes some users | Accepted v1 constraint; revisit (macOS 15 + Ollama-only cleanup) if demand appears |
| Parakeet covers only 25 (European) languages | Accepted v1 constraint; whisper.cpp engine slot planned for v2 |

---

## 10. Success Criteria

1. Cold start to first dictation (fresh Mac, no downloads finished): works via SpeechAnalyzer within 30s of first launch.
2. Steady-state: hold-Fn → speak 15s → release → cleaned text inserted in ≤1.5s, into every app in the manual matrix.
3. Standard cleanup turns "um so I think we should uh no wait we should definitely um ship on friday" into "I think we should definitely ship on Friday."
4. Dictionary term ("Kubernetes", "Boddapati") transcribed correctly after being added.
5. A stranger can go from GitHub Release download to dictating in under 3 minutes without reading docs.
6. Zero network connections except the model download (verifiable with Little Snitch).
