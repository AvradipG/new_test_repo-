import SceneKit
import SwiftUI
import TidyCore
import UIKit

/// Builds a simple, readable 3D model of a design: furniture as shaped blocks, walls, doors and windows.
enum Design3D {
    static func color(_ p: DesignPiece) -> UIColor {
        let k = p.kind
        if k.hasPrefix("rug") { return UIColor(red: 0.78, green: 0.62, blue: 0.48, alpha: 1) }
        if k.hasPrefix("sofa") || k == "armchair" || k == "bench" || k == "floor_cushion" { return UIColor(red: 0.45, green: 0.55, blue: 0.62, alpha: 1) }
        if k.hasPrefix("bed") { return UIColor(red: 0.88, green: 0.86, blue: 0.82, alpha: 1) }
        if k.hasPrefix("plant") { return UIColor(red: 0.30, green: 0.55, blue: 0.32, alpha: 1) }
        if k == "tv" || k == "tv_stand" { return UIColor(white: 0.15, alpha: 1) }
        if k == "mirror" { return UIColor(red: 0.75, green: 0.85, blue: 0.9, alpha: 1) }
        if k == "wall_art" || k == "gallery_wall" { return UIColor(red: 0.85, green: 0.55, blue: 0.35, alpha: 1) }
        if k == "curtains" { return UIColor(red: 0.85, green: 0.82, blue: 0.75, alpha: 1) }
        if FurnitureCatalog.isFixed(k) { return UIColor(white: 0.9, alpha: 1) }
        return UIColor(red: 0.72, green: 0.58, blue: 0.42, alpha: 1) // wood
    }

    private static func box(_ w: Double, _ h: Double, _ d: Double, _ c: UIColor, at p: SCNVector3, chamfer: Double = 0.02) -> SCNNode {
        let g = SCNBox(width: CGFloat(max(w, 0.01)), height: CGFloat(max(h, 0.005)), length: CGFloat(max(d, 0.01)),
                       chamferRadius: CGFloat(min(chamfer, min(w, h, d) / 2)))
        g.firstMaterial?.diffuse.contents = c
        let n = SCNNode(geometry: g)
        n.position = p
        return n
    }

    /// One piece, built around its own origin on the floor (front faces +z).
    static func node(for p: DesignPiece) -> SCNNode {
        let n = SCNNode()
        let w = p.width, d = p.depth, h = p.height, c = color(p), k = p.kind
        if k.hasPrefix("sofa") || k == "armchair" {
            if k == "sofa_l" {
                n.addChildNode(box(w, h * 0.5, d * 0.55, c, at: SCNVector3(0, Float(h * 0.25), Float(-d * 0.225))))
                n.addChildNode(box(w * 0.38, h * 0.5, d, c, at: SCNVector3(Float(w * 0.31), Float(h * 0.25), 0)))
            } else {
                n.addChildNode(box(w, h * 0.5, d, c, at: SCNVector3(0, Float(h * 0.25), 0)))
            }
            n.addChildNode(box(w, h, 0.18, c.withAlphaComponent(1), at: SCNVector3(0, Float(h / 2), Float(-d / 2 + 0.09))))
        } else if k.hasPrefix("bed") {
            n.addChildNode(box(w, h, d, c, at: SCNVector3(0, Float(h / 2), 0)))
            n.addChildNode(box(w, 1.0, 0.08, UIColor(red: 0.6, green: 0.48, blue: 0.36, alpha: 1), at: SCNVector3(0, 0.5, Float(-d / 2 + 0.04))))
            n.addChildNode(box(w * 0.8, 0.12, 0.35, .white, at: SCNVector3(0, Float(h + 0.06), Float(-d / 2 + 0.3))))
        } else if k.hasPrefix("desk") || k.hasPrefix("dining") || k.contains("table") || k == "standing_desk" || k == "nightstand" {
            let top: SCNNode
            if k == "table_round" {
                let cyl = SCNCylinder(radius: CGFloat(w / 2), height: 0.04)
                cyl.firstMaterial?.diffuse.contents = c
                top = SCNNode(geometry: cyl)
                top.position = SCNVector3(0, Float(h), 0)
            } else {
                top = box(w, 0.04, d, c, at: SCNVector3(0, Float(h), 0))
            }
            n.addChildNode(top)
            if k == "nightstand" || k == "side_table" {
                n.addChildNode(box(w * 0.9, h, d * 0.9, c, at: SCNVector3(0, Float(h / 2), 0)))
            } else {
                for sx in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
                    let leg = SCNCylinder(radius: 0.025, height: CGFloat(h))
                    leg.firstMaterial?.diffuse.contents = UIColor(white: 0.3, alpha: 1)
                    let l = SCNNode(geometry: leg)
                    l.position = SCNVector3(Float(sx * (w / 2 - 0.06)), Float(h / 2), Float(sz * (d / 2 - 0.06)))
                    n.addChildNode(l)
                } }
            }
        } else if k.hasPrefix("plant") {
            let pot = SCNCylinder(radius: CGFloat(w * 0.3), height: CGFloat(h * 0.3))
            pot.firstMaterial?.diffuse.contents = UIColor(red: 0.8, green: 0.5, blue: 0.35, alpha: 1)
            let potNode = SCNNode(geometry: pot)
            potNode.position = SCNVector3(0, Float(h * 0.15), 0)
            n.addChildNode(potNode)
            let leaves = SCNSphere(radius: CGFloat(w / 2))
            leaves.firstMaterial?.diffuse.contents = c
            let leafNode = SCNNode(geometry: leaves)
            leafNode.position = SCNVector3(0, Float(h * 0.3 + w / 2 + max(0, h * 0.7 - w) / 2), 0)
            leafNode.scale = SCNVector3(1, Float(max(1, h * 0.7 / max(w, 0.1))), 1)
            n.addChildNode(leafNode)
        } else if k.contains("lamp") {
            let pole = SCNCylinder(radius: 0.015, height: CGFloat(h * 0.8))
            pole.firstMaterial?.diffuse.contents = UIColor(white: 0.25, alpha: 1)
            let poleNode = SCNNode(geometry: pole)
            poleNode.position = SCNVector3(0, Float(h * 0.4), 0)
            n.addChildNode(poleNode)
            let shade = SCNCone(topRadius: CGFloat(w * 0.25), bottomRadius: CGFloat(w * 0.45), height: CGFloat(h * 0.25))
            shade.firstMaterial?.diffuse.contents = UIColor(red: 0.98, green: 0.93, blue: 0.8, alpha: 1)
            shade.firstMaterial?.emission.contents = UIColor(red: 1, green: 0.9, blue: 0.7, alpha: 0.6)
            let shadeNode = SCNNode(geometry: shade)
            shadeNode.position = SCNVector3(0, Float(h * 0.87), 0)
            n.addChildNode(shadeNode)
        } else if p.onWall {
            n.addChildNode(box(w, h, max(d, 0.02), c, at: SCNVector3(0, Float(p.y), 0), chamfer: 0.005))
            if k == "wall_art" || k == "gallery_wall" {
                n.addChildNode(box(w * 0.85, h * 0.8, 0.01, UIColor(red: 0.3, green: 0.45, blue: 0.5, alpha: 1),
                                   at: SCNVector3(0, Float(p.y), Float(max(d, 0.02) / 2 + 0.005)), chamfer: 0))
            }
        } else {
            n.addChildNode(box(w, h, d, c, at: SCNVector3(0, Float(h / 2), 0)))
        }
        n.position = SCNVector3(Float(p.x), 0, Float(p.z))
        n.eulerAngles.y = Float(-p.rotationDeg * .pi / 180)
        n.name = "piece:\(p.id.uuidString)"
        return n
    }

    @MainActor
    static func scene(room: Room, pieces: [DesignPiece]) -> SCNScene {
        let scene = SCNScene()
        let W = room.widthM, D = room.depthM, H = room.heightM
        let floor = box(W, 0.02, D, UIColor(red: 0.86, green: 0.78, blue: 0.66, alpha: 1), at: SCNVector3(0, -0.01, 0), chamfer: 0)
        scene.rootNode.addChildNode(floor)
        let wallColor = UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
        func wall(_ w: Double, at p: SCNVector3, yaw: Float) {
            let plane = SCNPlane(width: CGFloat(w), height: CGFloat(H))
            plane.firstMaterial?.diffuse.contents = wallColor
            plane.firstMaterial?.isDoubleSided = true
            let n = SCNNode(geometry: plane)
            n.position = p
            n.eulerAngles.y = yaw
            scene.rootNode.addChildNode(n)
        }
        if let walls = room.layout?.walls, !walls.isEmpty {
            for w in walls { wall(w.width, at: SCNVector3(Float(w.cx), Float(H / 2), Float(w.cz)), yaw: Float(w.yaw)) }
        } else {
            wall(W, at: SCNVector3(0, Float(H / 2), Float(-D / 2)), yaw: 0)
            wall(D, at: SCNVector3(Float(-W / 2), Float(H / 2), 0), yaw: .pi / 2)
        }
        for o in room.layout?.openings ?? [] {
            let c: UIColor = o.label == "window" ? UIColor(red: 0.7, green: 0.85, blue: 0.95, alpha: 1) : UIColor(red: 0.55, green: 0.4, blue: 0.3, alpha: 1)
            let n = box(o.width, o.height, 0.05, c, at: SCNVector3(Float(o.cx), Float(o.cy), Float(o.cz)), chamfer: 0)
            n.eulerAngles.y = Float(o.yaw)
            scene.rootNode.addChildNode(n)
        }
        for p in pieces { scene.rootNode.addChildNode(node(for: p)) }
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

    /// The design as a USDZ file for AR Quick Look (life-size).
    @MainActor
    static func exportUSDZ(room: Room, pieces: [DesignPiece], name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(TidyPackage.safe(name)).usdz")
        try? FileManager.default.removeItem(at: url)
        return scene(room: room, pieces: pieces).write(to: url, options: nil, delegate: nil, progressHandler: nil) ? url : nil
    }

    /// Words for where a piece is, for the picture prompt.
    static func whereWords(_ p: DesignPiece, W: Double, D: Double) -> String {
        let side = p.x < -W / 6 ? "on the left" : (p.x > W / 6 ? "on the right" : "in the middle")
        let depth = p.z < -D / 6 ? "towards the back wall" : (p.z > D / 6 ? "towards the front" : "mid-room")
        return p.onWall ? "on the \(p.z < -D / 3 ? "back" : (p.x < 0 ? "left" : "right")) wall, \(side)" : "\(side), \(depth)"
    }

    @MainActor
    static func picturePrompt(room: Room, design: DesignVariant, pieces: [DesignPiece]) -> String {
        let list = pieces.map { "- \($0.name) (\(String(format: "%.1f × %.1f m", $0.width, $0.depth))) \(whereWords($0, W: room.widthM, D: room.depthM))" }
            .joined(separator: "\n")
        return """
        Photorealistic interior photo of this same room, redesigned. Keep the room itself exactly as in the photo: walls, \
        windows, doors, floor, ceiling and camera viewpoint. Change only the furniture, decor and styling.
        Style: \(design.style.isEmpty ? design.name : design.style). \(design.rationale)
        Furniture and decor, roughly where they go (seen from the room's entrance):
        \(list)
        Calm, tidy and uncluttered, with closed storage and clear walkways. Natural light, realistic materials, no people, no text.
        """
    }
}

struct Design3DView: UIViewRepresentable {
    let room: Room
    let pieces: [DesignPiece]

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
        guard context.coordinator.last != pieces || v.scene == nil else { return }
        context.coordinator.last = pieces
        let scene = Design3D.scene(room: room, pieces: pieces)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.05
        let span = Float(max(room.widthM, room.depthM))
        cam.position = SCNVector3(Float(room.widthM) * 0.6, span * 1.1, Float(room.depthM) * 1.1)
        cam.look(at: SCNVector3(0, 0.3, 0))
        scene.rootNode.addChildNode(cam)
        let keepCamera = v.scene != nil ? v.pointOfView?.transform : nil
        v.scene = scene
        v.pointOfView = cam
        if let t = keepCamera { cam.transform = t }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last: [DesignPiece] = [] }
}
