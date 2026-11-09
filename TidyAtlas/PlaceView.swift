import MapKit
import SwiftData
import SwiftUI
import TidyCore
import UIKit

/// Top-down plan of a whole place from its LiDAR scan: every room in its real position, north arrow, address.
enum PlacePlan {
    @MainActor
    static func image(for place: Place) -> UIImage? {
        let rooms = place.rooms.filter { $0.fromHouseScan && $0.layout?.originX != nil }
        guard !rooms.isEmpty else { return nil }
        var minX = Double.infinity, maxX = -Double.infinity, minZ = Double.infinity, maxZ = -Double.infinity
        for r in rooms {
            let l = r.layout!
            minX = min(minX, l.originX! - l.widthM / 2); maxX = max(maxX, l.originX! + l.widthM / 2)
            minZ = min(minZ, l.originZ! - l.depthM / 2); maxZ = max(maxZ, l.originZ! + l.depthM / 2)
        }
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
            var sub = String(format: "%ld rooms · ≈ %.0f × %.0f m", rooms.count, W, D)
            if let a = place.address { sub += " · " + a }
            if let lat = place.latitude, let lon = place.longitude {
                sub += String(format: " · %.5f, %.5f", lat, lon)
                if let acc = place.geoAccuracyM { sub += String(format: " (±%.0f m)", acc) }
            }
            text(sub, at: CGPoint(x: margin, y: 90), size: 22, color: .darkGray)

            for r in rooms {
                let l = r.layout!
                let ox = l.originX!, oz = l.originZ!
                UIColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1).setFill()
                g.fill(CGRect(origin: pt(ox - r.widthM / 2, oz - r.depthM / 2),
                              size: CGSize(width: CGFloat(r.widthM) * scale, height: CGFloat(r.depthM) * scale)))
            }
            ink.setStroke()
            g.setLineWidth(5)
            for r in rooms {
                let l = r.layout!
                for w in l.walls {
                    let c = w.corners
                    g.move(to: pt(c[0].0 + l.originX!, c[0].1 + l.originZ!))
                    g.addLine(to: pt(c[1].0 + l.originX!, c[1].1 + l.originZ!))
                }
            }
            g.strokePath()
            for r in rooms {
                let l = r.layout!
                let c = pt(l.originX!, l.originZ!)
                for z in r.zones {
                    let p = pt(l.originX! + (z.posX - 0.5) * r.widthM, l.originZ! + (z.posZ - 0.5) * r.depthM)
                    teal.withAlphaComponent(0.35).setFill()
                    g.fill(CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                }
                text(r.name, at: CGPoint(x: c.x, y: c.y - 14), size: 26, weight: .bold, center: true)
                text("\(r.items.count) things · \(r.toSort.count) to sort", at: CGPoint(x: c.x, y: c.y + 18), size: 18,
                     color: r.toSort.isEmpty ? .systemGreen : .darkGray, center: true)
            }
            // North arrow: the scan's −Z axis points to `northBearing`, so north is drawn at −bearing from "up".
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("View", selection: $view) {
                    Text("Map").tag(0)
                    Text("3D").tag(1)
                    Text("Plan").tag(2)
                }
                .pickerStyle(.segmented)
                Group {
                    switch view {
                    case 0: mapView
                    case 1:
                        if let snap = RoomSnapshot.place(place, selected: nil) {
                            Room3DView(snapshot: snap) { _ in }
                        } else { emptyHint }
                    default:
                        if let plan {
                            ScrollView([.horizontal, .vertical]) { Image(uiImage: plan).resizable().scaledToFit().frame(width: 800) }
                        } else { emptyHint }
                    }
                }
                .frame(height: 440)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                HStack {
                    Button { showScan = true } label: {
                        Label(place.houseScannedAt == nil ? "Scan the whole place" : "Scan again", systemImage: "viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    if let f = place.houseScanFile {
                        Button { quickLook = Storage.roomScanURL(f) } label: { Label("Whole place in AR", systemImage: "arkit") }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)

                ForEach(place.sortedRooms) { room in
                    NavigationLink(value: room) { RoomCard(room: room) }.buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Palette.paper)
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScan) { HouseScanSheet(place: place) }
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
        place.rooms.filter(\.fromHouseScan).compactMap { r in
            r.geo.map { RoomPin(id: r.uid, name: r.name, coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        }
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
