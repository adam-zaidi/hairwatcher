import Vision
import CoreGraphics

/// The "hair zone" is a rectangle in normalized image coordinates (Vision's
/// bottom-left origin) that approximates where someone's hair is on screen,
/// derived purely from a face observation.
///
/// Construction:
///  - Horizontally: the face bounding box widened by `widthExpansion` on each side
///    so the temples / sides of the head are included.
///  - Vertically (top): pushed above the face bounding box by `topExpansion` of
///    the face height to capture the crown / volume above the head.
///  - Vertically (bottom): the average eye Y when face landmarks are available
///    (so chin / mouth / cheek touches don't count), otherwise 40% up the face box.
struct HairZone {
    let rect: CGRect

    static func compute(from face: VNFaceObservation) -> HairZone {
        let bbox = face.boundingBox

        let widthExpansion: CGFloat = 0.15
        let topExpansion: CGFloat = 0.7

        let minX = max(0, bbox.minX - bbox.width * widthExpansion)
        let maxX = min(1, bbox.maxX + bbox.width * widthExpansion)
        let topY = min(1, bbox.maxY + bbox.height * topExpansion)

        // Default: forehead-ish (40% up the face box).
        var lowerY = bbox.minY + bbox.height * 0.4

        // If we have landmarks, pin the lower edge to the eye line so that
        // touches on the lower face (mouth, chin, jaw) are excluded.
        if let leftEye = face.landmarks?.leftEye?.normalizedPoints,
           let rightEye = face.landmarks?.rightEye?.normalizedPoints,
           !leftEye.isEmpty,
           !rightEye.isEmpty {
            let avgEyeY = (averageY(leftEye) + averageY(rightEye)) / 2.0
            // Landmarks are normalized within the face bbox; map back to image space.
            let eyeImageY = bbox.minY + avgEyeY * bbox.height
            lowerY = eyeImageY
        }

        let height = max(0, topY - lowerY)
        let rect = CGRect(x: minX, y: lowerY, width: maxX - minX, height: height)
        return HairZone(rect: rect)
    }

    func contains(_ point: CGPoint) -> Bool {
        rect.contains(point)
    }

    private static func averageY(_ points: [CGPoint]) -> CGFloat {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
    }
}
