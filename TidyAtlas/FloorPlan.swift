import SwiftUI
import TidyCore
import UIKit

/// A top-down plan of a room drawn with Core Graphics: walls, storage spots, numbered things and dashed arrows to
/// where they go, with a legend. Shown in the app and uploaded to Google Drive as floor-plan.png.
enum FloorPlan {
    static let width: CGFloat = 1400

    @MainActor
    static func image(for room: Room) -> UIImage {
        let W = max(room.widthM, 1), D = max(room.depthM, 1)
        let margin: CGFloat = 70
        let scale = min((width - 2 * margin) / CGFloat(W), 900 / CGFloat(D))
        let planW = CGFloat(W) * scale, planH = CGFloat(D) * scale
        let origin = CGPoint(x: (width - planW) / 2, y: 130)
        let items = room.items.sorted { $0.createdAt < $1.createdAt }
        let legendTop = origin.y + planH + 80
        let height = legendTop + CGFloat(items.count) * 34 + 60

        let teal = UIColor(red: 0.10, green: 0.47, blue: 0.49, alpha: 1)
        let ink = UIColor(red: 0.10, green: 0.16, blue: 0.24, alpha: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            let g = ctx.cgContext
            UIColor(red: 0.97, green: 0.95, blue: 0.92, alpha: 1).setFill()
            g.fill(CGRect(x: 0, y: 0, width: width, height: height))

            func text(_ s: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = ink, center: Bool = false) {
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
                let str = NSAttributedString(string: s, attributes: attrs)
                let sz = str.size()
                str.draw(at: center ? CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2) : p)
            }
            /// Room unit coordinates (0...1, z from the far wall) to image points.
            func pt(_ ux: Double, _ uz: Double) -> CGPoint {
                CGPoint(x: origin.x + CGFloat(ux) * planW, y: origin.y + CGFloat(uz) * planH)
            }

            text("\(room.place?.name ?? "") › \(room.name)", at: CGPoint(x: margin, y: 30), size: 40, weight: .bold)
            text(String(format: "≈ %.1f × %.1f m · %ld things, %ld to sort%@", W, D, room.items.count, room.toSort.count,
                        room.sizeFromScan ? " · measured with LiDAR" : ""),
                 at: CGPoint(x: margin, y: 80), size: 22, color: .darkGray)

            // Floor and walls.
            UIColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1).setFill()
            g.fill(CGRect(origin: origin, size: CGSize(width: planW, height: planH)))
            ink.setStroke()
            g.setLineWidth(6)
            if let walls = room.layout?.walls, !walls.isEmpty {
                for w in walls {
                    let c = w.corners
                    let a = pt((c[0].0 / W) + 0.5, (c[0].1 / D) + 0.5), b = pt((c[1].0 / W) + 0.5, (c[1].1 / D) + 0.5)
                    g.move(to: a)
                    g.addLine(to: b)
                }
                g.strokePath()
            } else {
                g.stroke(CGRect(origin: origin, size: CGSize(width: planW, height: planH)))
            }
            text("far wall", at: CGPoint(x: origin.x + planW / 2, y: origin.y - 18), size: 16, color: .gray, center: true)

            // Scale bar: 1 m.
            g.setLineWidth(4)
            g.move(to: CGPoint(x: origin.x, y: origin.y + planH + 30))
            g.addLine(to: CGPoint(x: origin.x + scale, y: origin.y + planH + 30))
            g.strokePath()
            text("1 m", at: CGPoint(x: origin.x + scale + 10, y: origin.y + planH + 18), size: 18)

            // Storage spots.
            var zoneCenter: [UUID: CGPoint] = [:]
            for z in room.zones {
                let c = pt(z.posX, z.posZ)
                zoneCenter[z.uid] = c
                let w = CGFloat(min(z.sizeW, W)) * scale, d = CGFloat(min(z.sizeD, D)) * scale
                g.saveGState()
                g.translateBy(x: c.x, y: c.y)
                g.rotate(by: CGFloat(-z.yaw))
                let r = CGRect(x: -w / 2, y: -d / 2, width: max(w, 8), height: max(d, 8))
                teal.withAlphaComponent(z.isIdea ? 0.12 : 0.28).setFill()
                g.fill(r)
                teal.setStroke()
                g.setLineWidth(3)
                if z.isIdea { g.setLineDash(phase: 0, lengths: [10, 8]) }
                g.stroke(r)
                g.restoreGState()
                text(z.name, at: CGPoint(x: c.x, y: c.y), size: 18, weight: .semibold, color: teal, center: true)
            }

            // Things, numbered, with arrows to where they go.
            for (n, it) in items.enumerated() {
                let p = pt(it.posX, it.posZ)
                let color: UIColor = it.isSorted ? .systemGreen : (it.outOfPlace ? .systemOrange : teal)
                if !it.isSorted, let id = it.suggestedZoneID, let target = zoneCenter[id] {
                    g.saveGState()
                    color.withAlphaComponent(0.7).setStroke()
                    g.setLineWidth(3)
                    g.setLineDash(phase: 0, lengths: [12, 9])
                    g.move(to: p)
                    g.addLine(to: target)
                    g.strokePath()
                    g.restoreGState()
                }
                color.setFill()
                g.fillEllipse(in: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30))
                text("\(n + 1)", at: p, size: 15, weight: .bold, color: .white, center: true)
            }

            // Legend.
            text("Things", at: CGPoint(x: margin, y: legendTop - 44), size: 26, weight: .bold)
            for (n, it) in items.enumerated() {
                var line = "\(n + 1). \(it.quantity > 1 ? "\(it.quantity)× " : "")\(it.name)"
                if let s = it.sizeText { line += "  (\(s))" }
                if let z = room.zone(it.zoneID) { line += "  · in \(z.name)" }
                if it.isSorted { line += "  ✓ put away" }
                else if let to = room.zone(it.suggestedZoneID) { line += "  → \(to.name)" }
                else if it.action != .keep { line += "  → \(it.action.label)" }
                text(line, at: CGPoint(x: margin, y: legendTop + CGFloat(n) * 34), size: 20,
                     color: it.isSorted ? .darkGray : ink)
            }
        }
    }
}

/// The plan as a zoomable picture inside the app.
struct FloorPlanView: View {
    let room: Room
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 700)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: signature) { image = FloorPlan.image(for: room) }
    }

    /// Redraws when things, spots or sizes change.
    private var signature: String {
        "\(room.items.count)-\(room.toSort.count)-\(room.zones.count)-\(room.widthM)-\(room.depthM)-"
            + room.zones.map { "\($0.posX),\($0.posZ)" }.joined()
    }
}
