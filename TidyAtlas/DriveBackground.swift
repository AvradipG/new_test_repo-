// Background Drive uploads, copied from the Crystal Bowl Scanner (1.10).
import Foundation
import UIKit
import BackgroundTasks
import SwiftData

/// Drive uploads that keep going after the user leaves the app or locks the phone.
///
/// Each file's bytes go through a background URLSession: iOS itself carries the transfer on, even while the app
/// is suspended, and wakes the app when files finish. The app only needs a few seconds in front (or in the
/// background grace period) to open one Google upload session per file and hand the files to iOS.
final class DriveBackground: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = DriveBackground()
    static let identifier = "com.avradip.tidyatlas.drive"

    /// What a background task carries, stored in its taskDescription so it survives the app being closed.
    struct Item: Codable {
        var rel: String
        var size: Int64
        var modified: Date
    }

    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    private var systemCompletion: (() -> Void)?

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        c.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    func wake(completion: @escaping () -> Void) {
        lock.withLock { systemCompletion = completion }
        _ = session
    }

    func submit(_ item: Item, to sessionURL: URL, file: URL, mime: String) {
        var put = URLRequest(url: sessionURL)
        put.httpMethod = "PUT"
        put.setValue(mime, forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: put, fromFile: file)
        task.taskDescription = (try? JSONEncoder().encode(item)).flatMap { String(data: $0, encoding: .utf8) }
        task.resume()
    }

    /// Files iOS is still uploading.
    func inFlight() async -> Set<String> {
        let tasks = await session.allTasks
        var out = Set<String>()
        for t in tasks where t.state == .running || t.state == .suspended {
            if let item = Self.item(t) { out.insert(item.rel) }
        }
        return out
    }

    static func item(_ task: URLSessionTask) -> Item? {
        guard let d = task.taskDescription?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: d)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let item = Self.item(task) else { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let id = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["id"] as? String
        let fileID = error == nil && (200..<300).contains(code) ? id : nil
        Task { @MainActor in Organizer.current?.backgroundUploadFinished(item, fileID: fileID) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            await Organizer.current?.finishDriveUpload()
            let done = self.lock.withLock { () -> (() -> Void)? in
                defer { self.systemCompletion = nil }
                return self.systemCompletion
            }
            done?()
        }
    }
}

/// Owns the database and the organizer so they exist however iOS launches the app (also in the background,
/// to finish uploads). Same pattern as Crystal Bowl's AppDelegate.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let uploadTaskID = "com.avradip.tidyatlas.upload"
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Place.self, Room.self, Zone.self, Item.self, TidyStep.self, Capture.self)
        } catch {
            fatalError("Couldn't open the database: \(error)")
        }
    }()
    lazy var organizer = Organizer(container: container)

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = organizer
        _ = DriveBackground.shared.session
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.uploadTaskID, using: .main) { task in
            MainActor.assumeIsolated { AppDelegate.runUploadTask(task) }
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == DriveBackground.identifier { DriveBackground.shared.wake(completion: completionHandler) }
        else { completionHandler() }
    }

    /// Asks iOS for a later chance to start uploads that couldn't begin yet (no network, phone locked).
    static func scheduleUploadTask() {
        let r = BGProcessingTaskRequest(identifier: uploadTaskID)
        r.requiresNetworkConnectivity = true
        r.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(r)
    }

    private static func runUploadTask(_ task: BGTask) {
        let work = Task { @MainActor in
            await Organizer.current?.syncDrive()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
