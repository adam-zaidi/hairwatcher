import SwiftUI
import AppKit
import AVFoundation

/// Thin SwiftUI wrapper around an `AVCaptureVideoPreviewLayer`. Overlays are
/// drawn separately as SwiftUI shapes (see `OverlayShapesView`) so we don't
/// have to fight CALayer's coordinate quirks vs. AppKit's bottom-left origin.
struct DebugCameraView: NSViewRepresentable {
    let cameraManager: CameraManager

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.attach(cameraManager: cameraManager)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.attach(cameraManager: cameraManager)
    }

    static func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) {
        nsView.detach()
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private weak var cameraManager: CameraManager?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        previewLayer.videoGravity = .resizeAspect
        root.addSublayer(previewLayer)
    }

    func attach(cameraManager: CameraManager) {
        guard self.cameraManager !== cameraManager else { return }
        self.cameraManager?.detachPreview(from: previewLayer)
        self.cameraManager = cameraManager
        cameraManager.attachPreview(to: previewLayer)
    }

    func detach() {
        cameraManager?.detachPreview(from: previewLayer)
        cameraManager = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
