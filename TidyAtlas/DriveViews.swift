import SwiftUI

// Google Drive screens, adapted from the Crystal Bowl Scanner's DriveSettingsSection and DriveSetupSheet.

struct DriveSettingsSection: View {
    @EnvironmentObject private var organizer: Organizer
    @AppStorage(Organizer.uploadPhotosKey) private var uploadPhotos = true
    @State private var showSetup = false

    var body: some View {
        Section {
            if organizer.folderLinked {
                LabeledContent("Drive folder", value: organizer.folderName ?? "chosen folder")
                Button("Choose a different folder") { showSetup = true }
                Button("Stop copying to this folder", role: .destructive) { organizer.unlinkFolder() }
            } else if organizer.driveSignedIn {
                LabeledContent("Signed in as", value: organizer.driveEmail ?? "Google account")
                Button("Sign out of Google Drive", role: .destructive) { organizer.signOutOfDrive() }
            } else {
                Button { showSetup = true } label: {
                    Label("Connect Google Drive", systemImage: "icloud.and.arrow.up.fill").font(.headline)
                }
            }
            if organizer.folderLinked || organizer.driveSignedIn {
                Toggle("Also upload photos (Wi-Fi only)", isOn: $uploadPhotos)
                Button {
                    Task { await organizer.syncDrive() }
                } label: {
                    if organizer.isSyncing { ProgressView() } else { Label("Back up now", systemImage: "arrow.triangle.2.circlepath.icloud") }
                }
                .disabled(organizer.isSyncing)
                if let status = organizer.driveStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                } else if let when = organizer.lastDriveSync {
                    Label("Backed up \(when.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Google Drive backup")
        } footer: {
            Text("Everything uploads by itself after each scan or change, and in the background too (other apps open, phone locked): My Drive › \(TidyPackage.rootFolder) with inventory.json and inventory.csv (the whole database) and one folder per room with its floor plan, LiDAR room scan, thing pictures and room.json.")
        }
        .sheet(isPresented: $showSetup) { DriveSetupSheet() }
    }
}

/// Connecting Google Drive: the Google Drive app's folder (no sign-in here), or direct sign-in.
struct DriveSetupSheet: View {
    @EnvironmentObject private var organizer: Organizer
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GoogleAuth.clientIDKey) private var pastedClientID = ""
    @State private var picking = false
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Install the Google Drive app from the App Store and sign in to it (once).")
                    step(2, "Tap Choose folder. Tap Browse › Google Drive › My Drive. Create a folder named \(TidyPackage.rootFolder) (or pick it) and tap Open.")
                    step(3, "Done. Everything is copied there by itself, and the Google Drive app uploads it, even after you close Tidy Atlas.")
                    Button { picking = true } label: {
                        Label(organizer.folderLinked ? "Choose a different folder" : "Choose folder", systemImage: "folder.badge.plus")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    if organizer.folderLinked {
                        Label("Connected: \(organizer.folderName ?? "folder")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } header: {
                    Text("Recommended: through the Google Drive app")
                } footer: {
                    Text("No Google sign-in or setup inside Tidy Atlas.")
                }
                Section {
                    if organizer.driveSignedIn {
                        LabeledContent("Signed in as", value: organizer.driveEmail ?? "Google account")
                    } else if GoogleAuth.shared.clientID != nil {
                        Button {
                            signingIn = true
                            Task { await organizer.signInToDrive(); signingIn = false }
                        } label: {
                            if signingIn { ProgressView() } else { Label("Sign in with Google", systemImage: "person.badge.key") }
                        }
                    }
                    TextField("Google iOS client ID (optional)", text: $pastedClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                } header: {
                    Text("Alternative: direct upload")
                } footer: {
                    Text("Direct upload uses the Google sign-in set up for Crystal Bowl. If Google refuses it, paste an iOS client ID made for com.avradip.tidyatlas, or use the folder above.")
                }
            }
            .navigationTitle("Connect Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { organizer.linkFolder(url) }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        Label { Text(text) } icon: {
            Image(systemName: "\(n).circle.fill").foregroundStyle(Palette.teal).font(.title3)
        }
    }
}

/// Small status pill for the home screen.
struct DriveChip: View {
    @EnvironmentObject private var organizer: Organizer
    @State private var showSetup = false

    var body: some View {
        Button {
            if !(organizer.driveSignedIn || organizer.folderLinked) { showSetup = true }
            else { Task { await organizer.syncDrive() } }
        } label: {
            Group {
                if !(organizer.driveSignedIn || organizer.folderLinked) {
                    Label("Connect Google Drive", systemImage: "icloud.slash")
                } else if organizer.isSyncing || organizer.driveStatus != nil {
                    Label("Backing up…", systemImage: "arrow.triangle.2.circlepath.icloud")
                } else {
                    Label("On Drive", systemImage: "checkmark.icloud.fill").foregroundStyle(.green)
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSetup) { DriveSetupSheet() }
    }
}
