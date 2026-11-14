import Foundation
import RoomPlan
import SwiftData
import TidyCore

/// Map versions and splitting one scan into several rooms.
extension Organizer {
    /// RoomPlan's own rooms in the latest raw scan of this room (kitchen, living room…), centres in the scan's frame.
    static func sections(of room: Room) -> [(label: String, x: Double, z: Double)] {
        guard let captured = loadCaptured(room.capturedRoomFile) else { return [] }
        return captured.sections.map { s in (label: String(describing: s.label), x: Double(s.center.x), z: Double(s.center.z)) }
    }

    func saveMapVersion(_ place: Place, name: String, context: ModelContext) {
        let v = MapVersion(name: Clamp.text(name.isEmpty ? "Map of \(Date().formatted(date: .abbreviated, time: .shortened))" : name, 80))
        v.snapshotData = place.mapSnapshot().encoded()
        v.place = place
        context.insert(v)
        try? context.save()
    }

    /// Puts the map back the way a saved version had it (rooms made later stay as they are).
    func restoreMapVersion(_ v: MapVersion, context: ModelContext) {
        guard let place = v.place, let snap = v.snapshot else { return }
        saveMapVersion(place, name: "Before going back to \(v.name)", context: context)
        apply(snap, to: place)
        ActivityLog.add(.map, "Went back to the map version \"\(v.name)\" of \(place.name)", in: context)
        try? context.save()
        scheduleDriveSync()
    }

    func apply(_ snap: MapSnapshot, to place: Place) {
        for s in snap.rooms {
            place.rooms.first { $0.uid == s.id }?.apply(s)
        }
    }

    /// One scan that covered several rooms becomes one room per RoomPlan section. The first section stays this room
    /// (with its photos, plans and designs); storage spots and things move to the room they stand in. New rooms
    /// wait for a name.
    func splitBySections(_ room: Room, context: ModelContext) -> [Room] {
        let secs = Self.sections(of: room)
        guard let layout = room.layout, secs.count > 1, let place = room.place else { return [] }
        let parts = SectionSplit.split(layout, centers: secs.map { ($0.x, $0.z) })
        guard parts.count > 1 else { return [] }
        saveMapVersion(place, name: "Before splitting \(room.name)", context: context)

        let ox = layout.originX ?? 0, oz = layout.originZ ?? 0
        let W = room.widthM, D = room.depthM
        let centers = parts.map { (secs[$0.section].x, secs[$0.section].z) }
        func world(_ ux: Double, _ uz: Double) -> (Double, Double) { ((ux - 0.5) * W + ox, (uz - 0.5) * D + oz) }
        func part(_ ux: Double, _ uz: Double) -> Int { SectionSplit.assign([world(ux, uz)], centers: centers)[0] }

        // Where every storage spot and thing goes, worked out before any size changes.
        var zonePart: [UUID: Int] = [:]
        let nodes = room.storageNodes
        for z in room.zones where z.parentID == nil || !room.zones.contains(where: { $0.uid == z.parentID }) {
            let p = part(z.posX, z.posZ)
            for id in StorageTree.subtree(of: z.uid, in: nodes) { zonePart[id] = p }
        }
        var itemPart: [UUID: Int] = [:]
        for it in room.items {
            itemPart[it.uid] = it.zoneID.flatMap { zonePart[$0] } ?? part(it.posX, it.posZ)
        }
        let zoneWorld = Dictionary(room.zones.map { ($0.uid, world($0.posX, $0.posZ)) }, uniquingKeysWith: { a, _ in a })
        let itemWorld = Dictionary(room.items.map { ($0.uid, world($0.posX, $0.posZ)) }, uniquingKeysWith: { a, _ in a })
        let parentPlacement = room.mapX != nil ? room.placement : (room.fromHouseScan ? nil : room.placement)

        var targets: [Room] = []
        for (n, p) in parts.enumerated() {
            let label = secs[p.section].label
            let nice = Room.sectionNames[label]
            let r: Room
            if n == 0 {
                r = room
                if room.needsName, let nice { room.name = nice }
            } else {
                r = Room(name: nice ?? "Area \(n + 1)")
                r.place = place
                r.fromHouseScan = room.fromHouseScan
                r.needsName = true
                r.sectionsSplit = true
                context.insert(r)
            }
            r.sectionLabel = label
            if r.roomType.isEmpty || n > 0, label != "unidentified" { r.roomType = label }
            r.layout = p.layout
            r.widthM = p.layout.widthM
            r.depthM = p.layout.depthM
            r.heightM = p.layout.heightM
            r.sizeFromScan = true
            r.boundaryEdited = false
            if let pp = parentPlacement {
                let q = pp.toPlace(x: (p.layout.originX ?? 0) - ox, z: (p.layout.originZ ?? 0) - oz)
                r.mapX = q.x
                r.mapZ = q.z
                r.mapRotationDeg = pp.rotationDeg
            } else if n > 0 {
                r.mapX = nil
                r.mapZ = nil
            }
            targets.append(r)
        }
        room.sectionsSplit = true

        func unit(_ w: (Double, Double), in r: Room) -> (Double, Double) {
            let l = r.layout
            return (Clamp.unit((w.0 - (l?.originX ?? 0)) / r.widthM + 0.5), Clamp.unit((w.1 - (l?.originZ ?? 0)) / r.depthM + 0.5))
        }
        for z in room.zones {
            guard let p = zonePart[z.uid], let w = zoneWorld[z.uid] else { continue }
            let target = targets[p]
            let u = unit(w, in: target)
            z.posX = u.0
            z.posZ = u.1
            if target !== room { z.room = target }
        }
        for it in room.items {
            guard let p = itemPart[it.uid], let w = itemWorld[it.uid] else { continue }
            let target = targets[p]
            let u = unit(w, in: target)
            it.posX = u.0
            it.posZ = u.1
            if target !== room { it.room = target }
        }
        let names = targets.map(\.name).joined(separator: ", ")
        ActivityLog.add(.map, "Split the scan of \(room.name) into \(targets.count) rooms: \(names)", room: room, in: context)
        try? context.save()
        scheduleDriveSync()
        return Array(targets.dropFirst())
    }
}
