import AppKit
import Foundation

/// How urgent a feature's current status is. Drives color and icon everywhere the
/// menu bar and the Settings window show a status dot.
enum FeatureStatusTone: Equatable, Sendable {
    case off
    case idle
    case ready
    case busy
    case recording
    case attention
}

/// One feature's status, phrased the same way in the menu bar and in Settings.
struct FeatureStatusPresentation: Equatable, Sendable {
    let label: String
    let detail: String?
    let tone: FeatureStatusTone

    init(label: String, detail: String? = nil, tone: FeatureStatusTone) {
        self.label = label
        self.detail = detail
        self.tone = tone
    }

    var color: NSColor {
        switch tone {
        case .off: return .tertiaryLabelColor
        case .idle: return .secondaryLabelColor
        case .ready: return .systemGreen
        case .busy: return .systemBlue
        case .recording: return .systemRed
        case .attention: return .systemOrange
        }
    }

    var symbolName: String {
        switch tone {
        case .off: return "circle.dotted"
        case .attention: return "exclamationmark.circle.fill"
        default: return "circle.fill"
        }
    }

    static func speechToText(
        state: AppState,
        engine: LocalFeatureRuntimeStatus,
        enabled: Bool
    ) -> FeatureStatusPresentation {
        guard enabled else {
            return FeatureStatusPresentation(label: "Disabled", tone: .off)
        }

        switch state {
        case .recording, .recordingConversation:
            return FeatureStatusPresentation(label: state.label, tone: .recording)
        case .transcribingFile, .inspectingMedia, .finalizing, .inserting,
             .savingConversation, .startingConversation:
            return FeatureStatusPresentation(label: state.label, tone: .busy)
        case .installationRequired, .permissionRequired:
            return FeatureStatusPresentation(label: state.label, tone: .attention)
        case .configurationRequired(let issue):
            return FeatureStatusPresentation(label: state.label, detail: issue.message, tone: .attention)
        case .serverUnavailable(let message), .error(let message):
            return FeatureStatusPresentation(label: state.label, detail: message, tone: .attention)
        default:
            break
        }

        switch engine {
        case .disabled:
            return FeatureStatusPresentation(label: "Disabled", tone: .off)
        case .loading:
            return FeatureStatusPresentation(label: "Loading…", tone: .busy)
        case .error(let message):
            return FeatureStatusPresentation(label: "Needs attention", detail: message, tone: .attention)
        case .notLoaded:
            return FeatureStatusPresentation(label: "Not loaded", tone: .idle)
        case .ready:
            if state == .ready {
                return FeatureStatusPresentation(label: "Ready", tone: .ready)
            }
            return FeatureStatusPresentation(label: state.label, tone: .busy)
        }
    }

    static func textToSpeech(
        state: TextToSpeechState,
        engine: LocalFeatureRuntimeStatus,
        enabled: Bool
    ) -> FeatureStatusPresentation {
        guard enabled else {
            return FeatureStatusPresentation(label: "Disabled", tone: .off)
        }

        switch state {
        case .speaking(let paused):
            return FeatureStatusPresentation(label: paused ? "Paused" : "Reading…", tone: .busy)
        case .generating:
            return FeatureStatusPresentation(label: "Generating audio…", tone: .busy)
        case .starting:
            return FeatureStatusPresentation(label: "Preparing…", tone: .busy)
        case .canceling:
            return FeatureStatusPresentation(label: "Canceling…", tone: .busy)
        case .unavailable(let message):
            return FeatureStatusPresentation(label: "Needs setup", detail: message, tone: .attention)
        case .error(let message):
            return FeatureStatusPresentation(label: "Needs attention", detail: message, tone: .attention)
        case .idle, .ready:
            break
        }

        switch engine {
        case .disabled:
            return FeatureStatusPresentation(label: "Disabled", tone: .off)
        case .loading:
            return FeatureStatusPresentation(label: "Loading…", tone: .busy)
        case .error(let message):
            return FeatureStatusPresentation(label: "Needs attention", detail: message, tone: .attention)
        case .notLoaded:
            return FeatureStatusPresentation(label: "Not loaded", tone: .idle)
        case .ready:
            return FeatureStatusPresentation(label: "Ready", tone: .ready)
        }
    }

    /// The menu-bar icon tint, or nil to keep the default template color.
    static func menuBarTint(
        speechToText: FeatureStatusPresentation,
        textToSpeech: FeatureStatusPresentation
    ) -> NSColor? {
        let tones = [speechToText.tone, textToSpeech.tone]
        if tones.contains(.recording) { return .systemRed }
        if tones.contains(.attention) { return .systemOrange }
        if tones.contains(.busy) { return .systemBlue }
        if tones.contains(.ready) { return .systemGreen }
        return nil
    }
}
