import PaperCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: Store
    @State private var showNew = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let update = store.updateAvailable { UpdateBanner(remote: update) }
                QuestHeader()
                if let report = store.inboxReport {
                    InboxNotice(text: report) { store.inboxReport = nil }
                }
                ForEach(store.papers) { paper in
                    NavigationLink(value: paper.id) { PaperCard(paper: paper) }
                        .buttonStyle(.plain)
                }
                Button { showNew = true } label: {
                    Label("New paper", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                if store.paper(Templates.greenChristoffelID) == nil {
                    Button("Bring back Green–Christoffel") { store.restoreGreenChristoffel() }
                        .font(.footnote)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Paper Quest")
        .navigationDestination(for: String.self) { id in PaperView(paperID: id) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { DriveChip() } }
        .refreshable { await store.syncDrive() }
        .sheet(isPresented: $showNew) { NewPaperSheet() }
    }
}

/// Level, XP to the next level, streak and today's ring.
struct QuestHeader: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let xp = store.totalXP
        let level = Level.of(xp: xp)
        let goal = store.dailyGoal
        let today = store.today
        HStack(spacing: 16) {
            ZStack {
                Ring(fraction: Double(today) / Double(goal), lineWidth: 8,
                     color: today >= goal ? Palette.done : Palette.accent)
                VStack(spacing: 0) {
                    Text("\(today)/\(goal)").font(.display(.headline)).monospacedDigit()
                    Text("today").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Level \(level.number)").font(.display(.title3))
                    Text(level.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.gold)
                }
                Bar(fraction: level.fraction(xp: xp), height: 8, color: Palette.gold)
                HStack {
                    Text("\(xp) XP · \(level.next - xp) to level \(level.number + 1)")
                    Spacer()
                    Label("\(store.streak)", systemImage: "flame.fill")
                        .foregroundStyle(store.streak > 0 ? Palette.flame : Color.secondary)
                        .accessibilityLabel("\(store.streak)-day streak")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .card()
    }
}

struct PaperCard: View {
    let paper: Paper

    var body: some View {
        let tree = Tree(paper)
        let c = tree.counts(nil)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(paper.title).font(.display(.headline)).foregroundStyle(.primary)
                    if !paper.subtitle.isEmpty {
                        Text(paper.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                ZStack {
                    Ring(fraction: tree.fraction(nil), lineWidth: 5)
                    Text("\(Int((tree.fraction(nil) * 100).rounded()))%").font(.caption2.weight(.bold)).monospacedDigit()
                }
                .frame(width: 46, height: 46)
            }
            HStack(spacing: 6) {
                ForEach(tree.children(of: nil)) { s in
                    Capsule()
                        .fill(tree.mark(s.id) == .done ? Palette.done
                              : tree.mark(s.id) == .inProgress ? Palette.accent.opacity(0.35 + 0.65 * tree.fraction(s.id))
                              : Palette.track)
                        .frame(height: 6)
                }
            }
            HStack {
                Text("\(c.done) of \(c.total) done").monospacedDigit()
                Spacer()
                if let next = tree.nextUp() {
                    Text("Next: \(next.title)").lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .card()
    }
}

struct InboxNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Changes from Claude applied", systemImage: "tray.and.arrow.down.fill").font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .card()
    }
}

struct NewPaperSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Link to the manuscript (optional)", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Starts with Abstract, Introduction, Methods, Results, Discussion, Conclusions, Figures and tables, References and Submission. Rename, add or delete anything.")
                }
            }
            .navigationTitle("New paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        store.newPaper(title: title, url: url)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
