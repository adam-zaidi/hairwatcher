import AppKit

private enum OverlayTiming {
    static let standard: TimeInterval = 1.8
}

private enum OverlayLabelID {
    static let message = "overlayAlertLabel"
}

/// Panel that can become key so annoying mode can swallow keyboard input.
private final class BlockingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Content view that accepts first responder and swallows keyboard events.
private final class InputBlockingView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
}

/// Shows a large temporary on-screen warning overlay.
@MainActor
final class OverlayAlertManager {
    static let shared = OverlayAlertManager()

    private var standardPanel: NSPanel?
    private var blockingPanels: [NSPanel] = []
    private var blockingPanelScreenCount = 0
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func show(message: String, annoying: Bool = false, annoyingDuration: TimeInterval = 5) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if annoying {
            hideStandardPanel()
            showAnnoying(message: message, duration: annoyingDuration)
        } else {
            hideBlockingPanels()
            showStandard(message: message)
        }
    }

    // MARK: - Standard (small banner)

    private func showStandard(message: String) {
        let panel = standardPanel ?? makeStandardPanel()
        standardPanel = panel
        updateMessage(message, in: panel)
        centerStandard(panel)
        panel.orderFrontRegardless()

        scheduleHide(duration: OverlayTiming.standard) { [weak self] in
            self?.standardPanel?.orderOut(nil)
        }
    }

    private func hideStandardPanel() {
        standardPanel?.orderOut(nil)
    }

    private func makeStandardPanel() -> NSPanel {
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

        let label = makeMessageLabel(fontSize: 44)
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

    private func centerStandard(_ panel: NSPanel) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Annoying (fullscreen, all displays)

    private func showAnnoying(message: String, duration: TimeInterval) {
        ensureBlockingPanels()
        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() where index < blockingPanels.count {
            let panel = blockingPanels[index]
            panel.setFrame(screen.frame, display: false)
            updateMessage(message, in: panel)
            panel.orderFrontRegardless()
        }

        if let keyPanel = blockingPanelForMouseLocation() {
            keyPanel.makeKeyAndOrderFront(nil)
        } else {
            blockingPanels.first?.makeKeyAndOrderFront(nil)
        }

        scheduleHide(duration: duration) { [weak self] in
            self?.hideBlockingPanels()
        }
    }

    private func ensureBlockingPanels() {
        let screenCount = NSScreen.screens.count
        if screenCount == blockingPanelScreenCount, !blockingPanels.isEmpty {
            return
        }
        hideBlockingPanels()
        blockingPanels = NSScreen.screens.map { _ in makeBlockingPanel() }
        blockingPanelScreenCount = screenCount
    }

    private func hideBlockingPanels() {
        for panel in blockingPanels {
            panel.orderOut(nil)
        }
    }

    private func makeBlockingPanel() -> NSPanel {
        let panel = BlockingOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let container = InputBlockingView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        container.autoresizingMask = [.width, .height]

        let label = makeMessageLabel(fontSize: 68)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            container.trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 32),
        ])

        panel.contentView = container
        return panel
    }

    private func blockingPanelForMouseLocation() -> NSPanel? {
        let location = NSEvent.mouseLocation
        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() where index < blockingPanels.count {
            if screen.frame.contains(location) {
                return blockingPanels[index]
            }
        }
        return blockingPanels.first
    }

    // MARK: - Shared helpers

    private func makeMessageLabel(fontSize: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.identifier = NSUserInterfaceItemIdentifier(OverlayLabelID.message)
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBordered = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func updateMessage(_ message: String, in panel: NSPanel) {
        guard
            let container = panel.contentView,
            let label = container.subviews.first(where: {
                ($0 as? NSTextField)?.identifier?.rawValue == OverlayLabelID.message
            }) as? NSTextField
        else {
            return
        }
        label.stringValue = message
    }

    private func scheduleHide(duration: TimeInterval, onHide: @escaping () -> Void) {
        let work = DispatchWorkItem(block: onHide)
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
