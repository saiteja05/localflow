# Pending features & follow-up work

Living roadmap of work identified but not yet started or not yet fully
verified. Distinct from [known-issues.md](known-issues.md) (small defects in
shipped code) and [manual-test-matrix.md](manual-test-matrix.md) (the release
verification checklist). Update this file as items are picked up or closed.

## Resolved

- **Voice commands, dictation history window** — manually verified
  2026-07-08; rows in `docs/manual-test-matrix.md` checked off as Pass.
- **Menu-bar icon occasionally missing** — fixed.

## From known-issues.md worth promoting to active work

The functional items most likely to matter next, pulled up from
known-issues.md #1-8 for visibility:

- **#1 Parakeet download failure has no in-session retry** — requires an
  app relaunch today; add a retry button that resets the preparation flag.
- **#2 `AppSettings.ollamaEnabled` is dead** — pipeline always includes the
  Ollama provider regardless of the setting; either wire the toggle in or
  delete the setting.
- **#3 Session cap (10 min) auto-stops silently** — spec calls for a HUD
  note; currently indistinguishable from a normal stop.
- **#7 Paste-swap can't detect "no writable target"** — the universal
  insertion path reports success blindly; undetectable by construction, so
  this needs a design decision (accept the limitation and document it more
  visibly, or add a post-insert verification read where AX allows one).

Everything else in known-issues.md (#4-6, #8-17) is lower priority or
cosmetic; see that file directly.

## Feature ideas not yet designed

Nothing formally proposed yet. Candidates raised in passing during earlier
work, not committed to:

- Retry affordance for a failed Parakeet download without relaunching (see
  known-issues #1 above — this would be the fix).
- Per-app live-typing opt-out (some apps may be worse candidates for
  synthetic-keystroke drafts than others; no evidence yet this is needed).
- Live-typing into the focused app (experimental): HUD live preview works
  correctly, but the synthetic-keystroke typing into the target app itself
  does not land text end-to-end. A teardown race condition in
  FlowController.swift (clearTyped() running after the final insert) was
  identified and fixed, with a regression test added, but real-device
  verification on 2026-07-09 shows the underlying typing-into-app failure
  persists beyond that race condition. Root cause not yet identified.
  Deprioritized to backlog, revisit later.
- CI job that builds the App target (known-issues #16) so app-layer compile
  breaks surface before a release tag, not on one.

Any of these should go through the brainstorming skill for a proper design
before implementation, same as every other feature in this codebase.
