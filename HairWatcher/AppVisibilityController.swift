import AppKit

/// Controls whether the app appears in the Dock or runs as menu-bar-only.
@MainActor
final class AppVisibilityController {
    static let shared = AppVisibilityController()

    private init() {}

    func switchToMenuBarOnly() {
        guard NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func switchToDockAndActivate() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
