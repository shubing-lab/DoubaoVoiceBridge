import Foundation

enum HoldGesturePhase: Equatable {
    case idle
    case pending
    case dictating
    case passthrough
}

enum HoldGestureInput {
    case controlDown(targetAvailable: Bool)
    case controlUp
    case otherInput
    case thresholdReached
}

enum HoldGestureEffect: Equatable {
    case suppress
    case passThrough
    case scheduleThreshold
    case synthesizeControlDown
    case beginDictation
    case finishDictation
}

struct HoldGestureState {
    private(set) var phase: HoldGesturePhase = .idle

    mutating func reset() {
        phase = .idle
    }

    mutating func handle(_ input: HoldGestureInput) -> [HoldGestureEffect] {
        switch (phase, input) {
        case (.idle, .controlDown(let targetAvailable)):
            guard targetAvailable else { return [.passThrough] }
            phase = .pending
            return [.suppress, .scheduleThreshold]

        case (.pending, .thresholdReached):
            phase = .dictating
            return [.beginDictation]

        case (.pending, .otherInput):
            phase = .passthrough
            return [.synthesizeControlDown, .passThrough]

        case (.pending, .controlUp):
            phase = .idle
            return [.suppress]

        case (.dictating, .controlUp):
            return [.suppress, .finishDictation]

        case (.passthrough, .controlUp):
            phase = .idle
            return [.passThrough]

        case (.dictating, .otherInput), (.passthrough, .otherInput), (.idle, .otherInput):
            return [.passThrough]

        case (.idle, .controlUp), (.idle, .thresholdReached),
             (.pending, .controlDown), (.dictating, .controlDown),
             (.dictating, .thresholdReached), (.passthrough, .controlDown),
             (.passthrough, .thresholdReached):
            return phase == .dictating ? [.suppress] : [.passThrough]
        }
    }
}
