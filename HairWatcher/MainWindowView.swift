import SwiftUI
import AppKit

/// The contents of the main app window. A debug camera preview on the left,
/// the same settings panel that the menu-bar popover uses on the right.
enum MainWindowTab: String, CaseIterable, Identifiable {
    case live = "Live"
    case statistics = "Statistics"

    var id: String { rawValue }
}

struct MainWindowView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: MainWindowTab = .live

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(MainWindowTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .live:
                        previewPanel
                    case .statistics:
                        StatisticsView()
                    }
                }
                .frame(minWidth: 360, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                settingsPanel
                    .frame(width: 320)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    // MARK: - Preview

    private var previewPanel: some View {
        VStack(spacing: 0) {
            previewHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            previewSurface
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            legend
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        let aspect = previewAspectRatio
        ZStack(alignment: .topTrailing) {
            ZStack {
                if appState.cameraAuthorized && settings.enabled {
                    if settings.showLiveDebugPreview {
                        DebugCameraView(cameraManager: appState.cameraManager)
                        OverlayShapesView(debugFrame: appState.lastDebugFrame)
                    } else {
                        privacyPreviewPlaceholder
                    }
                } else {
                    placeholder
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            stateBadge
                .padding(10)
        }
    }

    /// The aspect ratio we lock the preview *and* the overlay to — taken from
    /// the camera's active format. Keeping both inside an aspect-fit container
    /// of the same ratio means the overlay's normalized coords map 1:1 to the
    /// pixels the user sees, with no letterbox math required.
    private var previewAspectRatio: CGFloat {
        let s = appState.cameraManager.captureSize
        guard s.width > 0, s.height > 0 else { return 4.0 / 3.0 }
        return s.width / s.height
    }

    private var previewHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Live debug preview").font(.headline)
                Text("Privacy-safe by default. Enable live preview only when debugging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var privacyPreviewPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Live preview hidden")
                .font(.headline)
            Text(PrivacyPolicy.localProcessingNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: !appState.cameraAuthorized
                  ? "video.slash"
                  : "pause.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(placeholderText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderText: String {
        if !appState.cameraAuthorized {
            return "Camera access is denied. Open System Settings to grant it."
        }
        if !settings.enabled {
            return "Detection is paused. Flip the toggle on the right to start watching."
        }
        return "Waiting for the first frame…"
    }

    private var stateBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                legendItem(color: .green, label: "Hands")
                legendItem(color: .red, label: "Hair hit")
                legendItem(color: .orange, label: "Face hit")
                legendItem(color: .yellow, label: "Hair zone")
                legendItem(color: .blue, label: "Face zone")
                Spacer()
            }
            Toggle("Show Live Debug Preview", isOn: $settings.showLiveDebugPreview)
                .toggleStyle(.checkbox)
            Text("Preview is display-only and opt-in. HairWatcher does not record, save, upload, or share video.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: - Settings (reuses the menu-bar popover view)

    private var settingsPanel: some View {
        ScrollView {
            MenuBarView(onQuit: { NSApp.terminate(nil) })
        }
    }

    // MARK: - State helpers

    private var stateText: String {
        if !settings.enabled { return "Paused" }
        if !appState.cameraAuthorized { return "No camera" }
        return DetectorStateDisplay.statusText(for: appState.detectorState, enabled: true)
    }

    private var stateColor: Color {
        if !settings.enabled || !appState.cameraAuthorized { return .gray }
        return DetectorStateDisplay.color(for: appState.detectorState, enabled: true)
    }
}

/// Pure-SwiftUI overlay drawn on top of the camera preview. The container
/// view it lives inside is locked to the camera's aspect ratio, so we can map
/// Vision's normalized [0,1] bottom-left coords directly to SwiftUI's
/// top-left coordinate system with a single Y flip.
struct OverlayShapesView: View {
    let debugFrame: HairTouchDetector.DebugFrame?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if let frame = debugFrame {
                    if let zone = frame.hairZone {
                        let r = visionRect(zone, in: size)
                        Rectangle()
                            .strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                    if let zone = frame.faceZone {
                        let r = visionRect(zone, in: size)
                        Rectangle()
                            .strokeBorder(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                    ForEach(Array(frame.handPoints.enumerated()), id: \.offset) { _, kp in
                        let p = visionPoint(kp.location, in: size)
                        let hit = kp.inHairZone || kp.inFaceZone
                        Circle()
                            .fill(keypointColor(kp))
                            .opacity(hit ? 0.95 : 0.75)
                            .frame(width: hit ? 12 : 8, height: hit ? 12 : 8)
                            .position(x: p.x, y: p.y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func visionPoint(_ p: CGPoint, in size: CGSize) -> CGPoint {
        // Vision: bottom-left origin, [0,1]. SwiftUI: top-left origin, in pts.
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private func visionRect(_ r: CGRect, in size: CGSize) -> CGRect {
        let x = r.minX * size.width
        let y = (1 - r.maxY) * size.height
        let w = r.width * size.width
        let h = r.height * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func keypointColor(_ kp: HairTouchDetector.HandKeypoint) -> Color {
        if kp.inHairZone && kp.inFaceZone { return .red }
        if kp.inHairZone { return .red }
        if kp.inFaceZone { return .orange }
        return .green
    }
}
