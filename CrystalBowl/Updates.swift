import Foundation
import SwiftUI
import UIKit

/// What the newest cloud build is, published by the build workflow next to the IPA.
struct RemoteVersion: Decodable, Equatable {
    var version: String
    var build: Int
    var commit: String
    var date: String
    var notes: [String]
}

enum InstallSource: String {
    case testFlight = "TestFlight"
    case sideloaded = "Sideloadly / cable"
    case appStore = "App Store"

    static var current: InstallSource {
        guard let receipt = Bundle.main.appStoreReceiptURL else { return .sideloaded }
        if receipt.lastPathComponent == "sandboxReceipt" { return .testFlight }
        return FileManager.default.fileExists(atPath: receipt.path) ? .appStore : .sideloaded
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    static var commit: String { Bundle.main.object(forInfoDictionaryKey: "CBGitCommit") as? String ?? "dev" }
    static var label: String { "\(version) (\(build))" }

    static let versionURL = URL(string: "https://raw.githubusercontent.com/AvradipG/new_test_repo-/ipa/version.json")!
    static let ipaURL = URL(string: "https://github.com/AvradipG/new_test_repo-/raw/ipa/CrystalBowlScanner.ipa")!
    static let testFlightURL = URL(string: "itms-beta://")!

    /// Text the user can paste into the Claude chat when something is wrong.
    static func problemReport(description: String, scans: [Scan]) -> String {
        let d = UIDevice.current
        var lines = [
            "Crystal Bowl problem report",
            "App: \(label), commit \(commit), installed via \(InstallSource.current.rawValue)",
            "Device: \(deviceModel()), \(d.systemName) \(d.systemVersion)",
            "Free space: \(freeSpace())",
            "",
            "What happened:",
            description.isEmpty ? "(not filled in)" : description,
        ]
        if let s = scans.first {
            lines.append("")
            lines.append("Latest scan: \(s.name), \(s.photoCount ?? 0) photos, \(s.passes ?? 1) pass(es), model: \(s.hasModel ? "yes" : "no")")
            if let st = s.stats {
                lines.append(String(format: "Axes %.1f × %.1f × %.1f mm, volume %.2f cm³, %d triangles, closed: %@",
                                    st.axisA, st.axisB, st.axisC, st.volumeCM3, st.triangleCount, st.isClosed ? "yes" : "no"))
            }
            lines.append("Cross-section stacks: \(s.sections?.count ?? 0)")
        }
        lines.append("")
        lines.append("Last lines of the app log:")
        lines.append(AppLog.tail(60))
        return lines.joined(separator: "\n")
    }

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func freeSpace() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let bytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension AppModel {
    /// Fetches version.json and records it when it is newer than the running build.
    func checkForUpdate() async {
        var request = URLRequest(url: AppInfo.versionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let remote = try? JSONDecoder().decode(RemoteVersion.self, from: data) else { return }
        latestRemote = remote
        lastUpdateCheck = Date()
    }

    var updateAvailable: RemoteVersion? {
        guard let r = latestRemote, r.build > AppInfo.build else { return nil }
        return r
    }
}

// MARK: Views

struct UpdateBanner: View {
    let remote: RemoteVersion
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Update ready: \(remote.version) (\(remote.build))", systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            ForEach(remote.notes.prefix(4), id: \.self) { note in
                Text("• \(note)").font(.callout)
            }
            if InstallSource.current == .sideloaded {
                Text("Download the new file on your PC and install it with Sideloadly.")
                    .font(.footnote).foregroundStyle(.secondary)
                ShareLink(item: AppInfo.ipaURL) { Label("Share download link", systemImage: "link") }
            } else {
                Text("New builds can take up to 15 minutes to appear in TestFlight.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { openURL(AppInfo.testFlightURL) } label: {
                    Label("Open TestFlight", systemImage: "airplane")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AboutView: View {
    @EnvironmentObject var model: AppModel
    @State private var problem = ""
    @State private var checking = false
    @State private var copied = false
    @AppStorage(AppModel.uploadLogKey) private var uploadLog = true

    var body: some View {
        List {
            Section("This version") {
                LabeledContent("Version", value: AppInfo.label)
                LabeledContent("Code commit", value: AppInfo.commit)
                LabeledContent("Installed via", value: InstallSource.current.rawValue)
            }

            Section {
                if let r = model.updateAvailable {
                    UpdateBanner(remote: r)
                } else if let r = model.latestRemote {
                    Label("You have the latest build", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if !r.notes.isEmpty {
                        ForEach(r.notes, id: \.self) { Text("• \($0)").font(.callout) }
                    }
                } else {
                    Text("Not checked yet.").foregroundStyle(.secondary)
                }
                Button {
                    checking = true
                    Task { await model.checkForUpdate(); checking = false }
                } label: {
                    if checking { ProgressView() } else { Label("Check for updates", systemImage: "arrow.clockwise") }
                }
                .disabled(checking)
            } header: {
                Text("Updates")
            } footer: {
                Text(model.lastUpdateCheck.map { "Last checked \($0.formatted(date: .omitted, time: .shortened))." } ?? "The app checks each time it opens.")
            }

            Section {
                TextField("What went wrong or what should change?", text: $problem, axis: .vertical)
                    .lineLimit(3...8)
                let report = AppInfo.problemReport(description: problem, scans: model.scans)
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label(copied ? "Copied. Paste it into the Claude chat" : "Copy report for Claude", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                }
                ShareLink(item: report) { Label("Share report", systemImage: "square.and.arrow.up") }
            } header: {
                Text("Report a problem")
            } footer: {
                Text("The report includes the app version, iPhone model, iOS version, the latest scan's numbers and the last lines of the app log, so the fix can be targeted. No photos are included.")
            }

            Section {
                NavigationLink { AppLogView() } label: { Label("Show the app log", systemImage: "doc.text.magnifyingglass") }
                ShareLink(item: AppLog.todayFile) { Label("Share today's log file", systemImage: "square.and.arrow.up") }
                Toggle("Send the app log to Google Drive", isOn: $uploadLog)
            } header: {
                Text("App log")
            } footer: {
                Text("The app writes down what it does: starts, phone locks, each build stage and how long it took, pauses, uploads, memory and heat warnings, and every error with its code. When the app crashes, iOS hands over a crash report at the next start, and it is kept too. Everything is in Files › On My iPhone › Crystal Bowl › App log, and goes to My Drive › Crystal Bowl Scans › _app-log. Each scan's own build log travels in its folder (logs/build-log.txt). No photos or passwords are written.")
            }
        }
        .navigationTitle("About and updates")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: problem) { _, _ in copied = false }
    }
}

/// The end of the app log, newest at the bottom.
struct AppLogView: View {
    @State private var text = ""
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "The log is empty." : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear {
                text = AppLog.tail(500)
                DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
            }
            .refreshable { text = AppLog.tail(500) }
        }
        .navigationTitle("App log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        }
    }
}
