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
