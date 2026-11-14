import SceneKit
import SwiftUI
import TidyCore
import UIKit

/// The whole place in 3D: every room on the map in its real position, empty (walls, doors, windows) or furnished
/// (each room's furniture as it is, or the design marked as current).
enum Place3D {
    @MainActor
    static func scene(_ place: Place, furnished: Bool) -> SCNScene? {
        let mapped = place.mappedRooms
        guard !mapped.isEmpty else { return nil }
        let pts = mapped.flatMap { $0.1.corners(width: $0.0.widthM, depth: $0.0.depthM) }
        let cx = ((pts.map(\.0).min() ?? 0) + (pts.map(\.0).max() ?? 0)) / 2
        let cz = ((pts.map(\.1).min() ?? 0) + (pts.map(\.1).max() ?? 0)) / 2
        let scene = SCNScene()
        for (room, pl) in mapped {
            let pieces = furnished ? furniture(of: room) : []
            let roomScene = Design3D.scene(room: room, pieces: pieces)
            let holder = SCNNode()
            holder.name = "room:\(room.uid.uuidString)"
            holder.position = SCNVector3(Float(pl.x - cx), 0, Float(pl.z - cz))
            holder.eulerAngles.y = Float(-pl.rotationDeg * .pi / 180)
            for child in roomScene.rootNode.childNodes where child.light == nil {
                child.removeFromParentNode()
                holder.addChildNode(child)
            }
            let label = SCNText(string: room.needsName ? "Name me" : room.name, extrusionDepth: 0.02)
            label.font = UIFont.systemFont(ofSize: 0.3, weight: .bold)
            label.flatness = 0.05
            label.firstMaterial?.diffuse.contents = room.needsName ? UIColor.systemOrange : UIColor(red: 0.1, green: 0.16, blue: 0.24, alpha: 1)
            let text = SCNNode(geometry: label)
            let (lo, hi) = text.boundingBox
            text.pivot = SCNMatrix4MakeTranslation((hi.x - lo.x) / 2 + lo.x, 0, 0)
            text.position = SCNVector3(0, Float(room.heightM) + 0.25, 0)
            text.constraints = [SCNBillboardConstraint()]
            holder.addChildNode(text)
            scene.rootNode.addChildNode(holder)
        }
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 800
        light.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 6, 0)
        scene.rootNode.addChildNode(light)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    /// The room's current design if it has one, otherwise the furniture from its scan and storage spots.
    @MainActor
    static func furniture(of room: Room) -> [DesignPiece] {
        if let d = room.designs.first(where: \.isCurrent) { return d.pieces }
        return room.scannedPieces()
    }

    /// The place as USDZ for AR Quick Look (life-size).
    @MainActor
    static func exportUSDZ(_ place: Place, furnished: Bool) -> URL? {
        guard let scene = scene(place, furnished: furnished) else { return nil }
        scene.rootNode.enumerateChildNodes { n, _ in n.constraints = nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(TidyPackage.safe(place.name))-\(furnished ? "furnished" : "empty").usdz")
        try? FileManager.default.removeItem(at: url)
        return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) ? url : nil
    }

    /// Size of the place on the map (for the camera).
    @MainActor
    static func span(_ place: Place) -> Float {
        let pts = place.mappedRooms.flatMap { $0.1.corners(width: $0.0.widthM, depth: $0.0.depthM) }
        let w = (pts.map(\.0).max() ?? 4) - (pts.map(\.0).min() ?? 0)
        let d = (pts.map(\.1).max() ?? 4) - (pts.map(\.1).min() ?? 0)
        return Float(max(w, d, 4))
    }
}

struct Place3DView: UIViewRepresentable {
    let place: Place
    let furnished: Bool
    /// Changes when the map or the furniture changes, so the scene is rebuilt only then.
    let version: String

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .clear
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        v.defaultCameraController.interactionMode = .orbitTurntable
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        let key = "\(furnished)-\(version)"
        guard context.coordinator.last != key || v.scene == nil else { return }
        context.coordinator.last = key
        guard let scene = Place3D.scene(place, furnished: furnished) else {
            v.scene = nil
            return
        }
        let span = Place3D.span(place)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.05
        cam.camera?.zFar = Double(span) * 10
        cam.position = SCNVector3(span * 0.35, span * 0.9, span * 0.8)
        cam.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cam)
        let keep = v.scene != nil ? v.pointOfView?.transform : nil
        v.scene = scene
        v.pointOfView = cam
        if let keep { cam.transform = keep }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = "" }
}
