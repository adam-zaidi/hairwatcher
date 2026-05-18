import SwiftUI
import AppKit

/// Content of the SwiftUI popover anchored to the menu bar status item.
struct MenuBarView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState
    @ObservedObject private var notifications = NotificationManager.shared

    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusBanner
            controls
            Divider()
            countRow
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .imageScale(.large)
            Text("HairWatcher").font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !appState.cameraAuthorized {
            banner(
                icon: "exclamationmark.triangle.fill",
                title: "Camera access denied",
                detail: "Grant camera permission so HairWatcher can see what your hands are doing.",
                actionLabel: "Open System Settings",
                action: openCameraSettings
            )
        } else if !appState.notificationsAuthorized {
            banner(
                icon: "bell.slash",
                title: "Notifications disabled",
                detail: "You won't be alerted until notifications are turned on for HairWatcher.",
                actionLabel: "Open Notification Settings",
                action: openNotificationSettings
            )
        } else {
            stateRow
        }
    }

    private var stateRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateText)
                .font(.callout)
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settings.enabled) {
                Text("Watch for hair touching")
            }
            .toggleStyle(.switch)
            .disabled(!appState.cameraAuthorized)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sensitivity").font(.callout)
                    Spacer()
                    Text(sensitivityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.sensitivity, in: 0.2 ... 0.95)
            }

            HStack {
                Text("Cooldown").font(.callout)
                Spacer()
                Stepper(
                    "\(settings.cooldownSeconds)s",
                    value: $settings.cooldownSeconds,
                    in: 5 ... 600,
                    step: 5
                )
            }

            Toggle(isOn: $settings.launchAtLogin) {
                Text("Launch at login")
            }
            .toggleStyle(.switch)

            Text(PrivacyPolicy.localProcessingNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var countRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "number.circle")
            Text("Today: \(notifications.todayCount) catches")
                .font(.callout)
            Spacer()
            Button("Reset") { notifications.resetTodayCount() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit", action: onQuit)
                .keyboardShortcut("q")
        }
    }

    // MARK: - Helpers

    private var sensitivityLabel: String {
        switch settings.sensitivity {
        case ..<0.4: return "Low"
        case ..<0.7: return "Medium"
        default: return "High"
        }
    }

    private var stateText: String {
        if !settings.enabled { return "Paused" }
        switch appState.detectorState {
        case .idle: return "Watching"
        case .touching: return "You're touching your hair!"
        case .noFace: return "Looking for your face…"
        case .disabled: return "Paused"
        }
    }

    private var stateColor: Color {
        if !settings.enabled { return .gray }
        switch appState.detectorState {
        case .idle: return .green
        case .touching: return .red
        case .noFace: return .yellow
        case .disabled: return .gray
        }
    }

    private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func banner(
        icon: String,
        title: String,
        detail: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).font(.callout).bold()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionLabel, action: action)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.15))
        )
    }
}
