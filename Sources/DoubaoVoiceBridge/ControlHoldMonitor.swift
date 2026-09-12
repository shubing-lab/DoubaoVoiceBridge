import AppKit
import ApplicationServices
import IOKit.hid
import os.log

enum ControlMonitorError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        "无法监听左 Control，请开启“辅助功能”和“输入监控”权限"
    }
}

enum DictationTrigger: Equatable {
    case leftControlHold
    case rightOptionToggle

    var keyCode: Int64 {
        switch self {
        case .leftControlHold: return 59
        case .rightOptionToggle: return 61
        }
    }

    var modifierFlag: CGEventFlags {
        switch self {
        case .leftControlHold: return .maskControl
        case .rightOptionToggle: return .maskAlternate
        }
    }

    var composerInstruction: String {
        switch self {
        case .leftControlHold: return "按住左 ⌃ 说话，松开后自动发送"
        case .rightOptionToggle: return "说完后再按右 ⌥，自动发送到 Mac mini"
        }
    }
}

/// Tracks the physical modifier state independently of Quartz event delivery.
/// UU 4.39.1 can consume the event before our tap callback, so the monitor uses
/// this seam for IOHID and event-tap callbacks alike and handles each edge once.
struct PhysicalModifierState: Equatable {
    private(set) var isDown = false

    mutating func observe(_ physicalState: Bool) -> PhysicalModifierTransition {
        guard physicalState != isDown else { return .unchanged }
        isDown = physicalState
        return physicalState ? .pressed : .released
    }
}

enum PhysicalModifierTransition: Equatable {
    case unchanged
    case pressed
    case released
}

final class ControlHoldMonitor {
    static let syntheticEventMarker: Int64 = 0x4456_4252
    private static let rightOptionComposerFocusDelay: TimeInterval = 0.12
    private static let keyboardUsagePage: UInt32 = 0x01
    private static let keyboardUsage: UInt32 = 0x06
    private static let rightOptionUsagePage: UInt32 = 0x07
    private static let rightOptionUsage: UInt32 = 0xE6
    private static let leftControlKeyCode: Int64 = DictationTrigger.leftControlHold.keyCode
    private static let rightOptionKeyCode: Int64 = DictationTrigger.rightOptionToggle.keyCode

    private let holdThreshold: TimeInterval
    private let targetProvider: () -> UURemoteTarget?
    private let localComposerReady: () -> Bool
    private let onBegin: (UURemoteTarget, DictationTrigger) -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "control")

    private var gesture = HoldGestureState()
    private var target: UURemoteTarget?
    private var activationWorkItem: DispatchWorkItem?
    private var syntheticDownWorkItem: DispatchWorkItem?
    private var syntheticDownPosted = false
    private var syntheticDownAt: Date?
    private var syntheticRoute: SyntheticControlRoute?
    private var syntheticTrigger: DictationTrigger?
    private var trigger: DictationTrigger?
    private var optionVoiceStarted = false
    private var localFocusDeadline: Date?
    private var releaseRequestedBeforeSyntheticDown = false
    private var physicalLeftControlIsDown = false
    private var physicalRightControlIsDown = false
    private var physicalRightOptionState = PhysicalModifierState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var hidManagerScheduled = false
    private(set) var activeTapLocation: CGEventTapLocation?
    var isGestureIdle: Bool { gesture.phase == .idle }

    init(
        holdThreshold: TimeInterval,
        targetProvider: @escaping () -> UURemoteTarget?,
        localComposerReady: @escaping () -> Bool,
        onBegin: @escaping (UURemoteTarget, DictationTrigger) -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.holdThreshold = min(max(holdThreshold, 0.18), 0.60)
        self.targetProvider = targetProvider
        self.localComposerReady = localComposerReady
        self.onBegin = onBegin
        self.onRelease = onRelease
        self.onCancel = onCancel
    }

    deinit {
        stop()
    }

    func start() throws {
        guard eventTap == nil else { return }

        let eventTypes: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel
        ]
        let eventMask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ControlHoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(proxy: proxy, type: type, event: event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            throw ControlMonitorError.eventTapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw ControlMonitorError.eventTapUnavailable
        }

        eventTap = tap
        activeTapLocation = .cghidEventTap
        physicalLeftControlIsDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Self.leftControlKeyCode))
        physicalRightControlIsDown = CGEventSource.keyState(.combinedSessionState, key: 62)
        physicalRightOptionState = PhysicalModifierState()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startHIDFallback()
        logger.notice("HID event tap started at head")
    }

    func stop() {
        resetGesture(notifyCancel: true)
        stopHIDFallback()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        activeTapLocation = nil
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.error("HID event tap disabled; re-enabling (reason=\(type.rawValue, privacy: .public))")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            resetGesture(notifyCancel: true)
            physicalLeftControlIsDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Self.leftControlKeyCode))
            physicalRightControlIsDown = CGEventSource.keyState(.combinedSessionState, key: 62)
            physicalRightOptionState = PhysicalModifierState()
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, keyCode == 62 {
            physicalRightControlIsDown.toggle()
            if gesture.phase == .pending {
                beginPassthroughForChord()
            } else if gesture.phase == .dictating {
                onCancel()
                resetGesture(notifyCancel: false)
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged, keyCode == Self.rightOptionKeyCode {
            // The aggregate Option flag can remain set by left Option after
            // right Option is released. Query the individual physical key;
            // a delayed callback is still a no-op if IOHID saw the edge first.
            let isDown = CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(Self.rightOptionKeyCode)
            )
            switch physicalRightOptionState.observe(isDown) {
            case .pressed:
                return handleRightOption(isDown: true, event: event)
            case .released:
                return handleRightOption(isDown: false, event: event)
            case .unchanged:
                return Unmanaged.passUnretained(event)
            }
        }
        if type == .flagsChanged, keyCode == Self.leftControlKeyCode {
            physicalLeftControlIsDown.toggle()
            let isDown = physicalLeftControlIsDown
            if isDown, case .idle = gesture.phase {
                let conflictingFlags: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]
                if physicalRightControlIsDown || !event.flags.intersection(conflictingFlags).isEmpty {
                    return Unmanaged.passUnretained(event)
                }
            }
            return handleLeftControl(isDown: isDown, event: event)
        }

        switch gesture.phase {
        case .pending:
            logger.notice("Dictation shortcut became a chord; restoring remote modifier passthrough")
            beginPassthroughForChord(proxy: proxy)
        case .dictating where trigger == .rightOptionToggle && type == .keyDown:
            logger.notice("Key press ended right Option dictation")
            finishOptionDictation()
            return nil
        case .idle, .dictating, .passthrough:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private static let hidInputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let monitor = Unmanaged<ControlHoldMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.handleHIDValue(value)
    }

    private func startHIDFallback() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: Self.keyboardUsagePage,
            kIOHIDDeviceUsageKey as String: Self.keyboardUsage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, Self.hidInputValueCallback, context)
        let runLoopMode = CFRunLoopMode.defaultMode.rawValue
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), runLoopMode)
        hidManagerScheduled = true
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            logger.error("IOHID right Option fallback unavailable (status=\(status, privacy: .public))")
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), runLoopMode)
            hidManagerScheduled = false
            return
        }
        hidManager = manager
        logger.notice("IOHID physical right Option fallback started")
    }

    private func stopHIDFallback() {
        guard let manager = hidManager else { return }
        if hidManagerScheduled {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
        hidManagerScheduled = false
    }

    private func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == Self.rightOptionUsagePage,
              IOHIDElementGetUsage(element) == Self.rightOptionUsage else { return }
        let physicalState = IOHIDValueGetIntegerValue(value) != 0
        let transition = physicalRightOptionState.observe(physicalState)
        guard transition != .unchanged else { return }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(source: source) else {
            logger.error("Unable to create right Option HID fallback event")
            return
        }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Self.rightOptionKeyCode)
        event.flags = CGEventSource.flagsState(.hidSystemState)
        logger.notice("Physical right Option edge recovered by IOHID (down=\(physicalState, privacy: .public))")
        _ = handleRightOption(isDown: physicalState, event: event)
    }

    private func handleLeftControl(isDown: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        if trigger == .rightOptionToggle {
            if gesture.phase == .pending {
                beginPassthroughForChord()
            }
            return Unmanaged.passUnretained(event)
        }
        if isDown {
            guard case .idle = gesture.phase else {
                return gesture.phase == .passthrough ? Unmanaged.passUnretained(event) : nil
            }
            guard let target = targetProvider() else {
                logger.notice("Left Control passed through because UU is not eligible")
                return Unmanaged.passUnretained(event)
            }

            logger.notice("Physical left Control down intercepted for local dictation")
            self.target = target
            trigger = .leftControlHold
            _ = gesture.handle(.controlDown(targetAvailable: true))
            let workItem = DispatchWorkItem { [weak self] in self?.activateDictationIfStillPending() }
            activationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
            return nil
        }

        switch gesture.phase {
        case .idle:
            return Unmanaged.passUnretained(event)
        case .pending:
            logger.notice("Physical left Control released before long-press threshold")
            _ = gesture.handle(.controlUp)
            resetGesture(notifyCancel: false)
            return nil
        case .passthrough:
            _ = gesture.handle(.controlUp)
            // The real left-Control release is about to pass through, so it
            // completes the synthetic down used to recover the chord.
            syntheticDownPosted = false
            resetGesture(notifyCancel: false)
            return Unmanaged.passUnretained(event)
        case .dictating:
            logger.notice("Physical left Control released; finishing local dictation")
            _ = gesture.handle(.controlUp)
            finishDictationGesture()
            return nil
        }
    }

    private func handleRightOption(isDown: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        if isDown {
            if gesture.phase == .dictating, trigger == .rightOptionToggle {
                return nil
            }
            guard case .idle = gesture.phase else {
                return gesture.phase == .passthrough ? Unmanaged.passUnretained(event) : nil
            }
            let conflictingFlags: CGEventFlags = [.maskShift, .maskControl, .maskCommand, .maskSecondaryFn]
            guard event.flags.intersection(conflictingFlags).isEmpty else {
                return Unmanaged.passUnretained(event)
            }
            guard let target = targetProvider() else {
                logger.notice("Right Option passed through because UU is not eligible")
                return Unmanaged.passUnretained(event)
            }

            logger.notice("Physical right Option intercepted for local dictation")
            self.target = target
            trigger = .rightOptionToggle
            _ = gesture.handle(.controlDown(targetAvailable: true))
            return nil
        }

        guard trigger == .rightOptionToggle else {
            return Unmanaged.passUnretained(event)
        }
        switch gesture.phase {
        case .idle:
            return Unmanaged.passUnretained(event)
        case .pending:
            guard let target else {
                resetGesture(notifyCancel: false)
                return nil
            }
            _ = gesture.handle(.thresholdReached)
            target.captureFocusedWindow()
            logger.notice("Right Option pressed; opening local composer")
            onBegin(target, .rightOptionToggle)
            localFocusDeadline = Date().addingTimeInterval(0.75)
            scheduleSyntheticDownCheck(after: Self.rightOptionComposerFocusDelay)
            return nil
        case .passthrough:
            _ = gesture.handle(.controlUp)
            syntheticDownPosted = false
            resetGesture(notifyCancel: false)
            return Unmanaged.passUnretained(event)
        case .dictating:
            logger.notice("Physical right Option released; finishing local dictation")
            finishOptionDictation()
            return nil
        }
    }

    private func activateDictationIfStillPending() {
        guard case .pending = gesture.phase,
              trigger == .leftControlHold,
              let target else { return }
        guard !physicalRightControlIsDown,
              targetProvider()?.processIdentifier == target.processIdentifier else {
            logger.notice("Long-press cancelled because UU is no longer the eligible target")
            resetGesture(notifyCancel: false)
            return
        }
        _ = gesture.handle(.thresholdReached)
        target.captureFocusedWindow()
        logger.notice("Long-press threshold reached; opening local composer")
        onBegin(target, .leftControlHold)
        localFocusDeadline = Date().addingTimeInterval(0.75)
        scheduleSyntheticDownCheck(after: 0.03)
    }

    private func postSyntheticDownIfNeeded() {
        guard case .dictating = gesture.phase, !syntheticDownPosted else { return }
        if releaseRequestedBeforeSyntheticDown {
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        guard localComposerReady() else {
            if Date() < localFocusDeadline ?? .distantPast {
                scheduleSyntheticDownCheck(after: 0.02)
            } else {
                logger.error("Local composer did not become ready; cancelling dictation")
                onCancel()
                resetGesture(notifyCancel: false)
            }
            return
        }
        guard let trigger else { return }
        logger.notice("Local composer is key and ready for Doubao voice input method")
        let route = SyntheticControlRoute.localHIDDictation
        guard postSyntheticModifier(trigger, down: true, route: route) else {
            logger.error("Unable to create synthetic local dictation shortcut")
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        switch trigger {
        case .leftControlHold:
            syntheticDownPosted = true
            syntheticDownAt = Date()
            syntheticRoute = route
            syntheticTrigger = trigger
            logger.notice("Synthetic local Control down posted at HID tap")
        case .rightOptionToggle:
            guard postSyntheticModifier(trigger, down: false, route: route) else {
                logger.error("Unable to complete synthetic local right Option press")
                onCancel()
                resetGesture(notifyCancel: false)
                return
            }
            optionVoiceStarted = true
            logger.notice("Synthetic local right Option press posted at HID tap")
        }
    }

    private func scheduleSyntheticDownCheck(after delay: TimeInterval) {
        syntheticDownWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.postSyntheticDownIfNeeded() }
        syntheticDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishDictationGesture() {
        if syntheticDownPosted {
            if let syntheticRoute {
                postSyntheticModifier(.leftControlHold, down: false, route: syntheticRoute)
            }
            syntheticDownPosted = false
            let heldLongEnough = Date().timeIntervalSince(syntheticDownAt ?? .distantPast) >= 0.15
            if heldLongEnough {
                logger.notice("Local Doubao voice input method gesture completed; waiting for transcript")
                onRelease()
            } else {
                logger.notice("Synthetic local Control hold was too short; cancelling")
                onCancel()
            }
            resetGesture(notifyCancel: false)
        } else {
            releaseRequestedBeforeSyntheticDown = true
        }
    }

    private func finishOptionDictation() {
        guard trigger == .rightOptionToggle else { return }
        guard optionVoiceStarted else {
            releaseRequestedBeforeSyntheticDown = true
            return
        }
        let route = SyntheticControlRoute.localHIDDictation
        guard postSyntheticModifier(.rightOptionToggle, down: true, route: route),
              postSyntheticModifier(.rightOptionToggle, down: false, route: route) else {
            logger.error("Unable to complete synthetic local right Option press")
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        logger.notice("Local right Option dictation gesture completed; waiting for transcript")
        onRelease()
        resetGesture(notifyCancel: false)
    }

    private func beginPassthroughForChord(proxy: CGEventTapProxy? = nil) {
        guard case .pending = gesture.phase else { return }
        activationWorkItem?.cancel()
        activationWorkItem = nil
        _ = gesture.handle(.otherInput)
        guard let trigger else { return }
        target = nil
        let route = SyntheticControlRoute.remoteHIDPassthrough
        if postSyntheticModifier(trigger, down: true, route: route, proxy: proxy) {
            syntheticDownPosted = true
            syntheticRoute = route
            syntheticTrigger = trigger
        } else {
            logger.error("Unable to recover remote modifier chord")
        }
    }

    private func resetGesture(notifyCancel: Bool) {
        let wasDictating = gesture.phase == .dictating
        if syntheticDownPosted, let syntheticRoute, let syntheticTrigger {
            postSyntheticModifier(syntheticTrigger, down: false, route: syntheticRoute)
        }
        activationWorkItem?.cancel()
        syntheticDownWorkItem?.cancel()
        activationWorkItem = nil
        syntheticDownWorkItem = nil
        syntheticDownPosted = false
        syntheticDownAt = nil
        syntheticRoute = nil
        syntheticTrigger = nil
        trigger = nil
        optionVoiceStarted = false
        localFocusDeadline = nil
        releaseRequestedBeforeSyntheticDown = false
        gesture.reset()
        target = nil
        if notifyCancel && wasDictating { onCancel() }
    }

    @discardableResult
    private func postSyntheticModifier(
        _ trigger: DictationTrigger,
        down: Bool,
        route: SyntheticControlRoute,
        proxy: CGEventTapProxy? = nil
    ) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(source: source) else { return false }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: trigger.keyCode)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        var flags = CGEventSource.flagsState(.combinedSessionState)
        if down {
            flags.insert(trigger.modifierFlag)
        } else {
            switch trigger {
            case .leftControlHold:
                if !physicalRightControlIsDown {
                    flags.remove(.maskControl)
                }
            case .rightOptionToggle:
                flags.remove(.maskAlternate)
            }
        }
        event.flags = flags
        if route == .remoteHIDPassthrough, let proxy {
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: route.eventTapLocation)
        }
        return true
    }
}

enum SyntheticControlRoute: Equatable {
    case remoteHIDPassthrough
    case localHIDDictation

    var eventTapLocation: CGEventTapLocation {
        switch self {
        case .remoteHIDPassthrough, .localHIDDictation:
            return .cghidEventTap
        }
    }
}
