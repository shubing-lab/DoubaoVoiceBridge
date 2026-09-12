import Foundation
import CoreGraphics
import AppKit

enum SelfTests {
    static func run() -> Bool {
        var failures: [String] = []

        func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual != expected {
                failures.append("\(label): expected \(expected), got \(actual)")
            }
        }

        do {
            check(DeliveryFocusPolicy.decision(frontmostPID: 100, targetPID: 100, bridgePID: 200, elapsed: 0.1), .ready, "target frontmost is ready")
            check(DeliveryFocusPolicy.decision(frontmostPID: 200, targetPID: 100, bridgePID: 200, elapsed: 0.5), .retryActivation, "bridge frontmost retries activation")
            check(DeliveryFocusPolicy.decision(frontmostPID: nil, targetPID: 100, bridgePID: 200, elapsed: 0.5), .retryActivation, "unknown frontmost retries activation")
            check(DeliveryFocusPolicy.decision(frontmostPID: 300, targetPID: 100, bridgePID: 200, elapsed: 0.5), .targetChanged, "third party frontmost fails")
            check(DeliveryFocusPolicy.decision(frontmostPID: 200, targetPID: 100, bridgePID: 200, elapsed: 2.0), .targetChanged, "bridge frontmost hard timeout fails")
            check(DeliveryFocusPolicy.decision(frontmostPID: 200, targetPID: 100, bridgePID: 200, elapsed: 3.0, retryDeadline: 5.0), .retryActivation, "three second sync delay preserves retry window")
            check(DeliveryFocusPolicy.decision(frontmostPID: 200, targetPID: 100, bridgePID: 200, elapsed: 5.0, retryDeadline: 5.0), .targetChanged, "sync delay plus two seconds expires retry")
            check(DeliveryEligibilityPolicy.failure(clipboardStringMatches: false, frontmostPIDMatches: true, focusedWindowMatches: true), .clipboardChanged, "changed clipboard fails")
            check(DeliveryEligibilityPolicy.failure(clipboardStringMatches: true, frontmostPIDMatches: true, focusedWindowMatches: false), .targetChanged, "changed AX window fails")
        }

        do {
            check(
                DictationTrigger.rightOptionToggle.keyCode,
                61,
                "right Option key code"
            )
            check(
                DictationTrigger.rightOptionToggle.modifierFlag,
                .maskAlternate,
                "right Option modifier flag"
            )
            check(
                DictationTrigger.rightOptionToggle.composerInstruction.contains("右 ⌥"),
                true,
                "right Option instruction"
            )
        }

        do {
            // Models UU 4.39.1 consuming the HID event before the bridge tap:
            // physical state edges must still produce exactly one transition.
            var state = PhysicalModifierState()
            check(state.observe(false), .unchanged, "right Option IOHID initial state")
            check(state.observe(true), .pressed, "right Option IOHID recovers press")
            check(state.observe(true), .unchanged, "right Option IOHID de-duplicates press")
            check(state.observe(false), .released, "right Option IOHID recovers release")
            check(state.observe(false), .unchanged, "right Option IOHID de-duplicates release")
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: true)), [.suppress, .scheduleThreshold], "long hold down")
            check(state.phase, .pending, "long hold pending")
            check(state.handle(.thresholdReached), [.beginDictation], "long hold threshold")
            check(state.phase, .dictating, "long hold dictating")
            check(state.handle(.controlUp), [.suppress, .finishDictation], "long hold release")
            state.reset()
            check(state.phase, .idle, "long hold idle")
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.otherInput), [.synthesizeControlDown, .passThrough], "chord recovery")
            check(state.phase, .passthrough, "chord passthrough")
            check(state.handle(.controlUp), [.passThrough], "chord release")
            check(state.phase, .idle, "chord idle")
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: false)), [.passThrough], "non-UU down")
            check(state.phase, .idle, "non-UU idle")
            check(state.handle(.controlUp), [.passThrough], "non-UU release")
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.controlUp), [.suppress], "quick tap")
            check(state.phase, .idle, "quick tap idle")
        }

        do {
            check(
                UURemoteForegroundEligibility.allowsTarget(
                    isFrontmost: true,
                    uuIsActive: false
                ),
                true,
                "frontmost UU is eligible"
            )
            check(
                UURemoteForegroundEligibility.allowsTarget(
                    isFrontmost: false,
                    uuIsActive: true
                ),
                true,
                "active UU remote window is eligible"
            )
            check(
                UURemoteForegroundEligibility.allowsTarget(
                    isFrontmost: false,
                    uuIsActive: false
                ),
                false,
                "background UU remains ineligible"
            )
        }

        do {
            let flagsMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
            let uu = InstalledEventTap(
                processIdentifier: 100,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            let bridge = InstalledEventTap(
                processIdentifier: 200,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [uu, bridge], bridgePID: 200, uuRemotePID: 100),
                true,
                "UU tap ahead requires reinstall"
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [bridge, uu], bridgePID: 200, uuRemotePID: 100),
                false,
                "bridge tap ahead stays installed"
            )
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 100),
                0.25,
                "same-PID UU activation is audited"
            )
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 101),
                0.8,
                "new-PID UU launch gets settle time"
            )
        }

        do {
            check(
                SyntheticControlRoute.localHIDDictation.eventTapLocation.rawValue,
                CGEventTapLocation.cghidEventTap.rawValue,
                "local dictation reaches input method HID taps"
            )
            check(
                SyntheticControlRoute.remoteHIDPassthrough.eventTapLocation.rawValue,
                CGEventTapLocation.cghidEventTap.rawValue,
                "remote Control chords stay on HID path"
            )
        }

        do {
            do {
                let events = try ClipboardKeyboardPaster.makeCommandVEvents()
                check(events.count, 4, "Command-V event count")
                check(
                    events.map(\.type),
                    [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                    "Command-V event types"
                )
                check(
                    events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                    [55, 9, 9, 55],
                    "Command-V event key codes"
                )
                check(events[0].flags.contains(.maskCommand), true, "Command down flag")
                check(
                    (events[0].flags.rawValue & 0x8) != 0,
                    true,
                    "left Command device flag"
                )
                check(events[1].flags, events[0].flags, "V down inherits Command state")
                check(events[2].flags, events[0].flags, "V up inherits Command state")
                check(events[3].flags.contains(.maskCommand), false, "Command up clears flag")
                check(
                    (events[3].flags.rawValue & 0x8) == 0,
                    true,
                    "Command up clears left device flag"
                )
                check(
                    events.allSatisfy {
                        $0.getIntegerValueField(.eventSourceUserData) ==
                            ControlHoldMonitor.syntheticEventMarker
                    },
                    true,
                    "Command-V events carry bridge marker"
                )
            } catch {
                failures.append("Command-V event creation: \(error)")
            }
        }

        do {
            check(PrivacySafeTextMetrics.lengthBucket(0), "empty", "empty length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(4), "1-4", "short length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(16), "5-16", "medium length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(64), "17-64", "long length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(65), "65+", "largest length bucket")
        }

        do {
            let name = NSPasteboard.Name("com.lyp.DoubaoVoiceBridge.self-test-\(UUID().uuidString)")
            let pasteboard = NSPasteboard(name: name)
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            _ = pasteboard.setString("same text", forType: .string)
            let firstGeneration = pasteboard.changeCount
            pasteboard.clearContents()
            _ = pasteboard.setString("same text", forType: .string)
            let secondGeneration = pasteboard.changeCount
            check(secondGeneration != firstGeneration, true, "same text pasteboard generation changes")
            check(
                DeliveryEligibilityPolicy.failure(
                    clipboardStringMatches: pasteboard.string(forType: .string) == "same text",
                    frontmostPIDMatches: true,
                    focusedWindowMatches: true
                ),
                nil,
                "same text survives clipboard generation change"
            )
            pasteboard.clearContents()
            check(
                DeliveryEligibilityPolicy.failure(
                    clipboardStringMatches: pasteboard.string(forType: .string) == "same text",
                    frontmostPIDMatches: true,
                    focusedWindowMatches: true
                ),
                .clipboardChanged,
                "cleared pasteboard blocks delivery"
            )
            _ = pasteboard.setString("different text", forType: .string)
            check(
                DeliveryEligibilityPolicy.failure(
                    clipboardStringMatches: pasteboard.string(forType: .string) == "same text",
                    frontmostPIDMatches: true,
                    focusedWindowMatches: true
                ),
                .clipboardChanged,
                "different text blocks delivery"
            )
            _ = pasteboard.setString("", forType: .string)
            check(
                DeliveryEligibilityPolicy.failure(
                    clipboardStringMatches: pasteboard.string(forType: .string) == "same text",
                    frontmostPIDMatches: true,
                    focusedWindowMatches: true
                ),
                .clipboardChanged,
                "empty string blocks delivery"
            )
            check(
                DeliveryEligibilityPolicy.failure(
                    clipboardStringMatches: true,
                    frontmostPIDMatches: false,
                    focusedWindowMatches: true
                ),
                .targetChanged,
                "target PID mismatch blocks delivery"
            )
            check(
                DeliveryEligibilityPolicy.failure(
                    clipboardStringMatches: true,
                    frontmostPIDMatches: true,
                    focusedWindowMatches: false
                ),
                .targetChanged,
                "focused window mismatch blocks delivery"
            )
        }

        do {
            check(
                TranscriptSettlePolicy.timeoutDecision(elapsed: 8.1),
                .continueWaiting,
                "soft transcript timeout keeps polling"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 8.1,
                    stableFor: 0.35
                ),
                true,
                "late unmarked transcript settles after soft timeout"
            )
            check(
                TranscriptSettlePolicy.timeoutDecision(elapsed: 30.0),
                .timeout,
                "hard transcript timeout fires at thirty seconds"
            )
        }

        do {
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: true,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "empty transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.45,
                    stableFor: 0.35
                ),
                true,
                "settle at optimized thresholds"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: true,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "marked transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.44,
                    stableFor: 1.0
                ),
                false,
                "release grace is preserved"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 0.34
                ),
                false,
                "tail correction resets stable window"
            )
            check(
                UURemoteDelivery.defaultPasteDelay >= UURemoteDelivery.minimumPasteDelay,
                true,
                "default UU sync delay respects safety floor"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.9)),
                UURemoteDelivery.defaultPasteDelay,
                "numeric v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: "0.9"),
                UURemoteDelivery.defaultPasteDelay,
                "string v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.7)),
                nil,
                "custom delay is preserved"
            )
        }

        do {
            let scrollView = NSScrollView(frame: .zero)
            let textView = NSTextView()
            textView.textContainerInset = NSSize(width: 12, height: 10)
            ComposerTextLayout.attach(textView, to: scrollView)
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
            ComposerTextLayout.synchronize(textView, with: scrollView)
            check(textView.frame.width > 0, true, "composer text view has drawable width")
            check(
                textView.frame.width,
                scrollView.contentSize.width,
                "composer text view tracks scroll width"
            )
            check(
                (textView.textContainer?.containerSize.width ?? 0) > 0,
                true,
                "composer text container has drawable width"
            )
            check(
                textView.textContainer?.widthTracksTextView,
                true,
                "composer container tracks text view width"
            )
        }

        if failures.isEmpty {
            print("SELF_TEST_OK tests=12")
            return true
        }
        for failure in failures {
            fputs("SELF_TEST_FAILURE \(failure)\n", stderr)
        }
        return false
    }
}
