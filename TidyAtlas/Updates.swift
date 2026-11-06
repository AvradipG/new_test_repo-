import Foundation
import SwiftUI
import UIKit

// Adapted from Crystal Bowl: the build workflow publishes version.json next to the IPA on the ipa-tidy-atlas branch.

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
    static var commit: String { Bundle.main.object(forInfoDictionaryKey: "TAGitCommit") as? String ?? "dev" }
    static var label: String { "\(version) (\(build))" }

    static let versionURL = URL(string: "https://raw.githubusercontent.com/AvradipG/new_test_repo-/ipa-tidy-atlas/version.json")!
    static let testFlightURL = URL(string: "itms-beta://")!

    /// Text to paste into the Claude chat when something is wrong.
    @MainActor
    static func problemReport(description: String, places: [Place]) -> String {
        let d = UIDevice.current
        let rooms = places.flatMap(\.rooms)
        var lines = [
            "Tidy Atlas problem report",
            "App: \(label), commit \(commit), installed via \(InstallSource.current.rawValue)",
            "Device: \(deviceModel()), \(d.systemName) \(d.systemVersion), LiDAR room scan: \(RoomScanSupport.isAvailable ? "yes" : "no")",
            "AI keys: Claude \(KeyStore.hasKey(.claude) ? "yes" : "no"), ChatGPT \(KeyStore.hasKey(.chatgpt) ? "yes" : "no"), order: \(AIService.preference.label), last answer from \(AIService.lastProvider?.label ?? "none yet")",
            "Places: \(places.count), rooms: \(rooms.count), things: \(rooms.reduce(0) { $0 + $1.items.count })",
            "",
            "What happened:",
            description.isEmpty ? "(not filled in)" : description,
        ]
        let failed = rooms.flatMap(\.captures).filter { $0.status == .failed }.sorted { $0.createdAt > $1.createdAt }
        if let f = failed.first {
            lines.append("")
            lines.append("Latest failed photo: \(f.error ?? "no message")")
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
}

extension Organizer {
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
            Text("New builds can take up to 15 minutes to appear in TestFlight.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { openURL(AppInfo.testFlightURL) } label: {
                Label("Open TestFlight", systemImage: "airplane")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
