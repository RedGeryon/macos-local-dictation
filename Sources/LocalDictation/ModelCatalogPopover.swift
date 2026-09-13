import AppKit

/// A small, keyboard-accessible catalog used by both local model features.
@MainActor
final class ModelCatalogPopover: NSViewController {
    struct Item {
        let title: String
        let summary: String
        let detail: String
        let installed: Bool
        let add: () -> Void

        init(title: String, summary: String = "", detail: String, installed: Bool, add: @escaping () -> Void) {
            self.title = title
            self.summary = summary
            self.detail = detail
            self.installed = installed
            self.add = add
        }
    }

    private let items: [Item]
    private let importAction: (() -> Void)?
    private var closeCatalog: (() -> Void)?
    private var infoPopover: NSPopover?

    init(items: [Item], importAction: (() -> Void)? = nil) {
        self.items = items
        self.importAction = importAction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("ModelCatalogPopover is code-only") }

    static func show(from anchor: NSView, items: [Item], importAction: (() -> Void)? = nil, retaining popover: inout NSPopover?) {
        let controller = ModelCatalogPopover(items: items, importAction: importAction)
        let catalog = NSPopover()
        catalog.behavior = .transient
        catalog.contentViewController = controller
        controller.closeCatalog = { [weak catalog] in catalog?.close() }
        controller.loadViewIfNeeded()
        let fitting = controller.view.fittingSize
        catalog.contentSize = NSSize(width: max(410, fitting.width), height: fitting.height)
        popover = catalog
        catalog.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Keeps explanatory text at a readable width. NSPopover otherwise fits an
    /// unconstrained wrapping label to its one-line minimum.
    static func makeInfoPopover(detail: String) -> NSPopover {
        let label = NSTextField(wrappingLabelWithString: detail)
        label.maximumNumberOfLines = 0
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(label)
        let measured = (detail as NSString).boundingRect(
            with: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)],
            context: nil
        ).size
        let height = ceil(measured.height) + 28
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: 328),
            body.heightAnchor.constraint(equalToConstant: height),
            label.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -12)
        ])
        let controller = NSViewController()
        controller.view = body
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 328, height: height)
        return popover
    }

    override func loadView() {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for (index, item) in items.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let text = NSStackView()
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.widthAnchor.constraint(equalToConstant: 285).isActive = true
            let title = NSTextField(labelWithString: item.title)
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            text.addArrangedSubview(title)
            if !item.summary.isEmpty {
                let summary = NSTextField(labelWithString: item.summary)
                summary.textColor = .secondaryLabelColor
                summary.lineBreakMode = .byTruncatingTail
                text.addArrangedSubview(summary)
            }
            row.addArrangedSubview(text)
            let info = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About \(item.title)")!, target: self, action: #selector(showInfo(_:)))
            info.isBordered = false
            info.toolTip = item.detail
            info.tag = index
            info.identifier = NSUserInterfaceItemIdentifier("catalog.info.\(index)")
            info.setAccessibilityRole(.button)
            info.setAccessibilityLabel("About \(item.title)")
            row.addArrangedSubview(info)
            let action = NSButton(title: item.installed ? "Installed" : "Download", target: self, action: #selector(add(_:)))
            action.identifier = NSUserInterfaceItemIdentifier("catalog.add.\(index)")
            action.tag = index
            action.isEnabled = !item.installed
            row.addArrangedSubview(action)
            stack.addArrangedSubview(row)
        }
        if importAction != nil {
            let importButton = NSButton(title: "Import Model…", target: self, action: #selector(importModel))
            importButton.identifier = NSUserInterfaceItemIdentifier("catalog.import")
            stack.addArrangedSubview(importButton)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        view = container
    }

    @objc private func add(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        let action = items[sender.tag].add
        closeCatalog?()
        action()
    }

    @objc private func importModel() {
        closeCatalog?()
        importAction?()
    }

    @objc private func showInfo(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        let popover = Self.makeInfoPopover(detail: items[sender.tag].detail)
        infoPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}
