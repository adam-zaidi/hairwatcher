import Foundation

/// Privacy invariants for HairWatcher.
///
/// These comments are intentionally close to the code so future changes do not
/// accidentally turn a local wellness utility into a camera streaming/recording
/// app.
///
/// - Raw `CMSampleBuffer` / `CVPixelBuffer` frames may only exist inside
///   `CameraManager` and `HairTouchDetector`.
/// - Raw frames must never be stored in `UserDefaults`, files, logs, or app
///   state.
/// - Touch event timestamps (date/time metadata only, no camera data) may be
///   stored in `UserDefaults` via `TouchHistoryStore` for local statistics.
/// - Raw frames must never be encoded as images/video, copied to pasteboard, or
///   sent over the network.
/// - The app must remain sandboxed with camera entitlement only. It must not add
///   network, user-selected file, audio input, Apple Events, Downloads, Desktop,
///   or Documents entitlements.
/// - The live preview is display-only and must be explicit opt-in.
enum PrivacyPolicy {
    static let localProcessingNotice =
        "Camera frames are processed locally in memory. No photos or video are recorded, saved, uploaded, or shared."
}
