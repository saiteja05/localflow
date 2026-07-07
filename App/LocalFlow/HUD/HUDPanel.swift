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
