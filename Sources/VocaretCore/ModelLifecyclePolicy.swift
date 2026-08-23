enum LocalModelTarget: Equatable, Sendable {
    case none
    case whisper
    case parakeet
}

enum ModelLifecycleAction: Equatable, Sendable {
    case unloadWhisper
    case unloadParakeet
    case preloadWhisper
    case preloadParakeet
}

enum ModelLifecyclePolicy {
    static func shouldApplySelection(requestedEngine: String, currentEngine: String) -> Bool {
        requestedEngine == currentEngine
    }

    static func shouldUnloadCloudFallback(
        startingGeneration: Int,
        currentGeneration: Int,
        currentEngine: String
    ) -> Bool {
        startingGeneration == currentGeneration && currentEngine == "soniox"
    }

    static func preloadTarget(engine: String) -> LocalModelTarget {
        switch engine.lowercased() {
        case "soniox": .none
        case "parakeet": .parakeet
        default: .whisper
        }
    }

    static func switchActions(from _: String, to engine: String) -> [ModelLifecycleAction] {
        var actions: [ModelLifecycleAction] = [.unloadWhisper, .unloadParakeet]
        switch preloadTarget(engine: engine) {
        case .none:
            break
        case .whisper:
            actions.append(.preloadWhisper)
        case .parakeet:
            actions.append(.preloadParakeet)
        }
        return actions
    }
}
