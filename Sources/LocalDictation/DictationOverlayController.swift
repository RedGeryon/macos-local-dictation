import AppKit

@MainActor
final class DictationOverlayController {
    private let panel: NSPanel
    private let stateLabel = NSTextField(labelWithString: "Listening…")
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 108),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        stateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stateLabel.textColor = .secondaryLabelColor
        transcriptLabel.font = .systemFont(ofSize: 18, weight: .medium)
        transcriptLabel.maximumNumberOfLines = 2
        transcriptLabel.lineBreakMode = .byTruncatingHead

        let stack = NSStackView(views: [stateLabel, transcriptLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -16)
        ])
        panel.contentView = effect
    }

    func showListening(mode: DictationMode) {
        stateLabel.stringValue = mode == .pushToTalk
            ? "Listening — release to insert · Esc to cancel"
            : "Hands-free — choose Stop or press Esc"
        transcriptLabel.stringValue = "Speak now…"
        show()
    }

    func updateTranscript(_ transcript: String) {
        transcriptLabel.stringValue = transcript.isEmpty ? "Listening…" : transcript
    }

    func showFinalizing() {
        stateLabel.stringValue = "Transcribing…"
    }

    func showCapturingTail() {
        stateLabel.stringValue = "Finishing speech…"
    }

    func showMessage(_ message: String) {
        stateLabel.stringValue = message
        transcriptLabel.stringValue = ""
        show()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show() {
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 56
        )
        panel.setFrameOrigin(origin)
    }
}
