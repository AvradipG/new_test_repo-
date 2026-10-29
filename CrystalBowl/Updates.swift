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
                Text("The report includes the app version, iPhone model, iOS version and the latest scan's numbers, so the fix can be targeted. No photos are included.")
            }
        }
        .navigationTitle("About and updates")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: problem) { _, _ in copied = false }
    }
}
