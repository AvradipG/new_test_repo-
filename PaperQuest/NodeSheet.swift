import PaperCore
import SwiftUI
import UIKit

/// One item: its mark, where it sits, what it's about in the manuscript, and a note.
struct NodeSheet: View {
    let paperID: String
    let nodeID: String
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var loaded = false
    @State private var copied = false
    @State private var manuscript: URL?

    var body: some View {
        NavigationStack {
            if let paper = store.paper(paperID), let node = Tree(paper).byID[nodeID] {
                form(paper, Tree(paper), node)
            } else {
                ContentUnavailableView("Item removed", systemImage: "questionmark.circle")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func form(_ paper: Paper, _ tree: Tree, _ node: Node) -> some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                    .font(.headline)
                let path = tree.path(node.id).map(\.title).joined(separator: " › ")
                if !path.isEmpty { Text(path).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Status") {
                HStack(spacing: 10) {
                    ForEach(Status.allCases, id: \.self) { s in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { store.setStatus(paperID, nodeID, s) }
                        } label: {
                            VStack(spacing: 6) {
                                StatusMark(status: s, size: 28)
                                Text(s.label).font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(tree.mark(node.id) == s ? Palette.accent.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                    }
                }
                if let done = node.completedAt, node.status == .done {
                    Text("Done \(done.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !node.detail.isEmpty || node.anchor != nil {
                Section("In the manuscript") {
                    if !node.detail.isEmpty { Text(node.detail).font(.callout) }
                    if let anchor = node.anchor {
                        LabeledContent("Label") { Text(anchor).font(.footnote.monospaced()) }
                        Button {
                            UIPasteboard.general.string = LatexRef.of(anchor)
                            copied = true
                        } label: {
                            Label(copied ? "Copied \(LatexRef.of(anchor))" : "Copy LaTeX reference", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    if let link = paper.manuscriptURL, let url = URL(string: link) {
                        Button { manuscript = url } label: { Label("Open the manuscript", systemImage: "doc.richtext") }
                    }
                }
            }
            Section {
                TextEditor(text: $note).frame(minHeight: 110)
            } header: {
                Text("Note")
            } footer: {
                Text("What's left, what a reviewer said, where you stopped. Claude sees notes in progress.md on Drive.")
            }
            Section {
                Button(role: .destructive) {
                    store.delete(paperID, nodeID)
                    dismiss()
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .navigationTitle(node.status == .done ? "Done" : "Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    persist(node)
                    dismiss()
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            title = node.title
            note = node.note
        }
        .onDisappear { persist(node) }
        .sheet(item: $manuscript) { url in SafariView(url: url).ignoresSafeArea() }
    }

    private func persist(_ node: Node) {
        guard loaded, let current = store.paper(paperID).flatMap({ Tree($0).byID[nodeID] }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && t != current.title { store.rename(paperID, nodeID, to: t) }
        if note != current.note { store.setNote(paperID, nodeID, note) }
    }
}
