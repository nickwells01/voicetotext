import Cocoa
import SwiftUI

final class RecordingOverlayWindow: NSPanel {
    static let shared = RecordingOverlayWindow()

    private static let defaultWidth: CGFloat = 360
    private static let minHeight: CGFloat = 80
    private static let maxHeight: CGFloat = 300

    private var isUpdatingHeight = false

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
        hostingView.sizingOptions = []
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
        guard !isUpdatingHeight else { return }
        isUpdatingHeight = true
        defer { isUpdatingHeight = false }

        let clamped = min(max(newHeight, Self.minHeight), Self.maxHeight)
        let currentFrame = frame
        // Grow downward: keep top edge fixed
        let topY = currentFrame.origin.y + currentFrame.size.height
        let newOriginY = topY - clamped
        let newFrame = NSRect(x: currentFrame.origin.x, y: newOriginY, width: Self.defaultWidth, height: clamped)
        setFrame(newFrame, display: true, animate: false)
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

    @MainActor
    func showToast(_ message: String) {
        // Show overlay briefly with toast message, then auto-hide after 2 seconds
        AppState.shared.toastMessage = message
        orderFrontRegardless()

        let minToastHeight: CGFloat = 80
        updateHeight(minToastHeight)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            AppState.shared.toastMessage = nil
            self?.orderOut(nil)
        }
    }
}
