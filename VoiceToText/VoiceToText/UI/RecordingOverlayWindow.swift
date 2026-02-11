import Cocoa
import SwiftUI

final class RecordingOverlayWindow: NSPanel {
    static let shared = RecordingOverlayWindow()

    private static let defaultWidth: CGFloat = 360
    private static let minHeight: CGFloat = 80
    private static let maxHeight: CGFloat = 300

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.minHeight),
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
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.minHeight)
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
    func updateHeight(_ newHeight: CGFloat) {
        let clamped = min(max(newHeight, Self.minHeight), Self.maxHeight)
        let currentFrame = frame
        // Grow downward: keep top edge fixed
        let topY = currentFrame.origin.y + currentFrame.size.height
        let newOriginY = topY - clamped
        let newFrame = NSRect(x: currentFrame.origin.x, y: newOriginY, width: Self.defaultWidth, height: clamped)
        setFrame(newFrame, display: true, animate: true)
    }

    @MainActor
    func show() {
        // Reset to minimum height
        let currentFrame = frame
        let topY = currentFrame.origin.y + currentFrame.size.height
        let resetFrame = NSRect(x: currentFrame.origin.x, y: topY - Self.minHeight, width: Self.defaultWidth, height: Self.minHeight)
        setFrame(resetFrame, display: false)
        positionNearTopCenter()
        orderFrontRegardless()
    }

    @MainActor
    func hide() {
        orderOut(nil)
    }
}
