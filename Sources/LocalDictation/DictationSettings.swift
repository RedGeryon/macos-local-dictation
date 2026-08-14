import Foundation

enum DictationShortcut: String, CaseIterable, Sendable {
    case functionKey
    case controlOptionSpace

    var title: String {
        switch self {
        case .functionKey: return "Hold Fn"
        case .controlOptionSpace: return "Hold Control–Option–Space"
        }
    }
}

enum ConversationShortcut {
    static let title = "Control–Option–C"
    static let menuKey = "c"
}

struct DictationSettings: Equatable, Sendable {
    var shortcut: DictationShortcut
    var removeFillers: Bool
    var automaticPunctuation: Bool
    var showLivePreview: Bool

    init(defaults: UserDefaults = .standard) {
        shortcut = DictationShortcut(rawValue: defaults.string(forKey: "dictationShortcut") ?? "")
            ?? .functionKey
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? true
        automaticPunctuation = defaults.object(forKey: "automaticPunctuation") as? Bool ?? true
        showLivePreview = defaults.object(forKey: "showLivePreview") as? Bool ?? true
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(shortcut.rawValue, forKey: "dictationShortcut")
        defaults.set(removeFillers, forKey: "removeFillers")
        defaults.set(automaticPunctuation, forKey: "automaticPunctuation")
        defaults.set(showLivePreview, forKey: "showLivePreview")
    }
}
