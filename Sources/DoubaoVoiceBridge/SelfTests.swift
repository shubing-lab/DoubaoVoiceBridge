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
                SyntheticControlRoute.localSessionDictation.eventTapLocation.rawValue,
                CGEventTapLocation.cgSessionEventTap.rawValue,
                "local dictation bypasses UU HID tap"
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
            print("SELF_TEST_OK tests=10")
            return true
        }
        for failure in failures {
            fputs("SELF_TEST_FAILURE \(failure)\n", stderr)
        }
        return false
    }
}
