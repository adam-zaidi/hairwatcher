import SwiftUI

@main
struct HairWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Observe so the App body re-renders (and the menu bar icon refreshes)
    // when state changes — these are the same singletons everything else uses.
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        Window("HairWatcher", id: "main") {
            MainWindowView()
                .environmentObject(settings)
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("HairWatcher", systemImage: menuBarIconName) {
            MenuBarMenuContent()
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarIconName: String {
        // `comb` only exists on macOS 14+. We're targeting 13, so we use
        // `scissors` (the universally hair-salon-shaped option). When the
        // detector is actively flagging a touch, swap to the filled circle
        // variant so it visually pops in the menu bar.
        if !appState.cameraAuthorized { return "exclamationmark.triangle" }
        if !settings.enabled { return "scissors" }
        switch appState.detectorState {
        case .touchingHair, .touchingFace, .touchingBoth:
            return "scissors.circle.fill"
        default:
            return "scissors"
        }
    }
}
