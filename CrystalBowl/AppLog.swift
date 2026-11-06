import Foundation
import UIKit
import MetricKit
import BackgroundTasks

/// The app's own diary: what it did and when, how long builds took, every error with its code, phone locks,
/// memory and heat warnings, and the crash reports iOS hands over. One text file per day in
/// Documents › App log (visible in the Files app); it goes to Google Drive › Crystal Bowl Scans › _app-log.
/// Each scan also keeps its own capture and build lines in Logs/build-log.txt, which travel with the scan.
enum AppLog {
    private static let queue = DispatchQueue(label: "crystalbowl.applog")

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("App log", isDirectory: true)
    }
    /// Crash, hang and exit reports from iOS (MetricKit), one JSON file each.
    static var reportsFolder: URL { folder.appendingPathComponent("iOS reports", isDirectory: true) }
    private static var stateURL: URL { folder.appendingPathComponent(".run-state.json") }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xx"
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static var todayFile: URL { folder.appendingPathComponent("crystal-bowl-\(dayFormat.string(from: Date())).log") }

    static func buildLogURL(_ scan: Scan) -> URL {
        scan.folderURL.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("build-log.txt")
    }

    // MARK: Writing

    static func info(_ area: String, _ text: String, scan: Scan? = nil) { write("INFO ", area, text, scan) }
    static func warn(_ area: String, _ text: String, scan: Scan? = nil) { write("WARN ", area, text, scan) }
    static func error(_ area: String, _ text: String, scan: Scan? = nil) { write("ERROR", area, text, scan) }
    static func error(_ area: String, _ text: String, _ err: Error, scan: Scan? = nil) {
        write("ERROR", area, text + ": " + describe(err), scan)
    }

    /// The message plus the domain and code, which is what tells one failure from another.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var s = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if let reason = ns.localizedFailureReason, !reason.isEmpty { s += " reason: \(reason)" }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += " ← \(under.localizedDescription) [\(under.domain) \(under.code)]"
        }
        let detail = String(describing: error)
        if detail.count < 400 && !s.contains(detail) { s += " (\(detail))" }
        return s
    }

    private static func write(_ level: String, _ area: String, _ text: String, _ scan: Scan?, now: Bool = false) {
        let line = "\(stampFormat.string(from: Date())) \(level) [\(area)] \(text)\n"
        let day = todayFile
        let scanLog = scan.map { buildLogURL($0) }
        let work = {
            append(line, to: day)
            if let scanLog { append(line, to: scanLog) }
        }
        if now { queue.sync(execute: work) } else { queue.async(execute: work) }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }

    private static func append(_ line: String, to url: URL) {
        let data = Data(line.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    /// Waits until every line so far is on disk (before the app may be stopped).
    static func flush() { queue.sync {} }

    // MARK: Run state (to notice a crash or a stop by iOS at the next start)

    private struct RunState: Codable {
        var version: String
        var onScreen: Bool
        var activity: String
        var updated: Date
    }

    private static var state = RunState(version: "", onScreen: false, activity: "starting", updated: Date())

    /// What the app is busy with; kept on disk so the next start can say what was going on if the app died.
    static func setActivity(_ activity: String) {
        queue.async {
            state.activity = activity
            state.updated = Date()
            saveState()
        }
    }

    static func setOnScreen(_ onScreen: Bool) {
        queue.async {
            state.onScreen = onScreen
            state.updated = Date()
            saveState()
        }
    }

    private static func saveState() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    private static func loadState() -> RunState? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? dec.decode(RunState.self, from: data)
    }

    // MARK: Start of a run

    private static var observers: [NSObjectProtocol] = []

    @MainActor
    static func startSession() {
        try? FileManager.default.createDirectory(at: reportsFolder, withIntermediateDirectories: true)
        prune()
        let label = AppInfo.label
        let prior: RunState? = queue.sync {
            let old = loadState()
            state = RunState(version: label, onScreen: false, activity: "starting", updated: Date())
            saveState()
            return old
        }

        let p = ProcessInfo.processInfo
        info("app", "──────── Crystal Bowl \(AppInfo.label), commit \(AppInfo.commit), \(InstallSource.current.rawValue)")
        info("app", "Device \(AppInfo.deviceModel()), iOS \(UIDevice.current.systemVersion), memory \(p.physicalMemory / 1_048_576) MB, "
             + "free space \(AppInfo.freeSpace()), low power mode \(p.isLowPowerModeEnabled ? "on" : "off"), heat \(thermal())")
        info("app", "Graphics chip for builds in the background: \(backgroundGPU)")
        if let prior {
            let ago = Int(Date().timeIntervalSince(prior.updated) / 60)
            if prior.onScreen {
                error("app", "The previous run (\(prior.version)) ended while on screen, \(ago) min ago, during: \(prior.activity). "
                      + "That is a crash or iOS stopping the app; iOS's crash report, if any, lands in App log › iOS reports.")
            } else if prior.activity.hasPrefix("building") || prior.activity.hasPrefix("capturing") {
                warn("app", "The previous run (\(prior.version)) was closed by iOS in the background, \(ago) min ago, during: \(prior.activity).")
            }
        }

        NSSetUncaughtExceptionHandler { e in
            AppLog.write("FATAL", "crash", "Uncaught exception \(e.name.rawValue): \(e.reason ?? "")\n    "
                         + e.callStackSymbols.prefix(30).joined(separator: "\n    "), nil, now: true)
        }

        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
                AppLog.warn("memory", "iOS says memory is low; the app uses \(AppLog.memoryInUseMB()) MB")
            },
            nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
                AppLog.info("heat", "Phone heat is now \(AppLog.thermal())")
            },
            nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
                AppLog.info("power", "Low power mode \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
            },
            nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil) { _ in
                AppLog.info("phone", "Phone locked")
            },
            nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { _ in
                AppLog.info("phone", "Phone unlocked")
            },
        ]
        IOSReports.shared.start()
    }

    static var backgroundGPU: String {
        if #available(iOS 26.0, *) {
            return BGTaskScheduler.supportedResources.contains(.gpu) ? "allowed on this iPhone" : "not allowed on this iPhone (iOS pauses the 3D build when the phone locks)"
        }
        return "not allowed before iOS 26"
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot (iOS slows the app)"
        case .critical: return "critical (iOS may stop the app)"
        @unknown default: return "unknown"
        }
    }

    static func memoryInUseMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// Keeps 60 days of daily files and reports.
    private static func prune() {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-60 * 86_400)
        for dir in [folder, reportsFolder] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in items where url.pathExtension == "log" || url.pathExtension == "json" {
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if mod < limit { try? fm.removeItem(at: url) }
            }
        }
    }

    // MARK: Reading and sharing

    /// The daily logs and iOS reports, as (path under _app-log, local file), oldest first.
    static func files() -> [(String, URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        let logs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        out += logs.map { ($0.lastPathComponent, $0) }
        let reports = ((try? fm.contentsOfDirectory(at: reportsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        out += reports.map { ("iOS reports/\($0.lastPathComponent)", $0) }
        return out
    }

    /// The last lines of the log, newest last (today's file, and yesterday's when today's is short).
    static func tail(_ count: Int) -> String {
        flush()
        let logs = files().filter { $0.0.hasSuffix(".log") }.suffix(2)
        var lines: [Substring] = []
        for (_, url) in logs {
            // Only the end of each file is read, so this stays quick however long the day's log is.
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let start = size > 96_000 ? size - 96_000 : 0
            try? h.seek(toOffset: start)
            guard let data = try? h.readToEnd() else { continue }
            var part = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            if start > 0 && !part.isEmpty { part.removeFirst() } // a cut line
            lines += part
        }
        return lines.suffix(count).joined(separator: "\n")
    }

    // MARK: MetricKit summaries

    fileprivate static func savedReport(_ data: Data, name: String) -> Bool {
        let url = reportsFolder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.createDirectory(at: reportsFolder, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    fileprivate static func compact(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else { return String(describing: any) }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Receives crash, hang and exit reports from iOS. iOS delivers them at the next start of the app (crashes)
/// or once a day (exit counts: how often iOS closed the app in the background, and why).
final class IOSReports: NSObject, MXMetricManagerSubscriber {
    static let shared = IOSReports()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        handle(diagnostics: MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { handle(diagnostics: payloads) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            let data = p.jsonRepresentation()
            guard AppLog.savedReport(data, name: "metrics-\(Self.name(p.timeStampEnd)).json") else { continue }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let exits = json["applicationExitMetrics"] as? [String: Any] {
                AppLog.info("ios-report", "Daily exit counts from iOS (\(Self.name(p.timeStampBegin)) to \(Self.name(p.timeStampEnd))): \(Self.nonZero(exits))")
            }
        }
    }

    private func handle(diagnostics payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            let data = p.jsonRepresentation()
            guard AppLog.savedReport(data, name: "diagnostics-\(Self.name(p.timeStampEnd)).json") else { continue }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for key in ["crashDiagnostics", "hangDiagnostics", "cpuExceptionDiagnostics", "diskWriteExceptionDiagnostics", "appLaunchDiagnostics"] {
                guard let list = json[key] as? [[String: Any]], !list.isEmpty else { continue }
                for item in list {
                    let meta = item["diagnosticMetaData"] ?? [:]
                    let text = "\(key) from iOS (\(Self.name(p.timeStampBegin)) to \(Self.name(p.timeStampEnd))): \(AppLog.compact(meta))"
                    if key == "crashDiagnostics" { AppLog.error("ios-report", text) } else { AppLog.warn("ios-report", text) }
                }
            }
        }
    }

    private static func name(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    /// Flattens nested counts and keeps only the ones above zero.
    private static func nonZero(_ dict: [String: Any], prefix: String = "") -> String {
        var parts: [String] = []
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let sub = v as? [String: Any] {
                let s = nonZero(sub, prefix: key)
                if !s.isEmpty { parts.append(s) }
            } else if let n = v as? NSNumber, n.doubleValue != 0 {
                parts.append("\(key)=\(n)")
            }
        }
        return parts.joined(separator: ", ")
    }
}
