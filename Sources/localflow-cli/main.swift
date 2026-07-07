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
