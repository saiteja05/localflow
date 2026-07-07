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
