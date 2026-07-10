# LocalFlow manual test matrix

Run before every release. Mark ✅/❌ + notes. (Spec §7.)

## Insertion targets (Standard cleanup, hold-Fn, say: "hello world this is a test")
| Target | Result | Notes |
|---|---|---|
| TextEdit (rich text) | | AX path |
| Notes | | AX path |
| Mail compose | | |
| Safari — Google search box | | paste path |
| Chrome — Gmail compose | | paste path |
| Slack message box | | Electron |
| VS Code editor | | Electron |
| Terminal prompt | | paste path |
| iTerm2 prompt | | |
| Spotlight search field | | |
| Safari password field | | MUST refuse: secure-input warning shows, no dictation |

## Gestures
| Case | Result |
|---|---|
| Hold Fn 0.5s+ → release → text inserted | |
| Tap Fn (<0.3s) → nothing happens | |
| Double-tap Fn → hands-free; tap again → text inserted | |
| Esc during recording → cancelled, nothing inserted | |
| Fn+←/→ while app active → cursor moves, NO dictation triggered | |
| Globe key alone → emoji picker does NOT appear (setting: Do Nothing) | |
| Right ⌘ hotkey mode works after switching in Settings | |
| Live preview: words appear in the HUD pill while speaking | |
| Edit mode: select text in Notes, hold Right ⌥, say "make this formal" → selection replaced | |
| Edit mode with nothing selected → "Select text first" notice, nothing typed | |
| Custom hotkey (⌘-key) held >1s → dictation completes, not cancelled by key-repeat | |

## Audio robustness
| Case | Result |
|---|---|
| First word intact when speaking immediately on press (×5) | |
| AirPods: first word intact after 30s of mic silence | |
| Unplug/switch mic between dictations → next dictation works | |
| Two dictations back-to-back (<1s apart) | |

## Cleanup + dictionary
| Case | Result |
|---|---|
| "um so I think we should uh no wait we should definitely um ship on friday" → self-correction applied, no fillers | |
| Vocabulary term ("Kubernetes") spelled correctly | |
| Replacement ("eng standup" → "Engineering Standup") applied | |
| Level Off → raw text with fillers | |
| Quit Ollama + disable Apple Intelligence → rules-only cleanup still inserts | |

## System behavior
| Case | Result |
|---|---|
| Clipboard content (image + text) restored after dictation | |
| Raycast/Maccy clipboard history does NOT show the transcript | |
| HUD never steals focus (type during recording) | |
| Menu icon reflects state through a full dictation | |
| Settings persist across relaunch | |
| Launch at login works after reboot | |
| Little Snitch/LuLu: zero network except model download | |

## Live-typing (experimental, opt-in — Settings → General)
| Case | Result | Notes |
|---|---|---|
| Enable, dictate into TextEdit → live text appears, then replaced by final cleaned text with no leftover characters | Fail | HUD live preview works; synthetic-keystroke typing into the target app lands no text. A teardown race condition was found and fixed but did not resolve this. Deprioritized to backlog, see docs/pending-features.md. |
| Enable, dictate into Notion (web) | | |
| Enable, dictate into Gmail compose (Safari) | | |
| Enable, dictate into WhatsApp (Electron/web) | | |
| Enable, disable "Live preview while dictating" (HUD off) → live-typing still engages | | regression check: `wantsHUD \|\| wantsLiveType` guard |
| Enable, press Esc mid-dictation → partial live-typed draft fully backspaced out, nothing left behind | | |
| Enable, Edit Mode (Right ⌥) → live-typing does NOT engage (scoped to normal dictation only) | | |
| Disabled (default) → no synthetic keystrokes at all during dictation | | |

## Voice commands (Settings → General, default on)
| Case | Result | Notes |
|---|---|---|
| Say "...scratch that..." mid-dictation, Level Off → discarded text does not appear | Pass | |
| Say "...scratch that..." mid-dictation, Level Standard | Pass | |
| Say "...scratch that..." mid-dictation, Level Heavy | Pass | |
| Say "...new paragraph..." → literal blank line in inserted text, Level Standard | Pass | |
| Say "...new line..." → literal single line break, Level Standard | Pass | |
| Voice commands + live-typing both on → command phrase visibly typed live, then corrected/converted once final text lands | Pass | expected, documented interaction |
| Disable voice commands → "scratch that"/"new paragraph" dictated verbatim as text | Pass | |

## Dictation history window
| Case | Result |
|---|---|
| Open via menu bar "Dictation History…" | Pass |
| Open via Settings → History → "Open Full History…" | Pass |
| Search box filters list by cleaned-text substring, case-insensitive | Pass |
| List updates live while a new dictation completes with the window open | Pass |
| Window resizes freely, reopens at a sane default size | Pass |
| App name resolves correctly for a currently running app | Pass |
| App name resolves correctly for an app that was quit after the dictation | Pass |
| Copy button copies the row's cleaned text to the clipboard | Pass |
