import SwiftUI

/// What goes on the sample sheets and into the separate pictures (3.8). Every item can be ticked on or off; the
/// choice applies to every scan and is used the next time sheets are made.
enum SheetItem: String, CaseIterable, Identifiable {
    case side0, side90, side180, sideMinus90, top, bottom, unrolled, measurements
    case rulers, scaleBars, sizeLines, markArrows, dials, protractor, angleCaptions, header
    case figures, plainViews

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case pictures = "Pictures"
        case drawn = "Drawn on the pictures"
        case files = "Files"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .side0, .side90, .side180, .sideMinus90, .top, .bottom, .unrolled, .measurements: return .pictures
        case .rulers, .scaleBars, .sizeLines, .markArrows, .dials, .protractor, .angleCaptions, .header: return .drawn
        case .figures, .plainViews: return .files
        }
    }

    var title: String {
        switch self {
        case .side0: return "Side 0° (the mark facing you)"
        case .side90: return "Side +90°"
        case .side180: return "Side 180°"
        case .sideMinus90: return "Side −90°"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .unrolled: return "Unrolled side (360°)"
        case .measurements: return "Measurements box"
        case .rulers: return "Graph paper and axes"
        case .scaleBars: return "Scale bars (clean sheet)"
        case .sizeLines: return "Height, width and diameter read-outs"
        case .markArrows: return "Reference mark arrows (▽)"
        case .dials: return "View dials"
        case .protractor: return "Protractor round the top"
        case .angleCaptions: return "Titles and angles"
        case .header: return "Sample name and date"
        case .figures: return "Each picture as its own PNG, with its graph and read-outs"
        case .plainViews: return "Plain views without drawings"
        }
    }

    var note: String? {
        switch self {
        case .bottom: return "Only when the rock was flipped and its underside scanned."
        case .rulers: return "Each side view sits on graph paper whose origin is the rock's lower-left corner."
        case .figures: return "One file per view: what is ticked above is drawn on it."
        case .plainViews: return "The bare 3D views, for your own layouts."
        default: return nil
        }
    }

    static func side(_ offset: Double) -> SheetItem {
        switch Int(offset.rounded()) {
        case 0: return .side0
        case 90: return .side90
        case -90, 270: return .sideMinus90
        default: return .side180
        }
    }
}

struct SheetOptions: Equatable {
    var off: Set<SheetItem> = []

    func has(_ i: SheetItem) -> Bool { !off.contains(i) }

    static let key = "sheet.off"

    static var current: SheetOptions {
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return SheetOptions(off: Set(raw.compactMap(SheetItem.init(rawValue:))))
    }

    func save() { UserDefaults.standard.set(off.map(\.rawValue).sorted(), forKey: Self.key) }

    /// One line for the app log.
    var summary: String {
        off.isEmpty ? "everything" : "all but " + SheetItem.allCases.filter { off.contains($0) }.map(\.title).joined(separator: ", ")
    }
}

/// Tick boxes for the sheet contents, and buttons to make the sheets again with them.
struct SheetOptionsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let scan: Scan?
    @State private var options = SheetOptions.current
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(SheetItem.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(SheetItem.allCases.filter { $0.group == group }) { item in
                            Button {
                                if options.off.contains(item) { options.off.remove(item) } else { options.off.insert(item) }
                                options.save()
                                note = nil
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Image(systemName: options.has(item) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(options.has(item) ? Color.accentColor : .secondary)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).foregroundStyle(.primary)
                                        if let n = item.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .accessibilityAddTraits(options.has(item) ? .isSelected : [])
                        }
                    }
                }
                Section {
                    if let scan {
                        Button { remake([scan]) } label: { Label("Make this scan's sheets again", systemImage: "arrow.clockwise") }
                    }
                    Button { remake(model.scans.filter { !$0.isPieces && $0.hasModel }) } label: {
                        Label("Make the sheets again for every scan", systemImage: "square.stack.3d.up")
                    }
                    if let note { Text(note).font(.footnote).foregroundStyle(.green) }
                } footer: {
                    Text("The reference mark is looked for again at the same time (marks set by hand are kept). It runs by itself while the app is open.")
                }
            }
            .navigationTitle("What to include")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func remake(_ scans: [Scan]) {
        model.remakeSheets(scans.map(\.id))
        note = scans.count == 1 ? "Making the sheets again…" : "Making the sheets again for \(scans.count) scans…"
    }
}

/// Settings: the tick boxes for every scan's sample sheets.
struct SheetOptionsSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var show = false

    var body: some View {
        Section {
            Button { show = true } label: { Label("Sample sheets: what to include…", systemImage: "checklist") }
        } footer: {
            Text("Tick the views, rulers, scale bars, mark arrows and files the sample sheets should have. Each view is also saved as its own PNG with its ruler and scale.")
        }
        .sheet(isPresented: $show) { SheetOptionsView(scan: nil).environmentObject(model) }
    }
}
