import SwiftUI
import AppKit

/// The dropdown shown when the user clicks the menu-bar icon. We use the
/// `.menu` MenuBarExtra style so each `Button` becomes a native menu item,
/// each `Text` an inline label, and each `Divider` a separator.
struct MenuBarMenuContent: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var notifications = NotificationManager.shared

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open HairWatcher Window") {
            openMainWindow()
        }
        .keyboardShortcut("o")

        Divider()

        Button(settings.enabled ? "Pause Watching" : "Resume Watching") {
            settings.enabled.toggle()
        }
        .disabled(!appState.cameraAuthorized)

        Text(statusLine)

        Text("Today: \(notifications.todayCount) catches")

        Divider()

        Button("Quit HairWatcher") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        if !appState.cameraAuthorized { return "Status: camera denied" }
        if !settings.enabled { return "Status: paused" }
        switch appState.detectorState {
        case .idle: return "Status: watching"
        case .touching: return "Status: touching hair!"
        case .noFace: return "Status: no face in view"
        case .disabled: return "Status: paused"
        }
    }

    /// Bring the existing main window forward if it exists, otherwise ask
    /// SwiftUI to (re)open the `Window("HairWatcher", id: "main")` scene.
    private func openMainWindow() {
        AppVisibilityController.shared.switchToDockAndActivate()
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "main" || $0.title == "HairWatcher"
        }) {
            existing.deminiaturize(nil)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: "main")
    }
}
