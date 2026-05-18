import AppKit

/// Shows a large temporary on-screen warning overlay.
@MainActor
final class OverlayAlertManager {
    static let shared = OverlayAlertManager()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func show(message: String, duration: TimeInterval = 1.8) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        updateMessage(message, in: panel)
        center(panel)
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor
        container.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "Stop touching your hair!")
        label.identifier = NSUserInterfaceItemIdentifier("overlayAlertLabel")
        label.font = .systemFont(ofSize: 44, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBordered = false
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 18),
            container.trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 18),
        ])

        panel.contentView = container
        return panel
    }

    private func updateMessage(_ message: String, in panel: NSPanel) {
        guard
            let container = panel.contentView,
            let label = container.subviews.first(where: {
                ($0 as? NSTextField)?.identifier?.rawValue == "overlayAlertLabel"
            }) as? NSTextField
        else {
            return
        }
        label.stringValue = message
    }

    private func center(_ panel: NSPanel) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}
