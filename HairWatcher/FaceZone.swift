import Vision
import CoreGraphics

/// The "face zone" is a rectangle in normalized image coordinates (Vision's
/// bottom-left origin) covering the lower face — chin, cheeks, mouth — but
/// excluding the forehead/hair region above the eye line.
struct FaceZone {
    let rect: CGRect

    static func compute(from face: VNFaceObservation) -> FaceZone {
        let bbox = face.boundingBox
        let widthExpansion: CGFloat = 0.15

        let minX = max(0, bbox.minX - bbox.width * widthExpansion)
        let maxX = min(1, bbox.maxX + bbox.width * widthExpansion)
        let lowerY = bbox.minY

        var upperY = bbox.minY + bbox.height * 0.4
        if let leftEye = face.landmarks?.leftEye?.normalizedPoints,
           let rightEye = face.landmarks?.rightEye?.normalizedPoints,
           !leftEye.isEmpty,
           !rightEye.isEmpty {
            let avgEyeY = (averageY(leftEye) + averageY(rightEye)) / 2.0
            upperY = bbox.minY + avgEyeY * bbox.height
        }

        let height = max(0, upperY - lowerY)
        let rect = CGRect(x: minX, y: lowerY, width: maxX - minX, height: height)
        return FaceZone(rect: rect)
    }

    func contains(_ point: CGPoint) -> Bool {
        rect.contains(point)
    }

    private static func averageY(_ points: [CGPoint]) -> CGFloat {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
    }
}
