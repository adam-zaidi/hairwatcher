import Vision
import CoreMedia
import CoreVideo
import Foundation

enum DetectorState: Equatable {
    case idle
    case touchingHair
    case touchingFace
    case touchingBoth
    case noFace
    case disabled
}

/// Per-frame hand+face inference plus sliding-window debouncers per touch kind.
final class HairTouchDetector {
    var onStateChange: ((DetectorState) -> Void)?
    var onHairTouchEvent: (() -> Void)?
    var onFaceTouchEvent: (() -> Void)?
    var onDebugFrame: ((DebugFrame) -> Void)?

    var sensitivity: Double = 0.66
    var watchTarget: WatchTarget = .both

    struct HandKeypoint: Equatable, Hashable, Sendable {
        let location: CGPoint
        let confidence: Float
        let inHairZone: Bool
        let inFaceZone: Bool
    }

    struct DebugFrame: Equatable, Sendable {
        let faceBoundingBox: CGRect?
        let hairZone: CGRect?
        let faceZone: CGRect?
        let handPoints: [HandKeypoint]
        let state: DetectorState
    }

    private static let triggerJoints: Set<VNHumanHandPoseObservation.JointName> = [
        .thumbTip, .thumbIP,
        .indexTip, .indexDIP, .indexPIP, .indexMCP,
        .middleTip, .middleDIP, .middlePIP, .middleMCP,
        .ringTip, .ringDIP, .ringPIP, .ringMCP,
        .littleTip, .littleDIP, .littlePIP, .littleMCP,
    ]

    private static let extraDebugJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .thumbMP, .thumbCMC,
    ]

    private let queue = DispatchQueue(label: "com.hairwatcher.vision", qos: .utility)
    private let windowSize = 6

    private var hairHitWindow: [Bool] = []
    private var faceHitWindow: [Bool] = []
    private var hairTouching = false
    private var faceTouching = false

    private(set) var state: DetectorState = .idle

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        queue.sync { [weak self] in
            self?.run(on: pixelBuffer)
        }
    }

    func reset(to newState: DetectorState = .idle) {
        queue.sync { [weak self] in
            guard let self else { return }
            self.hairHitWindow.removeAll()
            self.faceHitWindow.removeAll()
            self.hairTouching = false
            self.faceTouching = false
            self.transition(to: newState)
        }
    }

    private func run(on pixelBuffer: CVPixelBuffer) {
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
            hairHitWindow.removeAll()
            faceHitWindow.removeAll()
            hairTouching = false
            faceTouching = false
            transition(to: .noFace)
            emitDebug(faceBox: nil, hairZone: nil, faceZone: nil, handPoints: [])
            return
        }

        let largest = faces.max { lhs, rhs in
            (lhs.boundingBox.width * lhs.boundingBox.height) <
                (rhs.boundingBox.width * rhs.boundingBox.height)
        }!

        let hairZone = HairZone.compute(from: largest)
        let faceZone = FaceZone.compute(from: largest)
        let hands = handRequest.results ?? []
        let keypoints = collectKeypoints(
            from: hands,
            hairZone: hairZone,
            faceZone: faceZone
        )

        let hairHit = watchTarget.watchesHair && keypoints.contains { $0.inHairZone }
        let faceHit = watchTarget.watchesFace && keypoints.contains { $0.inFaceZone }

        emitDebug(
            faceBox: largest.boundingBox,
            hairZone: watchTarget.watchesHair ? hairZone.rect : nil,
            faceZone: watchTarget.watchesFace ? faceZone.rect : nil,
            handPoints: keypoints
        )

        if watchTarget.watchesHair {
            registerHit(hairHit, window: &hairHitWindow, wasTouching: &hairTouching) { [weak self] in
                self?.onHairTouchEvent?()
            }
        } else {
            hairHitWindow.removeAll()
            hairTouching = false
        }

        if watchTarget.watchesFace {
            registerHit(faceHit, window: &faceHitWindow, wasTouching: &faceTouching) { [weak self] in
                self?.onFaceTouchEvent?()
            }
        } else {
            faceHitWindow.removeAll()
            faceTouching = false
        }

        updateAggregateState()
    }

    private func registerHit(
        _ hit: Bool,
        window: inout [Bool],
        wasTouching: inout Bool,
        onNewTouch: @escaping () -> Void
    ) {
        window.append(hit)
        if window.count > windowSize {
            window.removeFirst(window.count - windowSize)
        }

        let hitCount = window.filter { $0 }.count
        let required = max(1, Int(ceil((1.0 - sensitivity) * Double(windowSize))))
        let isTouching = hitCount >= required

        if isTouching && !wasTouching {
            wasTouching = true
            DispatchQueue.main.async { onNewTouch() }
        } else if !isTouching && hitCount == 0 {
            wasTouching = false
        }
    }

    private func updateAggregateState() {
        let hairActive = watchTarget.watchesHair && hairTouching
        let faceActive = watchTarget.watchesFace && faceTouching

        let newState: DetectorState
        switch (hairActive, faceActive) {
        case (true, true): newState = .touchingBoth
        case (true, false): newState = .touchingHair
        case (false, true): newState = .touchingFace
        case (false, false):
            newState = .idle
        }
        transition(to: newState)
    }

    private func collectKeypoints(
        from hands: [VNHumanHandPoseObservation],
        hairZone: HairZone,
        faceZone: FaceZone
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
                let confident = point.confidence > 0.3
                let inHair = isTriggerJoint
                    && confident
                    && hairZone.contains(point.location)
                let inFace = isTriggerJoint
                    && confident
                    && faceZone.contains(point.location)
                result.append(HandKeypoint(
                    location: point.location,
                    confidence: point.confidence,
                    inHairZone: inHair,
                    inFaceZone: inFace
                ))
            }
        }
        return result
    }

    private func emitDebug(
        faceBox: CGRect?,
        hairZone: CGRect?,
        faceZone: CGRect?,
        handPoints: [HandKeypoint]
    ) {
        let frame = DebugFrame(
            faceBoundingBox: faceBox,
            hairZone: hairZone,
            faceZone: faceZone,
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
