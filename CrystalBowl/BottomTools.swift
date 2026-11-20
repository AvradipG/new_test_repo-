import SwiftUI
import simd
import ScanMath

/// The end a core stood on (3.20). The camera can't see a face lying on the table, whichever way the phone is
/// held, so photogrammetry closes the model there with a guess. For a core the guess was a shallow dish set up
/// inside the core (a "cup"); the app fills it flat at the table, which is where that face really is.
enum BottomTools {
    /// The model with its bottom filled, as STL and OBJ, next to the full model's files.
    static func exportFilled(_ scan: Scan) -> [URL] {
        guard scan.bottomFillActive, scan.standCutY == nil, let mesh = MeshTools.loadMesh(scan) else { return [] }
        let stl = scan.exportsURL.appendingPathComponent("\(scan.fileStem)_bottom-filled.stl")
        let obj = scan.exportsURL.appendingPathComponent("\(scan.fileStem)_bottom-filled.obj")
        return StandStrip.writeMesh(mesh, stl: stl, obj: obj, title: "\(scan.name): the end it stood on (unseen) filled flat at the table, metres")
    }

    static func manifest(_ scan: Scan) -> Any {
        guard let p = scan.bottomFill else { return NSNull() }
        var out: [String: Any] = [
            "applied": scan.bottomFillOff != true,
            "cut_y_m": p.cutY,
            "floor_y_m": p.floorY,
            "hollow_depth_mm": p.recess * 1000 * scan.scaleFactor,
            "note": "the end the core stood on faced the table and was never photographed; photogrammetry closed it with a hollow guess this deep. When applied, sizes, volume, sections and levelling use the model cut at cut_y_m with the side carried straight down to a flat end at the table (floor_y_m); model files *_bottom-filled.* hold that shape and the original model is unchanged. Scanning the end itself (flip pass, or the linked upside-down scan) replaces the guess with data",
        ]
        if let g = scan.bottomFillGain { out["volume_change_share"] = g }
        return out
    }
}

extension AppModel {
    /// The user switched the flat fill of the unseen bottom on or off: measured, sliced and levelled again.
    func setBottomFill(_ scan: Scan, on: Bool) {
        guard var s = scans.first(where: { $0.id == scan.id }) else { return }
        s.bottomFillOff = on ? nil : true
        s.extrasVersion = Swift.min(s.extrasVersion ?? 0, 10)
        try? ScanStore.save(s)
        reload()
        AppLog.info("bottom", on ? "Unseen bottom filled flat (set by hand)" : "Unseen bottom left as photogrammetry made it (set by hand)", scan: s)
        Task {
            await repair(s)
            await upgradeScans()
        }
    }
}

/// On the scan page: what was done to the end it stood on, and how to scan it for real.
struct BottomSection: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan

    var body: some View {
        if let p = scan.bottomFill {
            Section {
                let depth = p.recess * 1000 * scan.scaleFactor
                Label {
                    Text(String(format: "The end it stood on was on the table, so the camera never saw it. The 3D model had closed it with a guess %.1f mm up inside the core, like a cup.", depth))
                } icon: {
                    Image(systemName: "cylinder.split.1x2").foregroundStyle(.orange)
                }
                .font(.callout)
                Toggle(isOn: Binding(get: { scan.bottomFillOff != true }, set: { model.setBottomFill(scan, on: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fill it flat at the table")
                        if let g = scan.bottomFillGain {
                            Text(String(format: "Volume %+.1f %%. Sizes, slices and levelling use the filled shape.", g * 100))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(model.repairing.contains(scan.id))
            } header: {
                Text("The bottom")
            } footer: {
                Text("A face lying on the table can't be photographed from any side, with the phone held any way up. To have the real bottom: tap \"Turn it over and scan the other side\" below (a linked scan), or choose Dimensions + detail and \"Flip the rock and scan the underside\" during the scan. Standing the rock on something narrower than it (a bottle cap) also lets the low ring see under its edge; the app cuts the stand off.")
            }
        }
    }
}
