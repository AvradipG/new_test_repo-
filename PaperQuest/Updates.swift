import Foundation
import SwiftUI
import UIKit

// From Crystal Bowl / Tidy Atlas: the build workflow publishes version.json next to the IPA on ipa-paper-quest.

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
    static var commit: String { Bundle.main.object(forInfoDictionaryKey: "PQGitCommit") as? String ?? "dev" }
    static var label: String { "\(version) (\(build))" }

    static let versionURL = URL(string: "https://raw.githubusercontent.com/AvradipG/new_test_repo-/ipa-paper-quest/version.json")!
    static let testFlightURL = URL(string: "itms-beta://")!

    /// Text to paste into the Claude chat when something is wrong.
    @MainActor
    static func problemReport(_ store: Store, description: String) -> String {
        let d = UIDevice.current
        var lines = [
            "Paper Quest problem report",
            "App: \(label), commit \(commit), installed via \(InstallSource.current.rawValue)",
            "Device: \(d.model), \(d.systemName) \(d.systemVersion)",
            "Drive: \(store.driveSignedIn ? "signed in" : store.folderLinked ? "folder linked" : "not connected"), last sync \(store.lastDriveSync.map { $0.formatted() } ?? "never")",
            "Papers: \(store.papers.map { "\($0.title) (\($0.nodes.count) entries)" }.joined(separator: ", "))",
        ]
        if let s = store.driveStatus { lines.append("Drive status: \(s)") }
        let studio = StudioSession.shared
        lines.append("Manuscript Studio: \(studio.signedIn ? "signed in as \(studio.email ?? "?")" : "not signed in"), Google: \(GoogleAuth.shared.isSignedIn ? "signed in" : "not signed in")")
        if let s = studio.status { lines.append("Manuscript Studio status: \(s)") }
        lines += ["", "What happened:", description.isEmpty ? "(not filled in)" : description]
        return lines.joined(separator: "\n")
    }
}

extension Store {
    func checkForUpdate() async {
        var request = URLRequest(url: AppInfo.versionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let remote = try? JSONDecoder().decode(RemoteVersion.self, from: data) else { return }
        latestRemote = remote
    }

    var updateAvailable: RemoteVersion? {
        guard let r = latestRemote, r.build > AppInfo.build else { return nil }
        return r
    }
}

struct UpdateBanner: View {
    let remote: RemoteVersion
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Update ready: \(remote.version) (\(remote.build))", systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .foregroundStyle(Palette.accent)
            ForEach(remote.notes.prefix(4), id: \.self) { note in
                Text("• \(note)").font(.callout)
            }
            Text("New builds can take up to 15 minutes to appear in TestFlight.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { openURL(AppInfo.testFlightURL) } label: {
                Label("Open TestFlight", systemImage: "airplane")
            }
            .buttonStyle(.borderedProminent)
        }
        .card()
    }
}
