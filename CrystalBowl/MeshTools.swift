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
        let report = scan.exportsURL.appendingPathComponent("\(scan.fileStem)-report.txt")
        if (try? reportText(scan).write(to: report, atomically: true, encoding: .utf8)) != nil {
            urls.append(report)
        }
        return urls
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
        }
        lines.append("Scale comes from the iPhone LiDAR. Check one axis with calipers before relying on it.")
        return lines.joined(separator: "\n") + "\n"
    }
}
