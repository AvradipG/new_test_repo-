// Copied from the Crystal Bowl Scanner (1.10): phone light and focus helpers, and the life-size AR Quick Look view.
import AVFoundation
import ARKit
import QuickLook
import SwiftUI

/// Focus, exposure and light help for the 3D capture camera.
///
/// Object Capture runs the camera itself and has no focus or zoom settings. ARKit (iOS 16+) still hands out the
/// camera it uses, and that device accepts a focus and exposure point: the camera then keeps focusing and metering
/// on that spot as the user moves, which keeps the rock sharp and bright on its shadow side. Zoom stays off on
/// purpose: Object Capture needs the fixed wide lens for true scale, so the way to get closer is to move closer.
enum CameraAssist {
    static var device: AVCaptureDevice? {
        ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Focus and expose on a point of the screen (0…1 in portrait view coordinates). Returns false if refused.
    @discardableResult
    static func focus(atView p: CGPoint) -> Bool {
        // The camera's coordinates are landscape: x along the long side, from the top of the phone held upright.
        let poi = CGPoint(x: min(max(p.y, 0), 1), y: min(max(1 - p.x, 0), 1))
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return false }
        defer { d.unlockForConfiguration() }
        if d.isFocusPointOfInterestSupported {
            d.focusPointOfInterest = poi
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        }
        if d.isExposurePointOfInterestSupported {
            d.exposurePointOfInterest = poi
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        }
        if d.isSmoothAutoFocusSupported { d.isSmoothAutoFocusEnabled = false }
        return true
    }

    /// Back to the centre of the picture, where the rock normally is.
    static func recenter() { focus(atView: CGPoint(x: 0.5, y: 0.5)) }

    static var hasLight: Bool { device?.hasTorch == true }

    /// Turns the phone's light on at a soft level (too bright gives shiny spots on the rock) or off.
    @discardableResult
    static func setLight(_ on: Bool, level: Float = 0.45) -> Bool {
        guard let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return false }
        defer { d.unlockForConfiguration() }
        if on {
            return (try? d.setTorchModeOn(level: min(max(level, 0.05), AVCaptureDevice.maxAvailableTorchLevel))) != nil
        }
        d.torchMode = .off
        return true
    }
}

/// AR Quick Look: places the finished model on the real table at its true size, like furniture shopping apps,
/// so it can be held next to the real rock to check the scan.
struct ARModelPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: ARQuickLookPreviewItem
        init(url: URL) {
            item = ARQuickLookPreviewItem(fileAt: url)
            item.allowsContentScaling = false // life-size only
        }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }
    }
}
