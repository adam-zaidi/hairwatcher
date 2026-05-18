import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

/// Top-level coordinator: bootstraps permissions, wires the camera +
/// detector + notifications pipeline, and listens for system lifecycle
/// events. The status item itself is a SwiftUI `MenuBarExtra` over in
/// `HairWatcherApp.swift`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let appState = AppState.shared
    private let notifications = NotificationManager.shared

    // The camera + detector live on `AppState` so the SwiftUI window can reach
    // the same instances we're driving here.
    private var cameraManager: CameraManager { appState.cameraManager }
    private var detector: HairTouchDetector { appState.detector }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        wirePipeline()
        bindSettings()
        observeSystemEvents()
        UNUserNotificationCenter.current().delegate = self

        Task { await bootstrapPermissions() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cameraManager.stop()
    }

    /// Closing the main window leaves the menu-bar item in charge — we keep
    /// running so the user can re-open the window or quit from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Pipeline wiring

    private func wirePipeline() {
        // Camera frames -> detector. The closure runs on the camera processing
        // queue; the detector hops onto its own queue internally, so this is safe.
        cameraManager.setFrameConsumer { [detector] buffer in
            detector.process(sampleBuffer: buffer)
        }
        cameraManager.onConfigurationError = { message in
            NSLog("HairWatcher: camera configuration error: %@", message)
        }

        detector.onStateChange = { [weak self] state in
            self?.appState.detectorState = state
        }

        detector.onTouchEvent = { [weak self] in
            guard let self else { return }
            OverlayAlertManager.shared.show(message: "Stop touching your hair!")
            self.notifications.recordTouchEvent(cooldownSeconds: self.settings.cooldownSeconds)
        }

        detector.onDebugFrame = { [weak self] frame in
            self?.appState.lastDebugFrame = frame
        }
    }

    private func bindSettings() {
        settings.$enabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.applyEnabled(enabled) }
            .store(in: &cancellables)

        settings.$sensitivity
            .removeDuplicates()
            .sink { [weak self] value in self?.detector.sensitivity = value }
            .store(in: &cancellables)

        settings.$launchAtLogin
            .removeDuplicates()
            .sink { [weak self] enabled in self?.applyLaunchAtLogin(enabled) }
            .store(in: &cancellables)

        // Initial sync (in case the bind fires before applyEnabled wants to run).
        detector.sensitivity = settings.sensitivity
    }

    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(screensDidLock),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(screensDidUnlock),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Only react to our main app window (not panels/popovers).
        guard window.title == "HairWatcher" || window.identifier?.rawValue == "main" else { return }

        // Wait one runloop tick so AppKit has actually removed the window from
        // the visible set, then switch to menu-bar-only mode.
        DispatchQueue.main.async {
            let hasVisibleMainWindow = NSApp.windows.contains { candidate in
                !candidate.isMiniaturized
                    && candidate.isVisible
                    && (candidate.title == "HairWatcher" || candidate.identifier?.rawValue == "main")
            }
            if !hasVisibleMainWindow {
                self.settings.showLiveDebugPreview = false
                AppVisibilityController.shared.switchToMenuBarOnly()
            }
        }
    }

    @objc private func systemWillSleep() {
        cameraManager.stop()
        detector.reset(to: .disabled)
    }

    @objc private func systemDidWake() {
        if shouldRunCamera { cameraManager.start() }
    }

    @objc private func screensDidLock() {
        cameraManager.stop()
        detector.reset(to: .disabled)
    }

    @objc private func screensDidUnlock() {
        if shouldRunCamera { cameraManager.start() }
    }

    // MARK: - Permissions

    private func bootstrapPermissions() async {
        // Camera.
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let camGranted: Bool
        switch camStatus {
        case .authorized:
            camGranted = true
        case .notDetermined:
            camGranted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            camGranted = false
        }
        appState.cameraAuthorized = camGranted

        // Notifications.
        let notifGranted = await notifications.requestAuthorization()
        appState.notificationsAuthorized = notifGranted

        applyEnabled(settings.enabled)
    }

    // MARK: - Apply settings

    /// True iff the camera should be running *right now*.
    ///
    /// IMPORTANT: this reads `settings.enabled` directly, which is fine for
    /// callers that don't sit on the `@Published` publisher path (sleep/wake
    /// observers, bootstrap). Don't use it inside `applyEnabled` — that one
    /// gets called on `willSet`, before the stored property updates, so we
    /// must trust the `enabled` argument it was handed instead.
    private var shouldRunCamera: Bool {
        settings.enabled && appState.cameraAuthorized
    }

    private func applyEnabled(_ enabled: Bool) {
        let shouldRun = enabled && appState.cameraAuthorized
        if shouldRun {
            // Reset detector *before* the session can emit another frame, so we
            // never overlap Vision with stale debounce state from before pause.
            detector.reset(to: .idle)
            cameraManager.start()
            appState.detectorState = .idle
        } else {
            // Stop capture + frame delivery.
            cameraManager.stop()
            detector.reset(to: .disabled)
            appState.detectorState = .disabled
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            NSLog("HairWatcher: launch-at-login change failed: %@", String(describing: error))
            // Roll the toggle back to the actual state so the UI stays honest.
            settings.launchAtLogin = (service.status == .enabled)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show our banner+sound even when the app is "frontmost".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
