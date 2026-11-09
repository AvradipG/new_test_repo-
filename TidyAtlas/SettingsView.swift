import SwiftData
import SwiftUI
import TidyCore
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var organizer: Organizer
    @Query(sort: \Place.createdAt) private var places: [Place]
    @Query private var items: [Item]
    @State private var claudeKeyText = ""
    @State private var openAIKeyText = ""
    @State private var keyStatus: String?
    @State private var testing: AIProvider?
    @State private var keysVersion = 0
    @AppStorage(AIService.preferenceKey) private var preference = AIPreference.claudeFirst.rawValue
    @AppStorage(AIService.openAIModelKey) private var openAIModel = ""
    @ObservedObject private var location = LocationService.shared
    @AppStorage("nudgeOn") private var nudgeOn = false
    @AppStorage("nudgeMinutes") private var nudgeMinutes = 18 * 60
    @State private var problem = ""
    @State private var copied = false
    @State private var exportURL: URL?

    var body: some View {
        Form {
            Section {
                Picker("Who answers", selection: $preference) {
                    ForEach(AIPreference.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                keyRow(.claude, text: $claudeKeyText, placeholder: "sk-ant-…")
                keyRow(.chatgpt, text: $openAIKeyText, placeholder: "sk-…")
                TextField("ChatGPT model (blank = newest available)", text: $openAIModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                if openAIModel.trimmingCharacters(in: .whitespaces).isEmpty, let auto = AIService.autoPickedModel {
                    Text("Using \(auto)").font(.footnote).foregroundStyle(.secondary)
                }
                if let keyStatus { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
                Link("Claude key: console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                Link("ChatGPT key: platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
            } header: {
                Text("AI: Claude and ChatGPT")
            } footer: {
                Text("Keys stay through every update: they are kept in the iPhone Keychain (never in a file, the database or the app itself) and backed up by iCloud Keychain, so they also come back after reinstalling or on a new iPhone. Photos and your item list go to the service you choose only when you scan, plan or ask.")
            }

            DriveSettingsSection()

            Section {
                if location.isAllowed {
                    Label("On: photos are geotagged and the app knows which place you're at", systemImage: "location.fill")
                        .foregroundStyle(.green)
                } else if location.authorization == .notDetermined {
                    Button { location.requestPermission() } label: { Label("Allow location", systemImage: "location") }
                } else {
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                        Label("Location is off: turn it on in iPhone Settings", systemImage: "location.slash")
                    }
                }
            } header: { Text("Location (geotags)") } footer: {
                Text("Used only while the app is open: to geotag whole-place scans and photos, and to show the place you're at first. Stays on this iPhone and in your own Drive backup.")
            }

            Section {
                Toggle("Daily nudge", isOn: $nudgeOn)
                if nudgeOn {
                    DatePicker("Time", selection: nudgeTime, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("One friendly reminder a day to do a single tiny step.")
            }
            .onChange(of: nudgeOn) { _, _ in Task { await scheduleNudge() } }
            .onChange(of: nudgeMinutes) { _, _ in Task { await scheduleNudge() } }

            Section {
                Button {
                    exportURL = InventoryExport.csv(items: items)
                } label: { Label("Export inventory (CSV)", systemImage: "tablecells") }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
            } header: { Text("Your data") } footer: {
                Text("Everything lives in this iPhone's database. Photos are in Files › On My iPhone › Tidy Atlas.")
            }

            Section("This version") {
                LabeledContent("Version", value: AppInfo.label)
                LabeledContent("Code commit", value: AppInfo.commit)
                LabeledContent("Installed via", value: InstallSource.current.rawValue)
                LabeledContent("LiDAR room scan", value: RoomScanSupport.isAvailable ? "Available" : "Not on this iPhone")
                if let r = organizer.updateAvailable {
                    UpdateBanner(remote: r)
                } else if organizer.latestRemote != nil {
                    Label("You have the latest build", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button("Check for updates") { Task { await organizer.checkForUpdate() } }
            }

            Section {
                TextField("What went wrong or what should change?", text: $problem, axis: .vertical)
                    .lineLimit(3...8)
                let report = AppInfo.problemReport(description: problem, places: places)
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label(copied ? "Copied. Paste it into the Claude chat" : "Copy report for Claude",
                          systemImage: copied ? "checkmark" : "doc.on.clipboard")
                }
                ShareLink(item: report) { Label("Share report", systemImage: "square.and.arrow.up") }
            } header: { Text("Report a problem") } footer: {
                Text("Includes version, iPhone model and counts. No photos or item names.")
            }
        }
        .navigationTitle("Settings")
        .onChange(of: problem) { _, _ in copied = false }
    }

    private func keyRow(_ p: AIProvider, text: Binding<String>, placeholder: String) -> some View {
        let saved = keysVersion >= 0 && KeyStore.hasKey(p)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(p.label, systemImage: saved ? "checkmark.seal.fill" : "key")
                    .foregroundStyle(saved ? Color.green : Color.primary)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(saved ? "Saved, kept through updates" : "No key").font(.caption).foregroundStyle(.secondary)
            }
            SecureField(saved ? "Paste a new key to replace it" : placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button("Save") {
                    KeyStore.save(text.wrappedValue, for: p)
                    text.wrappedValue = ""
                    keysVersion += 1
                    keyStatus = "\(p.label) key saved."
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button {
                    testing = p
                    Task {
                        do { keyStatus = "\(p.label) works: " + (try await AIService.test(p)) }
                        catch { keyStatus = "\(p.label): \(error.localizedDescription)" }
                        testing = nil
                    }
                } label: { if testing == p { ProgressView() } else { Text("Test") } }
                .disabled(!saved || testing != nil)
                if saved {
                    Button("Remove", role: .destructive) {
                        KeyStore.save("", for: p)
                        keysVersion += 1
                        keyStatus = "\(p.label) key removed."
                    }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var nudgeTime: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: nudgeMinutes / 60, minute: nudgeMinutes % 60, second: 0, of: Date()) ?? Date()
        } set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            nudgeMinutes = (c.hour ?? 18) * 60 + (c.minute ?? 0)
        }
    }

    private func scheduleNudge() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily-nudge"])
        guard nudgeOn else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { nudgeOn = false; return }
        let content = UNMutableNotificationContent()
        content.title = "One tiny step?"
        content.body = "Pick one thing and give it a home. Two minutes is plenty."
        content.sound = .default
        var when = DateComponents()
        when.hour = nudgeMinutes / 60
        when.minute = nudgeMinutes % 60
        let request = UNNotificationRequest(identifier: "daily-nudge", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
        try? await center.add(request)
    }
}

enum InventoryExport {
    @MainActor
    static func csv(items: [Item]) -> URL? {
        guard let text = csvText(items: items) else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TidyAtlas-inventory-\(df.string(from: Date())).csv")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    @MainActor
    static func csvText(items: [Item]) -> String? {
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["place,room,spot,should_live_in,name,quantity,category,tags,size,status,plan,notes"]
        for it in items.sorted(by: { ($0.room?.name ?? "") < ($1.room?.name ?? "") }) {
            let room = it.room
            rows.append([
                room?.place?.name ?? "", room?.name ?? "", room?.zone(it.zoneID)?.name ?? "",
                room?.zone(it.suggestedZoneID)?.name ?? "", it.name, String(it.quantity), it.category,
                it.tags.joined(separator: "; "), it.sizeText ?? "", it.isSorted ? "put away" : "to sort", it.action.label, it.notes,
            ].map(cell).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}
