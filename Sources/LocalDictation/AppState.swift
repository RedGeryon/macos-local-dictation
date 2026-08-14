import Foundation

enum DictationMode: String, Sendable {
    case pushToTalk
    case handsFree
}

enum ConfigurationIssue: Equatable, Sendable {
    case engineMissing
    case engineNotExecutable
    case modelMissing
    case modelNotGGUF

    var message: String {
        switch self {
        case .engineMissing:
            return "Speech engine required"
        case .engineNotExecutable:
            return "Speech engine is not executable"
        case .modelMissing:
            return "Speech model required"
        case .modelNotGGUF:
            return "Choose a valid GGUF model"
        }
    }
}

enum AppState: Equatable, Sendable {
    case starting
    case installationRequired
    case configurationRequired(ConfigurationIssue)
    case loadingModel
    case ready
    case recording(DictationMode)
    case startingConversation
    case recordingConversation
    case savingConversation
    case finalizing
    case inserting
    case canceling
    case permissionRequired
    case serverUnavailable(String)
    case error(String)

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .installationRequired: return "Move to Applications"
        case .configurationRequired(let issue): return issue.message
        case .loadingModel: return "Loading speech model…"
        case .ready: return "Ready"
        case .recording(.pushToTalk): return "Listening"
        case .recording(.handsFree): return "Hands-free"
        case .startingConversation: return "Starting conversation…"
        case .recordingConversation: return "Recording conversation"
        case .savingConversation: return "Saving conversation…"
        case .finalizing: return "Finishing transcription…"
        case .inserting: return "Inserting text…"
        case .canceling: return "Canceling…"
        case .permissionRequired: return "Permissions required"
        case .serverUnavailable: return "Speech engine unavailable"
        case .error: return "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .recording, .recordingConversation: return "waveform.circle.fill"
        case .loadingModel, .starting, .startingConversation, .savingConversation,
             .finalizing, .inserting, .canceling:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .installationRequired, .configurationRequired, .permissionRequired:
            return "exclamationmark.circle.fill"
        case .serverUnavailable, .error:
            return "xmark.circle.fill"
        }
    }

    var isReady: Bool {
        self == .ready
    }
}
