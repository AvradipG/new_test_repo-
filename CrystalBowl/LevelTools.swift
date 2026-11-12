import SwiftUI
import ScanMath

/// Scan page (3.16): how to stand a core straight in the micro-CT so it turns without wobbling. A core whose end
/// is not cut square leans when it stands; slips of paper under the low side stand it straight. The angles count
/// from the reference mark (the red line, 0°) the same way as the scanning mat's ring, so the core can be set on
/// the mat with its mark at 0° and the paper slid in at the angle read off the ring.
struct LevelSection: View {
    let scan: Scan
    @AppStorage("level.paperMM") private var paperMM = 0.10
    @State private var turned = false

    var body: some View {
        if let l = scan.level {
            Section {
                content(l)
            } header: {
                Text("Standing straight in the micro-CT")
            } footer: {
                Text("Better than paper when the core is fussy: stand it in a short tube or sleeve that fits its side (the side then sets the axis, not the cut end), or have the ends faced square on a lathe or a lapping jig. Check on the micro-CT with two scout views 180° apart: the core's edges should line up.")
            }
        }
    }

    @ViewBuilder private func content(_ l: LevelReport) -> some View {
        if l.turnedOver != nil {
            Picker("Standing on", selection: $turned) {
                Text("The end it stood on").tag(false)
                Text("Turned over").tag(true)
            }
            .pickerStyle(.segmented)
        }
        let p: LevelPlan = (turned ? l.turnedOver : nil) ?? l.asScanned
        let mark: Double? = (scan.mark?.isTrusted ?? false) ? scan.mark?.angle : nil
        let s = CoreLeveller.slips(p, radiusMM: l.diameterMM / 2, markAngleDeg: mark, turnedOver: turned, paperMM: paperMM)
        let straight = p.tiltDeg < Swift.max(0.1, 1.5 * p.spreadDeg) || s.single.layers == 0
        Text(Self.leanText(p, lengthMM: l.lengthMM)).font(.callout)
        if straight {
            Label("It stands straight within what the scan can tell: no paper needed.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            LevelDial(single: s.single.angle, pair: s.pair.map { $0.angle }, markIsRed: mark != nil)
                .frame(height: 190)
            Label(Self.singleText(s.single), systemImage: "1.circle.fill").font(.callout.bold())
            Label(Self.pairText(s.pair), systemImage: "2.circle.fill").font(.callout)
        }
        Stepper(value: $paperMM, in: 0.03...0.5, step: 0.01) {
            Text(String(format: "Paper: %.2f mm a layer (printer paper about 0.10)", paperMM)).font(.footnote)
        }
        Text(Self.basisText(p, mark: mark, turned: turned)).font(.caption).foregroundStyle(.secondary)
    }

    /// Whole degrees, signed like the mat's ring.
    static func deg(_ d: Double) -> String {
        let v: Int = Int(Rotation.normalized(d).rounded())
        if v == 0 { return "0°" }
        return (v > 0 ? "+" : "−") + "\(abs(v))°"
    }

    /// For the Drive manifest.
    static func manifest(_ scan: Scan) -> Any {
        guard let l = scan.level else { return NSNull() }
        func plan(_ p: LevelPlan) -> [String: Any] {
            var d: [String: Any] = [:]
            d["tilt_deg"] = p.tiltDeg
            d["uncertainty_deg"] = p.spreadDeg
            d["lift_azimuth_model_deg"] = p.liftAzimuthDeg
            if let m = scan.mark { d["lift_angle_from_mark_deg"] = Rotation.normalized(p.liftAzimuthDeg + m.angle) }
            d["rim_gap_mm"] = p.rimGapMM
            d["method"] = p.method
            return d
        }
        var out: [String: Any] = [:]
        out["diameter_mm"] = l.diameterMM
        out["length_mm"] = l.lengthMM
        out["standing_tilt_deg"] = l.standingTiltDeg
        out["on_scanned_end"] = plan(l.asScanned)
        if let t = l.turnedOver { out["turned_over"] = plan(t) }
        out["note"] = "paper slips under the side to lift (angle from the reference mark, counter-clockwise seen from above, as on the scanning mat; mirrored when turned over) stand the axis straight; gap = tan(tilt) x (R + r cos(angle from the lift side)), the core pivoting on the opposite rim"
        return out
    }

    static func leanText(_ p: LevelPlan, lengthMM: Double) -> String {
        let offset: Double = lengthMM * tan(p.tiltDeg * .pi / 180)
        let a: String = String(format: "It leans %.2f° (± %.2f°): the top stands %.2f mm off the line of the base", p.tiltDeg, p.spreadDeg, offset)
        return a + String(format: "; under the rim on the low side the gap is %.2f mm.", p.rimGapMM)
    }

    static func singleText(_ s: (angle: Double, layers: Int, gapMM: Double)) -> String {
        let at: String = "One slip at " + Self.deg(s.angle) + " from the red line, just inside the edge: "
        return at + String(format: "%ld layer%@ (%.2f mm)", s.layers, s.layers == 1 ? "" : "s", s.gapMM)
    }

    static func pairText(_ pair: [(angle: Double, layers: Int, gapMM: Double)]) -> String {
        guard pair.count == 2 else { return "" }
        let at: String = "Steadier, two slips at " + Self.deg(pair[0].angle) + " and " + Self.deg(pair[1].angle)
        return at + String(format: ", %ld layer%@ each (%.2f mm)", pair[0].layers, pair[0].layers == 1 ? "" : "s", pair[0].gapMM)
    }

    static func basisText(_ p: LevelPlan, mark: Double?, turned: Bool) -> String {
        var t: String = mark != nil ? "0° is the red line (the reference mark); + counts counter-clockwise seen from above, as on the scanning mat. "
            : "No reference mark found: angles count from the 0° view of the sample sheet. Set the mark for angles from the red line. "
        if p.method == "as_stood" {
            t += "Measured from the lean the core had standing on its end in the scan; the table is taken as level (check it with a spirit level)."
        } else {
            t += "Measured from the face of that end against the core's side" + (turned ? ", as seen from above in the scan." : ".")
        }
        return t
    }
}

/// Top view of the core with the mat's ring: the red line at 0° (bottom), where the paper goes.
struct LevelDial: View {
    let single: Double
    let pair: [Double]
    let markIsRed: Bool

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 22
            func pt(_ deg: Double, _ rr: CGFloat) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: c.x + rr * CGFloat(sin(a)), y: c.y + rr * CGFloat(cos(a)))
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.secondary), lineWidth: 2)
            for deg in stride(from: 0.0, to: 360.0, by: 30.0) {
                var tick = Path()
                tick.move(to: pt(deg, r))
                tick.addLine(to: pt(deg, r + (deg.truncatingRemainder(dividingBy: 90) == 0 ? 9 : 5)))
                ctx.stroke(tick, with: .color(.secondary), lineWidth: 1)
            }
            // The red line at 0°.
            var mark = Path()
            mark.move(to: pt(0, r - 10))
            mark.addLine(to: pt(0, r + 10))
            ctx.stroke(mark, with: .color(markIsRed ? .red : .gray), lineWidth: 4)
            ctx.draw(Text("0°").font(.caption2.bold()), at: pt(0, r + 18))
            ctx.draw(Text("+90°").font(.caption2), at: pt(90, r + 18))
            ctx.draw(Text("−90°").font(.caption2), at: pt(-90, r + 18))
            ctx.draw(Text("180°").font(.caption2), at: pt(180, r + 18))
            for a in pair {
                let p = pt(a, r * 0.85)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.orange))
                ctx.draw(Text("2").font(.caption2.bold()).foregroundColor(.white), at: p)
            }
            let p = pt(single, r * 0.85)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.blue))
            ctx.draw(Text("1").font(.caption.bold()).foregroundColor(.white), at: p)
            // Which way the top leans.
            var arrow = Path()
            arrow.move(to: c)
            arrow.addLine(to: pt(single, r * 0.45))
            ctx.stroke(arrow, with: .color(.blue.opacity(0.6)), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
        .accessibilityLabel("Where the paper goes, seen from above, with the red line at the bottom")
    }
}
