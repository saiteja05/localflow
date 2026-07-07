# Known issues & tracked follow-ups (v0.1)

Triaged during the final whole-branch review (2026-07-06). None are merge blockers;
each was judged low-impact or has a documented mitigation.

## Functional

1. **Parakeet download failure has no in-session retry.** Engine preparation is
   one-shot per launch; a failed model download requires an app relaunch (the
   Transcription tab shows status but no retry button). Fix: retry button that
   resets the preparation flag. (spec §5/§6 "model status + retry")
2. **`AppSettings.ollamaEnabled` is dead.** The pipeline always includes the
   Ollama provider (harmless — availability probing skips it when absent), and
   Settings has no toggle. Honor it or delete it.
3. **Session cap (10 min) auto-stops silently.** Spec §5 says the HUD should
   note the cap; it currently processes like a normal stop.
4. **SpeechAnalyzer fallback locale nuances.** A bare 2-letter language override
   ("de") may not match SpeechAnalyzer's region-qualified locales; the fallback
   locale is fixed at launch and doesn't follow later override changes.
5. **Mic-device change mid-recording**: the tap is rebuilt and capture continues,
   but there is no detection of lost audio ("treat as cancel + notify" in spec §5
   is unimplemented). Known limitation.
6. **ReplacementEngine chain-replacement**: with rules whose written form matches
   another rule's spoken form, sequential replacement can cascade. Longest-first
   ordering mitigates; a placeholder-pass design would eliminate it.
7. **Paste-swap cannot detect "no writable target"** — the universal insertion
   path reports success blindly (spec §5 row undetectable by construction).
8. **In-flight insert when secure input engages mid-pipeline** completes its side
   effects; macOS blocks synthetic keystrokes during secure input, so practical
   risk is a no-op paste.

## UX / polish

9. **HUD positioning uses `NSScreen.main`** — may not track the active display on
   multi-monitor setups.
10. **Launch-at-login toggle** swallows `SMAppService` errors and never reconciles
    with `SMAppService.mainApp.status`.
11. **Hotkey-source start failure is silent** (`try? hotkeySource.start()`) — the
    dev-resign/TCC-churn case shows an idle icon with no explanation; should
    surface a disabled-phase reason.
12. **Menu/History `ForEach` keyed by timestamp** assumes no two dictations share
    a `Date` — fine at human cadence.

## Performance / cost

13. **Cleanup provider trial is sequential** — worst case ~8s (2 providers × 4s
    timeout) before rules fallback. Consider an overall deadline.
14. **HistoryStore opens a FileHandle per append** — negligible at dictation
    cadence.

## Build / release

15. **Release builds ship without hardened runtime** (`ENABLE_HARDENED_RUNTIME: NO`
    everywhere); spec §8 wants it on for release once a signing identity exists.
16. **CI doesn't build the app target** — App-layer compile breaks would surface
    only on a release tag. Add an xcodegen+xcodebuild job to ci.yml.

## Cosmetic

17. `AppleFMCleanerTests` mid-file import; 3-line session-staging duplication in
    `SystemFMBackend`; `TextInserter` could be plain `Sendable`; `makeSineBuffer`
    helper lives in `AudioFileLoaderTests.swift`; `AppSettings` decode-helper
    repetition (plan-mandated pattern).
