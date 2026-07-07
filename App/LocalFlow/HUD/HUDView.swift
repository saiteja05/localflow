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
