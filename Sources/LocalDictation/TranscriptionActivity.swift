import Foundation

/// Prevents automatic system and display sleep during user-requested transcription.
final class TranscriptionActivity {
    private var token: NSObjectProtocol?
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void

    init(
        begin: @escaping () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "Transcribing speech and saving the transcript"
            )
        },
        end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    func setActive(_ active: Bool) {
        if active {
            if token == nil { token = begin() }
        } else if let token {
            end(token)
            self.token = nil
        }
    }

    deinit {
        if let token { end(token) }
    }
}
