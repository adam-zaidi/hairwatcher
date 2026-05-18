import Vision
import CoreMedia
import CoreVideo
import Foundation

enum DetectorState: Equatable {
    case idle
    case touching
    case noFace
    case disabled
}

/// Per-frame hand+face inference plus a sliding-window debouncer that produces
/// stable `DetectorState` transitions.
///
/// Threading: `process(sampleBuffer:)` **must** be called from the
/// `AVCaptureVideoDataOutput` delegate queue (or any caller that guarantees the
/// `CMSampleBuffer` / `CVPixelBuffer` stays valid until `process` returns).
/// Vision work runs **synchronously** on `queue` so we never return from the
/// delegate while a buffer is still "in flight" — if we `async`d instead, AVF
/// would recycle the pixel buffer immediately and Vision would read garbage,
/// which often crashes deep inside Obj‑C with "collection mutated while
/// enumerated". Callbacks (`onStateChange`, `onTouchEvent`, `onDebugFrame`)
/// are still dispatched to the main thread.
final class HairTouchDetector {
    /// Fires every time the high-level state changes. Always on main.
    var onStateChange: ((DetectorState) -> Void)?

    /// Fires once per `idle -> touching` transition. Always on main.
    /// Use this to drive notifications.
    var onTouchEvent: (() -> Void)?

    /// Fires for every processed frame so a debug UI can draw the latest face
    /// box, hair zone, and hand keypoints. Always on main.
    var onDebugFrame: ((DebugFrame) -> Void)?

    /// 0 (least sensitive) … 1 (most sensitive).
    var sensitivity: Double = 0.66

    // MARK: - Debug payload

    struct HandKeypoint: Equatable, Hashable, Sendable {
        /// Vision-normalized coordinates (origin: bottom-left, range 0…1).
        let location: CGPoint
        let confidence: Float
        /// True only for "trigger" joints (fingertips/intermediate joints) that
        /// fall inside the hair zone.
        let inZone: Bool
    }

    struct DebugFrame: Equatable, Sendable {
        let faceBoundingBox: CGRect?
        let hairZone: CGRect?
        let handPoints: [HandKeypoint]
        let state: DetectorState
    }

    /// Joints we use to actually decide whether someone is touching their hair.
    private static let triggerJoints: Set<VNHumanHandPoseObservation.JointName> = [
        .thumbTip, .thumbIP,
        .indexTip, .indexDIP, .indexPIP, .indexMCP,
        .middleTip, .middleDIP, .middlePIP, .middleMCP,
        .ringTip, .ringDIP, .ringPIP, .ringMCP,
        .littleTip, .littleDIP, .littlePIP, .littleMCP,
    ]

    /// Joints we *don't* trigger on but still draw in the debug overlay so the
    /// hand outline reads more naturally on screen.
    private static let extraDebugJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .thumbMP, .thumbCMC,
    ]

    // Background wellness monitoring should not run at user-interaction
    // priority. Keeping Vision at utility QoS also avoids Thread Performance
    // Checker warnings where Vision internally waits on lower-priority work.
    private let queue = DispatchQueue(label: "com.hairwatcher.vision", qos: .utility)

    /// Sliding window of recent per-frame hit booleans. Newest at the end.
    private var hitWindow: [Bool] = []
    private let windowSize = 6

    private(set) var state: DetectorState = .idle

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // SYNC: the sample buffer is only valid until this delegate call returns.
        // Never `async` here — the next frame would reuse the same backing store
        // and corrupt Vision's internal state (classic SIGABRT / Obj‑C mutation
        // crashes on resume when the camera starts delivering again).
        queue.sync { [weak self] in
            self?.run(on: pixelBuffer)
        }
    }

    /// Forces the detector back to a clean idle state. Use when the camera stops.
    /// SYNC so callers (e.g. `applyEnabled`) can start the camera again only after
    /// debounce state is cleared — avoids racing the first post-resume frame.
    func reset(to newState: DetectorState = .idle) {
        queue.sync { [weak self] in
            guard let self else { return }
            self.hitWindow.removeAll()
            self.transition(to: newState)
        }
    }

    private func run(on pixelBuffer: CVPixelBuffer) {
        // Fresh requests every frame. Reusing `VNDetectHumanHandPoseRequest` /
        // `VNDetectFaceLandmarksRequest` across `perform` calls is a documented
        // sharp edge — internally they keep Obj‑C result collections that can
        // trip "*** was mutated while being enumerated" if a new `perform`
        // starts while old results are still being read or when tearing down
        // overlaps resume. Allocating two small objects per processed frame is
        // cheap vs. the Vision work itself.
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([faceRequest, handRequest])
        } catch {
            return
        }

        guard let faces = faceRequest.results, !faces.isEmpty else {
            // No face -> reset window and surface the noFace state.
            hitWindow.removeAll()
            transition(to: .noFace)
            emitDebug(faceBox: nil, zone: nil, handPoints: [])
            return
        }

        // Pick the largest face (presumably the user's, closest to the camera).
        let largest = faces.max { lhs, rhs in
            (lhs.boundingBox.width * lhs.boundingBox.height) <
                (rhs.boundingBox.width * rhs.boundingBox.height)
        }!

        let zone = HairZone.compute(from: largest)

        let hands = handRequest.results ?? []
        let keypoints = collectKeypoints(from: hands, zone: zone)
        let hit = keypoints.contains { $0.inZone }

        emitDebug(
            faceBox: largest.boundingBox,
            zone: zone.rect,
            handPoints: keypoints
        )
        registerHit(hit)
    }

    private func registerHit(_ hit: Bool) {
        hitWindow.append(hit)
        if hitWindow.count > windowSize {
            hitWindow.removeFirst(hitWindow.count - windowSize)
        }

        let hitCount = hitWindow.filter { $0 }.count

        // Sensitivity 0..1 maps to required-hits within the window:
        //  - sensitivity 1.0 -> required = 1 (any single hit triggers).
        //  - sensitivity 0.0 -> required = windowSize (entire window).
        let required = max(1, Int(ceil((1.0 - sensitivity) * Double(windowSize))))
        let isTouching = hitCount >= required

        switch (state, isTouching) {
        case (.touching, false) where hitCount == 0:
            // Only drop back to idle once the window is fully empty: avoids
            // flicker when a finger briefly leaves the zone.
            transition(to: .idle)

        case (.idle, true), (.noFace, true), (.disabled, true):
            transition(to: .touching)
            DispatchQueue.main.async { [weak self] in
                self?.onTouchEvent?()
            }

        case (.noFace, false):
            // Face came back into view, no touch yet.
            transition(to: .idle)

        default:
            break
        }
    }

    /// Pulls every reasonably-confident keypoint out of every detected hand,
    /// flagging the trigger joints that fell inside the hair zone. The
    /// returned list is used both for the touch decision (any `inZone == true`)
    /// and for the debug overlay rendering.
    ///
    /// We focus on fingertips/intermediate joints since those are the parts
    /// that actually go *into* hair. The wrist is included for the overlay
    /// only — it never drives a trigger because a hand resting in front of the
    /// face has a wrist near the cheek.
    private func collectKeypoints(
        from hands: [VNHumanHandPoseObservation],
        zone: HairZone
    ) -> [HandKeypoint] {
        var result: [HandKeypoint] = []
        let allJoints = Array(Self.triggerJoints) + Self.extraDebugJoints
        for hand in hands {
            for joint in allJoints {
                guard let point = try? hand.recognizedPoint(joint),
                      point.confidence > 0.2 else {
                    continue
                }
                let isTriggerJoint = Self.triggerJoints.contains(joint)
                let inZone = isTriggerJoint
                    && point.confidence > 0.3
                    && zone.contains(point.location)
                result.append(HandKeypoint(
                    location: point.location,
                    confidence: point.confidence,
                    inZone: inZone
                ))
            }
        }
        return result
    }

    private func emitDebug(
        faceBox: CGRect?,
        zone: CGRect?,
        handPoints: [HandKeypoint]
    ) {
        let frame = DebugFrame(
            faceBoundingBox: faceBox,
            hairZone: zone,
            handPoints: handPoints,
            state: state
        )
        DispatchQueue.main.async { [weak self] in
            self?.onDebugFrame?(frame)
        }
    }

    private func transition(to new: DetectorState) {
        guard new != state else { return }
        state = new
        DispatchQueue.main.async { [weak self, new] in
            self?.onStateChange?(new)
        }
    }
}
