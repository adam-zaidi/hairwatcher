# HairWatcher

A lightweight menu-bar macOS app that gently nags you when you're playing with your hair.
Runs the built-in camera locally through Apple's Vision framework — no model training,
no network entitlement, and no photos or video are recorded.

## How it works

```
camera ──► AVCaptureSession (480p, ~6 fps)
            │
            ▼
       VNImageRequestHandler ──► VNDetectHumanHandPoseRequest
                              └─► VNDetectFaceLandmarksRequest
            │
            ▼
       HairZone heuristic (forehead-and-up box, lower bound at the eye line)
            │
            ▼
       Sliding-window debouncer (N hits / M frames)
            │
            ▼
       UNNotificationCenter (cooldown-gated)
```

There's no ML training step. The "is my hand near my hair?" decision is purely
geometric: we ask Vision for hand keypoints and a face bounding box, build a
rectangle that approximates where the hair is on screen, and check whether any
finger keypoints fall inside it.

## Build & run

You need macOS 13+ and Xcode 15+ (tested on Xcode 26).

```bash
brew install xcodegen      # one-time
xcodegen generate          # produces HairWatcher.xcodeproj from project.yml
open HairWatcher.xcodeproj # then ⌘R in Xcode
```

If you'd rather not use XcodeGen, create a fresh "macOS App" target in Xcode,
drop everything in [HairWatcher/](HairWatcher/) into the target, and copy the
keys from [HairWatcher/Info.plist](HairWatcher/Info.plist) and
[HairWatcher/HairWatcher.entitlements](HairWatcher/HairWatcher.entitlements)
into your target's settings.

### Headless build (CI / sanity check)

```bash
xcodegen generate
xcodebuild -project HairWatcher.xcodeproj -scheme HairWatcher \
  -configuration Debug build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## First launch

The app will ask for two permissions in sequence:

1. **Camera** — required. Without it the menu bar shows a yellow warning and
   detection is paused.
2. **Notifications** — required to actually alert you. The menu bar surfaces
   the denied state and gives you a button straight to System Settings.

The app is `LSUIElement = YES`, so it lives only in the menu bar — no Dock icon,
no main window.

## Tuning

Click the menu-bar icon to open the popover, or open the main window for the optional
debug view.

- **Watch for hair touching** — master kill switch. Stops the capture session.
- **Sensitivity** (Low / Medium / High) — controls the debouncer's threshold.
  Internally maps to `required = ceil((1 - sensitivity) · windowSize)` hits in
  the last `windowSize` (= 6) frames. Higher sensitivity = fewer hits required.
- **Cooldown** — minimum seconds between notifications. Detection events are
  still counted during cooldown; you just don't get spammed.
- **Launch at login** — wired via `SMAppService.mainApp`.
- **Show Live Debug Preview** — opt-in only. Detection works with the preview
  hidden; when shown, the feed is display-only and is not recorded or uploaded.

## File map

| File | What it owns |
| --- | --- |
| [`HairWatcherApp.swift`](HairWatcher/HairWatcherApp.swift) | `@main` entry point, attaches the `AppDelegate`. |
| [`AppDelegate.swift`](HairWatcher/AppDelegate.swift) | Status item, popover, permissions bootstrap, system event observers, pipeline wiring. |
| [`CameraManager.swift`](HairWatcher/CameraManager.swift) | `AVCaptureSession` configuration, frame throttling to ~6 fps, sample-buffer callback. |
| [`HairTouchDetector.swift`](HairWatcher/HairTouchDetector.swift) | Vision requests, sliding-window debouncer, state machine. |
| [`HairZone.swift`](HairWatcher/HairZone.swift) | Pure function: face observation → "hair zone" rectangle. |
| [`NotificationManager.swift`](HairWatcher/NotificationManager.swift) | `UNUserNotificationCenter` wrapper, cooldown gate, daily counter. |
| [`Settings.swift`](HairWatcher/Settings.swift) | `AppSettings` (persisted) and `AppState` (live UI state). |
| [`MenuBarView.swift`](HairWatcher/MenuBarView.swift) | SwiftUI popover. |

## Known false positives

The heuristic is intentionally simple, which means it will fire on:

- **Adjusting glasses or eyebrows** — fingers cross the forehead, which the
  hair zone overlaps a little.
- **Scratching your forehead.**
- **Resting a hand against your temple** — fingertips often clip the zone.
- **Hat / hood adjustments.**

For most "stop touching your hair" coaching this is acceptable, since the
notification still tells you that *something* is up there. If you want to drive
the false-positive rate down, the natural next step is the hybrid path: feed
the cropped hair-zone patch into a small CoreML classifier as a secondary
filter. The geometric heuristic stays as the cheap front-end gate.

## Privacy and Security

HairWatcher is designed so camera frames are ephemeral:

- Frames are processed locally in memory by Apple's `Vision` framework.
- No photos or videos are recorded, saved, uploaded, shared, or copied to the pasteboard.
- The app has no network entitlement (`com.apple.security.network.client` is intentionally absent).
- The app is sandboxed (`com.apple.security.app-sandbox = true`) and only requests camera access (`com.apple.security.device.camera`).
- Only settings and today's touch count are persisted in `UserDefaults`.
- The live debug preview is opt-in and display-only. It can still expose the camera visually to someone who can see or record your screen, so keep it off unless debugging.

Before notarizing or distributing a build, run the privacy audit:

```bash
./scripts/privacy_audit.sh
```

To inspect a built app's signed entitlements:

```bash
codesign -d --entitlements :- /path/to/HairWatcher.app
spctl -a -vvv -t install /path/to/HairWatcher.app
```

## Not in scope

- Custom ML training.
- Cross-platform support.
- Any cloud / network functionality.
- A regular dock app variant — this is committed to menu-bar (`LSUIElement`).
