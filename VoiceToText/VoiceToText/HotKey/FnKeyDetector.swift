import Cocoa
import os

// MARK: - Fn Key Detector

/// Detects Fn key presses via CGEvent tap, supporting double-tap and hold detection.
final class FnKeyDetector {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceToText", category: "FnKeyDetector")

    // MARK: - Callbacks

    var onDoubleTap: (() -> Void)?
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?

    // MARK: - Configuration

    var doubleTapInterval: TimeInterval = 0.4

    // MARK: - State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    private var lastFnPressTime: Date?
    private var fnIsDown: Bool = false

    // MARK: - Lifecycle

    func start() {
        guard eventTap == nil else {
            logger.debug("Event tap already running")
            return
        }

        let tapThread = Thread { [weak self] in
            self?.createAndRunEventTap()
        }
        tapThread.name = "FnKeyDetector.EventTap"
        tapThread.qualityOfService = .userInteractive
        self.tapThread = tapThread
        tapThread.start()
    }

    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        if runLoopSource != nil {
            // Signal the run loop to stop on its thread
            if let tapThread = tapThread, tapThread.isExecuting {
                tapThread.cancel()
            }
            self.runLoopSource = nil
        }
        tapThread = nil
        fnIsDown = false
        lastFnPressTime = nil
        logger.info("Fn key detector stopped")
    }

    // MARK: - Event Tap Setup

    private func createAndRunEventTap() {
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let detector = Unmanaged<FnKeyDetector>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // Re-enable the tap if macOS disables it
                if let tap = detector.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                detector.logger.warning("Event tap was disabled, re-enabling")
                return Unmanaged.passUnretained(event)
            }

            detector.handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: callback,
            userInfo: selfPtr
        ) else {
            logger.error("Failed to create CGEvent tap. Accessibility permission may not be granted.")
            return
        }

        self.eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            logger.error("Failed to create run loop source for event tap")
            self.eventTap = nil
            return
        }

        self.runLoopSource = source

        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        logger.info("Fn key detector started")

        // Keep the run loop alive until the thread is cancelled
        while !Thread.current.isCancelled {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }

        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        logger.debug("Event tap run loop exited")
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let fnPressed = flags.contains(.maskSecondaryFn)

        if fnPressed && !fnIsDown {
            // Fn key pressed down
            fnIsDown = true
            onFnDown?()
            checkDoubleTap()
        } else if !fnPressed && fnIsDown {
            // Fn key released
            fnIsDown = false
            onFnUp?()
        }
    }

    private func checkDoubleTap() {
        let now = Date()
        defer { lastFnPressTime = now }

        guard let lastPress = lastFnPressTime else {
            return
        }

        let elapsed = now.timeIntervalSince(lastPress)
        if elapsed <= doubleTapInterval {
            logger.debug("Double-tap detected (interval: \(elapsed, format: .fixed(precision: 3))s)")
            lastFnPressTime = nil // Reset so next press starts fresh
            onDoubleTap?()
        }
    }

    deinit {
        stop()
    }
}
