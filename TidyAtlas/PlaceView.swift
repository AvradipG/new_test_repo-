import MapKit
import SwiftData
import SwiftUI
import TidyCore
import UIKit

/// Top-down plan of a whole place from its LiDAR scan: every room in its real position, north arrow, address.
enum PlacePlan {
    @MainActor
    static func image(for place: Place) -> UIImage? {
        let mapped = place.mappedRooms
        guard !mapped.isEmpty else { return nil }
        let pts = mapped.flatMap { $0.1.corners(width: $0.0.widthM, depth: $0.0.depthM) }
        let minX = pts.map(\.0).min()!, maxX = pts.map(\.0).max()!
        let minZ = pts.map(\.1).min()!, maxZ = pts.map(\.1).max()!
        let W = max(maxX - minX, 1), D = max(maxZ - minZ, 1)
        let width: CGFloat = 1600, margin: CGFloat = 80
        let scale = min((width - 2 * margin) / CGFloat(W), 1100 / CGFloat(D))
        let origin = CGPoint(x: (width - CGFloat(W) * scale) / 2, y: 170)
        let height = origin.y + CGFloat(D) * scale + 140
        let ink = UIColor(red: 0.10, green: 0.16, blue: 0.24, alpha: 1)
        let teal = UIColor(red: 0.10, green: 0.47, blue: 0.49, alpha: 1)
        func pt(_ x: Double, _ z: Double) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(x - minX) * scale, y: origin.y + CGFloat(z - minZ) * scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            let g = ctx.cgContext
            UIColor(red: 0.97, green: 0.95, blue: 0.92, alpha: 1).setFill()
            g.fill(CGRect(x: 0, y: 0, width: width, height: height))
            func text(_ s: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = ink, center: Bool = false) {
                let str = NSAttributedString(string: s, attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
                let sz = str.size()
                str.draw(at: center ? CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2) : p)
            }
            text(place.name, at: CGPoint(x: margin, y: 30), size: 44, weight: .bold)
            var sub = String(format: "%ld rooms · ≈ %.0f × %.0f m", mapped.count, W, D)
            if let a = place.address { sub += " · " + a }
            if let lat = place.latitude, let lon = place.longitude {
                sub += String(format: " · %.5f, %.5f", lat, lon)
                if let acc = place.geoAccuracyM { sub += String(format: " (±%.0f m)", acc) }
            }
            text(sub, at: CGPoint(x: margin, y: 90), size: 22, color: .darkGray)

            for (r, pl) in mapped {
                let c = pl.corners(width: r.widthM, depth: r.depthM)
                let path = CGMutablePath()
                path.addLines(between: c.map { pt($0.0, $0.1) })
                path.closeSubpath()
                g.addPath(path)
                UIColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1).setFill()
                g.fillPath()
            }
            ink.setStroke()
            g.setLineWidth(5)
            for (r, pl) in mapped {
                if let walls = r.layout?.walls, !walls.isEmpty {
                    for w in walls {
                        let c = w.corners
                        let a = pl.toPlace(x: c[0].0, z: c[0].1), b = pl.toPlace(x: c[1].0, z: c[1].1)
                        g.move(to: pt(a.x, a.z))
                        g.addLine(to: pt(b.x, b.z))
                    }
                } else {
                    let c = pl.corners(width: r.widthM, depth: r.depthM)
                    g.addLines(between: (c + [c[0]]).map { pt($0.0, $0.1) })
                }
            }
            g.strokePath()
            for (r, pl) in mapped {
                for z in r.zones where z.parentID == nil {
                    let q = pl.toPlace(x: (z.posX - 0.5) * r.widthM, z: (z.posZ - 0.5) * r.depthM)
                    let p = pt(q.x, q.z)
                    teal.withAlphaComponent(0.35).setFill()
                    g.fill(CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                }
                let c = pt(pl.x, pl.z)
                text(r.displayName, at: CGPoint(x: c.x, y: c.y - 14), size: 26, weight: .bold, color: r.needsName ? .systemOrange : ink, center: true)
                text("\(r.items.count) things · \(r.toSort.count) to sort", at: CGPoint(x: c.x, y: c.y + 18), size: 18,
                     color: r.toSort.isEmpty ? .systemGreen : .darkGray, center: true)
            }
            if let b = place.northBearing {
                let center = CGPoint(x: width - margin - 30, y: 70)
                let a = CGFloat(-b) * .pi / 180
                let tip = CGPoint(x: center.x + 40 * sin(a), y: center.y - 40 * cos(a))
                let tail = CGPoint(x: center.x - 25 * sin(a), y: center.y + 25 * cos(a))
                UIColor.systemRed.setStroke()
                g.setLineWidth(6)
                g.move(to: tail)
                g.addLine(to: tip)
                g.strokePath()
                text("N", at: CGPoint(x: tip.x + 14 * sin(a), y: tip.y - 14 * cos(a)), size: 22, weight: .bold, color: .systemRed, center: true)
            }
            ink.setStroke()
            g.setLineWidth(4)
            g.move(to: CGPoint(x: origin.x, y: height - 70))
            g.addLine(to: CGPoint(x: origin.x + scale, y: height - 70))
            g.strokePath()
            text("1 m", at: CGPoint(x: origin.x + scale + 10, y: height - 84), size: 18)
        }
    }
}

/// Everything about one place: map with GPS pins, the whole place in 3D and AR, and its floor plan.
struct PlaceView: View {
    @Bindable var place: Place
    @Environment(\.modelContext) private var context
    @State private var view = 0
    @State private var showScan = false
    @State private var quickLook: URL?
    @State private var plan: UIImage?
    @State private var addRooms = false
    @State private var rescanRoom: Room?
    @State private var naming: Room?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("View", selection: $view) {
                    Text("Map").tag(0)
                    Text("3D").tag(1)
                    Text("Plan").tag(2)
                    Text("Edit map").tag(3)
                }
                .pickerStyle(.segmented)
                Group {
                    switch view {
                    case 0: mapView
                    case 1:
                        if let snap = RoomSnapshot.place(place, selected: nil) {
                            Room3DView(snapshot: snap) { _ in }
                        } else { emptyHint }
                    case 3:
                        PlaceMapEditor(place: place)
                    default:
                        if let plan {
                            ScrollView([.horizontal, .vertical]) { Image(uiImage: plan).resizable().scaledToFit().frame(width: 800) }
                        } else { emptyHint }
                    }
                }
                .frame(minHeight: view == 3 ? 520 : 440, maxHeight: view == 3 ? .infinity : 440)
                .background(view == 3 ? Color.clear : Palette.card, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                scanButtons

                let unnamed = place.sortedRooms.filter(\.needsName)
                if !unnamed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(unnamed.count) room\(unnamed.count == 1 ? "" : "s") waiting for a name", systemImage: "tag").font(.headline)
                        ForEach(unnamed) { r in
                            Button { naming = r } label: { Label(r.name, systemImage: "pencil") }
                        }
                    }
                    .card(Color.orange.opacity(0.15))
                }

                ForEach(place.sortedRooms) { room in
                    NavigationLink(value: room) { RoomCard(room: room) }.buttonStyle(.plain)
                }

                if !place.scans.isEmpty { history }
            }
            .padding()
        }
        .background(Palette.paper)
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScan) { HouseScanSheet(place: place) }
        .fullScreenCover(isPresented: $addRooms) { HouseScanSheet(place: place, addToMap: true) }
        .fullScreenCover(item: $rescanRoom) { HouseScanSheet(place: place, rescan: $0) }
        .sheet(item: $naming) { RoomNameSheet(room: $0) }
        .alert("Scans", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .quickLookPreview($quickLook)
        .task(id: "\(place.rooms.count)-\(place.houseScannedAt?.timeIntervalSince1970 ?? 0)") { plan = PlacePlan.image(for: place) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(place.name, systemImage: place.kind.symbol).font(.display(.largeTitle))
            if let a = place.address { Label(a, systemImage: "mappin.and.ellipse").foregroundStyle(.secondary) }
            if let lat = place.latitude, let lon = place.longitude {
                Text(String(format: "%.5f, %.5f", lat, lon) + (place.geoAccuracyM.map { String(format: " · ±%.0f m", $0) } ?? "")
                     + (place.northBearing.map { " · scan faces \(GeoMath.compassName($0))" } ?? ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let when = place.houseScannedAt {
                Text("Whole place scanned \(when.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var mapView: some View {
        if let geo = place.geo {
            let center = CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
            Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 120, longitudinalMeters: 120))) {
                Marker(place.name, systemImage: place.kind.symbol, coordinate: center).tint(Palette.teal)
                ForEach(roomPins) { pin in
                    Annotation(pin.name, coordinate: pin.coordinate) {
                        Image(systemName: "square.split.bottomrightquarter.fill")
                            .padding(5).background(.white, in: Circle()).foregroundStyle(Palette.teal)
                    }
                }
            }
            .mapStyle(.hybrid)
        } else {
            emptyHint
        }
    }

    struct RoomPin: Identifiable {
        let id: UUID
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private var roomPins: [RoomPin] {
        place.rooms.filter { $0.placement != nil }.compactMap { r in
            r.geo.map { RoomPin(id: r.uid, name: r.name, coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        }
    }

    private var scanButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { if place.houseScannedAt == nil { showScan = true } else { addRooms = true } } label: {
                    Label(place.houseScannedAt == nil ? "Scan the whole place" : "Add rooms", systemImage: "plus.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                Menu {
                    ForEach(place.sortedRooms) { r in
                        Button(r.displayName) { rescanRoom = r }
                    }
                } label: { Label("Rescan a room", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .disabled(place.rooms.isEmpty)
            }
            .controlSize(.large)
            HStack {
                if let f = place.houseScanFile {
                    Button { quickLook = Storage.roomScanURL(f) } label: { Label("Whole place in AR", systemImage: "arkit") }
                }
                Menu {
                    Button("Read saved scans with this version", systemImage: "arrow.triangle.2.circlepath") {
                        let n = organizer.refreshScans(of: place, context: context)
                        message = n == 0 ? "No saved raw scans yet (rooms scanned from version 1.5 on keep theirs)." : "Updated \(n) room\(n == 1 ? "" : "s") from their saved scans. Your corrections, things and designs stayed."
                    }
                    Button("Rebuild the whole-place 3D model", systemImage: "cube") {
                        Task { message = await organizer.rebuildPlaceModel(place, context: context) ? "3D model rebuilt from every room's latest scan." : "No rooms with saved scans that share the map yet." }
                    }
                    Button("Start a brand-new scan of the place", systemImage: "viewfinder") { showScan = true }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
            .buttonStyle(.bordered)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan history").font(.display(.headline))
            Text("Every scan is kept. Open one in AR or put a room back the way that scan saw it.").font(.footnote).foregroundStyle(.secondary)
            ForEach(place.scans.sorted { $0.date > $1.date }) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(s.kind).font(.body.weight(.semibold))
                        Spacer()
                        Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(s.roomNames.joined(separator: ", ") + (s.joinedMap ? "" : " · placed by hand")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if let f = s.usdzFile, FileManager.default.fileExists(atPath: Storage.roomScanURL(f).path) {
                            Button("View in AR") { quickLook = Storage.roomScanURL(f) }
                        }
                        Menu("Restore a room") {
                            ForEach(place.rooms.filter { s.roomFiles[$0.uid.uuidString] != nil }) { r in
                                Button(r.displayName) {
                                    message = organizer.restore(r, from: s, context: context)
                                        ? "\(r.name) is back the way this scan saw it. Things, storage spots and designs stayed."
                                        : "That scan's file is missing."
                                }
                            }
                        }
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .card()
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "viewfinder").font(.largeTitle).foregroundStyle(.secondary)
            Text("Scan the whole place with LiDAR to see it here, geotagged with the phone's GPS.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
