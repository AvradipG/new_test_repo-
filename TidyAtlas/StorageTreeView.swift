import SwiftData
import SwiftUI
import TidyCore

/// Storage as a tree: a desk holds drawers, a drawer holds trays. Things live at any level.
struct StorageTreeView: View {
    let room: Room
    var onEdit: (Zone) -> Void
    var onPhotoInside: (Zone) -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage spots").font(.display(.headline))
            if room.zones.isEmpty {
                Text("None yet. Scan a photo or the room, or add your shelves, drawers and bins.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(room.children(of: nil)) { z in StorageNodeRow(room: room, zone: z, depth: 0, onEdit: onEdit, onPhotoInside: onPhotoInside) }
            Button { onEdit(newSpot(inside: nil)) } label: { Label("Add storage spot", systemImage: "plus") }
                .buttonStyle(.bordered)
        }
        .card()
    }

    private func newSpot(inside parent: Zone?) -> Zone {
        let z = Zone(name: parent == nil ? "New spot" : "New drawer", kind: parent == nil ? .shelf : .drawer)
        z.parentID = parent?.uid
        if let parent {
            z.posX = parent.posX
            z.posY = parent.posY
            z.posZ = parent.posZ
            z.sizeW = parent.sizeW * 0.8
            z.sizeH = max(0.1, parent.sizeH / 3)
            z.sizeD = parent.sizeD
        } else {
            z.posZ = 0.1
        }
        z.room = room
        context.insert(z)
        return z
    }
}

struct StorageNodeRow: View {
    let room: Room
    let zone: Zone
    let depth: Int
    var onEdit: (Zone) -> Void
    var onPhotoInside: (Zone) -> Void
    @Environment(\.modelContext) private var context
    @State private var open = false

    var body: some View {
        let kids = room.children(of: zone)
        let things = room.items.filter { $0.zoneID == zone.uid }
        let incoming = room.toSort.filter { $0.suggestedZoneID == zone.uid }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { withAnimation { open.toggle() } } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption.weight(.bold)).frame(width: 18)
                }
                .buttonStyle(.plain)
                .opacity(kids.isEmpty && things.isEmpty ? 0.25 : 1)
                Button { onEdit(zone) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(zone.name).font(.body.weight(.semibold))
                        Text([zone.kind.label, zone.isIdea ? "idea" : nil, zone.kitchenZone.flatMap { Kitchen.ZoneType(rawValue: $0)?.label },
                              things.isEmpty ? nil : "\(things.count) thing\(things.count == 1 ? "" : "s")",
                              kids.isEmpty ? nil : "\(kids.count) inside"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if incoming > 0 {
                    Text("\(incoming) incoming").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.teal, in: Capsule()).foregroundStyle(.white)
                }
                Menu {
                    Button("Photo inside this spot", systemImage: "camera") { onPhotoInside(zone) }
                    Button("Add a spot inside (drawer, tray, box…)", systemImage: "plus.square.on.square") { addInside() }
                    Button("Edit", systemImage: "pencil") { onEdit(zone) }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            if open {
                ForEach(things) { it in
                    HStack(spacing: 8) {
                        ItemThumb(file: it.thumbFile, category: it.category, size: 30)
                        Text((it.quantity > 1 ? "\(it.quantity)× " : "") + it.name).font(.callout)
                        if let d = it.expiresAt { Text("use by \(d.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.orange) }
                    }
                    .padding(.leading, 26)
                }
                ForEach(kids) { k in
                    StorageNodeRow(room: room, zone: k, depth: depth + 1, onEdit: onEdit, onPhotoInside: onPhotoInside)
                        .padding(.leading, 18)
                }
            }
        }
        .padding(10)
        .background(depth % 2 == 0 ? Palette.paper : Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func addInside() {
        let z = Zone(name: zone.kind == .desk || zone.kind == .cabinet ? "Drawer \(room.children(of: zone).count + 1)" : "Inside \(zone.name)",
                     kind: zone.kind == .closet ? .shelf : .drawer)
        z.parentID = zone.uid
        z.posX = zone.posX
        z.posY = zone.posY
        z.posZ = zone.posZ
        z.sizeW = zone.sizeW * 0.8
        z.sizeH = max(0.1, zone.sizeH / 3)
        z.sizeD = zone.sizeD
        z.kitchenZone = zone.kitchenZone
        z.room = room
        context.insert(z)
        try? context.save()
        open = true
        onEdit(z)
    }
}
