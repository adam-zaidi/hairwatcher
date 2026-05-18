import Foundation
import Combine

/// User-tunable preferences, persisted via `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Key {
        static let enabled = "enabled"
        static let sensitivity = "sensitivity"
        static let cooldownSeconds = "cooldownSeconds"
        static let launchAtLogin = "launchAtLogin"
        static let showLiveDebugPreview = "showLiveDebugPreview"
        static let watchTarget = "watchTarget"
    }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled) }
    }
    @Published var sensitivity: Double {
        didSet { UserDefaults.standard.set(sensitivity, forKey: Key.sensitivity) }
    }
    @Published var cooldownSeconds: Int {
        didSet { UserDefaults.standard.set(cooldownSeconds, forKey: Key.cooldownSeconds) }
    }
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    @Published var showLiveDebugPreview: Bool {
        didSet { UserDefaults.standard.set(showLiveDebugPreview, forKey: Key.showLiveDebugPreview) }
    }
    @Published var watchTarget: WatchTarget {
        didSet { UserDefaults.standard.set(watchTarget.rawValue, forKey: Key.watchTarget) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.enabled: true,
            Key.sensitivity: 0.66,
            Key.cooldownSeconds: 30,
            Key.launchAtLogin: false,
            Key.showLiveDebugPreview: false,
            Key.watchTarget: WatchTarget.both.rawValue,
        ])
        self.enabled = defaults.bool(forKey: Key.enabled)
        self.sensitivity = defaults.double(forKey: Key.sensitivity)
        self.cooldownSeconds = defaults.integer(forKey: Key.cooldownSeconds)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        self.showLiveDebugPreview = defaults.bool(forKey: Key.showLiveDebugPreview)
        let targetRaw = defaults.string(forKey: Key.watchTarget) ?? WatchTarget.both.rawValue
        self.watchTarget = WatchTarget(rawValue: targetRaw) ?? .both
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var detectorState: DetectorState = .idle
    @Published var cameraAuthorized: Bool = false
    @Published var notificationsAuthorized: Bool = false
    @Published var lastDebugFrame: HairTouchDetector.DebugFrame?

    let cameraManager = CameraManager()
    let detector = HairTouchDetector()

    private init() {}
}
