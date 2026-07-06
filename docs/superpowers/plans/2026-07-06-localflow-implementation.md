# LocalFlow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build LocalFlow — a fully local Wispr Flow for macOS: hold Fn, speak, release, and AI-polished text appears at the cursor in any app.

**Architecture:** A native Swift menu-bar agent app (`LSUIElement`) whose logic lives in seven local SPM library modules (CleanupKit, HotkeyKit, CaptureKit, TranscribeKit, InsertKit, Persistence, FlowCore) plus a CLI harness. STT is Parakeet TDT 0.6b-v3 via FluidAudio (CoreML/ANE) with Apple SpeechAnalyzer as the zero-download fallback; cleanup is a layered pipeline (rules → Apple Foundation Models → Ollama → rules-only); insertion uses a per-app strategy chain (paste-swap default).

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing (`import Testing`), SwiftUI + AppKit, FluidAudio 0.15.4, FoundationModels.framework, Speech.framework (SpeechAnalyzer), XcodeGen for the app target, GitHub Actions (`macos-26`).

## Global Constraints

- Platform: **Apple Silicon, macOS 26.0+** (`platforms: [.macOS(.v26)]` in Package.swift; `@available` annotations unnecessary inside the package).
- Permissions footprint: **Microphone + Accessibility only.** Never add Input Monitoring (use an active CGEventTap, not listen-only).
- **Never lose the user's words; never block insertion on AI failure** (cleanup fall-through must always produce text).
- Latency: key-release → inserted text ≤ 1.5s steady-state on M-series. LLM cleanup timeout: **4s** hard.
- Timing constants (from spec, do not change): short-press guard **0.3s**, double-tap window **0.4s**, session cap **600s**, clipboard restore delay **0.3s**, ring pre-buffer **0.5s**.
- Audio interchange format everywhere: **16 kHz mono Float32** (`AudioData`). SpeechAnalyzer additionally requires Int16 conversion at its boundary (Float32 input hard-crashes the process — verified).
- No `@Generable`/`@Guide` macros anywhere (requires full Xcode's macro plugin; plain-String responses are also required for `Guardrails.permissiveContentTransformations` to apply).
- Do NOT use faster-whisper/CTranslate2 or add whisper.cpp in v1.
- License: MIT for our code. Attribution required: FluidAudio (Apache-2.0), Parakeet weights (CC-BY-4.0).
- Tooling floor: Tasks 1–17 build with Command Line Tools alone (`swift build` / `swift test`). Tasks 18–23 require full **Xcode 26** + `brew install xcodegen`. Start the Xcode install early — it's a big download.
- Commit after every task (steps include exact commands). Repo root: `/Users/teja.boddapati/Desktop/localflow`.

## Shared Type Contracts (single source of truth)

Later tasks MUST use these exact names/signatures. Defining task in parentheses.

```swift
// CaptureKit (Task 8)
public struct AudioData: Sendable, Equatable {
    public static let sampleRate: Double = 16_000
    public var samples: [Float]                      // 16 kHz mono
    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public init(samples: [Float])
}
public protocol AudioCapturing: Sendable {
    func startCapture() throws
    func stopCapture() async -> AudioData
    func cancelCapture()
    var levels: AsyncStream<Float> { get }           // RMS 0…1 for HUD
}

// TranscribeKit (Task 14)
public struct Transcript: Sendable, Equatable {
    public var text: String
    public var languageHint: String?                 // BCP-47 or nil (Parakeet does not detect language)
    public init(text: String, languageHint: String?)
}
public protocol Transcriber: Sendable {
    func isReady() async -> Bool
    func transcribe(_ audio: AudioData) async throws -> Transcript
}

// CleanupKit (Task 2)
public enum CleanupLevel: String, Codable, CaseIterable, Sendable { case off, light, standard, heavy }
public struct Replacement: Codable, Equatable, Sendable {
    public var spoken: String
    public var written: String
    public init(spoken: String, written: String)
}
public struct CleanupOptions: Sendable, Equatable {
    public var level: CleanupLevel
    public var vocabulary: [String]
    public init(level: CleanupLevel, vocabulary: [String])
}
public struct CleanupResult: Sendable, Equatable {
    public var text: String
    public var providerID: String                    // "apple-fm" | "ollama" | "rules" | "raw"
    public init(text: String, providerID: String)
}
public protocol CleanupProvider: Sendable {
    var id: String { get }
    func isAvailable() async -> Bool
    func clean(_ text: String, options: CleanupOptions) async throws -> String
}
public protocol CleanupProcessing: Sendable {
    func process(_ raw: String, options: CleanupOptions, replacements: [Replacement]) async -> CleanupResult
}

// HotkeyKit (Task 6)
public enum HotkeyChoice: Codable, Equatable, Sendable {
    case fnKey
    case rightCommand
    case custom(keyCode: UInt16, modifierRawValue: UInt64)
}
public enum HotkeyRawEvent: Sendable, Equatable {
    case keyDown, keyUp, comboCancelled, escapePressed, secureInputChanged(Bool)
}
public protocol HotkeySource: Sendable {
    var events: AsyncStream<HotkeyRawEvent> { get }
    func start() throws
}

// InsertKit (Task 12)
public enum InsertionStrategy: String, Codable, Sendable { case axSelectedText, pasteSwap, typedUnicode }
public enum InsertionOutcome: Equatable, Sendable {
    case inserted(InsertionStrategy)
    case failedTextOnClipboard
}
public protocol TextInserting: Sendable {
    func insert(_ text: String, bundleID: String?) async -> InsertionOutcome
}

// Persistence (Task 13)
public struct AppSettings: Codable, Equatable, Sendable { /* fields in Task 13 */ }
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var rawText: String
    public var cleanedText: String
    public var appBundleID: String?
    public var providerID: String
    public init(timestamp: Date, rawText: String, cleanedText: String, appBundleID: String?, providerID: String)
}

// FlowCore (Task 10 & 17)
// GestureMachine (Task 10): pure reducer — see task for full definition.
// FlowController (Task 17): @MainActor @Observable orchestrator with
// public enum Phase: Equatable { case disabled(String), idle, recording(handsFree: Bool),
//                                transcribing, cleaning, inserting, notice(String) }
```

## File Structure

```
localflow/
├── Package.swift                          # LocalFlowKit: 7 libs + CLI (Task 1)
├── Sources/
│   ├── CleanupKit/
│   │   ├── CleanupTypes.swift             # Task 2
│   │   ├── RulesCleaner.swift             # Task 2
│   │   ├── ReplacementEngine.swift        # Task 3
│   │   ├── PromptBuilder.swift            # Task 4
│   │   ├── OllamaCleaner.swift            # Task 5 (+ OllamaAPI.swift DTOs)
│   │   ├── AppleFMCleaner.swift           # Task 9
│   │   └── CleanupPipeline.swift          # Task 7
│   ├── HotkeyKit/
│   │   ├── HotkeyTypes.swift              # Task 6
│   │   ├── KeyEventInterpreter.swift      # Task 6
│   │   ├── EventTapHotkeySource.swift     # Task 11
│   │   └── Permissions.swift              # Task 11 (AX check, secure input)
│   ├── CaptureKit/
│   │   ├── AudioData.swift                # Task 8
│   │   ├── RingBuffer.swift               # Task 8
│   │   ├── AudioResampler.swift           # Task 8
│   │   ├── AudioFileLoader.swift          # Task 8
│   │   └── AudioCaptureService.swift      # Task 15
│   ├── TranscribeKit/
│   │   ├── Transcriber.swift              # Task 14
│   │   ├── SystemTranscriber.swift        # Task 14 (SpeechAnalyzer)
│   │   ├── ParakeetTranscriber.swift      # Task 16 (FluidAudio)
│   │   └── TranscriberRouter.swift        # Task 16
│   ├── InsertKit/
│   │   ├── InsertionTypes.swift           # Task 12
│   │   ├── StrategyTable.swift            # Task 12
│   │   ├── UnicodeChunker.swift           # Task 12
│   │   ├── PasteboardSnapshot.swift       # Task 12
│   │   ├── FrontmostApp.swift             # Task 12
│   │   └── TextInserter.swift             # Task 12
│   ├── Persistence/
│   │   ├── AppSettings.swift              # Task 13
│   │   ├── SettingsStore.swift            # Task 13
│   │   ├── DictionaryStore.swift          # Task 13
│   │   └── HistoryStore.swift             # Task 13
│   ├── FlowCore/
│   │   ├── GestureMachine.swift           # Task 10
│   │   └── FlowController.swift           # Task 17
│   └── localflow-cli/
│       └── main.swift                     # Task 16 wiring (created Task 1 as stub)
├── Tests/
│   ├── CleanupKitTests/                   # Tasks 2,3,4,5,7,9
│   ├── HotkeyKitTests/                    # Task 6
│   ├── CaptureKitTests/                   # Task 8
│   ├── TranscribeKitTests/                # Tasks 14,16 (runtime-gated)
│   ├── InsertKitTests/                    # Task 12
│   ├── PersistenceTests/                  # Task 13
│   ├── FlowCoreTests/                     # Tasks 10,17
│   └── Fixtures/hello.wav                 # Task 14 (generated by `say`)
├── App/
│   ├── project.yml                        # Task 18 (XcodeGen; .xcodeproj is gitignored)
│   ├── LocalFlow/
│   │   ├── LocalFlowApp.swift             # Task 18 (@main, MenuBarExtra, composition root)
│   │   ├── AppState.swift                 # Task 18
│   │   ├── HUD/HUDPanel.swift             # Task 19
│   │   ├── HUD/HUDView.swift              # Task 19
│   │   ├── Onboarding/OnboardingView.swift# Task 20
│   │   ├── Settings/SettingsView.swift    # Task 21 (+ one file per tab)
│   │   └── Resources/                     # Task 18 (Info.plist via project.yml)
│   └── LocalFlow.entitlements             # Task 18
├── .github/workflows/ci.yml               # Task 1
├── .github/workflows/release.yml          # Task 23
├── docs/manual-test-matrix.md             # Task 23
├── .gitignore, LICENSE, README.md         # Task 1 (README finalized Task 23)
```

Module dependency graph (Package.swift): `CleanupKit`, `HotkeyKit`, `CaptureKit`, `InsertKit` are leaves. `TranscribeKit → CaptureKit + FluidAudio`. `Persistence → CleanupKit + HotkeyKit`. `FlowCore → all six`. `localflow-cli → FlowCore` (and transitively everything).

---

### Task 1: Package scaffolding, CI, license

**Files:**
- Create: `Package.swift`, `.gitignore`, `LICENSE`, `README.md`, `.github/workflows/ci.yml`
- Create: `Sources/<Module>/<Module>.swift` placeholder-free doc file for each of the 7 modules + `Sources/localflow-cli/main.swift`
- Create: `Tests/CleanupKitTests/SmokeTests.swift`

**Interfaces:**
- Produces: the SPM package every later task adds files into; CI that runs `swift build && swift test`.

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalFlowKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FlowCore", targets: ["FlowCore"]),
        .library(name: "CleanupKit", targets: ["CleanupKit"]),
        .library(name: "HotkeyKit", targets: ["HotkeyKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "TranscribeKit", targets: ["TranscribeKit"]),
        .library(name: "InsertKit", targets: ["InsertKit"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .executable(name: "localflow-cli", targets: ["localflow-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4"),
    ],
    targets: [
        .target(name: "CleanupKit"),
        .target(name: "HotkeyKit"),
        .target(name: "CaptureKit"),
        .target(name: "InsertKit"),
        .target(name: "TranscribeKit", dependencies: [
            "CaptureKit",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .target(name: "Persistence", dependencies: ["CleanupKit", "HotkeyKit"]),
        .target(name: "FlowCore", dependencies: [
            "CleanupKit", "HotkeyKit", "CaptureKit", "TranscribeKit", "InsertKit", "Persistence",
        ]),
        .executableTarget(name: "localflow-cli", dependencies: ["FlowCore"]),
        .testTarget(name: "CleanupKitTests", dependencies: ["CleanupKit"]),
        .testTarget(name: "HotkeyKitTests", dependencies: ["HotkeyKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(name: "TranscribeKitTests", dependencies: ["TranscribeKit"]),
        .testTarget(name: "InsertKitTests", dependencies: ["InsertKit"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "FlowCoreTests", dependencies: ["FlowCore"]),
    ]
)
```

- [ ] **Step 2: Create one compilable source file per target**

Each `Sources/<Module>/<Module>.swift` (7 files) contains exactly (substituting the module name):

```swift
/// CleanupKit — transcript post-processing: rules pass, LLM providers, pipeline.
/// Part of LocalFlow. See docs/superpowers/specs/2026-07-06-localflow-design.md §3.
```

Module doc lines: CleanupKit as above; HotkeyKit `global hotkey capture via CGEventTap (Fn push-to-talk)`; CaptureKit `always-warm microphone capture with ring pre-buffer`; TranscribeKit `local speech-to-text engines (Parakeet via FluidAudio, Apple SpeechAnalyzer)`; InsertKit `inserting text into the frontmost app`; Persistence `settings, dictionary, and history stores`; FlowCore `dictation session state machine and orchestration`.

`Sources/localflow-cli/main.swift`:

```swift
import Foundation
print("localflow-cli — pipeline harness. Commands arrive in Task 16.")
```

`Tests/CleanupKitTests/SmokeTests.swift`:

```swift
import Testing

@Test func packageBuilds() {
    #expect(Bool(true))
}
```

- [ ] **Step 3: Write .gitignore, LICENSE, README stub**

`.gitignore`:

```
.build/
.swiftpm/
DerivedData/
*.xcodeproj
.DS_Store
App/LocalFlow/Resources/Generated/
```

`LICENSE`: the standard MIT license text, `Copyright (c) 2026 Teja Boddapati`.

`README.md`:

```markdown
# LocalFlow

Hold a key, speak, release — polished text appears wherever your cursor is.
100% local voice dictation for macOS: no cloud, no accounts, no subscriptions.

**Status: under construction.** Design: `docs/superpowers/specs/2026-07-06-localflow-design.md`.
```

- [ ] **Step 4: Write .github/workflows/ci.yml**

`macos-26` is a preview label (verified July 2026: exists, default Xcode 26.5; `macos-latest` is still macOS 15 — do not use it).

```yaml
name: ci
on: [push, pull_request]
jobs:
  build-and-test:
    runs-on: macos-26
    env:
      DEVELOPER_DIR: /Applications/Xcode_26.5.app/Contents/Developer
    steps:
      - uses: actions/checkout@v4
      - name: Toolchain
        run: swift --version && xcrun --sdk macosx --show-sdk-version
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

- [ ] **Step 5: Verify build and test pass**

Run: `cd /Users/teja.boddapati/Desktop/localflow && swift build && swift test`
Expected: `Build complete!` then `Test run with 1 test passed`. (First run resolves FluidAudio — needs network.)

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "chore: scaffold SPM package, CI, license"
```

---

### Task 2: CleanupKit — shared types + RulesCleaner

**Files:**
- Create: `Sources/CleanupKit/CleanupTypes.swift`
- Create: `Sources/CleanupKit/RulesCleaner.swift`
- Test: `Tests/CleanupKitTests/RulesCleanerTests.swift`

**Interfaces:**
- Produces: `CleanupLevel`, `Replacement`, `CleanupOptions`, `CleanupResult`, `CleanupProvider`, `CleanupProcessing` (exactly as in Shared Type Contracts) and `RulesCleaner.clean(_ text: String) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/CleanupKitTests/RulesCleanerTests.swift`:

```swift
import Testing
@testable import CleanupKit

struct RulesCleanerTests {
    @Test func stripsStandaloneFillers() {
        #expect(RulesCleaner.clean("um I think uh we should ship") == "I think we should ship")
    }
    @Test func stripsFillersCaseInsensitively() {
        #expect(RulesCleaner.clean("Um, let's go") == "Let's go")
    }
    @Test func stripsFillerWithTrailingComma() {
        #expect(RulesCleaner.clean("so, um, the plan works") == "So, the plan works")
    }
    @Test func stripsYouKnowAtClauseBoundary() {
        #expect(RulesCleaner.clean("it works, you know, most days") == "It works, most days")
        #expect(RulesCleaner.clean("You know, it works") == "It works")
    }
    @Test func keepsYouKnowMidClause() {
        // First letter still gets capitalized (that rule is unconditional);
        // the point here is that mid-clause "you know" is NOT stripped.
        #expect(RulesCleaner.clean("do you know the answer") == "Do you know the answer")
    }
    @Test func collapsesImmediateWordRepetition() {
        #expect(RulesCleaner.clean("the the plan is is ready") == "The plan is ready")
    }
    @Test func repetitionCollapseIsCaseInsensitiveKeepsFirst() {
        #expect(RulesCleaner.clean("The the plan") == "The plan")
    }
    @Test func normalizesWhitespaceAndPunctuationSpacing() {
        #expect(RulesCleaner.clean("hello   world , again .") == "Hello world, again.")
    }
    @Test func capitalizesFirstLetter() {
        #expect(RulesCleaner.clean("hello there") == "Hello there")
    }
    @Test func doesNotAddTerminalPunctuation() {
        #expect(RulesCleaner.clean("quick search query") == "Quick search query")
    }
    @Test func emptyAndWhitespaceOnlyInputs() {
        #expect(RulesCleaner.clean("") == "")
        #expect(RulesCleaner.clean("   ") == "")
        #expect(RulesCleaner.clean("um uh") == "")
    }
    @Test func preservesMultiSentenceText() {
        #expect(RulesCleaner.clean("um okay. So the the deadline is friday.")
                == "Okay. So the deadline is friday.")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RulesCleanerTests`
Expected: FAIL — `cannot find 'RulesCleaner' in scope`.

- [ ] **Step 3: Write CleanupTypes.swift**

```swift
import Foundation

public enum CleanupLevel: String, Codable, CaseIterable, Sendable {
    case off, light, standard, heavy
}

public struct Replacement: Codable, Equatable, Sendable {
    public var spoken: String
    public var written: String
    public init(spoken: String, written: String) {
        self.spoken = spoken
        self.written = written
    }
}

public struct CleanupOptions: Sendable, Equatable {
    public var level: CleanupLevel
    public var vocabulary: [String]
    public init(level: CleanupLevel, vocabulary: [String]) {
        self.level = level
        self.vocabulary = vocabulary
    }
}

public struct CleanupResult: Sendable, Equatable {
    public var text: String
    public var providerID: String
    public init(text: String, providerID: String) {
        self.text = text
        self.providerID = providerID
    }
}

public protocol CleanupProvider: Sendable {
    var id: String { get }
    func isAvailable() async -> Bool
    func clean(_ text: String, options: CleanupOptions) async throws -> String
}

public protocol CleanupProcessing: Sendable {
    func process(_ raw: String, options: CleanupOptions, replacements: [Replacement]) async -> CleanupResult
}

public enum CleanupError: Error, Equatable {
    case unavailable
    case timedOut
    case refused          // guardrail / safety refusal
    case badResponse(String)
}
```

- [ ] **Step 4: Write RulesCleaner.swift**

```swift
import Foundation

/// Deterministic, instant transcript cleanup. Conservative by design:
/// only removes unambiguous fillers; never adds terminal punctuation
/// (users dictate fragments into search boxes).
public enum RulesCleaner {
    // Standalone filler words (word-boundary, case-insensitive).
    private static let fillers = ["um", "uh", "uhm", "umm", "erm", "er", "ah", "hmm"]

    public static func clean(_ text: String) -> String {
        var s = text

        // 1. Strip standalone fillers, consuming one adjacent comma if present:
        //    "um, so" -> "so";  "so, um, the" -> "so, the";  "I um think" -> "I think"
        let fillerAlternation = fillers.joined(separator: "|")
        s = s.replacingOccurrences(
            of: #"(?i)(?<![\w'])(?:\#(fillerAlternation))(?![\w'])[,]?\s*"#,
            with: "", options: .regularExpression)

        // 2. "you know" only at clause boundaries (start-or-after-comma AND before-comma).
        s = s.replacingOccurrences(
            of: #"(?i)(^|,)\s*you know\s*,\s*"#,
            with: "$1 ", options: .regularExpression)

        // 3. Collapse immediate word repetitions ("the the" -> "the"), keep the first token.
        while let range = s.range(
            of: #"(?i)(?<![\w'])([\w']+)(\s+\1)(?![\w'])"#, options: .regularExpression) {
            let match = String(s[range])
            let first = match.split(separator: " ", maxSplits: 1)[0]
            s = s.replacingCharacters(in: range, with: String(first))
        }

        // 4. Whitespace + punctuation spacing: collapse runs; no space before , . ! ? ; :
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        // Leftover doubled commas from removals: ", ," -> ","
        s = s.replacingOccurrences(of: #",\s*,"#, with: ",", options: .regularExpression)
        // Leading orphan punctuation after removals: "^, so" -> "so"
        s = s.replacingOccurrences(of: #"^[\s,.!?;:]+"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Capitalize first letter (leave the rest untouched).
        if let first = s.first, first.isLowercase {
            s = first.uppercased() + s.dropFirst()
        }
        return s
    }
}
```

- [ ] **Step 5: Run tests until green**

Run: `swift test --filter RulesCleanerTests`
Expected: PASS (12 tests). If a golden test fails on wording, fix the implementation — not the test — unless the expected string itself violates the rules stated in comments.

- [ ] **Step 6: Commit**

```bash
git add Sources/CleanupKit Tests/CleanupKitTests
git commit -m "feat(cleanup): shared types + deterministic rules cleaner"
```

---

### Task 3: CleanupKit — ReplacementEngine

**Files:**
- Create: `Sources/CleanupKit/ReplacementEngine.swift`
- Test: `Tests/CleanupKitTests/ReplacementEngineTests.swift`

**Interfaces:**
- Consumes: `Replacement` (Task 2).
- Produces: `ReplacementEngine.apply(_ replacements: [Replacement], to text: String) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import CleanupKit

struct ReplacementEngineTests {
    @Test func replacesWholeWordCaseInsensitively() {
        let r = [Replacement(spoken: "kubernetes", written: "Kubernetes")]
        #expect(ReplacementEngine.apply(r, to: "deploy to Kubernetes and kubernetes") ==
                "deploy to Kubernetes and Kubernetes")
    }
    @Test func replacesMultiWordPhrases() {
        let r = [Replacement(spoken: "eng standup", written: "Engineering Standup")]
        #expect(ReplacementEngine.apply(r, to: "join eng standup at 9") ==
                "join Engineering Standup at 9")
    }
    @Test func doesNotReplaceInsideWords() {
        let r = [Replacement(spoken: "cat", written: "CAT")]
        #expect(ReplacementEngine.apply(r, to: "concatenate the cat file") ==
                "concatenate the CAT file")
    }
    @Test func longestSpokenFormWinsWhenOverlapping() {
        let r = [Replacement(spoken: "sequel", written: "SQL"),
                 Replacement(spoken: "my sequel", written: "MySQL")]
        #expect(ReplacementEngine.apply(r, to: "use my sequel or sequel") == "use MySQL or SQL")
    }
    @Test func escapesRegexMetacharactersInSpokenForm() {
        let r = [Replacement(spoken: "c++", written: "C++")]
        #expect(ReplacementEngine.apply(r, to: "i like c++ a lot") == "i like C++ a lot")
    }
    @Test func emptyReplacementsIsIdentity() {
        #expect(ReplacementEngine.apply([], to: "hello") == "hello")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ReplacementEngineTests`
Expected: FAIL — `cannot find 'ReplacementEngine' in scope`.

- [ ] **Step 3: Write ReplacementEngine.swift**

```swift
import Foundation

/// Deterministic user-defined substitutions ("spoken form" -> "written form").
/// Applied AFTER the LLM pass — the LLM must never be trusted with these.
public enum ReplacementEngine {
    public static func apply(_ replacements: [Replacement], to text: String) -> String {
        var s = text
        // Longest spoken form first so "my sequel" beats "sequel".
        for r in replacements.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            guard !r.spoken.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: r.spoken)
            // Word-ish boundaries that tolerate non-word chars in the term itself (c++).
            let pattern = #"(?i)(?<![\w'])"# + escaped + #"(?![\w'])"#
            s = s.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: r.written),
                options: .regularExpression)
        }
        return s
    }
}
```

- [ ] **Step 4: Run tests until green**

Run: `swift test --filter ReplacementEngineTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanupKit/ReplacementEngine.swift Tests/CleanupKitTests/ReplacementEngineTests.swift
git commit -m "feat(cleanup): deterministic dictionary replacement engine"
```

---

### Task 4: CleanupKit — PromptBuilder

**Files:**
- Create: `Sources/CleanupKit/PromptBuilder.swift`
- Test: `Tests/CleanupKitTests/PromptBuilderTests.swift`

**Interfaces:**
- Consumes: `CleanupLevel` (Task 2).
- Produces: `PromptBuilder.instructions(level:vocabulary:) -> String` and `PromptBuilder.userPrompt(for:) -> String` — used verbatim by BOTH `AppleFMCleaner` (Task 9) and `OllamaCleaner` (Task 5) so behavior stays identical across providers.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import CleanupKit

struct PromptBuilderTests {
    @Test func standardInstructionsContainCoreDirectives() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: [])
        #expect(i.contains("punctuation"))
        #expect(i.contains("filler"))
        #expect(i.contains("self-correction") || i.contains("no wait"))
        #expect(i.contains("same language"))
        #expect(i.contains("Output only"))
        #expect(!i.contains("grammar"))          // heavy-only directive
    }
    @Test func heavyInstructionsAddGrammarAndLists() {
        let i = PromptBuilder.instructions(level: .heavy, vocabulary: [])
        #expect(i.contains("grammar"))
        #expect(i.contains("list"))
    }
    @Test func vocabularyIsEmbedded() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: ["Kubernetes", "Boddapati"])
        #expect(i.contains("Kubernetes, Boddapati"))
    }
    @Test func noVocabularySectionWhenEmpty() {
        let i = PromptBuilder.instructions(level: .standard, vocabulary: [])
        #expect(!i.contains("Vocabulary"))
    }
    @Test func userPromptWrapsTranscript() {
        #expect(PromptBuilder.userPrompt(for: "hello world") == "Transcript:\nhello world")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PromptBuilderTests`
Expected: FAIL — `cannot find 'PromptBuilder' in scope`.

- [ ] **Step 3: Write PromptBuilder.swift**

```swift
import Foundation

/// Single prompt contract shared by every LLM provider (spec §3).
/// Keep instructions short: they count against Apple FM's 4096-token window.
public enum PromptBuilder {
    public static func instructions(level: CleanupLevel, vocabulary: [String]) -> String {
        var lines = [
            "You clean up dictated text.",
            "Fix punctuation and capitalization. Remove filler words and false starts.",
            "Apply self-corrections: if the speaker says \"no wait\" or \"I mean\", keep only the corrected version.",
            "Preserve wording and meaning otherwise. Keep the same language as the input.",
        ]
        if level == .heavy {
            lines.append("Also fix grammar, split run-on sentences, and format spoken enumerations (\"first... second...\") as lists.")
        }
        if !vocabulary.isEmpty {
            lines.append("Vocabulary that may appear (use exact spelling): \(vocabulary.joined(separator: ", ")).")
        }
        lines.append("Output only the cleaned text — no preamble, no quotes, no commentary.")
        return lines.joined(separator: " ")
    }

    public static func userPrompt(for transcript: String) -> String {
        "Transcript:\n" + transcript
    }
}
```

- [ ] **Step 4: Run tests until green**

Run: `swift test --filter PromptBuilderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanupKit/PromptBuilder.swift Tests/CleanupKitTests/PromptBuilderTests.swift
git commit -m "feat(cleanup): shared LLM prompt builder"
```

---

### Task 5: CleanupKit — OllamaCleaner

**Files:**
- Create: `Sources/CleanupKit/OllamaAPI.swift` (request/response DTOs)
- Create: `Sources/CleanupKit/OllamaCleaner.swift`
- Test: `Tests/CleanupKitTests/OllamaCleanerTests.swift`

**Interfaces:**
- Consumes: `CleanupProvider`, `CleanupOptions`, `CleanupError`, `PromptBuilder` (Tasks 2, 4).
- Produces: `OllamaCleaner(model:baseURL:urlSession:)` conforming to `CleanupProvider` with `id == "ollama"`.

Verified API facts (July 2026, github.com/ollama/ollama/docs/api.md): `think`, `keep_alive`, `stream` are **top-level** request fields (`think:false` needs Ollama ≥ 0.9.0; inside `options` they are silently ignored); `temperature` goes inside `options`; non-streaming response text is at `message.content`; liveness probe is `GET /api/tags` → `{"models":[{"name":...}]}`.

- [ ] **Step 1: Write the failing tests (URLProtocol stub)**

`Tests/CleanupKitTests/OllamaCleanerTests.swift`:

```swift
import Foundation
import Testing
@testable import CleanupKit

/// Serial URLProtocol stub. Set `StubURLProtocol.handler` per test.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("no stub handler") }
        // Body arrives as a stream for URLSession uploads; read it fully.
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            req.httpBody = data
        }
        let (status, data) = handler(req)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct OllamaCleanerTests {
    let options = CleanupOptions(level: .standard, vocabulary: ["Kubernetes"])

    @Test func cleanSendsCorrectRequestShapeAndParsesContent() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/chat")
            let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
            #expect(body["model"] as? String == "qwen3:4b-instruct")
            #expect(body["stream"] as? Bool == false)
            #expect(body["think"] as? Bool == false)          // top-level, NOT in options
            #expect(body["keep_alive"] as? Int == -1)          // top-level, NOT in options
            let opts = body["options"] as! [String: Any]
            #expect((opts["temperature"] as! NSNumber).doubleValue == 0.2)
            let messages = body["messages"] as! [[String: String]]
            #expect(messages[0]["role"] == "system")
            #expect(messages[0]["content"]!.contains("Kubernetes"))
            #expect(messages[1]["role"] == "user")
            #expect(messages[1]["content"]!.hasPrefix("Transcript:"))
            let resp = #"{"message":{"role":"assistant","content":"Cleaned text."},"done":true}"#
            return (200, Data(resp.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        let out = try await cleaner.clean("um cleaned text", options: options)
        #expect(out == "Cleaned text.")
    }

    @Test func stripsEmptyThinkBlockFromContent() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"message":{"role":"assistant","content":"<think></think>\n\nReal output"}}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        #expect(try await cleaner.clean("x", options: options) == "Real output")
    }

    @Test func non200Throws() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        await #expect(throws: CleanupError.self) {
            _ = try await cleaner.clean("x", options: options)
        }
    }

    @Test func emptyContentThrowsBadResponse() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"message":{"role":"assistant","content":"  "}}"#.utf8)) }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        await #expect(throws: CleanupError.badResponse("empty content")) {
            _ = try await cleaner.clean("x", options: options)
        }
    }

    @Test func isAvailableTrueWhenModelListed() async {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/tags")
            return (200, Data(#"{"models":[{"name":"qwen3:4b-instruct"},{"name":"gemma4:latest"}]}"#.utf8))
        }
        #expect(await OllamaCleaner(urlSession: stubbedSession()).isAvailable() == true)
    }

    @Test func isAvailableMatchesBareNameAgainstLatestTag() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"models":[{"name":"gemma4:latest"}]}"#.utf8)) }
        let cleaner = OllamaCleaner(model: "gemma4", urlSession: stubbedSession())
        #expect(await cleaner.isAvailable() == true)
    }

    @Test func isAvailableFalseWhenModelMissingOrServerDown() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"models":[]}"#.utf8)) }
        #expect(await OllamaCleaner(urlSession: stubbedSession()).isAvailable() == false)
        StubURLProtocol.handler = { _ in (500, Data()) }
        #expect(await OllamaCleaner(urlSession: stubbedSession()).isAvailable() == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OllamaCleanerTests`
Expected: FAIL — `cannot find 'OllamaCleaner' in scope`.

- [ ] **Step 3: Write OllamaAPI.swift**

```swift
import Foundation

/// DTOs for Ollama's HTTP API (docs/api.md, verified 2026-07).
enum OllamaAPI {
    struct ChatMessage: Codable { var role: String; var content: String }
    struct ChatOptions: Codable { var temperature: Double }
    struct ChatRequest: Codable {
        var model: String
        var messages: [ChatMessage]
        var stream: Bool
        var think: Bool          // top-level (Ollama >= 0.9.0); ignored by older servers
        var keep_alive: Int      // -1 keeps the model resident
        var options: ChatOptions
    }
    struct ChatResponse: Codable {
        struct Message: Codable { var content: String }
        var message: Message
    }
    struct TagsResponse: Codable {
        struct Model: Codable { var name: String }
        var models: [Model]
    }
}
```

- [ ] **Step 4: Write OllamaCleaner.swift**

```swift
import Foundation

public final class OllamaCleaner: CleanupProvider {
    public let id = "ollama"
    private let model: String
    private let baseURL: URL
    private let urlSession: URLSession
    private let requestTimeout: TimeInterval

    public init(model: String = "qwen3:4b-instruct",
                baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                urlSession: URLSession = .shared,
                requestTimeout: TimeInterval = 4) {
        self.model = model
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
    }

    public func isAvailable() async -> Bool {
        var req = URLRequest(url: baseURL.appending(path: "api/tags"))
        req.timeoutInterval = 1  // liveness probe must be fast
        guard let (data, resp) = try? await urlSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(OllamaAPI.TagsResponse.self, from: data)
        else { return false }
        return tags.models.contains { tag in
            tag.name == model || tag.name.split(separator: ":").first.map(String.init) == model
        }
    }

    public func clean(_ text: String, options: CleanupOptions) async throws -> String {
        let body = OllamaAPI.ChatRequest(
            model: model,
            messages: [
                .init(role: "system",
                      content: PromptBuilder.instructions(level: options.level,
                                                          vocabulary: options.vocabulary)),
                .init(role: "user", content: PromptBuilder.userPrompt(for: text)),
            ],
            stream: false, think: false, keep_alive: -1,
            options: .init(temperature: 0.2))

        var req = URLRequest(url: baseURL.appending(path: "api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = requestTimeout

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw CleanupError.unavailable }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CleanupError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let decoded = try? JSONDecoder().decode(OllamaAPI.ChatResponse.self, from: data) else {
            throw CleanupError.badResponse("undecodable body")
        }
        var content = decoded.message.content
        // Older servers ignore think:false; a /no_think-style empty think block may remain.
        content = content.replacingOccurrences(
            of: #"^\s*<think>\s*</think>\s*"#, with: "", options: .regularExpression)
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw CleanupError.badResponse("empty content") }
        return content
    }
}
```

- [ ] **Step 5: Run tests until green**

Run: `swift test --filter OllamaCleanerTests`
Expected: PASS (7 tests).

- [ ] **Step 6 (optional, local only): Smoke against the real Ollama on this machine**

Run: `ollama list` — this machine has `gemma4:latest`. Then in a scratch `swift repl` or by temporarily adding a CLI hook later (Task 16 wires this properly), no action required now.

- [ ] **Step 7: Commit**

```bash
git add Sources/CleanupKit/Ollama*.swift Tests/CleanupKitTests/OllamaCleanerTests.swift
git commit -m "feat(cleanup): Ollama provider with stubbed-transport tests"
```

---

### Task 6: HotkeyKit — types + pure KeyEventInterpreter

**Files:**
- Create: `Sources/HotkeyKit/HotkeyTypes.swift`
- Create: `Sources/HotkeyKit/KeyEventInterpreter.swift`
- Test: `Tests/HotkeyKitTests/KeyEventInterpreterTests.swift`

**Interfaces:**
- Produces: `HotkeyChoice`, `HotkeyRawEvent`, `HotkeySource`, `KeyCodes`, `KeyFlags` and
  `KeyEventInterpreter` with `mutating func interpret(_ input: CGInput) -> Output` where
  `Output = (event: HotkeyRawEvent?, swallow: Bool)`. Task 11 feeds it real CGEvents; tests feed synthetic ones.

Semantics (from spec + verified research): Fn/Globe arrives as `flagsChanged` with keyCode 63 and the `maskSecondaryFn` bit (0x800000) — bit set = press, bit clear = release. Arrow/function keys also set `.maskSecondaryFn`, so ALWAYS check keyCode. If any other key goes down while the hotkey is held, the user meant a combo (Fn+arrow): emit `.comboCancelled` once and suppress the eventual `.keyUp`. Swallow (consume) only our own Fn `flagsChanged` events so the emoji picker doesn't also fire; never swallow rightCommand flags (would break ⌘-combos) or unrelated events. Esc pressed while NOT holding emits `.escapePressed` (FlowController uses it to cancel hands-free recording).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import HotkeyKit

struct KeyEventInterpreterTests {
    @Test func fnPressAndRelease() {
        var i = KeyEventInterpreter(choice: .fnKey)
        let down = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        #expect(down.event == .keyDown && down.swallow == true)
        let up = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: 0))
        #expect(up.event == .keyUp && up.swallow == true)
    }
    @Test func arrowKeySettingFnFlagIsIgnored() {
        var i = KeyEventInterpreter(choice: .fnKey)
        let out = i.interpret(.flagsChanged(keyCode: 123, flags: KeyFlags.secondaryFn)) // left arrow
        #expect(out.event == nil && out.swallow == false)
    }
    @Test func comboCancelsHoldAndSuppressesKeyUp() {
        var i = KeyEventInterpreter(choice: .fnKey)
        _ = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        let cancel = i.interpret(.keyDown(keyCode: 123, flags: KeyFlags.secondaryFn)) // Fn+left
        #expect(cancel.event == .comboCancelled && cancel.swallow == false)
        let release = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: 0))
        #expect(release.event == nil)   // keyUp suppressed after cancellation
    }
    @Test func rightCommandPressReleaseNotSwallowed() {
        var i = KeyEventInterpreter(choice: .rightCommand)
        let down = i.interpret(.flagsChanged(keyCode: KeyCodes.rightCommand, flags: KeyFlags.command))
        #expect(down.event == .keyDown && down.swallow == false)
        let up = i.interpret(.flagsChanged(keyCode: KeyCodes.rightCommand, flags: 0))
        #expect(up.event == .keyUp && up.swallow == false)
    }
    @Test func customComboPressRelease() {
        var i = KeyEventInterpreter(choice: .custom(keyCode: 49, modifierRawValue: KeyFlags.command)) // ⌘Space
        let down = i.interpret(.keyDown(keyCode: 49, flags: KeyFlags.command))
        #expect(down.event == .keyDown && down.swallow == true)
        // Release matches on keyCode even if the modifier lifted first:
        let up = i.interpret(.keyUp(keyCode: 49, flags: 0))
        #expect(up.event == .keyUp && up.swallow == true)
    }
    @Test func customComboWithoutModifierDoesNotTrigger() {
        var i = KeyEventInterpreter(choice: .custom(keyCode: 49, modifierRawValue: KeyFlags.command))
        let out = i.interpret(.keyDown(keyCode: 49, flags: 0))
        #expect(out.event == nil && out.swallow == false)
    }
    @Test func escapeWhileIdleEmitsEscapePressed() {
        var i = KeyEventInterpreter(choice: .fnKey)
        let out = i.interpret(.keyDown(keyCode: KeyCodes.escape, flags: 0))
        #expect(out.event == .escapePressed && out.swallow == false)
    }
    @Test func escapeWhileHoldingIsComboCancel() {
        var i = KeyEventInterpreter(choice: .fnKey)
        _ = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        let out = i.interpret(.keyDown(keyCode: KeyCodes.escape, flags: KeyFlags.secondaryFn))
        #expect(out.event == .comboCancelled)
    }
    @Test func repeatedFlagsChangedWhileHeldEmitsNothing() {
        var i = KeyEventInterpreter(choice: .fnKey)
        _ = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        let dup = i.interpret(.flagsChanged(keyCode: KeyCodes.fn, flags: KeyFlags.secondaryFn))
        #expect(dup.event == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyEventInterpreterTests`
Expected: FAIL — `cannot find 'KeyEventInterpreter' in scope`.

- [ ] **Step 3: Write HotkeyTypes.swift**

```swift
import Foundation

public enum HotkeyChoice: Codable, Equatable, Sendable {
    case fnKey
    case rightCommand
    case custom(keyCode: UInt16, modifierRawValue: UInt64)
}

public enum HotkeyRawEvent: Sendable, Equatable {
    case keyDown          // hotkey hold began
    case keyUp            // hotkey hold ended
    case comboCancelled   // another key pressed mid-hold (user meant Fn+arrow etc.)
    case escapePressed    // Esc pressed while hotkey not held
    case secureInputChanged(Bool)
}

public protocol HotkeySource: Sendable {
    var events: AsyncStream<HotkeyRawEvent> { get }
    func start() throws
}

public enum KeyCodes {
    public static let fn: UInt16 = 63            // kVK_Function
    public static let rightCommand: UInt16 = 54  // kVK_RightCommand
    public static let escape: UInt16 = 53        // kVK_Escape
}

public enum KeyFlags {
    public static let secondaryFn: UInt64 = 0x0080_0000  // CGEventFlags.maskSecondaryFn
    public static let command: UInt64 = 0x0010_0000      // CGEventFlags.maskCommand
    public static let option: UInt64 = 0x0008_0000       // CGEventFlags.maskAlternate
    public static let control: UInt64 = 0x0004_0000      // CGEventFlags.maskControl
    public static let shift: UInt64 = 0x0002_0000        // CGEventFlags.maskShift
}
```

- [ ] **Step 4: Write KeyEventInterpreter.swift**

```swift
import Foundation

/// Pure translator from low-level key events to hotkey semantics.
/// Owns NO timing logic — short-press and double-tap live in FlowCore.GestureMachine.
public struct KeyEventInterpreter: Sendable {
    public enum CGInput: Equatable, Sendable {
        case flagsChanged(keyCode: UInt16, flags: UInt64)
        case keyDown(keyCode: UInt16, flags: UInt64)
        case keyUp(keyCode: UInt16, flags: UInt64)
    }
    public typealias Output = (event: HotkeyRawEvent?, swallow: Bool)

    private let choice: HotkeyChoice
    private var holding = false
    private var cancelled = false

    public init(choice: HotkeyChoice) {
        self.choice = choice
    }

    public mutating func interpret(_ input: CGInput) -> Output {
        switch (choice, input) {
        // --- Fn/Globe: flagsChanged keyCode 63; bit set = press, clear = release.
        case (.fnKey, .flagsChanged(KeyCodes.fn, let flags)):
            return handleModifierEdge(bitSet: flags & KeyFlags.secondaryFn != 0, swallow: true)
        // --- Right ⌘: flagsChanged keyCode 54. Never swallow (⌘-combos must keep working).
        case (.rightCommand, .flagsChanged(KeyCodes.rightCommand, let flags)):
            return handleModifierEdge(bitSet: flags & KeyFlags.command != 0, swallow: false)
        // --- Custom combo: plain keyDown/keyUp with required modifiers.
        case (.custom(let kc, let mods), .keyDown(kc, let flags)) where flags & mods == mods && !holding:
            holding = true; cancelled = false
            return (.keyDown, true)
        case (.custom(let kc, _), .keyUp(kc, _)) where holding:
            holding = false
            return cancelled ? (nil, true) : (.keyUp, true)
        default:
            break
        }
        // Any other keyDown: combo-cancel if mid-hold; Esc signal if idle.
        if case .keyDown(let kc, _) = input {
            if holding, !cancelled {
                cancelled = true
                return (.comboCancelled, false)
            }
            if !holding, kc == KeyCodes.escape {
                return (.escapePressed, false)
            }
        }
        return (nil, false)
    }

    private mutating func handleModifierEdge(bitSet: Bool, swallow: Bool) -> Output {
        if bitSet {
            guard !holding else { return (nil, swallow) }   // repeat
            holding = true; cancelled = false
            return (.keyDown, swallow)
        } else {
            guard holding else { return (nil, false) }
            holding = false
            return cancelled ? (nil, swallow) : (.keyUp, swallow)
        }
    }
}
```

- [ ] **Step 5: Run tests until green**

Run: `swift test --filter KeyEventInterpreterTests`
Expected: PASS (9 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/HotkeyKit Tests/HotkeyKitTests
git commit -m "feat(hotkey): types + pure key-event interpreter"
```

---

### Task 7: CleanupKit — CleanupPipeline

**Files:**
- Create: `Sources/CleanupKit/CleanupPipeline.swift`
- Test: `Tests/CleanupKitTests/CleanupPipelineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–4 (`RulesCleaner`, `ReplacementEngine`, `CleanupProvider`, types).
- Produces: `CleanupPipeline(providers:timeout:)` conforming to `CleanupProcessing`. **Contract: `process` NEVER throws and never returns empty text for non-empty input** (spec §5: never block insertion on AI failure).

Behavior matrix (spec §3): `.off` → replacements only, providerID "raw". `.light` → rules + replacements, "rules". `.standard`/`.heavy` → rules, then first available provider that succeeds within `timeout` (default 4s); its output gets replacements, providerID = provider.id; every provider failing → rules text + replacements, "rules". Replacements apply at ALL levels (explicit user intent).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import CleanupKit

/// Configurable fake provider.
final class FakeProvider: CleanupProvider, @unchecked Sendable {
    let id: String
    var available = true
    var result: Result<String, CleanupError> = .success("LLM CLEANED")
    var delay: TimeInterval = 0
    private(set) var cleanCallCount = 0
    init(id: String) { self.id = id }
    func isAvailable() async -> Bool { available }
    func clean(_ text: String, options: CleanupOptions) async throws -> String {
        cleanCallCount += 1
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try result.get()
    }
}

struct CleanupPipelineTests {
    let replacements = [Replacement(spoken: "local flow", written: "LocalFlow")]

    func options(_ level: CleanupLevel) -> CleanupOptions {
        CleanupOptions(level: level, vocabulary: [])
    }

    @Test func offAppliesOnlyReplacements() async {
        let p = CleanupPipeline(providers: [FakeProvider(id: "apple-fm")])
        let r = await p.process("um the local flow app", options: options(.off), replacements: replacements)
        #expect(r.text == "um the LocalFlow app")   // fillers kept: raw mode
        #expect(r.providerID == "raw")
    }

    @Test func lightRunsRulesAndReplacementsNoLLM() async {
        let fake = FakeProvider(id: "apple-fm")
        let p = CleanupPipeline(providers: [fake])
        let r = await p.process("um the local flow app", options: options(.light), replacements: replacements)
        #expect(r.text == "The LocalFlow app")
        #expect(r.providerID == "rules")
        #expect(fake.cleanCallCount == 0)
    }

    @Test func standardUsesFirstAvailableProvider() async {
        let unavailable = FakeProvider(id: "apple-fm"); unavailable.available = false
        let ollama = FakeProvider(id: "ollama"); ollama.result = .success("Ollama cleaned local flow.")
        let p = CleanupPipeline(providers: [unavailable, ollama])
        let r = await p.process("raw", options: options(.standard), replacements: replacements)
        #expect(r.text == "Ollama cleaned LocalFlow.")   // replacements post-LLM
        #expect(r.providerID == "ollama")
        #expect(unavailable.cleanCallCount == 0)
    }

    @Test func providerErrorFallsThroughToNext() async {
        let failing = FakeProvider(id: "apple-fm"); failing.result = .failure(.refused)
        let ollama = FakeProvider(id: "ollama")
        let p = CleanupPipeline(providers: [failing, ollama])
        let r = await p.process("raw", options: options(.standard), replacements: [])
        #expect(r.providerID == "ollama")
    }

    @Test func allProvidersFailingFallsBackToRules() async {
        let a = FakeProvider(id: "apple-fm"); a.result = .failure(.unavailable)
        let b = FakeProvider(id: "ollama"); b.available = false
        let p = CleanupPipeline(providers: [a, b])
        let r = await p.process("um hello there", options: options(.standard), replacements: [])
        #expect(r.text == "Hello there")
        #expect(r.providerID == "rules")
    }

    @Test func slowProviderTimesOutAndFallsThrough() async {
        let slow = FakeProvider(id: "apple-fm"); slow.delay = 5
        let fast = FakeProvider(id: "ollama")
        let p = CleanupPipeline(providers: [slow, fast], timeout: 0.2)
        let start = Date()
        let r = await p.process("raw", options: options(.standard), replacements: [])
        #expect(r.providerID == "ollama")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func llmReturningEmptyFallsThrough() async {
        let empty = FakeProvider(id: "apple-fm"); empty.result = .success("   ")
        let p = CleanupPipeline(providers: [empty])
        let r = await p.process("um hello", options: options(.standard), replacements: [])
        #expect(r.text == "Hello")
        #expect(r.providerID == "rules")
    }

    @Test func emptyInputShortCircuits() async {
        let fake = FakeProvider(id: "apple-fm")
        let p = CleanupPipeline(providers: [fake])
        let r = await p.process("", options: options(.standard), replacements: replacements)
        #expect(r.text == "" && r.providerID == "raw")
        #expect(fake.cleanCallCount == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CleanupPipelineTests`
Expected: FAIL — `cannot find 'CleanupPipeline' in scope`.

- [ ] **Step 3: Write CleanupPipeline.swift**

```swift
import Foundation

/// Orchestrates: rules pass -> first working LLM provider (with timeout) -> replacements.
/// NEVER throws; the worst case is the rules-cleaned text (spec: never block insertion).
public struct CleanupPipeline: CleanupProcessing {
    private let providers: [any CleanupProvider]
    private let timeout: TimeInterval

    public init(providers: [any CleanupProvider], timeout: TimeInterval = 4) {
        self.providers = providers
        self.timeout = timeout
    }

    public func process(_ raw: String, options: CleanupOptions,
                        replacements: [Replacement]) async -> CleanupResult {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return CleanupResult(text: "", providerID: "raw") }

        func finish(_ text: String, _ providerID: String) -> CleanupResult {
            CleanupResult(text: ReplacementEngine.apply(replacements, to: text),
                          providerID: providerID)
        }

        switch options.level {
        case .off:
            return finish(trimmedRaw, "raw")
        case .light:
            return finish(RulesCleaner.clean(trimmedRaw), "rules")
        case .standard, .heavy:
            let ruled = RulesCleaner.clean(trimmedRaw)
            for provider in providers {
                guard await provider.isAvailable() else { continue }
                do {
                    let out = try await withTimeout(timeout) {
                        try await provider.clean(ruled, options: options)
                    }
                    let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { return finish(cleaned, provider.id) }
                } catch {
                    continue  // fall through to next provider (spec §5)
                }
            }
            return finish(ruled, "rules")
        }
    }
}

/// Races `work` against a deadline. Throws CleanupError.timedOut on expiry.
func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CleanupError.timedOut
        }
        guard let first = try await group.next() else { throw CleanupError.timedOut }
        group.cancelAll()
        return first
    }
}
```

- [ ] **Step 4: Run tests until green**

Run: `swift test --filter CleanupPipelineTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CleanupKit/CleanupPipeline.swift Tests/CleanupKitTests/CleanupPipelineTests.swift
git commit -m "feat(cleanup): never-fail cleanup pipeline with provider fallback"
```

---

### Task 8: CaptureKit — AudioData, RingBuffer, resampler, file loader

**Files:**
- Create: `Sources/CaptureKit/AudioData.swift`, `Sources/CaptureKit/RingBuffer.swift`, `Sources/CaptureKit/AudioResampler.swift`, `Sources/CaptureKit/AudioFileLoader.swift`
- Test: `Tests/CaptureKitTests/RingBufferTests.swift`, `Tests/CaptureKitTests/AudioResamplerTests.swift`, `Tests/CaptureKitTests/AudioFileLoaderTests.swift`

**Interfaces:**
- Produces: `AudioData` (see Shared Contracts), `AudioCapturing` protocol,
  `RingBuffer(capacity:)` with `write(_: [Float])` / `snapshot() -> [Float]`,
  `AudioResampler(inputFormat:)` with `process(_ buffer: AVAudioPCMBuffer) -> [Float]` (streaming-safe) and `static convertAll(_ buffer:) -> [Float]` (one-shot),
  `AudioFileLoader.load(url:) throws -> AudioData`.

- [ ] **Step 1: Write the failing RingBuffer tests**

```swift
import Testing
@testable import CaptureKit

struct RingBufferTests {
    @Test func underfilledSnapshotReturnsWhatWasWritten() {
        var rb = RingBuffer(capacity: 8)
        rb.write([1, 2, 3])
        #expect(rb.snapshot() == [1, 2, 3])
    }
    @Test func overflowKeepsNewestInOrder() {
        var rb = RingBuffer(capacity: 4)
        rb.write([1, 2, 3])
        rb.write([4, 5, 6])
        #expect(rb.snapshot() == [3, 4, 5, 6])
    }
    @Test func writeLargerThanCapacityKeepsTail() {
        var rb = RingBuffer(capacity: 3)
        rb.write([1, 2, 3, 4, 5])
        #expect(rb.snapshot() == [3, 4, 5])
    }
    @Test func emptyBufferSnapshotsEmpty() {
        #expect(RingBuffer(capacity: 4).snapshot().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RingBufferTests`
Expected: FAIL — `cannot find 'RingBuffer' in scope`.

- [ ] **Step 3: Write AudioData.swift and RingBuffer.swift**

`Sources/CaptureKit/AudioData.swift`:

```swift
import Foundation

/// Canonical audio interchange: 16 kHz mono Float32 (spec Global Constraints).
public struct AudioData: Sendable, Equatable {
    public static let sampleRate: Double = 16_000
    public var samples: [Float]
    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public init(samples: [Float]) { self.samples = samples }
}

public protocol AudioCapturing: Sendable {
    func startCapture() throws
    func stopCapture() async -> AudioData
    func cancelCapture()
    var levels: AsyncStream<Float> { get }
}
```

`Sources/CaptureKit/RingBuffer.swift`:

```swift
/// Fixed-capacity float ring buffer for the ~0.5s pre-roll that prevents
/// first-word clipping (spec §2). Not thread-safe; owner synchronizes.
public struct RingBuffer: Sendable {
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = false
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: 0, count: self.capacity)
    }

    public mutating func write(_ samples: [Float]) {
        for s in samples.suffix(capacity) {
            storage[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
            if writeIndex == 0 { filled = true }
        }
        if samples.count >= capacity { filled = true }
    }

    public func snapshot() -> [Float] {
        if !filled { return Array(storage[0..<writeIndex]) }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }
}
```

- [ ] **Step 4: Run RingBuffer tests until green**

Run: `swift test --filter RingBufferTests`
Expected: PASS (4 tests). Note: `writeLargerThanCapacityKeepsTail` exercises the `suffix(capacity)` path and `overflowKeepsNewestInOrder` the wraparound path — if either fails, fix indexing, don't loosen the test.

- [ ] **Step 5: Write the failing resampler + loader tests**

`Tests/CaptureKitTests/AudioResamplerTests.swift`:

```swift
import AVFoundation
import Testing
@testable import CaptureKit

/// 0.5s sine at `hz` in the given format.
func makeSineBuffer(sampleRate: Double, channels: AVAudioChannelCount, hz: Double = 440) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let frames = AVAudioFrameCount(sampleRate / 2)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<Int(channels) {
        let ptr = buf.floatChannelData![ch]
        for i in 0..<Int(frames) {
            ptr[i] = sinf(Float(2.0 * .pi * hz * Double(i) / sampleRate)) * 0.5
        }
    }
    return buf
}

struct AudioResamplerTests {
    @Test func oneShotConverts48kStereoTo16kMono() {
        let input = makeSineBuffer(sampleRate: 48_000, channels: 2)
        let out = AudioResampler.convertAll(input)
        // 0.5s of audio -> ~8000 samples at 16k (converter latency tolerance ±256)
        #expect(abs(out.count - 8000) < 256)
        #expect(out.contains { abs($0) > 0.1 })          // signal survived
        #expect(out.allSatisfy { $0.isFinite })
    }
    @Test func streamingConversionAccumulatesAcrossCalls() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let resampler = AudioResampler(inputFormat: format)!
        var total: [Float] = []
        for _ in 0..<4 {
            total += resampler.process(makeSineBuffer(sampleRate: 48_000, channels: 1))
        }
        // 4 × 0.5s -> ~32000 samples at 16k
        #expect(abs(total.count - 32_000) < 1024)
    }
}
```

`Tests/CaptureKitTests/AudioFileLoaderTests.swift`:

```swift
import AVFoundation
import Testing
@testable import CaptureKit

struct AudioFileLoaderTests {
    @Test func loadsWavAndResamplesTo16k() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "loader-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = makeSineBuffer(sampleRate: 44_100, channels: 1)
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)

        let audio = try AudioFileLoader.load(url: url)
        #expect(abs(audio.duration - 0.5) < 0.05)
        #expect(audio.samples.contains { abs($0) > 0.1 })
    }
    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            _ = try AudioFileLoader.load(url: URL(filePath: "/nonexistent/x.wav"))
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `swift test --filter AudioResamplerTests && swift test --filter AudioFileLoaderTests`
Expected: FAIL — `cannot find 'AudioResampler' in scope`.

- [ ] **Step 7: Write AudioResampler.swift**

```swift
import AVFoundation

/// Converts arbitrary input PCM to the canonical 16 kHz mono Float32.
public final class AudioResampler {
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioData.sampleRate,
        channels: 1, interleaved: false)!

    private let converter: AVAudioConverter
    private var pending: AVAudioPCMBuffer?

    public init?(inputFormat: AVAudioFormat) {
        guard let c = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else { return nil }
        converter = c
    }

    /// Streaming-safe: keeps converter state across calls (use .noDataNow, never .endOfStream).
    public func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        pending = buffer
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity)
        else { return [] }
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { [weak self] _, inputStatus in
            if let b = self?.pending {
                self?.pending = nil
                inputStatus.pointee = .haveData
                return b
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// One-shot conversion for whole files (flushes with .endOfStream).
    public static func convertAll(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var supplied = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
```

- [ ] **Step 8: Write AudioFileLoader.swift**

```swift
import AVFoundation

public enum AudioFileError: Error { case unreadable, emptyFile }

/// Loads any AVAudioFile-readable file into canonical AudioData (fixtures, CLI).
public enum AudioFileLoader {
    public static func load(url: URL) throws -> AudioData {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { throw AudioFileError.emptyFile }
        try file.read(into: buffer)
        let samples = AudioResampler.convertAll(buffer)
        guard !samples.isEmpty else { throw AudioFileError.unreadable }
        return AudioData(samples: samples)
    }
}
```

- [ ] **Step 9: Run all CaptureKit tests until green**

Run: `swift test --filter CaptureKitTests`
Expected: PASS (8 tests).

- [ ] **Step 10: Commit**

```bash
git add Sources/CaptureKit Tests/CaptureKitTests
git commit -m "feat(capture): audio types, ring buffer, resampler, file loader"
```

---

### Task 9: CleanupKit — AppleFMCleaner (Foundation Models)

**Files:**
- Create: `Sources/CleanupKit/AppleFMCleaner.swift`
- Test: `Tests/CleanupKitTests/AppleFMCleanerTests.swift`

**Interfaces:**
- Consumes: `CleanupProvider`, `CleanupError`, `PromptBuilder` (Tasks 2, 4).
- Produces: `AppleFMCleaner(backend:)` conforming to `CleanupProvider` (`id == "apple-fm"`), plus `func prewarm(options: CleanupOptions) async`. Internal seam `FMBackend` so unit tests never touch the real model.

Verified API facts (shipped macOS 26.5 SDK): `SystemLanguageModel(guardrails: .permissiveContentTransformations)` suppresses `guardrailViolation` for **String-generating** requests (why we don't use `@Generable`); `LanguageModelSession(model:instructions:)`; `session.prewarm()` (helps if ≥1s before use); `respond(to:options:)` → `Response<String>` with `.content`; `GenerationOptions(temperature: 0.2)`; errors are `LanguageModelSession.GenerationError` (non-frozen — `@unknown default` required): `.guardrailViolation`, `.refusal`, `.exceededContextWindowSize`, `.assetsUnavailable`, `.rateLimited`, `.concurrentRequests`, …; context window 4096 tokens; Apple guidance: fresh session per independent request.

- [ ] **Step 1: Write the failing unit tests (mock backend)**

```swift
import Testing
@testable import CleanupKit

final class MockFMBackend: FMBackend, @unchecked Sendable {
    var available = true
    var response: Result<String, CleanupError> = .success("Cleaned.")
    private(set) var lastInstructions: String?
    private(set) var lastPrompt: String?
    private(set) var prewarmCount = 0
    func isAvailable() async -> Bool { available }
    func respond(instructions: String, prompt: String, temperature: Double) async throws -> String {
        lastInstructions = instructions
        lastPrompt = prompt
        return try response.get()
    }
    func prewarm(instructions: String) async { prewarmCount += 1 }
}

struct AppleFMCleanerTests {
    let options = CleanupOptions(level: .standard, vocabulary: ["LocalFlow"])

    @Test func buildsPromptFromPromptBuilder() async throws {
        let backend = MockFMBackend()
        let cleaner = AppleFMCleaner(backend: backend)
        _ = try await cleaner.clean("um hello", options: options)
        #expect(backend.lastInstructions == PromptBuilder.instructions(level: .standard,
                                                                       vocabulary: ["LocalFlow"]))
        #expect(backend.lastPrompt == PromptBuilder.userPrompt(for: "um hello"))
    }
    @Test func trimsAndStripsWrappingQuotes() async throws {
        let backend = MockFMBackend()
        backend.response = .success("  \"Hello there.\"  ")
        let cleaner = AppleFMCleaner(backend: backend)
        #expect(try await cleaner.clean("x", options: options) == "Hello there.")
    }
    @Test func emptyModelOutputThrowsBadResponse() async {
        let backend = MockFMBackend()
        backend.response = .success("   ")
        let cleaner = AppleFMCleaner(backend: backend)
        await #expect(throws: CleanupError.badResponse("empty model output")) {
            _ = try await cleaner.clean("x", options: options)
        }
    }
    @Test func backendErrorsPropagate() async {
        let backend = MockFMBackend()
        backend.response = .failure(.refused)
        let cleaner = AppleFMCleaner(backend: backend)
        await #expect(throws: CleanupError.refused) {
            _ = try await cleaner.clean("x", options: options)
        }
    }
    @Test func availabilityDelegatesToBackend() async {
        let backend = MockFMBackend()
        backend.available = false
        #expect(await AppleFMCleaner(backend: backend).isAvailable() == false)
    }
    @Test func prewarmForwardsBuiltInstructions() async {
        let backend = MockFMBackend()
        await AppleFMCleaner(backend: backend).prewarm(options: options)
        #expect(backend.prewarmCount == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppleFMCleanerTests`
Expected: FAIL — `cannot find 'AppleFMCleaner' in scope`.

- [ ] **Step 3: Write AppleFMCleaner.swift**

```swift
import Foundation
import FoundationModels

/// Seam so unit tests never touch the real on-device model.
protocol FMBackend: Sendable {
    func isAvailable() async -> Bool
    /// Throws CleanupError only (maps FoundationModels errors internally).
    func respond(instructions: String, prompt: String, temperature: Double) async throws -> String
    func prewarm(instructions: String) async
}

public actor AppleFMCleaner: CleanupProvider {
    public nonisolated let id = "apple-fm"
    private let backend: any FMBackend

    public init() { self.backend = SystemFMBackend() }
    init(backend: any FMBackend) { self.backend = backend }

    public func isAvailable() async -> Bool { await backend.isAvailable() }

    public func clean(_ text: String, options: CleanupOptions) async throws -> String {
        let out = try await backend.respond(
            instructions: PromptBuilder.instructions(level: options.level,
                                                     vocabulary: options.vocabulary),
            prompt: PromptBuilder.userPrompt(for: text),
            temperature: 0.2)
        var cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Small models occasionally wrap output in quotes despite instructions.
        if cleaned.count > 1, cleaned.hasPrefix("\""), cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleaned.isEmpty else { throw CleanupError.badResponse("empty model output") }
        return cleaned
    }

    /// Call after launch and whenever cleanup settings change (FlowController does this).
    public func prewarm(options: CleanupOptions) async {
        await backend.prewarm(instructions: PromptBuilder.instructions(
            level: options.level, vocabulary: options.vocabulary))
    }
}

/// Real backend. "Next session" pattern: keep ONE fresh, prewarmed, unused session ready;
/// consume it per request (Apple guidance: new session per independent request — the 4096-token
/// window includes the whole transcript, which only grows).
actor SystemFMBackend: FMBackend {
    private var prepared: (instructions: String, session: LanguageModelSession)?

    private static func makeSession(instructions: String) -> LanguageModelSession {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: instructions)
    }

    func isAvailable() async -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    func prewarm(instructions: String) async {
        let session = Self.makeSession(instructions: instructions)
        session.prewarm()
        prepared = (instructions, session)
    }

    func respond(instructions: String, prompt: String, temperature: Double) async throws -> String {
        let session: LanguageModelSession
        if let p = prepared, p.instructions == instructions, !p.session.isResponding {
            session = p.session
        } else {
            session = Self.makeSession(instructions: instructions)
        }
        prepared = nil
        defer { // Prepare the next one so the following dictation gets a warm start.
            let next = Self.makeSession(instructions: instructions)
            next.prewarm()
            prepared = (instructions, next)
        }
        do {
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(temperature: temperature))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:            throw CleanupError.refused
            case .assetsUnavailable:                       throw CleanupError.unavailable
            case .exceededContextWindowSize:               throw CleanupError.badResponse("context window exceeded")
            case .rateLimited, .concurrentRequests:        throw CleanupError.unavailable
            default:                                       throw CleanupError.badResponse(String(describing: error))
            @unknown default:                              throw CleanupError.badResponse(String(describing: error))
            }
        }
    }
}
```

Note: `default:` + `@unknown default:` both present is intentional — `GenerationError` has more cases (`.unsupportedGuide`, `.unsupportedLanguageOrLocale`, `.decodingFailure`) that `default:` covers, and the enum is non-frozen. If the compiler warns that `@unknown default` is unreachable, drop the plain `default:` and enumerate the remaining cases explicitly.

- [ ] **Step 4: Run unit tests until green**

Run: `swift test --filter AppleFMCleanerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Add the runtime-gated integration test**

Append to `Tests/CleanupKitTests/AppleFMCleanerTests.swift`:

```swift
import FoundationModels

/// Real on-device model. Runs only where Apple Intelligence is on (skipped in CI).
@Suite struct AppleFMIntegrationTests {
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func realModelCleansDictatedText() async throws {
        let cleaner = AppleFMCleaner()
        let out = try await cleaner.clean(
            "um so i think we should uh no wait we should definitely ship on friday",
            options: CleanupOptions(level: .standard, vocabulary: []))
        #expect(!out.isEmpty)
        #expect(!out.lowercased().contains("um"))
        #expect(out.lowercased().contains("friday"))
    }
}
```

- [ ] **Step 6: Run the integration test on this machine**

Run: `swift test --filter AppleFMIntegrationTests`
Expected: PASS if Apple Intelligence is enabled on this Mac; SKIPPED otherwise (both acceptable; note which happened in the task report).

- [ ] **Step 7: Commit**

```bash
git add Sources/CleanupKit/AppleFMCleaner.swift Tests/CleanupKitTests/AppleFMCleanerTests.swift
git commit -m "feat(cleanup): Apple Foundation Models provider with prewarmed next-session pattern"
```

---

### Task 10: FlowCore — GestureMachine (pure reducer)

**Files:**
- Create: `Sources/FlowCore/GestureMachine.swift`
- Test: `Tests/FlowCoreTests/GestureMachineTests.swift`

**Interfaces:**
- Produces: `GestureMachine` — ALL press/tap timing semantics live here (the interpreter from Task 6 owns none). FlowController (Task 17) feeds it inputs with timestamps and executes returned effects.

Semantics (spec §3, timing constants from Global Constraints): hold ≥0.3s then release → process. Release <0.3s → wait 0.4s for a second press: second press → hands-free recording (capture keeps running from the FIRST press; VAD trims the gap); window expires → discard as accidental tap. In hands-free, the next full tap (down+up) stops and processes. Esc or combo-cancel discards. Cap timer fires → process what we have.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import FlowCore

struct GestureMachineTests {
    func machine(handsFree: Bool = true) -> GestureMachine {
        GestureMachine(handsFreeEnabled: handsFree)
    }

    @Test func holdAndReleaseProcesses() {
        var m = machine()
        #expect(m.handle(.keyDown(10.0)) == [.startCapture])
        #expect(m.handle(.keyUp(10.5)) == [.stopAndProcess])   // 0.5s ≥ 0.3s
        #expect(m.state == .idle)
    }
    @Test func shortPressEntersTapPendingThenDiscardsOnTimer() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.keyUp(10.1)) == [.scheduleDoubleTapTimer])  // 0.1s < 0.3s
        #expect(m.state == .tapPending(tapEnd: 10.1))
        #expect(m.handle(.doubleTapTimerFired(10.55)) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func shortPressWithHandsFreeDisabledDiscardsImmediately() {
        var m = machine(handsFree: false)
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.keyUp(10.1)) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func doubleTapEntersHandsFree() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        _ = m.handle(.keyUp(10.1))
        #expect(m.handle(.keyDown(10.3)) == [])                 // within 0.4s window
        #expect(m.state == .handsFreeRecording)
        #expect(m.handle(.keyUp(10.4)) == [])                   // release of 2nd tap ignored
        #expect(m.state == .handsFreeRecording)
    }
    @Test func tapInHandsFreeStopsAndProcesses() {
        var m = machine()
        _ = m.handle(.keyDown(10.0)); _ = m.handle(.keyUp(10.1))
        _ = m.handle(.keyDown(10.3)); _ = m.handle(.keyUp(10.4))   // now hands-free
        #expect(m.handle(.keyDown(20.0)) == [])
        #expect(m.state == .handsFreeStopPending)
        #expect(m.handle(.keyUp(20.1)) == [.stopAndProcess])
        #expect(m.state == .idle)
    }
    @Test func lateDoubleTapTimerInHandsFreeIsIgnored() {
        var m = machine()
        _ = m.handle(.keyDown(10.0)); _ = m.handle(.keyUp(10.1))
        _ = m.handle(.keyDown(10.3))                               // hands-free
        #expect(m.handle(.doubleTapTimerFired(10.5)) == [])        // stale timer
        #expect(m.state == .handsFreeRecording)
    }
    @Test func escapeDiscardsWhileHoldRecording() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.escape) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func escapeDiscardsWhileHandsFree() {
        var m = machine()
        _ = m.handle(.keyDown(10.0)); _ = m.handle(.keyUp(10.1)); _ = m.handle(.keyDown(10.3))
        #expect(m.handle(.escape) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func comboCancelDiscards() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.comboCancelled) == [.discardCapture])
        #expect(m.state == .idle)
    }
    @Test func capTimerProcessesWhileHoldRecording() {
        var m = machine()
        _ = m.handle(.keyDown(10.0))
        #expect(m.handle(.capTimerFired) == [.stopAndProcess])
        #expect(m.state == .idle)
    }
    @Test func capTimerProcessesWhileHandsFree() {
        var m = machine()
        _ = m.handle(.keyDown(10.0)); _ = m.handle(.keyUp(10.1)); _ = m.handle(.keyDown(10.3))
        #expect(m.handle(.capTimerFired) == [.stopAndProcess])
    }
    @Test func inputsInIdleAreIgnored() {
        var m = machine()
        #expect(m.handle(.keyUp(1)) == [])
        #expect(m.handle(.escape) == [])
        #expect(m.handle(.capTimerFired) == [])
        #expect(m.handle(.doubleTapTimerFired(1)) == [])
        #expect(m.state == .idle)
    }
    @Test func isRecordingReflectsState() {
        var m = machine()
        #expect(m.isRecording == false)
        _ = m.handle(.keyDown(10.0))
        #expect(m.isRecording == true)
        #expect(m.isHandsFree == false)
        _ = m.handle(.keyUp(10.1)); _ = m.handle(.keyDown(10.3))
        #expect(m.isRecording == true)
        #expect(m.isHandsFree == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GestureMachineTests`
Expected: FAIL — `cannot find 'GestureMachine' in scope`.

- [ ] **Step 3: Write GestureMachine.swift**

```swift
import Foundation

/// Pure reducer for the push-to-talk / hands-free gesture protocol.
/// Timestamps are supplied by the caller (testable); no clocks or timers inside.
public struct GestureMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case holdRecording(start: TimeInterval)
        case tapPending(tapEnd: TimeInterval)     // short press; waiting for possible 2nd tap
        case handsFreeRecording
        case handsFreeStopPending                  // stop-tap is down, waiting for its release
    }
    public enum Input: Equatable, Sendable {
        case keyDown(TimeInterval)
        case keyUp(TimeInterval)
        case escape
        case comboCancelled
        case doubleTapTimerFired(TimeInterval)
        case capTimerFired
    }
    public enum Effect: Equatable, Sendable {
        case startCapture
        case stopAndProcess
        case discardCapture
        case scheduleDoubleTapTimer   // fire after doubleTapWindow
    }

    public private(set) var state: State = .idle
    public let shortPressThreshold: TimeInterval
    public let doubleTapWindow: TimeInterval
    public let handsFreeEnabled: Bool

    public var isRecording: Bool {
        switch state {
        case .holdRecording, .tapPending, .handsFreeRecording, .handsFreeStopPending: return true
        case .idle: return false
        }
    }
    public var isHandsFree: Bool {
        switch state {
        case .handsFreeRecording, .handsFreeStopPending: return true
        default: return false
        }
    }

    public init(shortPressThreshold: TimeInterval = 0.3,
                doubleTapWindow: TimeInterval = 0.4,
                handsFreeEnabled: Bool = true) {
        self.shortPressThreshold = shortPressThreshold
        self.doubleTapWindow = doubleTapWindow
        self.handsFreeEnabled = handsFreeEnabled
    }

    public mutating func handle(_ input: Input) -> [Effect] {
        switch (state, input) {
        case (.idle, .keyDown(let t)):
            state = .holdRecording(start: t)
            return [.startCapture]

        case (.holdRecording(let start), .keyUp(let t)):
            if t - start >= shortPressThreshold {
                state = .idle
                return [.stopAndProcess]
            }
            if handsFreeEnabled {
                state = .tapPending(tapEnd: t)
                return [.scheduleDoubleTapTimer]
            }
            state = .idle
            return [.discardCapture]

        case (.tapPending(let tapEnd), .doubleTapTimerFired(let t)) where t - tapEnd >= doubleTapWindow - 0.001:
            state = .idle
            return [.discardCapture]

        case (.tapPending, .keyDown):
            state = .handsFreeRecording   // capture has been running since the first press
            return []

        case (.handsFreeRecording, .keyDown):
            state = .handsFreeStopPending
            return []

        case (.handsFreeStopPending, .keyUp):
            state = .idle
            return [.stopAndProcess]

        case (.holdRecording, .capTimerFired),
             (.tapPending, .capTimerFired),
             (.handsFreeRecording, .capTimerFired),
             (.handsFreeStopPending, .capTimerFired):
            state = .idle
            return [.stopAndProcess]

        case (.holdRecording, .escape), (.holdRecording, .comboCancelled),
             (.tapPending, .escape), (.tapPending, .comboCancelled),
             (.handsFreeRecording, .escape), (.handsFreeRecording, .comboCancelled),
             (.handsFreeStopPending, .escape), (.handsFreeStopPending, .comboCancelled):
            state = .idle
            return [.discardCapture]

        default:
            return []   // ignore (incl. stale doubleTapTimerFired in any other state)
        }
    }
}
```

- [ ] **Step 4: Run tests until green**

Run: `swift test --filter GestureMachineTests`
Expected: PASS (13 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowCore/GestureMachine.swift Tests/FlowCoreTests/GestureMachineTests.swift
git commit -m "feat(flow): pure gesture state machine (hold, double-tap hands-free, cancel, cap)"
```

---

### Task 11: HotkeyKit — EventTapHotkeySource + Permissions

**Files:**
- Create: `Sources/HotkeyKit/EventTapHotkeySource.swift`
- Create: `Sources/HotkeyKit/Permissions.swift`
- Test: build-only here; live verification via `localflow-cli hotkey` (Task 16) and the manual matrix (Task 23) — a CGEventTap cannot run without the Accessibility grant, which unit tests don't have.

**Interfaces:**
- Consumes: `KeyEventInterpreter`, `HotkeyChoice`, `HotkeyRawEvent`, `HotkeySource` (Task 6).
- Produces: `EventTapHotkeySource(choice:)` conforming to `HotkeySource` (+ `updateChoice(_:)`), `Permissions.accessibilityGranted`, `Permissions.requestAccessibility()`, `Permissions.isSecureInputActive`.

Verified facts: active tap (`.defaultTap`) needs Accessibility only (no Input Monitoring); callback must handle `.tapDisabledByTimeout` / `.tapDisabledByUserInput` by re-enabling; returning `nil` from the callback swallows the event; dev-build gotcha — TCC grants attach to the code signature, so re-signing between builds can silently kill the tap.

- [ ] **Step 1: Write Permissions.swift**

```swift
import ApplicationServices
import Carbon.HIToolbox

public enum Permissions {
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt directing the user to System Settings.
    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// True while any process holds Secure Event Input (password fields,
    /// terminals with Secure Keyboard Entry). Event taps go deaf during it (spec §5).
    public static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Name of the app holding Secure Event Input, when determinable (spec §5:
    /// tell the user WHICH app). Returns nil when secure input is off.
    public static func secureInputAppName() -> String? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = dict["kCGSSessionSecureInputPID"] as? Int32 else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }
}
```

Add `import AppKit` at the top of `Permissions.swift` (for `NSRunningApplication`).

- [ ] **Step 2: Write EventTapHotkeySource.swift**

```swift
import AppKit
import CoreGraphics

/// Owns the CGEventTap. All interpretation is delegated to KeyEventInterpreter;
/// this class only bridges CGEvents in and HotkeyRawEvents out.
public final class EventTapHotkeySource: HotkeySource, @unchecked Sendable {
    public let events: AsyncStream<HotkeyRawEvent>
    private let continuation: AsyncStream<HotkeyRawEvent>.Continuation
    private let lock = NSLock()
    private var interpreter: KeyEventInterpreter
    private var tap: CFMachPort?
    private var secureInputTimer: Timer?
    private var lastSecureInput = false

    public init(choice: HotkeyChoice) {
        self.interpreter = KeyEventInterpreter(choice: choice)
        (events, continuation) = AsyncStream.makeStream(of: HotkeyRawEvent.self)
    }

    public func updateChoice(_ choice: HotkeyChoice) {
        lock.lock(); defer { lock.unlock() }
        interpreter = KeyEventInterpreter(choice: choice)
    }

    public enum TapError: Error { case creationFailed /* Accessibility not granted, usually */ }

    public func start() throws {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,             // active: lets us swallow the Fn press
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let source = Unmanaged<EventTapHotkeySource>
                    .fromOpaque(userInfo!).takeUnretainedValue()
                return source.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { throw TapError.creationFailed }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Poll Secure Event Input (no notification API exists for it).
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let active = Permissions.isSecureInputActive
            if active != self.lastSecureInput {
                self.lastSecureInput = active
                self.continuation.yield(.secureInputChanged(active))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        secureInputTimer = timer
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables taps that stall or after user-input protection; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let input: KeyEventInterpreter.CGInput
        switch type {
        case .flagsChanged: input = .flagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown:      input = .keyDown(keyCode: keyCode, flags: flags)
        case .keyUp:        input = .keyUp(keyCode: keyCode, flags: flags)
        default:            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let output = interpreter.interpret(input)
        lock.unlock()
        if let e = output.event { continuation.yield(e) }
        return output.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
```

Keep the callback trivially fast (interpret + yield only) — a slow callback triggers `tapDisabledByTimeout` and lags ALL keyboard input system-wide.

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (no warnings in HotkeyKit).

- [ ] **Step 4: Commit**

```bash
git add Sources/HotkeyKit
git commit -m "feat(hotkey): CGEventTap source with auto re-enable + secure-input watcher"
```

---

### Task 12: InsertKit — strategies, chunker, pasteboard hygiene, inserter

**Files:**
- Create: `Sources/InsertKit/InsertionTypes.swift`, `Sources/InsertKit/StrategyTable.swift`, `Sources/InsertKit/UnicodeChunker.swift`, `Sources/InsertKit/PasteboardSnapshot.swift`, `Sources/InsertKit/FrontmostApp.swift`, `Sources/InsertKit/TextInserter.swift`
- Test: `Tests/InsertKitTests/StrategyTableTests.swift`, `Tests/InsertKitTests/UnicodeChunkerTests.swift`, `Tests/InsertKitTests/PasteboardSnapshotTests.swift`

**Interfaces:**
- Produces: `InsertionStrategy`, `InsertionOutcome`, `TextInserting` (Shared Contracts); `StrategyTable(overrides:)` with `strategy(for bundleID: String?) -> InsertionStrategy`; `UnicodeChunker.chunks(of:maxUTF16PerChunk:) -> [String]`; `PasteboardSnapshot.capture(from:)` / `restore(to:)`; `FrontmostApp.bundleID() -> String?`; `TextInserter(table:)` conforming to `TextInserting`.

Verified facts: paste-swap + synthetic ⌘V is the universal default; AX `kAXSelectedTextAttribute` works in native Cocoa apps but desyncs Chromium/Electron and fails in terminals; `CGEventKeyboardSetUnicodeString` truncates ~20 UTF-16 units per event (we chunk at 18); mark transient pastes with `org.nspasteboard.TransientType`; restore the clipboard after 0.3s.

- [ ] **Step 1: Write the failing tests**

`Tests/InsertKitTests/StrategyTableTests.swift`:

```swift
import Testing
@testable import InsertKit

struct StrategyTableTests {
    @Test func unknownAppDefaultsToPasteSwap() {
        #expect(StrategyTable().strategy(for: "com.example.unknown") == .pasteSwap)
    }
    @Test func nilBundleIDDefaultsToPasteSwap() {
        #expect(StrategyTable().strategy(for: nil) == .pasteSwap)
    }
    @Test func curatedNativeAppsUseAX() {
        let t = StrategyTable()
        #expect(t.strategy(for: "com.apple.TextEdit") == .axSelectedText)
        #expect(t.strategy(for: "com.apple.Notes") == .axSelectedText)
    }
    @Test func overridesBeatCuratedDefaults() {
        let t = StrategyTable(overrides: ["com.apple.TextEdit": .typedUnicode])
        #expect(t.strategy(for: "com.apple.TextEdit") == .typedUnicode)
    }
}
```

`Tests/InsertKitTests/UnicodeChunkerTests.swift`:

```swift
import Testing
@testable import InsertKit

struct UnicodeChunkerTests {
    @Test func shortStringIsSingleChunk() {
        #expect(UnicodeChunker.chunks(of: "hello") == ["hello"])
    }
    @Test func chunksRespectUTF16Limit() {
        let text = String(repeating: "a", count: 50)
        let chunks = UnicodeChunker.chunks(of: text, maxUTF16PerChunk: 18)
        #expect(chunks.allSatisfy { $0.utf16.count <= 18 })
        #expect(chunks.joined() == text)
    }
    @Test func neverSplitsEmoji() {
        let text = String(repeating: "👩‍👩‍👧‍👦", count: 10)   // 11 UTF-16 units each
        let chunks = UnicodeChunker.chunks(of: text, maxUTF16PerChunk: 18)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 18 })
    }
    @Test func emptyStringYieldsNoChunks() {
        #expect(UnicodeChunker.chunks(of: "") == [])
    }
}
```

`Tests/InsertKitTests/PasteboardSnapshotTests.swift`:

```swift
import AppKit
import Testing
@testable import InsertKit

struct PasteboardSnapshotTests {
    // A named pasteboard so tests NEVER touch the user's real clipboard.
    @Test func capturesAndRestoresStringContent() {
        let pb = NSPasteboard(name: NSPasteboard.Name("localflow-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pb)
        pb.clearContents()
        pb.setString("transient transcript", forType: .string)

        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "original")
    }
    @Test func restoringEmptyPasteboardClearsIt() {
        let pb = NSPasteboard(name: NSPasteboard.Name("localflow-test-\(UUID().uuidString)"))
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pb)
        pb.setString("junk", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InsertKitTests`
Expected: FAIL — types not found.

- [ ] **Step 3: Write the five implementation files**

`Sources/InsertKit/InsertionTypes.swift`:

```swift
public enum InsertionStrategy: String, Codable, Sendable {
    case axSelectedText   // Accessibility API — native Cocoa apps only
    case pasteSwap        // clipboard swap + synthetic ⌘V — universal default
    case typedUnicode     // chunked CGEventKeyboardSetUnicodeString — last resort
}

public enum InsertionOutcome: Equatable, Sendable {
    case inserted(InsertionStrategy)
    case failedTextOnClipboard   // couldn't insert; transcript left on the clipboard
}

public protocol TextInserting: Sendable {
    func insert(_ text: String, bundleID: String?) async -> InsertionOutcome
}
```

`Sources/InsertKit/StrategyTable.swift`:

```swift
/// Per-app insertion strategy. Curated list is deliberately small: AX only where
/// verified reliable; EVERYTHING unknown gets pasteSwap (spec §3).
public struct StrategyTable: Sendable {
    public static let curatedDefaults: [String: InsertionStrategy] = [
        "com.apple.TextEdit": .axSelectedText,
        "com.apple.Notes": .axSelectedText,
        "com.apple.Stickies": .axSelectedText,
    ]
    private let overrides: [String: InsertionStrategy]

    public init(overrides: [String: InsertionStrategy] = [:]) {
        self.overrides = overrides
    }
    public func strategy(for bundleID: String?) -> InsertionStrategy {
        guard let id = bundleID else { return .pasteSwap }
        return overrides[id] ?? Self.curatedDefaults[id] ?? .pasteSwap
    }
}
```

`Sources/InsertKit/UnicodeChunker.swift`:

```swift
/// CGEventKeyboardSetUnicodeString silently truncates around 20 UTF-16 units
/// per event — chunk at 18, never splitting a grapheme cluster.
public enum UnicodeChunker {
    public static func chunks(of text: String, maxUTF16PerChunk: Int = 18) -> [String] {
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for ch in text {
            let units = ch.utf16.count
            if currentUnits + units > maxUTF16PerChunk, !current.isEmpty {
                result.append(current)
                current = ""; currentUnits = 0
            }
            current.append(ch)
            currentUnits += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
```

`Sources/InsertKit/PasteboardSnapshot.swift`:

```swift
import AppKit

/// Full-fidelity clipboard save/restore around a paste-swap.
public struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    public static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
        return PasteboardSnapshot(items: items)
    }

    public func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
```

`Sources/InsertKit/FrontmostApp.swift`:

```swift
import AppKit

public enum FrontmostApp {
    public static func bundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
```

- [ ] **Step 4: Write TextInserter.swift**

```swift
import AppKit
import ApplicationServices
import CoreGraphics

public final class TextInserter: TextInserting, @unchecked Sendable {
    private let table: StrategyTable
    private let clipboardRestoreDelay: TimeInterval

    public init(table: StrategyTable = StrategyTable(), clipboardRestoreDelay: TimeInterval = 0.3) {
        self.table = table
        self.clipboardRestoreDelay = clipboardRestoreDelay
    }

    public func insert(_ text: String, bundleID: String?) async -> InsertionOutcome {
        switch table.strategy(for: bundleID) {
        case .axSelectedText:
            if await insertViaAX(text) { return .inserted(.axSelectedText) }
            // AX failed (focus element refused) — fall through to the universal path.
            return await pasteSwap(text)
        case .pasteSwap:
            return await pasteSwap(text)
        case .typedUnicode:
            await typeUnicode(text)
            return .inserted(.typedUnicode)
        }
    }

    // MARK: AX — clean insertion at the caret, no clipboard, native apps only.
    @MainActor
    private func insertViaAX(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return false }
        let ax = unsafeDowncast(element as AnyObject, to: AXUIElement.self)
        // Setting kAXSelectedTextAttribute replaces the selection (or inserts at the caret).
        return AXUIElementSetAttributeValue(ax,
                kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    // MARK: Paste swap — snapshot clipboard, transient paste, ⌘V, restore.
    private func pasteSwap(_ text: String) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers (Raycast, Maccy…) honor this and skip the entry.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        guard postCmdV() else {
            // Could not synthesize the keystroke: leave transcript on the clipboard (spec §5).
            return .failedTextOnClipboard
        }
        try? await Task.sleep(for: .seconds(clipboardRestoreDelay))
        snapshot.restore(to: pasteboard)
        return .inserted(.pasteSwap)
    }

    private func postCmdV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),  // kVK_ANSI_V
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: Typed unicode — layout-independent, chunked, slow. Last resort.
    private func typeUnicode(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for chunk in UnicodeChunker.chunks(of: text) {
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(8))   // pacing: fast posting drops chars
        }
    }
}
```

- [ ] **Step 5: Run tests until green**

Run: `swift test --filter InsertKitTests`
Expected: PASS (10 tests). The `TextInserter` posting paths are exercised manually via `localflow-cli insert` (Task 16) and the manual matrix.

- [ ] **Step 6: Commit**

```bash
git add Sources/InsertKit Tests/InsertKitTests
git commit -m "feat(insert): strategy table, chunker, clipboard hygiene, inserter"
```

---

### Task 13: Persistence — settings, dictionary, history stores

**Files:**
- Create: `Sources/Persistence/AppSettings.swift`, `Sources/Persistence/SettingsStore.swift`, `Sources/Persistence/DictionaryStore.swift`, `Sources/Persistence/HistoryStore.swift`
- Test: `Tests/PersistenceTests/SettingsStoreTests.swift`, `Tests/PersistenceTests/DictionaryStoreTests.swift`, `Tests/PersistenceTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: `CleanupLevel`, `Replacement` (CleanupKit), `HotkeyChoice` (HotkeyKit).
- Produces: `AppSettings` (fields below), `HistoryEntry` (Shared Contracts), and three `@Observable` stores: `SettingsStore(directory:)` (`.settings`, auto-saves on change via `update(_:)`), `DictionaryStore(directory:)` (`.vocabulary`, `.replacements`, `add/remove/save`), `HistoryStore(directory:)` (`.entries`, `add(_:)`, `clear()`, `isEnabled`, `retentionLimit`).
- All stores: JSON(-L) files under the given directory; corrupt/missing files → defaults, never crash. Default directory helper: `PersistenceLocation.applicationSupport()` → `~/Library/Application Support/LocalFlow/`.

- [ ] **Step 1: Write the failing tests**

`Tests/PersistenceTests/SettingsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Persistence
import CleanupKit
import HotkeyKit

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "localflow-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct SettingsStoreTests {
    @Test func freshStoreHasDefaults() {
        let store = SettingsStore(directory: tempDir())
        #expect(store.settings == AppSettings())
        #expect(store.settings.cleanupLevel == .standard)
        #expect(store.settings.hotkey == .fnKey)
        #expect(store.settings.historyRetention == 100)
    }
    @Test func updatePersistsAcrossReload() {
        let dir = tempDir()
        let store = SettingsStore(directory: dir)
        var s = store.settings
        s.cleanupLevel = .heavy
        s.hotkey = .rightCommand
        store.update(s)
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.cleanupLevel == .heavy)
        #expect(reloaded.settings.hotkey == .rightCommand)
    }
    @Test func corruptFileFallsBackToDefaults() throws {
        let dir = tempDir()
        try Data("not json".utf8).write(to: dir.appending(path: "settings.json"))
        #expect(SettingsStore(directory: dir).settings == AppSettings())
    }
    @Test func decodingToleratesMissingKeys() throws {
        let dir = tempDir()
        try Data(#"{"cleanupLevel":"light"}"#.utf8).write(to: dir.appending(path: "settings.json"))
        let store = SettingsStore(directory: dir)
        #expect(store.settings.cleanupLevel == .light)     // provided key honored
        #expect(store.settings.historyRetention == 100)    // missing keys -> defaults
    }
}
```

`Tests/PersistenceTests/DictionaryStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Persistence
import CleanupKit

struct DictionaryStoreTests {
    @Test func startsEmptyAndPersists() {
        let dir = tempDir()
        let store = DictionaryStore(directory: dir)
        #expect(store.vocabulary.isEmpty && store.replacements.isEmpty)
        store.addVocabulary("Kubernetes")
        store.addReplacement(Replacement(spoken: "local flow", written: "LocalFlow"))
        let reloaded = DictionaryStore(directory: dir)
        #expect(reloaded.vocabulary == ["Kubernetes"])
        #expect(reloaded.replacements == [Replacement(spoken: "local flow", written: "LocalFlow")])
    }
    @Test func vocabularyDeduplicatesCaseInsensitively() {
        let store = DictionaryStore(directory: tempDir())
        store.addVocabulary("Kubernetes")
        store.addVocabulary("kubernetes")
        #expect(store.vocabulary.count == 1)
    }
    @Test func removeWorks() {
        let store = DictionaryStore(directory: tempDir())
        store.addVocabulary("Zig")
        store.removeVocabulary("Zig")
        #expect(store.vocabulary.isEmpty)
    }
    @Test func exportImportRoundTrips() throws {
        let a = DictionaryStore(directory: tempDir())
        a.addVocabulary("Kubernetes")
        a.addReplacement(Replacement(spoken: "eng standup", written: "Engineering Standup"))
        let b = DictionaryStore(directory: tempDir())
        try b.importData(a.exportData())
        #expect(b.vocabulary == a.vocabulary)
        #expect(b.replacements == a.replacements)
    }
    @Test func importOfGarbageThrowsAndLeavesStoreIntact() {
        let store = DictionaryStore(directory: tempDir())
        store.addVocabulary("Keep")
        #expect(throws: (any Error).self) { try store.importData(Data("nope".utf8)) }
        #expect(store.vocabulary == ["Keep"])
    }
}
```

`Tests/PersistenceTests/HistoryStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Persistence

struct HistoryStoreTests {
    func entry(_ n: Int) -> HistoryEntry {
        HistoryEntry(timestamp: Date(timeIntervalSince1970: Double(n)),
                     rawText: "raw \(n)", cleanedText: "clean \(n)",
                     appBundleID: "com.apple.Notes", providerID: "apple-fm")
    }
    @Test func addsAndPersists() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        store.add(entry(1)); store.add(entry(2))
        let reloaded = HistoryStore(directory: dir)
        #expect(reloaded.entries.count == 2)
        #expect(reloaded.entries.last?.cleanedText == "clean 2")
    }
    @Test func retentionTrimsOldest() {
        let store = HistoryStore(directory: tempDir())
        store.retentionLimit = 3
        for n in 1...5 { store.add(entry(n)) }
        #expect(store.entries.map(\.rawText) == ["raw 3", "raw 4", "raw 5"])
    }
    @Test func disabledStoreRecordsNothing() {
        let store = HistoryStore(directory: tempDir())
        store.isEnabled = false
        store.add(entry(1))
        #expect(store.entries.isEmpty)
    }
    @Test func clearRemovesEverythingIncludingOnDisk() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        store.add(entry(1))
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(HistoryStore(directory: dir).entries.isEmpty)
    }
    @Test func corruptLinesAreSkipped() throws {
        let dir = tempDir()
        let good = try String(data: JSONEncoder().encode(entry(1)), encoding: .utf8)!
        try Data("garbage\n\(good)\n".utf8).write(to: dir.appending(path: "history.jsonl"))
        #expect(HistoryStore(directory: dir).entries.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PersistenceTests`
Expected: FAIL — types not found.

- [ ] **Step 3: Write AppSettings.swift**

```swift
import Foundation
import CleanupKit
import HotkeyKit

public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: HotkeyChoice = .fnKey
    public var handsFreeEnabled: Bool = true
    public var cleanupLevel: CleanupLevel = .standard
    public var languageOverride: String? = nil      // nil = auto (Parakeet v3 auto-detects)
    public var microphoneUID: String? = nil         // nil = system default input
    public var ollamaEnabled: Bool = true
    public var ollamaModel: String = "qwen3:4b-instruct"
    public var historyEnabled: Bool = true
    public var historyRetention: Int = 100
    public var launchAtLogin: Bool = false

    public init() {}

    // Tolerant decoding: any missing/new key falls back to its default so
    // settings files survive app upgrades in both directions. Note the
    // .flatMap unwrap: `try?` + `decodeIfPresent` yields a double optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        hotkey           = (try? c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)).flatMap { $0 } ?? d.hotkey
        handsFreeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .handsFreeEnabled)).flatMap { $0 } ?? d.handsFreeEnabled
        cleanupLevel     = (try? c.decodeIfPresent(CleanupLevel.self, forKey: .cleanupLevel)).flatMap { $0 } ?? d.cleanupLevel
        languageOverride = (try? c.decodeIfPresent(String.self, forKey: .languageOverride)).flatMap { $0 }
        microphoneUID    = (try? c.decodeIfPresent(String.self, forKey: .microphoneUID)).flatMap { $0 }
        ollamaEnabled    = (try? c.decodeIfPresent(Bool.self, forKey: .ollamaEnabled)).flatMap { $0 } ?? d.ollamaEnabled
        ollamaModel      = (try? c.decodeIfPresent(String.self, forKey: .ollamaModel)).flatMap { $0 } ?? d.ollamaModel
        historyEnabled   = (try? c.decodeIfPresent(Bool.self, forKey: .historyEnabled)).flatMap { $0 } ?? d.historyEnabled
        historyRetention = (try? c.decodeIfPresent(Int.self, forKey: .historyRetention)).flatMap { $0 } ?? d.historyRetention
        launchAtLogin    = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)).flatMap { $0 } ?? d.launchAtLogin
    }
}
```

```swift
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var rawText: String
    public var cleanedText: String
    public var appBundleID: String?
    public var providerID: String
    public init(timestamp: Date, rawText: String, cleanedText: String,
                appBundleID: String?, providerID: String) {
        self.timestamp = timestamp
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.appBundleID = appBundleID
        self.providerID = providerID
    }
}

public enum PersistenceLocation {
    public static func applicationSupport() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appending(path: "LocalFlow")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
```

(`HistoryEntry` and `PersistenceLocation` live in `AppSettings.swift` alongside the settings type — three small types, one file.)

- [ ] **Step 4: Write the three stores**

`Sources/Persistence/SettingsStore.swift`:

```swift
import Foundation
import Observation

@Observable
public final class SettingsStore {
    public private(set) var settings: AppSettings
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "settings.json")
        settings = (try? JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: fileURL)))
            ?? AppSettings()
    }

    public func update(_ newValue: AppSettings) {
        settings = newValue
        if let data = try? JSONEncoder().encode(newValue) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
```

`Sources/Persistence/DictionaryStore.swift`:

```swift
import Foundation
import Observation
import CleanupKit

@Observable
public final class DictionaryStore {
    private struct FileModel: Codable {
        var vocabulary: [String] = []
        var replacements: [Replacement] = []
    }
    public private(set) var vocabulary: [String]
    public private(set) var replacements: [Replacement]
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "dictionary.json")
        let model = (try? JSONDecoder().decode(FileModel.self, from: Data(contentsOf: fileURL)))
            ?? FileModel()
        vocabulary = model.vocabulary
        replacements = model.replacements
    }

    public func addVocabulary(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !vocabulary.contains(where: { $0.lowercased() == trimmed.lowercased() })
        else { return }
        vocabulary.append(trimmed)
        save()
    }
    public func removeVocabulary(_ term: String) {
        vocabulary.removeAll { $0 == term }
        save()
    }
    public func addReplacement(_ r: Replacement) {
        guard !r.spoken.isEmpty else { return }
        replacements.append(r)
        save()
    }
    public func removeReplacement(_ r: Replacement) {
        replacements.removeAll { $0 == r }
        save()
    }

    // Import/export (spec §6): the file format IS the on-disk format.
    public func exportData() throws -> Data {
        try JSONEncoder().encode(FileModel(vocabulary: vocabulary, replacements: replacements))
    }
    public func importData(_ data: Data) throws {
        let model = try JSONDecoder().decode(FileModel.self, from: data)
        vocabulary = model.vocabulary
        replacements = model.replacements
        save()
    }

    private func save() {
        let model = FileModel(vocabulary: vocabulary, replacements: replacements)
        if let data = try? JSONEncoder().encode(model) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
```

`Sources/Persistence/HistoryStore.swift`:

```swift
import Foundation
import Observation

@Observable
public final class HistoryStore {
    public private(set) var entries: [HistoryEntry]
    public var isEnabled = true
    public var retentionLimit = 100 {
        didSet { trimAndRewrite() }
    }
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "history.jsonl")
        let decoder = JSONDecoder()
        let raw = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        entries = raw.split(separator: "\n").compactMap {
            try? decoder.decode(HistoryEntry.self, from: Data($0.utf8))
        }
    }

    public func add(_ entry: HistoryEntry) {
        guard isEnabled else { return }
        entries.append(entry)
        if entries.count > retentionLimit {
            trimAndRewrite()
        } else if let line = try? JSONEncoder().encode(entry),
                  let handle = appendHandle() {
            handle.write(line)
            handle.write(Data("\n".utf8))
            try? handle.close()
        }
    }

    public func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func appendHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }
        try? handle.seekToEnd()
        return handle
    }

    private func trimAndRewrite() {
        if entries.count > retentionLimit { entries.removeFirst(entries.count - retentionLimit) }
        let encoder = JSONEncoder()
        let lines = entries.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 5: Run tests until green**

Run: `swift test --filter PersistenceTests`
Expected: PASS (14 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Persistence Tests/PersistenceTests
git commit -m "feat(persistence): observable settings, dictionary, and history stores"
```

---

### Task 14: TranscribeKit — Transcriber protocol + SystemTranscriber (SpeechAnalyzer)

**Files:**
- Create: `Sources/TranscribeKit/Transcriber.swift`, `Sources/TranscribeKit/SystemTranscriber.swift`
- Create: `Tests/TranscribeKitTests/Fixtures/hello.wav` (generated — see Step 1)
- Modify: `Package.swift` (add test resources)
- Test: `Tests/TranscribeKitTests/SystemTranscriberTests.swift`

**Interfaces:**
- Consumes: `AudioData` (CaptureKit).
- Produces: `Transcript`, `Transcriber` (Shared Contracts), `TranscriptionError`, `SystemTranscriber(locale:)` with `func prepare() async throws` (reserves locale + downloads the system model asset).

Verified facts (macOS 26.5 SDK, executed): preset is `.transcription` (`.offlineTranscription` from WWDC does NOT exist); feed buffers must be **16 kHz mono Int16** — Float32 hard-crashes with an uncatchable precondition, so convert via `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`; start consuming `transcriber.results` (async let) BEFORE `analyzeSequence` or results are lost; asset flow is `AssetInventory.reserve(locale:)` → `status(forModules:)` → `assetInstallationRequest(supporting:)?.downloadAndInstall()`; compare locales via `identifier(.bcp47)`; no TCC permission needed for buffer transcription.

- [ ] **Step 1: Generate the spoken fixture**

```bash
mkdir -p Tests/TranscribeKitTests/Fixtures
say -v Samantha -o /tmp/localflow-fixture.aiff "hello world this is a test of local flow dictation"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/localflow-fixture.aiff Tests/TranscribeKitTests/Fixtures/hello.wav
afinfo Tests/TranscribeKitTests/Fixtures/hello.wav | head -5
```

Expected: `afinfo` reports 16000 Hz, 1 ch, Int16 WAVE, ~3–4s duration.

- [ ] **Step 2: Declare the resource in Package.swift**

Change the TranscribeKitTests target line to:

```swift
        .testTarget(name: "TranscribeKitTests", dependencies: ["TranscribeKit"],
                    resources: [.copy("Fixtures")]),
```

- [ ] **Step 3: Write the failing tests**

`Tests/TranscribeKitTests/SystemTranscriberTests.swift`:

```swift
import Foundation
import Testing
@testable import TranscribeKit
import CaptureKit

enum Fixture {
    static func hello() throws -> AudioData {
        let url = Bundle.module.url(forResource: "hello", withExtension: "wav",
                                    subdirectory: "Fixtures")!
        return try AudioFileLoader.load(url: url)
    }
}

struct SystemTranscriberTests {
    @Test func transcriptTypeRoundTrips() {
        let t = Transcript(text: "hi", languageHint: "en-US")
        #expect(t.text == "hi" && t.languageHint == "en-US")
    }

    /// Integration: needs the en-US system speech asset. Soft-skips when absent
    /// (CI images may not have it); downloads on first local run via prepare().
    @Test func transcribesFixtureSpeech() async throws {
        let transcriber = SystemTranscriber(locale: Locale(identifier: "en_US"))
        do { try await transcriber.prepare() } catch {
            print("SKIP: system speech model unavailable: \(error)")
            return
        }
        guard await transcriber.isReady() else {
            print("SKIP: system speech model not installed")
            return
        }
        let result = try await transcriber.transcribe(Fixture.hello())
        let lower = result.text.lowercased()
        #expect(lower.contains("hello"))
        #expect(lower.contains("test"))
    }

    @Test func emptyAudioReturnsEmptyTranscript() async throws {
        let transcriber = SystemTranscriber(locale: Locale(identifier: "en_US"))
        guard await transcriber.isReady() else {
            print("SKIP: system speech model not installed")
            return
        }
        let silent = AudioData(samples: Array(repeating: 0, count: 16_000))
        let result = try await transcriber.transcribe(silent)
        #expect(result.text.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter SystemTranscriberTests`
Expected: FAIL — `cannot find 'SystemTranscriber' in scope`.

- [ ] **Step 5: Write Transcriber.swift**

```swift
import Foundation

public struct Transcript: Sendable, Equatable {
    public var text: String
    public var languageHint: String?   // BCP-47; Parakeet does not detect language (input hint only)
    public init(text: String, languageHint: String?) {
        self.text = text
        self.languageHint = languageHint
    }
}

public protocol Transcriber: Sendable {
    func isReady() async -> Bool
    func transcribe(_ audio: CaptureKit.AudioData) async throws -> Transcript
}

public enum TranscriptionError: Error {
    case modelUnavailable
    case audioFormatUnsupported
    case engineFailure(String)
}
```

Add `import CaptureKit` at the top (for `AudioData` in the protocol).

- [ ] **Step 6: Write SystemTranscriber.swift**

```swift
import AVFoundation
import Foundation
import Speech
import CaptureKit

/// Apple SpeechAnalyzer (macOS 26): the zero-download transcriber used while
/// Parakeet downloads or as fallback. Weaker on jargon; no auto language ID.
public actor SystemTranscriber: Transcriber {
    private let locale: Locale

    public init(locale: Locale = Locale(identifier: "en_US")) {
        self.locale = locale
    }

    public func isReady() async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    /// Reserve the locale and download the system asset if needed (system-managed, shared).
    public func prepare() async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
            throw TranscriptionError.modelUnavailable
        }
        let reserved = await AssetInventory.reservedLocales
        if !reserved.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) {
            try await AssetInventory.reserve(locale: locale)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()   // fast no-op when already installed
        }
    }

    public func transcribe(_ audio: CaptureKit.AudioData) async throws -> Transcript {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // CRASH HAZARD (verified): the analyzer accepts ONLY 16/8 kHz mono Int16.
        // Feeding Float32 traps the process. Always convert.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]) else {
            throw TranscriptionError.audioFormatUnsupported
        }
        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: CaptureKit.AudioData.sampleRate,
                                        channels: 1, interleaved: false)!
        guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                                 frameCapacity: AVAudioFrameCount(audio.samples.count))
        else { throw TranscriptionError.audioFormatUnsupported }
        floatBuffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { src in
            floatBuffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        let int16Buffer = try Self.convert(floatBuffer, to: analyzerFormat)

        // Consume results BEFORE feeding input, or they are silently lost (verified).
        async let transcriptFuture: AttributedString = transcriber.results
            .reduce(AttributedString()) { partial, result in partial + result.text }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        inputBuilder.yield(AnalyzerInput(buffer: int16Buffer))
        inputBuilder.finish()

        if let lastSampleTime = try await analyzer.analyzeSequence(inputSequence) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = String((try await transcriptFuture).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, languageHint: locale.identifier(.bcp47))
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TranscriptionError.audioFormatUnsupported
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.audioFormatUnsupported
        }
        nonisolated(unsafe) var supplied = false
        var err: NSError?
        let status = converter.convert(to: output, error: &err) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw TranscriptionError.audioFormatUnsupported }
        return output
    }
}
```

- [ ] **Step 7: Run tests until green**

Run: `swift test --filter SystemTranscriberTests`
Expected: PASS. On this machine `transcribesFixtureSpeech` must actually run (macOS 26.5 with en-US likely installed; `prepare()` downloads it if not) and assert the fixture words. Report SKIP vs PASS honestly.

- [ ] **Step 8: Commit**

```bash
git add Sources/TranscribeKit Tests/TranscribeKitTests Package.swift
git commit -m "feat(transcribe): protocol + SpeechAnalyzer system transcriber with Int16 conversion"
```

---

### Task 15: CaptureKit — AudioCaptureService (always-warm engine)

**Files:**
- Create: `Sources/CaptureKit/AudioCaptureService.swift`
- Test: build-only; live verification via `localflow-cli record` (Task 16) — CI has no microphone.

**Interfaces:**
- Consumes: `RingBuffer`, `AudioResampler`, `AudioData`, `AudioCapturing` (Task 8).
- Produces: `AudioCaptureService(preBufferSeconds:)` conforming to `AudioCapturing`, plus `func warmUp() throws` (starts the engine; call at app launch), `func setPreferredInput(uid: String?)`, `static func requestMicrophoneAccess() async -> Bool`, `static var microphoneAuthorized: Bool`, `static func availableInputs() -> [(uid: String, name: String)]`.

- [ ] **Step 1: Write AudioCaptureService.swift**

```swift
import AVFoundation
import CoreAudio

/// Always-warm capture: the engine runs continuously (negligible CPU), feeding a
/// rolling pre-buffer so dictation includes ~0.5s BEFORE the hotkey press —
/// this kills first-word clipping and Bluetooth-mic wake loss (spec §2).
public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    public let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ring: RingBuffer
    private var active: [Float] = []
    private var accumulating = false
    private var resampler: AudioResampler?
    private let preBufferSamples: Int

    public init(preBufferSeconds: TimeInterval = 0.5) {
        preBufferSamples = Int(preBufferSeconds * AudioData.sampleRate)
        ring = RingBuffer(capacity: preBufferSamples)
        (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.rebuildTap()   // AirPods connect/disconnect, default-device change
        }
    }

    // MARK: permissions / devices

    public static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    public static func availableInputs() -> [(uid: String, name: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// nil = system default. Sets the engine input device via CoreAudio.
    public func setPreferredInput(uid: String?) {
        guard let uid else { return rebuildTap() }   // revert to default on nil
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr,
                                       &size, &deviceID)
        }
        guard status == noErr, deviceID != 0, let unit = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        rebuildTap()
    }

    // MARK: engine lifecycle

    public func warmUp() throws {
        installTap()
        engine.prepare()
        try engine.start()
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        resampler = AudioResampler(inputFormat: format)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
    }

    private func rebuildTap() {
        lock.lock(); defer { lock.unlock() }
        installTap()
        if !engine.isRunning { engine.prepare(); try? engine.start() }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let samples = resampler?.process(buffer), !samples.isEmpty else { return }
        var rms: Float = 0
        for s in samples { rms += s * s }
        rms = min(1, sqrt(rms / Float(samples.count)) * 4)   // scaled for HUD meters
        lock.lock()
        ring.write(samples)
        if accumulating { active.append(contentsOf: samples) }
        lock.unlock()
        levelContinuation.yield(rms)
    }

    // MARK: AudioCapturing

    public func startCapture() throws {
        if !engine.isRunning { try warmUp() }
        lock.lock(); defer { lock.unlock() }
        active = ring.snapshot()   // splice in the pre-roll
        accumulating = true
    }

    public func stopCapture() async -> AudioData {
        lock.lock(); defer { lock.unlock() }
        accumulating = false
        let samples = active
        active = []
        return AudioData(samples: samples)
    }

    public func cancelCapture() {
        lock.lock(); defer { lock.unlock() }
        accumulating = false
        active = []
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/CaptureKit/AudioCaptureService.swift
git commit -m "feat(capture): always-warm AVAudioEngine capture with pre-roll splice"
```

---

### Task 16: TranscribeKit — ParakeetTranscriber + router; CLI harness

**Files:**
- Create: `Sources/TranscribeKit/ParakeetTranscriber.swift`, `Sources/TranscribeKit/TranscriberRouter.swift`
- Modify: `Sources/localflow-cli/main.swift` (replace stub entirely)
- Test: `Tests/TranscribeKitTests/ParakeetTranscriberTests.swift`

**Interfaces:**
- Consumes: `Transcriber`, `Transcript`, `AudioData`; FluidAudio (`AsrModels.downloadAndLoad(version: .v3, progressHandler:)`, `AsrManager`, `TdtDecoderState`, `VadManager.segmentSpeechAudio`, `AsrModels.modelsExist(at:)`, `AsrModels.defaultCacheDirectory(for:)`).
- Produces: `ParakeetTranscriber()` with `prepare(progress: (@Sendable (Double, String) -> Void)?) async throws`, `setLanguage(_ bcp47: String?)`, `static var modelIsDownloaded: Bool`; `TranscriberRouter(primary:fallback:)`; a working `localflow-cli` with `transcribe`, `record`, `hotkey`, `insert` commands.

Verified facts (FluidAudio v0.15.4 source): every `transcribe` overload requires `inout TdtDecoderState` (README is stale); `AsrManager` is an actor — `init(config: .default)` then `try await loadModels(models)`; audio must be ≥ 4800 samples (0.3s) or `ASRError.invalidAudioData`; `ASRResult.text/.confidence` (NO detected language); models land in `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`; `VadManager` init auto-downloads Silero (`segmentSpeechAudio(_:) -> [[Float]]` returns speech slices); `Language` is a `String`-raw enum used only as an input hint.

- [ ] **Step 1: Write the failing/gated tests**

`Tests/TranscribeKitTests/ParakeetTranscriberTests.swift`:

```swift
import Foundation
import Testing
@testable import TranscribeKit
import CaptureKit

struct ParakeetTranscriberTests {
    @Test func tooShortAudioReturnsEmptyTranscriptNotError() async throws {
        let t = ParakeetTranscriber()
        guard await t.isReady() else { print("SKIP: Parakeet model not downloaded"); return }
        let blip = AudioData(samples: Array(repeating: 0, count: 1000))  // < 0.3s
        let result = try await t.transcribe(blip)
        #expect(result.text.isEmpty)
    }

    /// Integration: runs only when the ~600MB model is already cached locally.
    /// First-time download happens via `localflow-cli transcribe` or app onboarding.
    @Test func transcribesFixtureSpeech() async throws {
        guard ParakeetTranscriber.modelIsDownloaded else {
            print("SKIP: Parakeet model not downloaded"); return
        }
        let t = ParakeetTranscriber()
        try await t.prepare(progress: nil)
        let result = try await t.transcribe(try Fixture.hello())
        let lower = result.text.lowercased()
        #expect(lower.contains("hello"))
        #expect(lower.contains("test"))
    }

    @Test func routerFallsBackWhenPrimaryNotReady() async throws {
        struct NeverReady: Transcriber {
            func isReady() async -> Bool { false }
            func transcribe(_ audio: AudioData) async throws -> Transcript {
                throw TranscriptionError.modelUnavailable
            }
        }
        struct AlwaysReady: Transcriber {
            func isReady() async -> Bool { true }
            func transcribe(_ audio: AudioData) async throws -> Transcript {
                Transcript(text: "fallback", languageHint: nil)
            }
        }
        let router = TranscriberRouter(primary: NeverReady(), fallback: AlwaysReady())
        let out = try await router.transcribe(AudioData(samples: Array(repeating: 0, count: 8000)))
        #expect(out.text == "fallback")
        #expect(await router.isReady() == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ParakeetTranscriberTests`
Expected: FAIL — `cannot find 'ParakeetTranscriber' in scope`.

- [ ] **Step 3: Write ParakeetTranscriber.swift**

```swift
import Foundation
import FluidAudio
import CaptureKit

/// Primary STT: NVIDIA Parakeet TDT 0.6b-v3 on the Neural Engine via FluidAudio.
/// ~0.2-0.5s for typical utterances; 25 European languages; stays resident.
public actor ParakeetTranscriber: Transcriber {
    public enum State: Sendable, Equatable {
        case notPrepared, downloading(Double), ready, failed(String)
    }
    public private(set) var state: State = .notPrepared
    private var manager: AsrManager?
    private var vad: VadManager?
    private var language: Language?

    public init() {}

    public static var modelIsDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    /// BCP-47-ish code from settings ("en", "de", …); nil = auto-detect.
    public func setLanguage(_ bcp47: String?) {
        language = bcp47.flatMap { Language(rawValue: String($0.prefix(2))) }
    }

    public func isReady() async -> Bool { state == .ready }

    /// Downloads (~600MB, once) and loads the models. Progress: fraction + phase label.
    public func prepare(progress: (@Sendable (Double, String) -> Void)?) async throws {
        guard state != .ready else { return }
        state = .downloading(0)
        do {
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { p in
                    let label: String
                    switch p.phase {
                    case .listing: label = "Preparing download…"
                    case .downloading(let done, let total): label = "Downloading model \(done)/\(total)…"
                    case .compiling(let name): label = "Compiling \(name)…"
                    }
                    progress?(p.fractionCompleted, label)
                })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            // VAD is best-effort: silence trimming improves quality but must never block.
            self.vad = try? await VadManager()
            state = .ready
        } catch {
            state = .failed(String(describing: error))
            throw TranscriptionError.engineFailure(String(describing: error))
        }
    }

    public func transcribe(_ audio: CaptureKit.AudioData) async throws -> Transcript {
        guard let manager, state == .ready else { throw TranscriptionError.modelUnavailable }
        // FluidAudio throws ASRError.invalidAudioData under 4800 samples (0.3s).
        guard audio.samples.count >= 4800 else {
            return Transcript(text: "", languageHint: language?.rawValue)
        }
        var samples = audio.samples
        if let vad {
            // Trim non-speech; keep raw audio if VAD errors or finds nothing
            // (better to transcribe silence than to drop real speech).
            if let segments = try? await vad.segmentSpeechAudio(samples), !segments.isEmpty {
                samples = segments.flatMap { $0 }
            }
        }
        guard samples.count >= 4800 else {
            return Transcript(text: "", languageHint: language?.rawValue)
        }
        var decoderState = try TdtDecoderState()   // fresh per utterance (no cross-talk)
        let result = try await manager.transcribe(samples, decoderState: &decoderState,
                                                  language: language)
        return Transcript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                          languageHint: language?.rawValue)
    }
}
```

Swift 6 note: `decoderState` must be a local `var` — passing a stored actor property `inout` across `await` does not compile.

- [ ] **Step 4: Write TranscriberRouter.swift**

```swift
import CaptureKit

/// Prefers the primary (Parakeet) when ready; falls back to the system
/// transcriber so dictation works from first launch (spec §2, §5).
public struct TranscriberRouter: Transcriber {
    private let primary: any Transcriber
    private let fallback: any Transcriber

    public init(primary: any Transcriber, fallback: any Transcriber) {
        self.primary = primary
        self.fallback = fallback
    }
    public func isReady() async -> Bool {
        if await primary.isReady() { return true }
        return await fallback.isReady()
    }
    public func transcribe(_ audio: CaptureKit.AudioData) async throws -> Transcript {
        if await primary.isReady() {
            return try await primary.transcribe(audio)
        }
        return try await fallback.transcribe(audio)
    }
}
```

- [ ] **Step 5: Run tests until green**

Run: `swift test --filter ParakeetTranscriberTests`
Expected: PASS (router test always runs; the two Parakeet tests SKIP until the model is cached — they go live after Step 7).

- [ ] **Step 6: Replace localflow-cli main.swift (full dev harness)**

```swift
import Foundation
import CaptureKit
import CleanupKit
import HotkeyKit
import InsertKit
import TranscribeKit

// localflow-cli — permission-free pipeline harness (spec §7).
//   transcribe <wav> [--engine parakeet|system] [--level off|light|standard|heavy]
//   record [seconds]         capture from mic, run full pipeline, print
//   hotkey                   print hotkey events for 15s (grant Accessibility to your terminal)
//   insert <text>            3s delay, then insert into the focused app

let args = Array(CommandLine.arguments.dropFirst())

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
}

func makeTranscriber(engine: String) async throws -> any Transcriber {
    switch engine {
    case "system":
        let t = SystemTranscriber()
        try await t.prepare()
        return t
    default:
        let t = ParakeetTranscriber()
        try await t.prepare { fraction, label in
            print("  \(label) \(Int(fraction * 100))%")
        }
        return t
    }
}

func runPipeline(_ audio: AudioData, engine: String, level: CleanupLevel) async throws {
    print("audio: \(String(format: "%.2f", audio.duration))s")
    let transcriber = try await makeTranscriber(engine: engine)

    let t0 = Date()
    let transcript = try await transcriber.transcribe(audio)
    let sttSecs = Date().timeIntervalSince(t0)
    print("raw (\(String(format: "%.2f", sttSecs))s STT): \(transcript.text)")

    let pipeline = CleanupPipeline(providers: [AppleFMCleaner(), OllamaCleaner()])
    let t1 = Date()
    let result = await pipeline.process(transcript.text,
                                        options: CleanupOptions(level: level, vocabulary: []),
                                        replacements: [])
    let cleanSecs = Date().timeIntervalSince(t1)
    print("cleaned via \(result.providerID) (\(String(format: "%.2f", cleanSecs))s): \(result.text)")
}

let level = CleanupLevel(rawValue: flagValue("--level") ?? "standard") ?? .standard
let engine = flagValue("--engine") ?? "parakeet"

switch args.first ?? "" {
case "transcribe":
    guard args.count >= 2 else { print("usage: localflow-cli transcribe <wav>"); exit(1) }
    let audio = try AudioFileLoader.load(url: URL(filePath: args[1]))
    try await runPipeline(audio, engine: engine, level: level)

case "record":
    let seconds = Double(args.count > 1 ? args[1] : "5") ?? 5
    guard await AudioCaptureService.requestMicrophoneAccess() else {
        print("microphone permission denied"); exit(1)
    }
    let capture = AudioCaptureService()
    try capture.warmUp()
    print("recording \(Int(seconds))s — speak now…")
    try capture.startCapture()
    try await Task.sleep(for: .seconds(seconds))
    let audio = await capture.stopCapture()
    try await runPipeline(audio, engine: engine, level: level)

case "hotkey":
    let source = EventTapHotkeySource(choice: .fnKey)
    do { try source.start() } catch {
        print("event tap failed — grant Accessibility to this terminal in System Settings")
        exit(1)
    }
    print("listening 15s — press/hold Fn…")
    let task = Task {
        for await event in source.events { print("  event: \(event)") }
    }
    try await Task.sleep(for: .seconds(15))
    task.cancel()

case "insert":
    guard args.count >= 2 else { print("usage: localflow-cli insert <text>"); exit(1) }
    print("focus a text field — inserting in 3s…")
    try await Task.sleep(for: .seconds(3))
    let outcome = await TextInserter().insert(args[1], bundleID: FrontmostApp.bundleID())
    print("outcome: \(outcome)")

default:
    print("commands: transcribe | record | hotkey | insert")
}
```

Note: `main.swift` supports top-level `await` in an executable target with Swift 6 tools.

- [ ] **Step 7: End-to-end verification on this machine (downloads the model, ~600MB)**

Run: `swift run localflow-cli transcribe Tests/TranscribeKitTests/Fixtures/hello.wav --engine parakeet`
Expected: download progress lines on first run, then `raw (~0.3-0.6s STT): hello world this is a test of local flow dictation` (approximately) and a `cleaned via apple-fm` (or `ollama`/`rules`) line. Record the timings in the task report.

Run: `swift run localflow-cli transcribe Tests/TranscribeKitTests/Fixtures/hello.wav --engine system`
Expected: same fixture via SpeechAnalyzer.

Run: `swift test --filter ParakeetTranscriberTests`
Expected: PASS with the integration tests now LIVE (model is cached).

- [ ] **Step 8: Commit**

```bash
git add Sources/TranscribeKit Sources/localflow-cli Tests/TranscribeKitTests
git commit -m "feat(transcribe): Parakeet v3 via FluidAudio, router, CLI pipeline harness"
```

---

### Task 17: FlowCore — FlowController (orchestrator)

**Files:**
- Create: `Sources/FlowCore/FlowController.swift`
- Test: `Tests/FlowCoreTests/FlowControllerTests.swift`

**Interfaces:**
- Consumes: every protocol from earlier tasks (`HotkeySource`, `AudioCapturing`, `Transcriber`, `CleanupProcessing`, `TextInserting`), `GestureMachine`, the three stores, `Permissions`.
- Produces: `@MainActor @Observable public final class FlowController` with:
  `public enum Phase: Equatable { case disabled(String), idle, recording(handsFree: Bool), transcribing, cleaning, inserting, notice(String) }`,
  `public private(set) var phase: Phase`,
  `public var lastCleanedText: String?`,
  `init(hotkeys:capture:transcriber:cleanup:inserter:settings:dictionary:history:frontmostBundleID:now:)`,
  `public func start()`. The app target (Task 18) builds it with real implementations; tests use mocks.

Error behavior (spec §5, all encoded in tests): silence → notice "Didn't catch that", nothing inserted, no history; insertion failure → notice "Couldn't insert — it's on your clipboard", history still recorded; transcriber error → notice "Transcription failed", no insertion; secure input → `.disabled` until it clears; cleanup can never fail (pipeline contract). Notices auto-clear to `.idle` after 2s.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import FlowCore
import CaptureKit
import CleanupKit
import HotkeyKit
import InsertKit
import Persistence
import TranscribeKit

// MARK: mocks

final class MockHotkeySource: HotkeySource, @unchecked Sendable {
    let events: AsyncStream<HotkeyRawEvent>
    let continuation: AsyncStream<HotkeyRawEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream(of: HotkeyRawEvent.self) }
    func start() throws {}
}

final class MockCapture: AudioCapturing, @unchecked Sendable {
    var audioToReturn = AudioData(samples: Array(repeating: 0.1, count: 16_000))  // 1s
    private(set) var startCount = 0, stopCount = 0, cancelCount = 0
    let levels: AsyncStream<Float> = AsyncStream { $0.finish() }
    func startCapture() throws { startCount += 1 }
    func stopCapture() async -> AudioData { stopCount += 1; return audioToReturn }
    func cancelCapture() { cancelCount += 1 }
}

final class MockTranscriber: Transcriber, @unchecked Sendable {
    var result: Result<Transcript, TranscriptionError> = .success(Transcript(text: "raw words", languageHint: nil))
    func isReady() async -> Bool { true }
    func transcribe(_ audio: AudioData) async throws -> Transcript { try result.get() }
}

struct EchoCleanup: CleanupProcessing {
    func process(_ raw: String, options: CleanupOptions, replacements: [Replacement]) async -> CleanupResult {
        CleanupResult(text: "CLEANED: \(raw)", providerID: "mock")
    }
}

final class MockInserter: TextInserting, @unchecked Sendable {
    var outcome: InsertionOutcome = .inserted(.pasteSwap)
    private(set) var insertedTexts: [String] = []
    func insert(_ text: String, bundleID: String?) async -> InsertionOutcome {
        insertedTexts.append(text)
        return outcome
    }
}

// MARK: harness

@MainActor
struct Harness {
    let hotkeys = MockHotkeySource()
    let capture = MockCapture()
    let transcriber = MockTranscriber()
    let inserter = MockInserter()
    let history: HistoryStore
    let controller: FlowController
    var clock: TimeInterval = 100

    init() {
        let dir = tempDirFC()
        history = HistoryStore(directory: dir)
        let settings = SettingsStore(directory: dir)
        nonisolated(unsafe) var now: TimeInterval = 100
        controller = FlowController(
            hotkeys: hotkeys, capture: capture, transcriber: transcriber,
            cleanup: EchoCleanup(), inserter: inserter,
            settings: settings, dictionary: DictionaryStore(directory: dir), history: history,
            frontmostBundleID: { "com.apple.Notes" },
            now: { now })
        self.nowRef = { now = $0 }
    }
    let nowRef: (TimeInterval) -> Void

    /// Simulate a hold of `duration` seconds and wait for the pipeline to finish.
    func dictate(holdFor duration: TimeInterval) async {
        nowRef(100)
        hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        nowRef(100 + duration)
        hotkeys.continuation.yield(.keyUp)
        // Poll until controller returns to a terminal phase.
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(20))
            if case .idle = controller.phase { return }
            if case .notice = controller.phase { return }
        }
    }
}

func tempDirFC() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "flowcore-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: tests

@MainActor
struct FlowControllerTests {
    @Test func happyPathInsertsCleanedTextAndRecordsHistory() async {
        let h = Harness()
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts == ["CLEANED: raw words"])
        #expect(h.history.entries.count == 1)
        #expect(h.history.entries.first?.rawText == "raw words")
        #expect(h.history.entries.first?.appBundleID == "com.apple.Notes")
        #expect(h.controller.lastCleanedText == "CLEANED: raw words")
        #expect(h.capture.startCount == 1 && h.capture.stopCount == 1)
    }
    @Test func emptyTranscriptShowsNoticeAndInsertsNothing() async {
        let h = Harness()
        h.transcriber.result = .success(Transcript(text: "", languageHint: nil))
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.history.entries.isEmpty)
        #expect(h.controller.phase == .notice("Didn't catch that"))
    }
    @Test func tooShortAudioIsDiscardedViaNotice() async {
        let h = Harness()
        h.capture.audioToReturn = AudioData(samples: Array(repeating: 0, count: 1600)) // 0.1s
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.controller.phase == .notice("Didn't catch that"))
    }
    @Test func transcriberFailureShowsNotice() async {
        let h = Harness()
        h.transcriber.result = .failure(.engineFailure("boom"))
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.controller.phase == .notice("Transcription failed"))
    }
    @Test func insertionFailureNoticesButKeepsHistory() async {
        let h = Harness()
        h.inserter.outcome = .failedTextOnClipboard
        h.controller.start()
        await h.dictate(holdFor: 0.5)
        #expect(h.controller.phase == .notice("Couldn't insert — it's on your clipboard"))
        #expect(h.history.entries.count == 1)
    }
    @Test func escapeCancelsRecordingWithoutInsertion() async {
        let h = Harness()
        h.controller.start()
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        h.hotkeys.continuation.yield(.escapePressed)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.capture.cancelCount == 1)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.controller.phase == .idle)
    }
    @Test func secureInputDisablesAndReenables() async {
        let h = Harness()
        h.controller.start()
        h.hotkeys.continuation.yield(.secureInputChanged(true))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .disabled("Secure input active"))
        // Hotkey presses are ignored while disabled:
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.startCount == 0)
        h.hotkeys.continuation.yield(.secureInputChanged(false))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.phase == .idle)
    }
    @Test func recordingPhaseIsVisibleWhileHolding() async {
        let h = Harness()
        h.controller.start()
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.controller.phase == .recording(handsFree: false))
        h.hotkeys.continuation.yield(.keyUp)   // cleanup: end the session
        try? await Task.sleep(for: .milliseconds(200))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FlowControllerTests`
Expected: FAIL — `cannot find 'FlowController' in scope`.

- [ ] **Step 3: Write FlowController.swift**

```swift
import Foundation
import Observation
import CaptureKit
import CleanupKit
import HotkeyKit
import InsertKit
import Persistence
import TranscribeKit

/// Orchestrates: hotkey events -> GestureMachine -> capture/transcribe/clean/insert.
/// UI observes `phase`; all pipeline work runs off the main actor via Tasks.
@MainActor
@Observable
public final class FlowController {
    public enum Phase: Equatable, Sendable {
        case disabled(String)
        case idle
        case recording(handsFree: Bool)
        case transcribing
        case cleaning
        case inserting
        case notice(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastCleanedText: String?

    private let hotkeys: any HotkeySource
    private let capture: any AudioCapturing
    private let transcriber: any Transcriber
    private let cleanup: any CleanupProcessing
    private let inserter: any TextInserting
    private let settings: SettingsStore
    private let dictionary: DictionaryStore
    private let history: HistoryStore
    private let frontmostBundleID: @Sendable () -> String?
    private let now: @Sendable () -> TimeInterval

    private var machine: GestureMachine
    private var eventTask: Task<Void, Never>?
    private var doubleTapTimer: Task<Void, Never>?
    private var capTimer: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    private let sessionCap: TimeInterval

    public init(hotkeys: any HotkeySource,
                capture: any AudioCapturing,
                transcriber: any Transcriber,
                cleanup: any CleanupProcessing,
                inserter: any TextInserting,
                settings: SettingsStore,
                dictionary: DictionaryStore,
                history: HistoryStore,
                frontmostBundleID: @escaping @Sendable () -> String? = { FrontmostApp.bundleID() },
                now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
                sessionCap: TimeInterval = 600) {
        self.hotkeys = hotkeys
        self.capture = capture
        self.transcriber = transcriber
        self.cleanup = cleanup
        self.inserter = inserter
        self.settings = settings
        self.dictionary = dictionary
        self.history = history
        self.frontmostBundleID = frontmostBundleID
        self.now = now
        self.sessionCap = sessionCap
        self.machine = GestureMachine(handsFreeEnabled: settings.settings.handsFreeEnabled)
    }

    public func start() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.hotkeys.events {
                self.handleHotkey(event)
            }
        }
    }

    private func handleHotkey(_ event: HotkeyRawEvent) {
        if case .secureInputChanged(let active) = event {
            if active {
                if machine.isRecording { run(machine.handle(.escape)) }
                // Name the app holding secure input when we can (spec §5).
                let holder = Permissions.secureInputAppName().map { " (\($0))" } ?? ""
                phase = .disabled("Secure input active" + holder)
            } else if case .disabled = phase {
                phase = .idle
            }
            return
        }
        if case .disabled = phase { return }   // ignore keys while disabled

        switch event {
        case .keyDown:         run(machine.handle(.keyDown(now())))
        case .keyUp:           run(machine.handle(.keyUp(now())))
        case .escapePressed:   run(machine.handle(.escape))
        case .comboCancelled:  run(machine.handle(.comboCancelled))
        case .secureInputChanged: break
        }
    }

    private func run(_ effects: [GestureMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startCapture:
                do {
                    try capture.startCapture()
                    phase = .recording(handsFree: machine.isHandsFree)
                    startCapTimer()
                } catch {
                    phase = .notice("Microphone unavailable")
                    scheduleNoticeClear()
                }
            case .discardCapture:
                cancelTimers()
                capture.cancelCapture()
                phase = .idle
            case .stopAndProcess:
                cancelTimers()
                Task { await self.process() }
            case .scheduleDoubleTapTimer:
                doubleTapTimer?.cancel()
                doubleTapTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(0.4))
                    guard let self, !Task.isCancelled else { return }
                    self.run(self.machine.handle(.doubleTapTimerFired(self.now())))
                }
            }
        }
        // Recording phase can change (e.g. tapPending -> handsFree) without effects.
        if machine.isRecording, case .recording = phase {
            phase = .recording(handsFree: machine.isHandsFree)
        }
    }

    private func startCapTimer() {
        capTimer?.cancel()
        capTimer = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.sessionCap))
            guard !Task.isCancelled else { return }
            self.run(self.machine.handle(.capTimerFired))
        }
    }

    private func cancelTimers() {
        doubleTapTimer?.cancel(); doubleTapTimer = nil
        capTimer?.cancel(); capTimer = nil
    }

    private func process() async {
        phase = .transcribing
        let audio = await capture.stopCapture()
        guard audio.duration >= 0.35 else { return notice("Didn't catch that") }

        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(audio)
        } catch {
            return notice("Transcription failed")
        }
        let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return notice("Didn't catch that") }

        phase = .cleaning
        let options = CleanupOptions(level: settings.settings.cleanupLevel,
                                     vocabulary: dictionary.vocabulary)
        let result = await cleanup.process(raw, options: options,
                                           replacements: dictionary.replacements)

        phase = .inserting
        let bundleID = frontmostBundleID()
        let outcome = await inserter.insert(result.text, bundleID: bundleID)
        lastCleanedText = result.text

        history.isEnabled = settings.settings.historyEnabled
        history.retentionLimit = settings.settings.historyRetention
        history.add(HistoryEntry(timestamp: Date(), rawText: raw, cleanedText: result.text,
                                 appBundleID: bundleID, providerID: result.providerID))

        switch outcome {
        case .inserted:
            phase = .idle
        case .failedTextOnClipboard:
            notice("Couldn't insert — it's on your clipboard")
        }
    }

    private func notice(_ message: String) {
        phase = .notice(message)
        scheduleNoticeClear()
    }

    private func scheduleNoticeClear() {
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if case .notice = self.phase { self.phase = .idle }
        }
    }
}
```

- [ ] **Step 4: Run tests until green**

Run: `swift test --filter FlowControllerTests`
Expected: PASS (8 tests). Then run the FULL suite: `swift test` — everything from Tasks 1–17 must be green.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlowCore/FlowController.swift Tests/FlowCoreTests/FlowControllerTests.swift
git commit -m "feat(flow): orchestrating controller wiring hotkeys to the full pipeline"
```

---

### Task 18: App target — XcodeGen scaffold, composition root, menu bar shell

> **PREREQUISITE for Tasks 18–23:** full Xcode 26 (App Store) and `brew install xcodegen`. After installing Xcode: `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept`.

**Files:**
- Create: `App/project.yml`, `App/LocalFlow.entitlements`, `App/LocalFlow/LocalFlowApp.swift`, `App/LocalFlow/AppState.swift`
- Test: build + launch; menu bar icon appears; Quit works.

**Interfaces:**
- Consumes: everything (via `FlowCore` etc. products of the local package).
- Produces: `AppState` (`@MainActor @Observable`) — the composition root all later app tasks extend: `.controller: FlowController`, `.settingsStore`, `.dictionaryStore`, `.historyStore`, `.capture: AudioCaptureService`, `.parakeet: ParakeetTranscriber`, `.appleFM: AppleFMCleaner`, `.modelProgress: Double`, `.modelPhaseLabel: String`, `.accessibilityGranted: Bool`, `.microphoneGranted: Bool`, `func bootstrap() async`.

- [ ] **Step 1: Write App/project.yml**

```yaml
name: LocalFlow
options:
  bundleIdPrefix: dev.localflow
  deploymentTarget:
    macOS: "26.0"
packages:
  LocalFlowKit:
    path: ..
targets:
  LocalFlow:
    type: application
    platform: macOS
    sources: [LocalFlow]
    dependencies:
      - package: LocalFlowKit
        products: [FlowCore, CleanupKit, HotkeyKit, CaptureKit, TranscribeKit, InsertKit, Persistence]
    info:
      path: LocalFlow/Info.plist
      properties:
        LSUIElement: true                # menu bar agent: no Dock icon
        CFBundleDisplayName: LocalFlow
        CFBundleShortVersionString: "0.1.0"
        NSMicrophoneUsageDescription: >-
          LocalFlow records audio only while you hold the dictation key and
          transcribes it entirely on this Mac. Nothing is sent anywhere.
    entitlements:
      path: LocalFlow.entitlements   # checked-in file (Step 2), relative to App/
    settings:
      base:
        ENABLE_HARDENED_RUNTIME: NO     # dev builds; release signing in Task 23
        CODE_SIGN_IDENTITY: "-"
        SWIFT_VERSION: "6.0"
```

**No App Sandbox** — CGEventTaps and AX insertion are incompatible with it (spec: distribute outside the App Store).

**Dev-signing gotcha (verified):** TCC's Accessibility grant sticks to the code signature; ad-hoc (`-`) signing changes every build, so the grant dies on rebuild. For daily development create a self-signed code-signing certificate once (Keychain Access → Certificate Assistant → Create a Certificate → name `LocalFlow Dev`, type Code Signing) and change `CODE_SIGN_IDENTITY: "LocalFlow Dev"`. Do this at first annoyance; ad-hoc is fine for the initial build.

- [ ] **Step 2: Write App/LocalFlow.entitlements**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Write AppState.swift**

```swift
import Foundation
import Observation
import CaptureKit
import CleanupKit
import FlowCore
import HotkeyKit
import InsertKit
import Persistence
import TranscribeKit

/// Composition root: builds the real object graph and boots the pipeline.
@MainActor
@Observable
final class AppState {
    let settingsStore: SettingsStore
    let dictionaryStore: DictionaryStore
    let historyStore: HistoryStore
    let capture: AudioCaptureService
    let parakeet: ParakeetTranscriber
    let appleFM: AppleFMCleaner
    let hotkeySource: EventTapHotkeySource
    let controller: FlowController

    var modelProgress: Double = 0
    var modelPhaseLabel: String = ""
    var modelReady = false
    var accessibilityGranted = Permissions.accessibilityGranted
    var microphoneGranted = AudioCaptureService.microphoneAuthorized

    init() {
        let dir = PersistenceLocation.applicationSupport()
        settingsStore = SettingsStore(directory: dir)
        dictionaryStore = DictionaryStore(directory: dir)
        historyStore = HistoryStore(directory: dir)
        capture = AudioCaptureService()
        parakeet = ParakeetTranscriber()
        appleFM = AppleFMCleaner()
        hotkeySource = EventTapHotkeySource(choice: settingsStore.settings.hotkey)

        let transcriber = TranscriberRouter(primary: parakeet, fallback: SystemTranscriber())
        let pipeline = CleanupPipeline(providers: [
            appleFM,
            OllamaCleaner(model: settingsStore.settings.ollamaModel),
        ])
        controller = FlowController(
            hotkeys: hotkeySource, capture: capture, transcriber: transcriber,
            cleanup: pipeline, inserter: TextInserter(),
            settings: settingsStore, dictionary: dictionaryStore, history: historyStore)
    }

    /// Idempotent: safe to re-run whenever permissions change.
    func bootstrap() async {
        accessibilityGranted = Permissions.accessibilityGranted
        microphoneGranted = AudioCaptureService.microphoneAuthorized

        if microphoneGranted { try? capture.warmUp() }
        if accessibilityGranted { try? hotkeySource.start() }
        controller.start()

        // Prewarm Apple FM so the first dictation's cleanup is warm (spec §2).
        await appleFM.prewarm(options: CleanupOptions(
            level: settingsStore.settings.cleanupLevel,
            vocabulary: dictionaryStore.vocabulary))

        // Parakeet: download in background; SpeechAnalyzer covers the meantime.
        if !modelReady {
            try? await parakeet.prepare { [weak self] fraction, label in
                Task { @MainActor in
                    self?.modelProgress = fraction
                    self?.modelPhaseLabel = label
                }
            }
            modelReady = await parakeet.isReady()
        }
        await parakeet.setLanguage(settingsStore.settings.languageOverride)
    }
}
```

- [ ] **Step 4: Write LocalFlowApp.swift (minimal shell — menu grows in Task 22)**

```swift
import SwiftUI

@main
struct LocalFlowApp: App {
    @State private var appState: AppState

    init() {
        // Single construction site — no property-initializer default, which
        // would build (and discard) a second AppState before this init runs.
        let state = AppState()
        _appState = State(initialValue: state)
        Task { await state.bootstrap() }
    }

    var body: some Scene {
        MenuBarExtra {
            Button("Quit LocalFlow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: menuIcon)   // Observation-tracked: re-renders on phase change
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuIcon: String {
        switch appState.controller.phase {
        case .recording:  return "waveform.badge.mic"
        case .transcribing, .cleaning, .inserting: return "hourglass"
        case .disabled:   return "waveform.slash"
        case .idle, .notice: return "waveform"
        }
    }
}
```

- [ ] **Step 5: Generate, build, launch**

```bash
cd App && xcodegen && cd ..
xcodebuild -project App/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/LocalFlow-*/Build/Products/Debug/LocalFlow.app
```

Expected: build succeeds; a waveform icon appears in the menu bar; macOS prompts for Microphone on first capture warm-up; Quit works. (Accessibility isn't granted yet — that's Task 20's onboarding.)

- [ ] **Step 6: Commit**

```bash
git add App .gitignore
git commit -m "feat(app): XcodeGen menu-bar shell + composition root"
```

---

### Task 19: App — floating HUD pill

**Files:**
- Create: `App/LocalFlow/HUD/HUDView.swift`, `App/LocalFlow/HUD/HUDPanel.swift`
- Modify: `App/LocalFlow/AppState.swift` (own the HUD controller, observe phase)
- Test: build + manual (dictate and watch the pill).

**Interfaces:**
- Consumes: `FlowController.Phase`, `AudioCapturing.levels`.
- Produces: `HUDPanelController(controller:levels:)` with `func observe()` — shows/hides itself from phase changes; nothing else needs to call it.

- [ ] **Step 1: Write HUDView.swift**

```swift
import SwiftUI
import FlowCore

struct HUDView: View {
    let phase: FlowController.Phase
    let level: Float   // 0…1 mic RMS while recording

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .recording(let handsFree):
                Circle().fill(.red).frame(width: 9, height: 9)
                LevelBars(level: level)
                if handsFree { Text("hands-free").font(.caption2).foregroundStyle(.secondary) }
            case .transcribing, .cleaning, .inserting:
                ProgressView().controlSize(.small)
                Text("Processing…").font(.callout)
            case .notice(let message):
                Image(systemName: "info.circle").foregroundStyle(.yellow)
                Text(message).font(.callout)
            case .idle, .disabled:
                EmptyView()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize()
    }
}

struct LevelBars: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Float(i) / 12.0 < level ? Color.red : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 14)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
```

- [ ] **Step 2: Write HUDPanel.swift**

```swift
import AppKit
import SwiftUI
import CaptureKit
import FlowCore

/// Non-activating floating pill, bottom-center. NEVER steals focus (spec §6):
/// .nonactivatingPanel + .floating level + joins all Spaces and full-screen apps.
@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private let controller: FlowController
    private var level: Float = 0
    private var hideTask: Task<Void, Never>?

    init(controller: FlowController, levels: AsyncStream<Float>) {
        self.controller = controller
        panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 240, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        Task { [weak self] in
            for await l in levels { self?.level = l; self?.render() }
        }
    }

    /// Re-render on every phase change via Observation tracking.
    func observe() {
        withObservationTracking {
            _ = controller.phase
        } onChange: {
            Task { @MainActor [weak self] in
                self?.render()
                self?.observe()
            }
        }
        render()
    }

    private func render() {
        let phase = controller.phase
        switch phase {
        case .idle, .disabled:
            hideTask?.cancel()
            hideTask = Task { [weak self] in   // brief linger so the ✓ moment isn't jarring
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
            return
        case .notice:
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        default:
            hideTask?.cancel()
        }
        panel.contentView = NSHostingView(rootView: HUDView(phase: phase, level: level))
        panel.setContentSize(panel.contentView!.fittingSize)
        position()
        panel.orderFrontRegardless()
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + 24))
    }
}
```

- [ ] **Step 3: Wire into AppState**

Add to `AppState`:

```swift
    private var hud: HUDPanelController?
```

and at the end of `bootstrap()`:

```swift
        if hud == nil {
            hud = HUDPanelController(controller: controller, levels: capture.levels)
            hud?.observe()
        }
```

- [ ] **Step 4: Build, launch, verify manually**

```bash
cd App && xcodegen && cd .. && xcodebuild -project App/LocalFlow.xcodeproj -scheme LocalFlow build
```

Manual check (Accessibility not granted yet, so trigger via phases you can reach): grant mic when prompted; the pill must appear bottom-center while phases change and NEVER take focus from the frontmost app. Full dictation check happens after Task 20.

- [ ] **Step 5: Commit**

```bash
git add App && git commit -m "feat(app): non-activating floating HUD pill"
```

---

### Task 20: App — onboarding (permissions + model download + try-it)

**Files:**
- Create: `App/LocalFlow/Onboarding/OnboardingView.swift`
- Modify: `Sources/Persistence/AppSettings.swift` (add `onboardingCompleted: Bool = false` + its tolerant-decoding line + a test in `SettingsStoreTests` asserting the default)
- Modify: `App/LocalFlow/LocalFlowApp.swift` (open onboarding window when needed)
- Test: `swift test --filter SettingsStoreTests` + manual walkthrough.

**Interfaces:**
- Consumes: `AppState` (permission flags, `modelProgress`, `bootstrap()`), `Permissions.requestAccessibility()`, `AudioCaptureService.requestMicrophoneAccess()`.
- Produces: `OnboardingView(appState:)` — a 4-step window; sets `settings.onboardingCompleted` when finished.

- [ ] **Step 1: Add the settings field + test**

In `AppSettings`: add `public var onboardingCompleted: Bool = false` with the same tolerant-decoding pattern as every other field. In `SettingsStoreTests` add:

```swift
    @Test func onboardingDefaultsToIncomplete() {
        #expect(SettingsStore(directory: tempDir()).settings.onboardingCompleted == false)
    }
```

Run: `swift test --filter SettingsStoreTests` — PASS (5 tests).

- [ ] **Step 2: Write OnboardingView.swift**

```swift
import SwiftUI
import CaptureKit
import HotkeyKit

struct OnboardingView: View {
    @Bindable var appState: AppState
    @State private var step = 0
    // Poll grants: AX/mic status have no change notifications.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case 0: welcome
            case 1: microphone
            case 2: accessibility
            case 3: model
            default: tryIt
            }
        }
        .padding(32)
        .frame(width: 460, height: 340)
        .onReceive(poll) { _ in
            appState.microphoneGranted = AudioCaptureService.microphoneAuthorized
            appState.accessibilityGranted = Permissions.accessibilityGranted
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 44))
            Text("Welcome to LocalFlow").font(.title.bold())
            Text("Hold **Fn**, speak, release — polished text appears wherever your cursor is. Everything runs on this Mac; your voice never leaves it.")
                .multilineTextAlignment(.center)
            Button("Get Started") { step = 1 }.buttonStyle(.borderedProminent)
        }
    }

    private var microphone: some View {
        permissionStep(
            title: "Microphone",
            detail: "LocalFlow needs the microphone to hear you. Audio is processed on-device and discarded after each dictation.",
            granted: appState.microphoneGranted,
            request: { Task { _ = await AudioCaptureService.requestMicrophoneAccess() } },
            next: { step = 2 })
    }

    private var accessibility: some View {
        permissionStep(
            title: "Accessibility",
            detail: "This lets LocalFlow type the transcribed text into other apps and listen for the Fn key. Enable LocalFlow in System Settings → Privacy & Security → Accessibility.",
            granted: appState.accessibilityGranted,
            request: {
                Permissions.requestAccessibility()
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            },
            next: { step = 3 })
    }

    private var model: some View {
        VStack(spacing: 12) {
            Text("Downloading speech model").font(.title2.bold())
            Text("Parakeet v3 (~600 MB, one time). You can already dictate using Apple's built-in model while this finishes.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            ProgressView(value: appState.modelReady ? 1 : appState.modelProgress)
            Text(appState.modelReady ? "Ready" : appState.modelPhaseLabel)
                .font(.caption).foregroundStyle(.secondary)
            Button(appState.modelReady ? "Continue" : "Continue (download in background)") { step = 4 }
                .buttonStyle(.borderedProminent)
        }
    }

    private var tryIt: some View {
        VStack(spacing: 12) {
            Text("Try it").font(.title2.bold())
            Text("Click into the field below, then **hold Fn** and say hello.")
            TextField("Dictate here…", text: .constant("")).textFieldStyle(.roundedBorder)
            if let last = appState.controller.lastCleanedText {
                Text("Heard: “\(last)”").foregroundStyle(.secondary)
            }
            Button("Done") {
                var s = appState.settingsStore.settings
                s.onboardingCompleted = true
                appState.settingsStore.update(s)
                NSApplication.shared.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!(appState.microphoneGranted && appState.accessibilityGranted))
        }
    }

    private func permissionStep(title: String, detail: String, granted: Bool,
                                request: @escaping () -> Void,
                                next: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(title).font(.title2.bold())
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
            }
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if granted {
                Button("Continue") { Task { await appState.bootstrap() }; next() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Grant \(title) Access") { request() }.buttonStyle(.borderedProminent)
            }
        }
    }
}
```

- [ ] **Step 3: Open onboarding from the app when needed**

In `LocalFlowApp`, add a `Window` scene and open it at launch when incomplete:

```swift
        Window("Welcome to LocalFlow", id: "onboarding") {
            OnboardingView(appState: appState)
        }
        .windowResizability(.contentSize)
```

And in the `MenuBarExtra` content add (temporary until Task 22 finalizes the menu):

```swift
            @Environment(\.openWindow) var openWindow
```

Opening at launch: in `bootstrap()` (AppState), after the permission flags are read:

```swift
        if !settingsStore.settings.onboardingCompleted
            || !accessibilityGranted || !microphoneGranted {
            NSApplication.shared.activate()
            // openWindow is a View concern: post a notification the app scene observes.
            NotificationCenter.default.post(name: .localFlowShowOnboarding, object: nil)
        }
```

with, in a shared file (add to `AppState.swift`):

```swift
extension Notification.Name {
    static let localFlowShowOnboarding = Notification.Name("localFlowShowOnboarding")
}
```

and in `LocalFlowApp`, on the MenuBarExtra label view:

```swift
            .onReceive(NotificationCenter.default.publisher(for: .localFlowShowOnboarding)) { _ in
                openWindow(id: "onboarding")
            }
```

- [ ] **Step 4: Full manual walkthrough**

Rebuild + launch. Walk all 4 steps on this machine: grant mic, grant Accessibility (System Settings opens via deep link, toggle LocalFlow on), watch the model download progress, then hold Fn in the try-it field and confirm text appears. THE CORE LOOP IS NOW LIVE end-to-end.

- [ ] **Step 5: Commit**

```bash
git add App Sources/Persistence Tests/PersistenceTests
git commit -m "feat(app): onboarding with permission walkthrough and model download"
```

---

### Task 21: App — Settings window

**Files:**
- Create: `App/LocalFlow/Settings/SettingsView.swift`, `App/LocalFlow/Settings/GeneralTab.swift`, `App/LocalFlow/Settings/TranscriptionTab.swift`, `App/LocalFlow/Settings/CleanupTab.swift`, `App/LocalFlow/Settings/DictionaryTab.swift`, `App/LocalFlow/Settings/HistoryTab.swift`, `App/LocalFlow/Settings/AboutTab.swift`
- Modify: `App/LocalFlow/LocalFlowApp.swift` (add `Settings` scene)
- Test: build + manual sweep of every control.

**Interfaces:**
- Consumes: the three stores, `AudioCaptureService.availableInputs()`, `AppleFMCleaner.isAvailable()`, `OllamaCleaner.isAvailable()`, `ParakeetTranscriber` state, `SMAppService`.
- Produces: `SettingsView(appState:)` — every spec §6 setting editable and persisted.

- [ ] **Step 1: Write SettingsView.swift (container)**

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    var body: some View {
        TabView {
            GeneralTab(appState: appState).tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionTab(appState: appState).tabItem { Label("Transcription", systemImage: "waveform") }
            CleanupTab(appState: appState).tabItem { Label("AI Cleanup", systemImage: "wand.and.stars") }
            DictionaryTab(appState: appState).tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab(appState: appState).tabItem { Label("History", systemImage: "clock") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 400)
    }
}
```

Add to `LocalFlowApp.body`:

```swift
        Settings { SettingsView(appState: appState) }
```

- [ ] **Step 2: Write the tabs**

Every tab edits a local copy and calls `appState.settingsStore.update(_:)` — a small helper on each tab keeps this uniform:

```swift
// shared helper — put in SettingsView.swift
extension AppState {
    func editSettings(_ change: (inout AppSettings) -> Void) {
        var s = settingsStore.settings
        change(&s)
        settingsStore.update(s)
    }
}
```

`GeneralTab.swift`:

```swift
import SwiftUI
import HotkeyKit
import Persistence
import ServiceManagement

struct GeneralTab: View {
    @Bindable var appState: AppState
    @State private var recordingHotkey = false
    @State private var hotkeyMonitor: Any?

    // NSEvent device-independent modifier bits (⌘ 1<<20, ⌥ 1<<19, ⌃ 1<<18, ⇧ 1<<17)
    // coincide with the CGEventFlags masks in HotkeyKit.KeyFlags, so the recorded
    // rawValue is directly usable by KeyEventInterpreter.
    private var customHotkeyLabel: String {
        if case .custom(let keyCode, _) = appState.settingsStore.settings.hotkey {
            return "Custom (key \(keyCode))"
        }
        return "Custom"
    }

    var body: some View {
        Form {
            Picker("Dictation hotkey", selection: Binding(
                get: { appState.settingsStore.settings.hotkey },
                set: { choice in
                    appState.editSettings { $0.hotkey = choice }
                    appState.hotkeySource.updateChoice(choice)
                })) {
                Text("Hold Fn (Globe)").tag(HotkeyChoice.fnKey)
                Text("Hold Right ⌘").tag(HotkeyChoice.rightCommand)
                // Show a currently-set custom combo so the Picker has a matching tag.
                if case .custom = appState.settingsStore.settings.hotkey {
                    Text(customHotkeyLabel).tag(appState.settingsStore.settings.hotkey)
                }
            }
            LabeledContent("Custom hotkey") {
                Button(recordingHotkey ? "Press your key combo…" : "Record Custom Hotkey…") {
                    recordingHotkey = true
                    // Local monitor: only sees events while Settings is the key window.
                    hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        let choice = HotkeyChoice.custom(
                            keyCode: UInt16(event.keyCode),
                            modifierRawValue: UInt64(event.modifierFlags
                                .intersection([.command, .option, .control, .shift]).rawValue))
                        appState.editSettings { $0.hotkey = choice }
                        appState.hotkeySource.updateChoice(choice)
                        recordingHotkey = false
                        if let m = hotkeyMonitor { NSEvent.removeMonitor(m); hotkeyMonitor = nil }
                        return nil   // swallow the keystroke
                    }
                }
            }
            Toggle("Double-tap for hands-free mode", isOn: Binding(
                get: { appState.settingsStore.settings.handsFreeEnabled },
                set: { on in appState.editSettings { $0.handsFreeEnabled = on } }))
            Toggle("Launch at login", isOn: Binding(
                get: { appState.settingsStore.settings.launchAtLogin },
                set: { on in
                    appState.editSettings { $0.launchAtLogin = on }
                    if on { try? SMAppService.mainApp.register() }
                    else { try? SMAppService.mainApp.unregister() }
                }))
            Text("Tip: set System Settings → Keyboard → “Press 🌐 key” to “Do Nothing” so the emoji picker never appears.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).padding()
    }
}
```

`TranscriptionTab.swift`:

```swift
import SwiftUI
import CaptureKit

struct TranscriptionTab: View {
    @Bindable var appState: AppState
    // Parakeet TDT 0.6b-v3's 25 supported languages (spec §6: auto or pin one of 25).
    private static let parakeetV3Codes = [
        "en", "de", "fr", "es", "it", "pt", "nl", "pl", "sv", "da", "fi", "el", "hu",
        "ro", "sk", "cs", "bg", "hr", "lt", "lv", "et", "sl", "mt", "uk", "ru",
    ]
    private let languages: [(code: String?, name: String)] =
        [(nil, "Auto-detect")] + parakeetV3Codes
            .map { ($0, Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
            .sorted { $0.1 < $1.1 }

    var body: some View {
        Form {
            Picker("Language", selection: Binding(
                get: { appState.settingsStore.settings.languageOverride },
                set: { code in
                    appState.editSettings { $0.languageOverride = code }
                    Task { await appState.parakeet.setLanguage(code) }
                })) {
                ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
            }
            Picker("Microphone", selection: Binding(
                get: { appState.settingsStore.settings.microphoneUID },
                set: { uid in
                    appState.editSettings { $0.microphoneUID = uid }
                    appState.capture.setPreferredInput(uid: uid)
                })) {
                Text("System default").tag(String?.none)
                ForEach(AudioCaptureService.availableInputs(), id: \.uid) {
                    Text($0.name).tag(String?.some($0.uid))
                }
            }
            LabeledContent("Speech model") {
                if appState.modelReady {
                    Label("Parakeet v3 ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .trailing) {
                        ProgressView(value: appState.modelProgress)
                        Text(appState.modelPhaseLabel).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
    }
}
```

`CleanupTab.swift`:

```swift
import SwiftUI
import CleanupKit

struct CleanupTab: View {
    @Bindable var appState: AppState
    @State private var appleFMAvailable = false
    @State private var ollamaAvailable = false

    var body: some View {
        Form {
            Picker("Cleanup level", selection: Binding(
                get: { appState.settingsStore.settings.cleanupLevel },
                set: { level in
                    appState.editSettings { $0.cleanupLevel = level }
                    Task {
                        await appState.appleFM.prewarm(options: CleanupOptions(
                            level: level, vocabulary: appState.dictionaryStore.vocabulary))
                    }
                })) {
                Text("Off — raw transcription").tag(CleanupLevel.off)
                Text("Light — instant rules only").tag(CleanupLevel.light)
                Text("Standard — AI cleanup").tag(CleanupLevel.standard)
                Text("Heavy — AI cleanup + grammar").tag(CleanupLevel.heavy)
            }
            .pickerStyle(.inline)

            Section("Providers") {
                LabeledContent("Apple Intelligence") {
                    statusBadge(appleFMAvailable,
                                offHint: "Enable Apple Intelligence in System Settings")
                }
                LabeledContent("Ollama") {
                    statusBadge(ollamaAvailable, offHint: "Not running — optional")
                }
                TextField("Ollama model", text: Binding(
                    get: { appState.settingsStore.settings.ollamaModel },
                    set: { m in appState.editSettings { $0.ollamaModel = m } }))
                    .help("Model tag to use when Ollama is the cleanup provider")
            }
        }
        .formStyle(.grouped).padding()
        .task {
            appleFMAvailable = await appState.appleFM.isAvailable()
            ollamaAvailable = await OllamaCleaner(
                model: appState.settingsStore.settings.ollamaModel).isAvailable()
        }
    }

    private func statusBadge(_ ok: Bool, offHint: String) -> some View {
        Label(ok ? "Available" : offHint,
              systemImage: ok ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(ok ? .green : .secondary)
    }
}
```

`DictionaryTab.swift`:

```swift
import SwiftUI
import CleanupKit

struct DictionaryTab: View {
    @Bindable var appState: AppState
    @State private var newTerm = ""
    @State private var newSpoken = ""
    @State private var newWritten = ""

    var body: some View {
        Form {
            Section("Vocabulary — words the AI should spell correctly") {
                HStack {
                    TextField("Add term (e.g. Kubernetes)", text: $newTerm)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm).disabled(newTerm.isEmpty)
                }
                ForEach(appState.dictionaryStore.vocabulary, id: \.self) { term in
                    HStack {
                        Text(term); Spacer()
                        Button(role: .destructive) {
                            appState.dictionaryStore.removeVocabulary(term)
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Replacements — always substitute exactly") {
                HStack {
                    TextField("Spoken (eng standup)", text: $newSpoken)
                    Image(systemName: "arrow.right")
                    TextField("Written (Engineering Standup)", text: $newWritten)
                    Button("Add") {
                        appState.dictionaryStore.addReplacement(
                            Replacement(spoken: newSpoken, written: newWritten))
                        newSpoken = ""; newWritten = ""
                    }.disabled(newSpoken.isEmpty || newWritten.isEmpty)
                }
                ForEach(appState.dictionaryStore.replacements, id: \.spoken) { r in
                    HStack {
                        Text("\(r.spoken) → \(r.written)"); Spacer()
                        Button(role: .destructive) {
                            appState.dictionaryStore.removeReplacement(r)
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
    }

    private func addTerm() {
        appState.dictionaryStore.addVocabulary(newTerm)
        newTerm = ""
    }
}

// Import/export (spec §6) — same JSON schema as the on-disk dictionary.json.
extension DictionaryTab {
    @ViewBuilder var importExportSection: some View {
        Section {
            HStack {
                Button("Import…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url,
                       let data = try? Data(contentsOf: url) {
                        try? appState.dictionaryStore.importData(data)
                    }
                }
                Button("Export…") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.json]
                    panel.nameFieldStringValue = "localflow-dictionary.json"
                    if panel.runModal() == .OK, let url = panel.url,
                       let data = try? appState.dictionaryStore.exportData() {
                        try? data.write(to: url)
                    }
                }
            }
        }
    }
}
```

Add `importExportSection` as the last section inside the `Form` in `body`, and `import UniformTypeIdentifiers` at the top of the file.

```swift
// (end of DictionaryTab)
```

`HistoryTab.swift`:

```swift
import SwiftUI
import AppKit

struct HistoryTab: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Toggle("Keep dictation history (stored only on this Mac)", isOn: Binding(
                get: { appState.settingsStore.settings.historyEnabled },
                set: { on in
                    appState.editSettings { $0.historyEnabled = on }
                    appState.historyStore.isEnabled = on
                }))
            Stepper("Keep last \(appState.settingsStore.settings.historyRetention) dictations",
                    value: Binding(
                        get: { appState.settingsStore.settings.historyRetention },
                        set: { n in
                            appState.editSettings { $0.historyRetention = n }
                            appState.historyStore.retentionLimit = n
                        }), in: 10...1000, step: 10)
            Button("Clear History", role: .destructive) { appState.historyStore.clear() }

            Section("Recent") {
                ForEach(appState.historyStore.entries.suffix(20).reversed(), id: \.timestamp) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.cleanedText).lineLimit(2)
                            Text(e.timestamp, style: .relative).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(e.cleanedText, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
    }
}
```

`AboutTab.swift`:

```swift
import SwiftUI

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 40))
            Text("LocalFlow").font(.title.bold())
            Text("Version 0.1.0").foregroundStyle(.secondary)
            Text("100% local dictation. Your voice never leaves this Mac.\nThe only network traffic is the one-time model download.")
                .multilineTextAlignment(.center)
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("Built on:").font(.caption.bold())
                Text("• FluidAudio — Apache License 2.0").font(.caption)
                Text("• NVIDIA Parakeet TDT 0.6b-v3 weights — CC-BY-4.0").font(.caption)
                Text("• Apple FoundationModels & SpeechAnalyzer").font(.caption)
            }
        }
        .padding(24)
    }
}
```

- [ ] **Step 3: Build + manual sweep**

Rebuild, open Settings from the menu bar (⌘, works once the Settings scene exists). Verify: every control persists across an app relaunch (check `~/Library/Application Support/LocalFlow/settings.json`); hotkey switch to Right ⌘ takes effect immediately; dictionary entries influence the next dictation (vocabulary in prompt, replacement applied).

- [ ] **Step 4: Commit**

```bash
git add App && git commit -m "feat(app): full settings window (6 tabs)"
```

---

### Task 22: App — complete the menu bar menu

**Files:**
- Modify: `App/LocalFlow/LocalFlowApp.swift` (full menu)
- Modify: `Sources/FlowCore/FlowController.swift` (add `setPaused(_:)`)
- Test: `Tests/FlowCoreTests/FlowControllerTests.swift` (pause test) + manual.

**Interfaces:**
- Produces: `FlowController.setPaused(_ paused: Bool)` — pausing sets `.disabled("Paused")` (hotkeys already ignored in that phase); unpausing restores `.idle`.

- [ ] **Step 1: Add the failing pause test**

Append to `FlowControllerTests`:

```swift
    @Test func pauseBlocksDictationAndUnpauseRestores() async {
        let h = Harness()
        h.controller.start()
        h.controller.setPaused(true)
        h.hotkeys.continuation.yield(.keyDown)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.startCount == 0)
        #expect(h.controller.phase == .disabled("Paused"))
        h.controller.setPaused(false)
        #expect(h.controller.phase == .idle)
    }
```

Run: `swift test --filter FlowControllerTests` — FAIL (`setPaused` missing).

- [ ] **Step 2: Implement setPaused in FlowController**

```swift
    public func setPaused(_ paused: Bool) {
        if paused {
            if machine.isRecording { run(machine.handle(.escape)) }
            phase = .disabled("Paused")
        } else if phase == .disabled("Paused") {
            phase = .idle
        }
    }
```

Run: `swift test --filter FlowControllerTests` — PASS (9 tests).

- [ ] **Step 3: Write the full menu**

Replace the `MenuBarExtra` content in `LocalFlowApp.swift`:

```swift
        MenuBarExtra {
            let paused = appState.controller.phase == .disabled("Paused")
            Button(paused ? "Resume Dictation" : "Pause Dictation") {
                appState.controller.setPaused(!paused)
            }
            Button("Copy Last Transcript") {
                if let text = appState.controller.lastCleanedText {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .disabled(appState.controller.lastCleanedText == nil)

            Menu("Recent Dictations") {
                ForEach(appState.historyStore.entries.suffix(5).reversed(), id: \.timestamp) { e in
                    Button(String(e.cleanedText.prefix(48))) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.cleanedText, forType: .string)
                    }
                }
            }
            .disabled(appState.historyStore.entries.isEmpty)

            Divider()
            if case .disabled(let reason) = appState.controller.phase, reason != "Paused" {
                Text("⚠︎ \(reason)")
            }
            SettingsLink { Text("Settings…") }.keyboardShortcut(",")
            Divider()
            Button("Quit LocalFlow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: menuIcon)
        }
```

- [ ] **Step 4: Build + manual verify**

Rebuild + relaunch. Verify: pause/resume; copy-last puts the cleaned text on the clipboard; recent list shows the last 5; the ⚠︎ row appears when a password field holds secure input (open Safari, click a password box).

- [ ] **Step 5: Commit**

```bash
git add App Sources/FlowCore Tests/FlowCoreTests
git commit -m "feat(app): full menu (pause, copy last, recent, settings)"
```

---

### Task 23: Distribution — README, manual test matrix, release workflow

**Files:**
- Create: `docs/manual-test-matrix.md`, `.github/workflows/release.yml`, `docs/homebrew-cask-template.rb`
- Modify: `README.md` (full version)
- Test: full `swift test` + the manual matrix executed once, results recorded in the matrix file.

- [ ] **Step 1: Write docs/manual-test-matrix.md**

```markdown
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
```

- [ ] **Step 2: Write the release workflow**

`.github/workflows/release.yml`:

```yaml
name: release
on:
  push:
    tags: ["v*"]
jobs:
  build-release:
    runs-on: macos-26
    env:
      DEVELOPER_DIR: /Applications/Xcode_26.5.app/Contents/Developer
    steps:
      - uses: actions/checkout@v4
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Tests
        run: swift test
      - name: Build app
        run: |
          cd App && xcodegen && cd ..
          xcodebuild -project App/LocalFlow.xcodeproj -scheme LocalFlow \
            -configuration Release -derivedDataPath build \
            CODE_SIGN_IDENTITY="-" build
      - name: Zip
        run: |
          ditto -c -k --keepParent \
            build/Build/Products/Release/LocalFlow.app LocalFlow.zip
      - name: Release
        uses: softprops/action-gh-release@v2
        with:
          files: LocalFlow.zip
          body: |
            Unsigned build — after unzipping, run once with:
            `xattr -dr com.apple.quarantine LocalFlow.app` or right-click → Open.
            (Developer ID signing + notarization planned.)
```

- [ ] **Step 3: Write docs/homebrew-cask-template.rb**

```ruby
# Template for a Homebrew cask (submit to homebrew/cask or a personal tap
# once a signed release exists; --no-quarantine needed while unsigned).
cask "localflow" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_ZIP_SHA256"
  url "https://github.com/OWNER/localflow/releases/download/v#{version}/LocalFlow.zip"
  name "LocalFlow"
  desc "Hold a key, speak, release — 100% local AI dictation"
  homepage "https://github.com/OWNER/localflow"
  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64
  app "LocalFlow.app"
end
```

(`OWNER` is the GitHub username chosen when the repo is published — the only allowed placeholder in this plan, resolved at publish time.)

- [ ] **Step 4: Write the full README.md**

```markdown
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
```

- [ ] **Step 5: Run the full gate**

```bash
swift test                          # all green
```

Then execute `docs/manual-test-matrix.md` end-to-end on this machine and fill in the results column. Fix anything ❌ before calling v0.1.0 done.

- [ ] **Step 6: Commit**

```bash
git add README.md docs .github
git commit -m "docs: README, manual test matrix, release workflow, cask template"
```

---

## Completion Criteria (spec §10)

1. Fresh-launch dictation works within 30s (SystemTranscriber path) — verified in Task 20.
2. Steady-state ≤1.5s release-to-inserted-text — measured via `localflow-cli` timings (Task 16) and stopwatch in the matrix.
3. The "no wait" self-correction golden phrase cleans correctly — matrix + `AppleFMIntegrationTests`.
4. Dictionary term respected — matrix.
5. Stranger install ≤3 min — README install path.
6. Zero network post-download — matrix (Little Snitch row).

