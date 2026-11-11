import UIKit
import Photos

extension Notification.Name {
    /// The phone was shaken (any screen of the app).
    static let deviceDidShake = Notification.Name("CrystalBowl.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}

/// A picture of the app's screen for a problem report (3.13): shake the phone and the screen is saved to Photos
/// and to App log › Screens, which goes to Google Drive › Crystal Bowl Scans › _app-log › Screens with the log, so
/// it can be looked at next to the log lines of the same moment. Works when an iOS screenshot doesn't.
enum ScreenSnap {
    static var folder: URL { AppLog.folder.appendingPathComponent("Screens", isDirectory: true) }
    private static var last = Date.distantPast

    private static let nameFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Saves the screen as it is now. Returns false when nothing could be drawn (or a snap was just taken).
    @MainActor
    static func take(reason: String) -> Bool {
        guard Date().timeIntervalSince(last) > 2 else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return false }
        last = Date()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let png = image.pngData() else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "screen-" + nameFormat.string(from: Date()) + ".png"
        let url = folder.appendingPathComponent(name)
        guard (try? png.write(to: url, options: .atomic)) != nil else { return false }
        AppLog.info("screen", "Screen saved for a report (\(reason)): Screens/\(name), \(AppInfo.label). A live camera picture may show black in it.")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
            }, completionHandler: nil)
        }
        Task { await AppModel.current?.uploadAppLog() }
        return true
    }
}
