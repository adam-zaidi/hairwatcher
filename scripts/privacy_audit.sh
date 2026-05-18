#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-}"

python3 - "$ROOT" "$APP_PATH" <<'PY'
import os
import re
import subprocess
import sys

root = sys.argv[1]
app_path = sys.argv[2]
failures = 0

def note(message: str) -> None:
    print(message)

def fail(message: str) -> None:
    global failures
    failures += 1
    print(f"\n[privacy-audit] FAIL: {message}", file=sys.stderr)

def swift_files():
    base = os.path.join(root, "HairWatcher")
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if not d.endswith(".xcassets")]
        for filename in filenames:
            if filename.endswith(".swift"):
                yield os.path.join(dirpath, filename)

def scan_file(path: str, pattern: re.Pattern[str]):
    matches = []
    with open(path, "r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if pattern.search(line):
                rel = os.path.relpath(path, root)
                matches.append(f"{rel}:{line_number}:{line.rstrip()}")
    return matches

def check_source_pattern(label: str, regex: str) -> None:
    pattern = re.compile(regex)
    matches = []
    for path in swift_files():
        matches.extend(scan_file(path, pattern))
    if matches:
        fail(label)
        print("\n".join(matches), file=sys.stderr)

def check_forbidden_entitlements(path: str) -> None:
    forbidden = re.compile(
        r"com\.apple\.security\.(network\.(client|server)|"
        r"files\.(user-selected|downloads|desktop|documents)\.(read-only|read-write)|"
        r"automation\.apple-events|device\.audio-input)"
    )
    matches = scan_file(path, forbidden)
    if matches:
        fail(f"forbidden entitlement in {os.path.relpath(path, root)}")
        print("\n".join(matches), file=sys.stderr)

note("[privacy-audit] Scanning source for camera exfiltration risks...")

check_source_pattern(
    "network APIs are not allowed",
    r"URLSession|import\s+Network|NWConnection|NWListener|NWTCPConnection|CFStream|CFSocket|URLRequest|WebSocket|webSocketTask",
)
check_source_pattern(
    "recording/photo capture APIs are not allowed",
    r"AVAssetWriter|AVCaptureMovieFileOutput|AVCapturePhotoOutput|AVCaptureAudioDataOutput|AVAudioRecorder|ScreenCaptureKit|SCStream",
)
check_source_pattern(
    "image/video export APIs are not allowed",
    r"CGImageDestination|NSBitmapImageRep|CIContext\([^)]*\)\.write|CMSampleBufferCreateCopy|CVPixelBufferCreate|VTCompressionSession|AVAssetExportSession",
)
check_source_pattern(
    "direct camera-data file writes are not allowed",
    r"FileManager\.default\.(createFile|copyItem|moveItem)|\.write\(to:|\.write\(contentsOf:",
)

note("[privacy-audit] Checking raw camera types stay inside approved files...")
raw_pattern = re.compile(r"CMSampleBuffer|CVPixelBuffer|AVCaptureVideoDataOutput|AVCaptureSession")
approved = {"CameraManager.swift", "HairTouchDetector.swift", "DebugCameraView.swift", "PrivacyPolicy.swift"}
raw_matches = []
for path in swift_files():
    if os.path.basename(path) in approved:
        continue
    raw_matches.extend(scan_file(path, raw_pattern))
if raw_matches:
    fail("raw camera buffer/session types used outside approved camera/detector/preview files")
    print("\n".join(raw_matches), file=sys.stderr)

note("[privacy-audit] Checking source entitlements stay minimal...")
check_forbidden_entitlements(os.path.join(root, "HairWatcher", "HairWatcher.entitlements"))
check_forbidden_entitlements(os.path.join(root, "project.yml"))

if app_path:
    note(f"[privacy-audit] Inspecting signed entitlements for: {app_path}")
    if not os.path.isdir(app_path):
        fail(f"app path does not exist: {app_path}")
    else:
        result = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", app_path],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        entitlements = result.stdout
        if not entitlements.strip():
            fail("could not read signed entitlements from app")
        else:
            if "com.apple.security.app-sandbox" not in entitlements:
                fail("signed app is missing sandbox entitlement")
            if "com.apple.security.device.camera" not in entitlements:
                fail("signed app is missing camera entitlement")
            forbidden = re.compile(
                r"com\.apple\.security\.(network\.(client|server)|"
                r"files\.(user-selected|downloads|desktop|documents)\.(read-only|read-write)|"
                r"automation\.apple-events|device\.audio-input)"
            )
            if forbidden.search(entitlements):
                fail("signed app contains forbidden entitlement")
                print(entitlements, file=sys.stderr)

if failures:
    print(f"\n[privacy-audit] {failures} issue(s) found.", file=sys.stderr)
    sys.exit(1)

note("[privacy-audit] PASS: no camera exfiltration guardrail violations found.")
PY
