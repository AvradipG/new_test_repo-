import PaperCore
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @State private var problem = ""
    @State private var copiedReport = false

    var body: some View {
        Form {
            Section {
                Stepper(value: Binding(get: { store.dailyGoal }, set: { store.dailyGoal = $0 }), in: 1...30) {
                    LabeledContent("Daily goal", value: "\(store.dailyGoal) ticks")
                }
            } header: {
                Text("Quest")
            } footer: {
                Text("Every finished item is +\(Points.leaf) XP; a whole subsection +\(Points.bonus(depth: 1)), a section +\(Points.bonus(depth: 0)). Tick at least one item a day to keep the streak.")
            }

            AISettingsSection()

            StudioSettingsSection()

            DriveSettingsSection()

            Section {
                Text("Through the Drive connector, Claude reads Paper Quest › <paper> › progress.md to see where you are, plan the next steps and write handoffs. When the app is linked to that folder through the Google Drive app, Claude can also tick, add or annotate items by dropping a file into claude-inbox; the app applies it at the next sync and shows what changed.")
                    .font(.footnote)
            } header: {
                Text("Claude")
            }

            Section {
                TextField("What went wrong? (optional)", text: $problem, axis: .vertical)
                Button {
                    UIPasteboard.general.string = AppInfo.problemReport(store, description: problem)
                    copiedReport = true
                } label: {
                    Label(copiedReport ? "Copied. Paste it into the Claude chat." : "Copy a problem report", systemImage: copiedReport ? "checkmark" : "ladybug")
                }
            } header: {
                Text("Something wrong?")
            }

            Section("About") {
                LabeledContent("Version", value: AppInfo.label)
                LabeledContent("Commit", value: AppInfo.commit)
                LabeledContent("Installed via", value: InstallSource.current.rawValue)
                if let update = store.updateAvailable {
                    Text("Update ready: \(update.version) (\(update.build))").foregroundStyle(Palette.accent)
                }
            }
        }
        .navigationTitle("Settings")
    }
}

struct DriveSettingsSection: View {
    @EnvironmentObject private var store: Store
    @State private var showSetup = false

    var body: some View {
        Section {
            if store.folderLinked {
                LabeledContent("Drive folder", value: store.folderName ?? "chosen folder")
                Button("Choose a different folder") { showSetup = true }
                Button("Stop syncing with this folder", role: .destructive) { store.unlinkFolder() }
            } else if store.driveSignedIn {
                LabeledContent("Signed in as", value: store.driveEmail ?? "Google account")
                Button("Sign out of Google Drive", role: .destructive) { store.signOutOfDrive() }
            } else {
                Button { showSetup = true } label: {
                    Label("Connect Google Drive", systemImage: "icloud.and.arrow.up.fill").font(.headline)
                }
            }
            if store.driveConnected {
                Button {
                    Task { await store.syncDrive() }
                } label: {
                    if store.isSyncing { ProgressView() } else { Label("Sync now", systemImage: "arrow.triangle.2.circlepath.icloud") }
                }
                .disabled(store.isSyncing)
                if let status = store.driveStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                } else if let when = store.lastDriveSync {
                    Label("Synced \(when.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(Palette.done)
                }
            }
        } header: {
            Text("Google Drive")
        } footer: {
            Text("After every change and when the app opens or closes: My Drive › \(Store.rootFolderName) › one folder per paper with progress.json and progress.md. Changes made on another device are merged in.")
        }
        .sheet(isPresented: $showSetup) { DriveSetupSheet() }
    }
}

/// Connecting Google Drive: the Google Drive app's folder (no sign-in here; Claude's inbox works), or direct sign-in.
struct DriveSetupSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GoogleAuth.clientIDKey) private var pastedClientID = ""
    @State private var picking = false
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Install the Google Drive app and sign in to it (once).")
                    step(2, "Tap Choose folder › Browse › Google Drive › My Drive. Create a folder named \(Store.rootFolderName) (or pick it) and tap Open.")
                    step(3, "Done. Progress is written there after every change, Claude's inbox files are picked up, and the Google Drive app uploads it.")
                    Button { picking = true } label: {
                        Label(store.folderLinked ? "Choose a different folder" : "Choose folder", systemImage: "folder.badge.plus")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    if store.folderLinked {
                        Label("Connected: \(store.folderName ?? "folder")", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.done)
                    }
                } header: {
                    Text("Recommended: through the Google Drive app")
                } footer: {
                    Text("No Google sign-in inside Paper Quest, and Claude can send changes back through the claude-inbox folder.")
                }
                Section {
                    if store.driveSignedIn {
                        LabeledContent("Signed in as", value: store.driveEmail ?? "Google account")
                    } else if GoogleAuth.shared.clientID != nil {
                        Button {
                            signingIn = true
                            Task {
                                await store.signInToDrive()
                                signingIn = false
                                if store.driveSignedIn && store.driveStatus == nil { dismiss() }
                            }
                        } label: {
                            if signingIn { ProgressView() } else { Label("Sign in with Google", systemImage: "person.badge.key") }
                        }
                    }
                    TextField("Google iOS client ID (optional)", text: $pastedClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    if let status = store.driveStatus {
                        Label(status, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    } else if store.isSyncing {
                        HStack { ProgressView(); Text("Syncing with Drive…").font(.footnote) }
                    } else if let when = store.lastDriveSync, store.driveConnected {
                        Label("Synced \(when.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud.fill")
                            .font(.footnote).foregroundStyle(Palette.done)
                    }
                } header: {
                    Text("Alternative: direct sync")
                } footer: {
                    Text("Uses the Google sign-in set up for Crystal Bowl. Syncs your devices and lets Claude read progress.md, but Google only lets the app see its own files, so Claude's inbox needs the folder route above.")
                }
            }
            .navigationTitle("Connect Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { store.linkFolder(url) }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        Label { Text(text) } icon: {
            Image(systemName: "\(n).circle.fill").foregroundStyle(Palette.accent).font(.title3)
        }
    }
}

/// Small status pill for the home screen.
struct DriveChip: View {
    @EnvironmentObject private var store: Store
    @State private var showSetup = false

    var body: some View {
        Button {
            if !store.driveConnected { showSetup = true } else { Task { await store.syncDrive() } }
        } label: {
            Group {
                if !store.driveConnected {
                    Label("Connect Drive", systemImage: "icloud.slash")
                } else if store.isSyncing {
                    Label("Syncing…", systemImage: "arrow.triangle.2.circlepath.icloud")
                } else if store.driveStatus != nil {
                    Label("Sync paused", systemImage: "exclamationmark.icloud").foregroundStyle(Palette.flame)
                } else {
                    Label("On Drive", systemImage: "checkmark.icloud.fill").foregroundStyle(Palette.done)
                }
            }
            .font(.footnote.weight(.semibold))
        }
        .sheet(isPresented: $showSetup) { DriveSetupSheet() }
    }
}

/// Claude and ChatGPT: keys (Keychain), which one answers, and the ChatGPT model.
struct AISettingsSection: View {
    @AppStorage(AIService.providerKey) private var provider = AIProvider.claude.rawValue
    @AppStorage(AIService.backupKey) private var backup = true
    @AppStorage(AIService.openAIModelKey) private var openAIModel = ""
    @State private var claudeKey = ""
    @State private var chatKey = ""
    @State private var hasClaude = KeyStore.hasKey(.claude)
    @State private var hasChat = KeyStore.hasKey(.chatgpt)
    @State private var testing: AIProvider?
    @State private var result: String?

    var body: some View {
        Section {
            Picker("Answers first", selection: $provider) {
                Text("Claude").tag(AIProvider.claude.rawValue)
                Text("ChatGPT").tag(AIProvider.chatgpt.rawValue)
            }
            Toggle("Other one as backup", isOn: $backup)
            keyRow(.claude, text: $claudeKey, has: $hasClaude, placeholder: "sk-ant-…")
            keyRow(.chatgpt, text: $chatKey, has: $hasChat, placeholder: "sk-…")
            TextField("ChatGPT model (blank = Astra if your account has it)", text: $openAIModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            if openAIModel.isEmpty, let auto = AIService.autoPickedModel {
                LabeledContent("ChatGPT model in use", value: auto).font(.footnote)
            }
            if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Claude and ChatGPT")
        } footer: {
            Text("Claude: Opus 5.5, effort High. ChatGPT: Astra (or the model typed above), reasoning High. Keys stay in this iPhone's Keychain (and iCloud Keychain), are kept through every update and are only sent to Anthropic or OpenAI when you ask something.")
        }
    }

    private func keyRow(_ p: AIProvider, text: Binding<String>, has: Binding<Bool>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(p.label) key").font(.subheadline.weight(.semibold))
                Spacer()
                if has.wrappedValue {
                    Label("Saved", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Palette.done)
                }
            }
            HStack {
                SecureField(has.wrappedValue ? "Replace the saved key" : placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") {
                    KeyStore.save(text.wrappedValue, for: p)
                    text.wrappedValue = ""
                    has.wrappedValue = KeyStore.hasKey(p)
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if has.wrappedValue {
                HStack {
                    Button {
                        testing = p
                        result = nil
                        Task {
                            do { result = "\(p.label): " + (try await AIService.test(p)) }
                            catch { result = "\(p.label): \(error.localizedDescription)" }
                            testing = nil
                        }
                    } label: {
                        if testing == p { ProgressView() } else { Text("Test") }
                    }
                    .disabled(testing != nil)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        KeyStore.save("", for: p)
                        has.wrappedValue = false
                    }
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }
        }
    }
}

struct StudioSettingsSection: View {
    @ObservedObject private var session = StudioSession.shared

    var body: some View {
        Section {
            if session.signedIn {
                LabeledContent("Signed in as", value: session.email ?? "Google account")
                Button("Sign out of Manuscript Studio", role: .destructive) { session.signOut() }
            } else {
                Button {
                    Task { await session.signIn() }
                } label: {
                    if session.busy { ProgressView() } else { Label("Sign in with Google", systemImage: "person.badge.key") }
                }
            }
            if let s = session.status { Text(s).font(.footnote).foregroundStyle(.secondary) }
            if session.needsSafelist { SafelistHelp() }
        } header: {
            Text("Manuscript Studio")
        } footer: {
            Text("The same Google account as the web app at manuscript-studio-181489801873.web.app. Edits from Claude or ChatGPT are saved as new revisions there, with full history.")
        }
    }
}
