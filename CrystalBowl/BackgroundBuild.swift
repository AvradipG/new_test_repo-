import Foundation
import UIKit
import BackgroundTasks
import UserNotifications

/// Keeps a model build running when the user leaves the app or locks the phone.
///
/// On iOS 26 and later the build is handed to the system as a continued-processing task: iOS shows its
/// progress in a system banner and lets the app keep working in the background. Earlier systems get the
/// usual short background grace period. If iOS still stops the work, the build is resumed from its checkpoint
/// the next time the app runs (see AppModel.resumePendingBuilds).
@MainActor
final class BackgroundBuild {
    static let shared = BackgroundBuild()
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml ("<prefix>.*").
    static let prefix = "com.avradip.crystalbowl.build"

    /// Called when iOS takes the background time back; the build should stop cleanly so it can resume later.
    var onExpire: (() -> Void)?
    private(set) var expired = false

    private var legacyID: UIBackgroundTaskIdentifier = .invalid
    private var task: BGTask?
    private var active = false
    private var title = ""
    private var fraction = 0.0
    private var note = ""

    func begin(title: String) {
        end(success: false)
        expired = false
        active = true
        self.title = title
        fraction = 0
        note = "Starting…"
        legacyID = UIApplication.shared.beginBackgroundTask(withName: "model-build") {
            MainActor.assumeIsolated { BackgroundBuild.shared.endLegacy() }
        }
        if #available(iOS 26.0, *) { submitContinued() }
    }

    func update(fraction: Double, note: String) {
        self.fraction = max(0, min(1, fraction))
        self.note = note
        if #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask {
            t.progress.completedUnitCount = Int64(self.fraction * 1000)
            t.updateTitle(title, subtitle: note)
        }
    }

    func end(success: Bool) {
        active = false
        if let t = task {
            task = nil
            t.setTaskCompleted(success: success)
        }
        endLegacy()
    }

    private func endLegacy() {
        if legacyID != .invalid {
            UIApplication.shared.endBackgroundTask(legacyID)
            legacyID = .invalid
        }
    }

    @available(iOS 26.0, *)
    private func submitContinued() {
        // Each build gets its own identifier under the permitted wildcard, so registering never repeats one.
        let id = "\(Self.prefix).\(Int(Date().timeIntervalSince1970 * 1000))"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil, launchHandler: Self.launchHandler)
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: note)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.info("background", "Asked iOS to keep the build going outside the app")
        } catch {
            AppLog.warn("background", "iOS won't keep the build going outside the app: \(AppLog.describe(error))")
        }
    }

    /// Runs on a background queue when iOS starts the task; the work itself is already running in the app.
    private nonisolated static func launchHandler(_ task: BGTask) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { BackgroundBuild.shared.attach(task) }
        }
    }

    private func attach(_ t: BGTask) {
        guard active else {
            t.setTaskCompleted(success: true)
            return
        }
        task = t
        AppLog.info("background", "iOS accepted the build as a background task")
        t.expirationHandler = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { BackgroundBuild.shared.expire() }
            }
        }
        if #available(iOS 26.0, *), let c = t as? BGContinuedProcessingTask {
            c.progress.totalUnitCount = 1000
            c.progress.completedUnitCount = Int64(fraction * 1000)
            c.updateTitle(title, subtitle: note)
        }
    }

    private func expire() {
        expired = true
        AppLog.warn("background", "iOS took the background time back (or the build was stopped from the Lock Screen)")
        onExpire?()
        if let t = task {
            task = nil
            t.setTaskCompleted(success: false)
        }
    }
}

/// Local notifications for builds that finish or pause while the user is in another app.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posted only when the app isn't on screen; on screen the app shows its own banner.
    @MainActor
    static func post(id: String, title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
