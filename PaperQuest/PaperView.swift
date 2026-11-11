import PaperCore
import SwiftUI
import UIKit

/// One paper as a tree: sections → subsections → components, each with its mark, and a progress bar on every parent.
struct PaperView: View {
    let paperID: String
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []
    @State private var loadedExpansion = false
    @AppStorage("tree.hideDone") private var hideDone = false
    @State private var detail: Node?
    @State private var parentMenu: Node?
    @State private var addUnder: AddTarget?
    @State private var renaming: Node?
    @State private var text = ""
    @State private var manuscript: URL?
    @State private var showPaperInfo = false
    @State private var confirmRemove = false
    @State private var showReader = false

    struct AddTarget: Identifiable {
        let parent: Node?
        var id: String { parent?.id ?? "top" }
    }

    var body: some View {
        if let paper = store.paper(paperID) {
            content(paper, Tree(paper))
        } else {
            ContentUnavailableView("Paper removed", systemImage: "doc.questionmark")
        }
    }

    // Split into small pieces: one big expression is too much for the Swift type checker.
    private func content(_ paper: Paper, _ tree: Tree) -> some View {
        let base = ScrollViewReader { proxy in list(paper, tree, proxy) }
            .navigationTitle(paper.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { toolbarMenu(paper, tree) } }
            .onAppear { loadExpansion(tree) }
            .onChange(of: expanded) { _, value in
                UserDefaults.standard.set(Array(value), forKey: "tree.expanded.\(paperID)")
            }
        return withAlerts(withDialog(withSheets(base, paper), tree), paper)
    }

    private func list(_ paper: Paper, _ tree: Tree, _ proxy: ScrollViewProxy) -> some View {
        let rows = tree.rows(expanded: expanded, hideDone: hideDone)
        return List {
            Section {
                PaperHeader(paper: paper, tree: tree) { node in
                    reveal(node, tree)
                    withAnimation { proxy.scrollTo(node.id, anchor: .center) }
                } openManuscript: {
                    openManuscript(paper)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(rows) { row in rowView(row, tree) }
            } header: {
                checklistHeader
            }
            Section {
                Button { addUnder = AddTarget(parent: nil); text = "" } label: {
                    Label("Add a section", systemImage: "plus")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var checklistHeader: some View {
        HStack {
            Text("Checklist")
            Spacer()
            Button(hideDone ? "Show done" : "Hide done") { withAnimation { hideDone.toggle() } }
                .font(.caption.weight(.semibold))
                .textCase(nil)
        }
    }

    private func rowView(_ row: Row, _ tree: Tree) -> some View {
        NodeRow(row: row, tree: tree, isExpanded: expanded.contains(row.id), onMark: {
            markTapped(row, tree)
        }, onTap: {
            if row.hasChildren { toggle(row.id) } else { detail = row.node }
        })
        .id(row.id)
        .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe(row, tree) }
        .swipeActions(edge: .trailing) { trailingSwipe(row) }
        .contextMenu { menu(for: row, tree) }
    }

    @ViewBuilder
    private func leadingSwipe(_ row: Row, _ tree: Tree) -> some View {
        if tree.mark(row.id) == .done {
            Button { store.setStatus(paperID, row.id, .todo) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .tint(.gray)
        } else {
            Button { store.setStatus(paperID, row.id, .done) } label: { Label("Done", systemImage: "checkmark") }
                .tint(Palette.done)
        }
    }

    @ViewBuilder
    private func trailingSwipe(_ row: Row) -> some View {
        Button(role: .destructive) { store.delete(paperID, row.id) } label: { Label("Delete", systemImage: "trash") }
        if !row.hasChildren && row.node.status != .inProgress {
            Button { store.setStatus(paperID, row.id, .inProgress) } label: { Label("Start", systemImage: "play.fill") }
                .tint(Palette.accent)
        }
    }

    private func toolbarMenu(_ paper: Paper, _ tree: Tree) -> some View {
        Menu {
            Button { expandAll(tree) } label: { Label("Expand all", systemImage: "chevron.down.2") }
            Button { expanded = [] } label: { Label("Collapse all", systemImage: "chevron.up.2") }
            if paper.manuscriptURL != nil {
                Button { openManuscript(paper) } label: { Label("Open manuscript", systemImage: "doc.richtext") }
            }
            if StudioSession.shared.signedIn && (paper.manuscriptURL?.contains("manuscript-studio-181489801873") ?? false) {
                Button { showReader = true } label: { Label("Read the paper", systemImage: "book") }
            }
            Button { showPaperInfo = true } label: { Label("Title and link", systemImage: "pencil") }
            Button(role: .destructive) { confirmRemove = true } label: { Label("Remove from this iPhone", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// In the Manuscript tab when signed in to Manuscript Studio (and the paper lives there), else in Safari.
    private func openManuscript(_ paper: Paper) {
        let inStudio = paper.manuscriptURL?.contains("manuscript-studio-181489801873") ?? false
        if inStudio && store.openManuscript(paper.id) { return }
        manuscript = paper.manuscriptURL.flatMap { URL(string: $0) }
    }

    private func expandAll(_ tree: Tree) {
        let parents = tree.ordered().filter { tree.hasChildren($0.id) }.map { $0.id }
        expanded = Set(parents)
    }

    private func withSheets<V: View>(_ view: V, _ paper: Paper) -> some View {
        view
            .sheet(item: $detail) { node in NodeSheet(paperID: paperID, nodeID: node.id) }
            .sheet(item: $manuscript) { url in SafariView(url: url).ignoresSafeArea() }
            .sheet(isPresented: $showPaperInfo) { PaperInfoSheet(paper: paper) }
            .sheet(isPresented: $showReader) {
                NavigationStack {
                    ReaderView(paperID: paper.id, title: paper.title)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showReader = false } } }
                }
            }
    }

    private var parentMenuShown: Binding<Bool> {
        Binding(get: { parentMenu != nil }, set: { if !$0 { parentMenu = nil } })
    }

    private var addShown: Binding<Bool> {
        Binding(get: { addUnder != nil }, set: { if !$0 { addUnder = nil } })
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func withDialog<V: View>(_ view: V, _ tree: Tree) -> some View {
        let title: String = parentMenu?.title ?? ""
        return view.confirmationDialog(title, isPresented: parentMenuShown, titleVisibility: .visible,
                                       presenting: parentMenu) { (node: Node) in
            parentActions(node, tree)
        } message: { (node: Node) in
            Text(countText(node, tree))
        }
    }

    private func countText(_ node: Node, _ tree: Tree) -> String {
        let k = tree.counts(node.id)
        return "\(k.done) of \(k.total) done"
    }

    @ViewBuilder
    private func parentActions(_ node: Node, _ tree: Tree) -> some View {
        let k = tree.counts(node.id)
        if k.done < k.total {
            Button("Mark all \(k.total) done") { store.setStatus(paperID, node.id, .done) }
            Button("Start the next item") { store.setStatus(paperID, node.id, .inProgress) }
        }
        if k.done > 0 || tree.mark(node.id) != .todo {
            Button("Reset all to do", role: .destructive) { store.setStatus(paperID, node.id, .todo) }
        }
    }

    private var addTitle: String {
        if let parent = addUnder?.parent { return "Add to \(parent.title)" }
        return "New section"
    }

    private func commitAdd() {
        let parent = addUnder?.parent?.id
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            store.add(paperID, title: text, under: parent)
            if let parent { expanded.insert(parent) }
        }
        addUnder = nil
    }

    private func commitRename() {
        if let n = renaming { store.rename(paperID, n.id, to: text) }
        renaming = nil
    }

    private func withAlerts<V: View>(_ view: V, _ paper: Paper) -> some View {
        view
            .alert(addTitle, isPresented: addShown) {
                TextField("Title", text: $text)
                Button("Add") { commitAdd() }
                Button("Cancel", role: .cancel) { addUnder = nil }
            }
            .alert("Rename", isPresented: renameShown) {
                TextField("Title", text: $text)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("Remove \(paper.title) from this iPhone?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) {
                    store.removePaper(paperID)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its copy in Google Drive stays, so nothing is lost. Delete that folder in Drive if you want it gone everywhere.")
            }
    }

    @ViewBuilder
    private func menu(for row: Row, _ tree: Tree) -> some View {
        Button { addUnder = AddTarget(parent: row.node); text = "" } label: {
            Label(row.hasChildren ? "Add an item" : "Split into steps", systemImage: "plus")
        }
        Button { renaming = row.node; text = row.node.title } label: { Label("Rename", systemImage: "pencil") }
        if !row.hasChildren {
            Button { detail = row.node } label: { Label("Details and note", systemImage: "note.text") }
        }
        Button { store.move(paperID, row.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
        Button { store.move(paperID, row.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
        if row.hasChildren {
            Button { store.setStatus(paperID, row.id, .done) } label: { Label("Mark all done", systemImage: "checkmark.circle") }
        }
        Button(role: .destructive) { store.delete(paperID, row.id) } label: { Label("Delete", systemImage: "trash") }
    }

    private func markTapped(_ row: Row, _ tree: Tree) {
        if row.hasChildren {
            parentMenu = row.node
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { store.cycle(paperID, row.id) }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func reveal(_ node: Node, _ tree: Tree) {
        for p in tree.path(node.id) { expanded.insert(p.id) }
    }

    private func loadExpansion(_ tree: Tree) {
        guard !loadedExpansion else { return }
        loadedExpansion = true
        if let saved = UserDefaults.standard.stringArray(forKey: "tree.expanded.\(paperID)") {
            expanded = Set(saved)
        } else if let next = tree.nextUp() {
            reveal(next, tree)
        }
    }
}

/// Title, overall bar, XP and the next quest.
struct PaperHeader: View {
    let paper: Paper
    let tree: Tree
    let show: (Node) -> Void
    let openManuscript: () -> Void
    @EnvironmentObject private var store: Store

    var body: some View {
        let c = tree.counts(nil)
        let xp = Points.xp(tree)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if !paper.subtitle.isEmpty {
                    Text(paper.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int((tree.fraction(nil) * 100).rounded()))%").font(.display(.largeTitle)).monospacedDigit()
                    Text("\(c.done) of \(c.total) items").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Label("\(xp) XP", systemImage: "star.fill").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.gold).monospacedDigit()
                }
                Bar(fraction: tree.fraction(nil), height: 10)
                if paper.manuscriptURL != nil {
                    Button(action: openManuscript) {
                        Label("Open the manuscript", systemImage: "doc.richtext")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }
            .card()

            if let next = tree.nextUp() {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Next up", systemImage: "flag.checkered").font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
                    HStack(alignment: .top, spacing: 12) {
                        StatusMark(status: next.status, size: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(next.title).font(.headline)
                            Text(tree.path(next.id).map(\.title).joined(separator: " › "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    HStack {
                        if next.status == .todo {
                            Button { store.setStatus(paper.id, next.id, .inProgress) } label: { Label("Start", systemImage: "play.fill") }
                                .buttonStyle(.bordered)
                        }
                        Button { store.setStatus(paper.id, next.id, .done) } label: { Label("Done", systemImage: "checkmark") }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.done)
                        Spacer()
                        Button("Show") { show(next) }.buttonStyle(.borderless)
                    }
                }
                .card()
            } else if c.total > 0 {
                Label("Everything is done. Submit it!", systemImage: "party.popper.fill")
                    .font(.headline).foregroundStyle(Palette.done)
                    .card()
            }
        }
        .padding(.vertical, 4)
    }
}

struct NodeRow: View {
    let row: Row
    let tree: Tree
    let isExpanded: Bool
    let onMark: () -> Void
    let onTap: () -> Void

    var body: some View {
        let mark = tree.mark(row.id)
        let top = row.depth == 0
        HStack(spacing: 10) {
            if row.depth > 0 {
                Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            }
            Button(action: onMark) {
                StatusMark(status: mark, fraction: row.hasChildren ? tree.fraction(row.id) : nil, size: top ? 26 : 22)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Button(action: onTap) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.node.title)
                            .font(top ? .headline : row.hasChildren ? .subheadline.weight(.semibold) : .body)
                            .foregroundStyle(mark == .done && !row.hasChildren ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        if row.hasChildren {
                            let k = tree.counts(row.id)
                            HStack(spacing: 8) {
                                Bar(fraction: tree.fraction(row.id), height: 4)
                                Text("\(k.done)/\(k.total)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        } else if !row.node.note.isEmpty {
                            Text(row.node.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if row.hasChildren {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
        }
        .padding(.vertical, top ? 4 : 0)
    }
}

struct PaperInfoSheet: View {
    let paper: Paper
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") { TextField("Title", text: $title) }
                Section {
                    TextField("https://…", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Manuscript link")
                } footer: {
                    Text("Opened by \"Open the manuscript\". Green–Christoffel opens in Manuscript Studio (Firebase).")
                }
            }
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.renamePaper(paper.id, title: title, url: url)
                        dismiss()
                    }
                }
            }
            .onAppear {
                title = paper.title
                url = paper.manuscriptURL ?? ""
            }
        }
        .presentationDetents([.medium])
    }
}
