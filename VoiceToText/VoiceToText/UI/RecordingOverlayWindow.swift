import Cocoa
import SwiftUI

final class RecordingOverlayWindow: NSPanel {
    static let shared = RecordingOverlayWindow()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 50),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: true
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let hostingView = NSHostingView(
            rootView: RecordingOverlayView()
                .environmentObject(AppState.shared)
                .environmentObject(TranscriptionPipeline.shared)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 220, height: 50)
        contentView = hostingView

        positionNearTopCenter()
    }

    private func positionNearTopCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.maxY - frame.height - 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    @MainActor
    func show() {
        positionNearTopCenter()
        orderFrontRegardless()
    }

    @MainActor
    func hide() {
        orderOut(nil)
    }
}
