import SwiftUI
import AppKit

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

        if settings.watchTarget.watchesHair {
            Text("Hair today: \(notifications.todayHairCount) catches")
        }
        if settings.watchTarget.watchesFace {
            Text("Face today: \(notifications.todayFaceCount) catches")
        }

        Divider()

        Button("Quit HairWatcher") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        if !appState.cameraAuthorized { return "Status: camera denied" }
        if !settings.enabled { return "Status: paused" }
        let text = DetectorStateDisplay.statusText(for: appState.detectorState, enabled: true)
        return "Status: \(text.lowercased())"
    }

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
