import Foundation
import ModelIO
import simd
import ScanMath

/// Reads the reconstructed USDZ with Model I/O to measure it and convert it to lab formats.
enum MeshTools {
    static func measure(_ url: URL) -> MeshStats? {
        guard let mesh = loadMesh(url) else { return nil }
        return ScanMath.stats(positions: mesh.positions, indices: mesh.indices, unitToMM: 1000)
    }

    /// All triangles of the model in world coordinates (metres).
    static func loadMesh(_ url: URL) -> (positions: [SIMD3<Float>], indices: [UInt32])? {
        let asset = MDLAsset(url: url)
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        for mesh in meshes {
            guard let attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let base = UInt32(positions.count)
            for i in 0..<mesh.vertexCount {
                let p = attr.dataStart.advanced(by: i * attr.stride).assumingMemoryBound(to: Float.self)
                let w = world * SIMD4<Float>(p[0], p[1], p[2], 1)
                positions.append(SIMD3<Float>(w.x, w.y, w.z))
            }
            let subs = (mesh.submeshes as? [MDLSubmesh]) ?? []
            for sub in subs where sub.geometryType == .triangles {
                let map = sub.indexBuffer.map()
                let n = sub.indexCount
                switch sub.indexType {
                case .uInt32:
                    let p = map.bytes.assumingMemoryBound(to: UInt32.self)
                    for i in 0..<n { indices.append(base + p[i]) }
                case .uInt16:
                    let p = map.bytes.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<n { indices.append(base + UInt32(p[i])) }
                case .uInt8:
                    let p = map.bytes.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<n { indices.append(base + UInt32(p[i])) }
                default:
                    continue
                }
            }
        }
        guard !positions.isEmpty, !indices.isEmpty else { return nil }
        return (positions, indices)
    }

    /// Writes OBJ, PLY and STL next to the USDZ plus a text report. Returns every file to share.
    static func exportAll(_ scan: Scan) -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: scan.exportsURL, withIntermediateDirectories: true)
        var urls: [URL] = [scan.modelURL]
        let asset = MDLAsset(url: scan.modelURL)
        for ext in ["obj", "ply", "stl"] where MDLAsset.canExportFileExtension(ext) {
            let out = scan.exportsURL.appendingPathComponent("\(scan.fileStem).\(ext)")
            try? fm.removeItem(at: out)
            if (try? asset.export(to: out)) != nil, fm.fileExists(atPath: out.path) {
                urls.append(out)
            }
        }
        if let report = writeReport(scan) { urls.append(report) }
        let dims = dimensionsURL(scan)
        if (try? dimensionsData(scan).write(to: dims, options: .atomic)) != nil { urls.append(dims) }
        return urls
    }

    static func dimensionsURL(_ scan: Scan) -> URL { scan.exportsURL.appendingPathComponent("\(scan.fileStem)-dimensions.json") }

    /// Overall dimensions in one small file for other software: principal axes, upright size, volume and scale.
    static func dimensionsData(_ scan: Scan) -> Data {
        let f = scan.scaleFactor
        var d: [String: Any] = [
            "schema": "crystal-bowl.dimensions/1", "units": "mm",
            "scan_id": scan.id, "specimen_alias": scan.name,
            "app_version": AppInfo.version, "app_build": AppInfo.build,
            "scale_source": scan.caliper == nil ? "iPhone LiDAR, not independently checked" : "iPhone LiDAR, checked with calipers (see caliper_check)",
            "notes": [
                "principal_axes_mm: the model's own axes, a longest, c shortest (extents along PCA axes)",
                "upright_as_scanned_mm: height along model +Y (up during capture); length x width is the smallest rectangle around the footprint seen from above; max_diameter is the widest horizontal distance",
                "whole model: a holder or billets scanned with the rock are included",
                "exterior surface only, not CT",
            ],
        ]
        guard let s = scan.stats else {
            d["status"] = "not measured yet"
            return (try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        }
        d["status"] = "measured"
        d["principal_axes_mm"] = ["a": s.axisA, "b": s.axisB, "c": s.axisC]
        d["volume_cm3"] = s.volumeCM3
        d["mesh_closed"] = s.isClosed
        if let e = s.medianEdgeMM { d["median_edge_mm"] = e }
        if let u = s.upright {
            d["upright_as_scanned_mm"] = ["height": u.heightMM, "length": u.lengthMM, "width": u.widthMM,
                                          "max_diameter": u.maxDiameterMM, "min_width": u.minWidthMM]
        }
        if let c = scan.caliper {
            d["caliper_check"] = ["axis": c.axisName, "measured_mm": c.measuredMM, "model_mm": c.measuredMM / f, "factor": f] as [String: Any]
            var corrected: [String: Double] = ["a": s.axisA * f, "b": s.axisB * f, "c": s.axisC * f, "volume_cm3": s.volumeCM3 * f * f * f]
            if let u = s.upright {
                corrected["height"] = u.heightMM * f
                corrected["length"] = u.lengthMM * f
                corrected["width"] = u.widthMM * f
                corrected["max_diameter"] = u.maxDiameterMM * f
            }
            d["caliper_corrected_mm"] = corrected
        }
        return (try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Writes (or rewrites) the text report next to the lab formats.
    @discardableResult
    static func writeReport(_ scan: Scan) -> URL? {
        try? FileManager.default.createDirectory(at: scan.exportsURL, withIntermediateDirectories: true)
        let report = scan.exportsURL.appendingPathComponent("\(scan.fileStem)-report.txt")
        return (try? reportText(scan).write(to: report, atomically: true, encoding: .utf8)) != nil ? report : nil
    }

    /// Lab files already written for a scan (USDZ first), without regenerating anything.
    static func existingExports(_ scan: Scan) -> [URL] {
        guard scan.hasModel else { return [] }
        let fm = FileManager.default
        let others = ["stl", "ply", "obj", "mtl"].map { scan.exportsURL.appendingPathComponent("\(scan.fileStem).\($0)") }
            + [scan.exportsURL.appendingPathComponent("\(scan.fileStem)-report.txt"), dimensionsURL(scan)]
        return [scan.modelURL] + others.filter { fm.fileExists(atPath: $0.path) }
    }

    static func reportText(_ scan: Scan) -> String {
        let f = ISO8601DateFormatter()
        var lines = [
            "Crystal Bowl Scanner report",
            "Sample: \(scan.name)",
            "Scanned: \(f.string(from: scan.created))",
            "Photos: \(scan.photoCount.map(String.init) ?? "unknown") in \(scan.passes ?? 1) pass(es)",
            "Model units: metres (USDZ, OBJ, PLY, STL). Y axis is up.",
        ]
        if let s = scan.stats {
            lines.append(String(format: "Principal axes a × b × c: %.1f × %.1f × %.1f mm", s.axisA, s.axisB, s.axisC))
            lines.append(String(format: "Volume: %.2f cm³ (%@)", s.volumeCM3, s.isClosed ? "closed mesh" : "mesh has gaps, approximate"))
            lines.append("Triangles: \(s.triangleCount), vertices: \(s.vertexCount)")
            if let e = s.medianEdgeMM {
                lines.append(String(format: "Mesh detail: median triangle edge %.2f mm (mesh sampling, not validated resolution)", e))
            }
            if let u = s.upright {
                lines.append(String(format: "Upright as scanned: height %.1f mm; footprint %.1f × %.1f mm; widest across %.1f mm; narrowest %.1f mm",
                                    u.heightMM, u.lengthMM, u.widthMM, u.maxDiameterMM, u.minWidthMM))
            }
            if let c = scan.caliper {
                let axisName = c.axisName
                let f = scan.scaleFactor
                lines.append(String(format: "Caliper check: %@ = %.2f mm measured; scan %.2f mm; scan is %+.1f%% off", axisName, c.measuredMM, c.measuredMM / f, (1 / f - 1) * 100))
                lines.append(String(format: "Caliper-corrected axes a × b × c: %.1f × %.1f × %.1f mm, volume %.2f cm³ (multiply mesh coordinates by %.4f)",
                                    s.axisA * f, s.axisB * f, s.axisC * f, s.volumeCM3 * f * f * f, f))
            }
        }
        if let cov = scan.coverage, cov.count == 3 {
            lines.append(String(format: "Photo coverage of the last side (low / middle / high): %.0f%% / %.0f%% / %.0f%%", cov[0] * 100, cov[1] * 100, cov[2] * 100))
        }
        lines.append(scan.caliper == nil
            ? "Scale comes from the iPhone LiDAR. Check one axis with calipers before relying on it."
            : "Mesh files keep the LiDAR scale; apply the caliper factor above for corrected coordinates.")
        return lines.joined(separator: "\n") + "\n"
    }
}
