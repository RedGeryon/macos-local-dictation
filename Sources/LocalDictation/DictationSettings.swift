import Foundation

struct DictationSettings: Equatable, Sendable {
    var bindings: ShortcutBindings
    var removeFillers: Bool
    var automaticPunctuation: Bool
    var showLivePreview: Bool

    /// How Quick Dictation push-to-talk is triggered right now.
    var quickDictationTrigger: DictationTrigger { bindings.quickDictation }

    init(defaults: UserDefaults = .standard) {
        // The development TTS preview uses a separate defaults domain. If it
        // has never saved ASR preferences, retain the production choices rather
        // than resetting the user's existing dictation setup.
        let production = LocalDictationPreviewIdentity.isPreview()
            ? UserDefaults(suiteName: "org.localdictation.app")
            : nil
        bindings = ShortcutBindings.load(defaults: defaults)
        removeFillers = (defaults.object(forKey: "removeFillers") as? Bool)
            ?? (production?.object(forKey: "removeFillers") as? Bool) ?? true
        automaticPunctuation = (defaults.object(forKey: "automaticPunctuation") as? Bool)
            ?? (production?.object(forKey: "automaticPunctuation") as? Bool) ?? true
        showLivePreview = (defaults.object(forKey: "showLivePreview") as? Bool)
            ?? (production?.object(forKey: "showLivePreview") as? Bool) ?? true
    }

    func persist(to defaults: UserDefaults = .standard) {
        bindings.persist(to: defaults)
        defaults.set(removeFillers, forKey: "removeFillers")
        defaults.set(automaticPunctuation, forKey: "automaticPunctuation")
        defaults.set(showLivePreview, forKey: "showLivePreview")
    }
}
