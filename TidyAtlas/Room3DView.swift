import SceneKit
import simd
import SwiftUI
import TidyCore
import UIKit

/// Everything the 3D map needs, as plain values so the scene is rebuilt only when something changed.
struct RoomSnapshot: Equatable {
    struct ZoneMark: Equatable {
        var id: UUID
        var name: String
        var center: SIMD3<Float>
        var size: SIMD3<Float>
        var yaw: Float
        var isIdea: Bool
    }

    struct ItemMark: Equatable {
        var id: UUID
        var name: String
        var position: SIMD3<Float>
        var state: State
        var target: SIMD3<Float>?
    }

    enum State: Equatable { case toSort, outOfPlace, sorted }

    var width: Float
    var depth: Float
    var height: Float
    var walls: [WorldBox]
    var zones: [ZoneMark]
    var items: [ItemMark]
    var selected: UUID?

    @MainActor
    init(room: Room, selected: UUID?) {
        let w = Float(room.widthM), d = Float(room.depthM), h = Float(room.heightM)
        width = w
        depth = d
        height = h
        walls = room.layout?.walls ?? []
        self.selected = selected
        var centers: [UUID: SIMD3<Float>] = [:]
        zones = room.zones.map { z in
            let size = SIMD3<Float>(min(Float(z.sizeW), w), min(Float(z.sizeH), h), min(Float(z.sizeD), d))
            let bottom = min(Float(z.posY) * h, h - size.y)
            let c = SIMD3<Float>((Float(z.posX) - 0.5) * w, bottom + size.y / 2, (Float(z.posZ) - 0.5) * d)
            centers[z.uid] = c
            return ZoneMark(id: z.uid, name: z.name, center: c, size: size, yaw: Float(z.yaw), isIdea: z.isIdea)
        }
        var stacks: [String: Int] = [:]
        items = room.items.sorted { $0.createdAt < $1.createdAt }.map { it in
            var p = SIMD3<Float>((Float(it.posX) - 0.5) * w, max(Float(it.posY), 0.02) * h, (Float(it.posZ) - 0.5) * d)
            let key = "\(Int((p.x * 4).rounded())):\(Int((p.z * 4).rounded()))"
            let n = stacks[key, default: 0]
            stacks[key] = n + 1
            p.y += Float(n) * 0.14
            let state: State = it.isSorted ? .sorted : (it.outOfPlace ? .outOfPlace : .toSort)
            return ItemMark(id: it.uid, name: it.name, position: p, state: state,
                            target: it.isSorted ? nil : it.suggestedZoneID.flatMap { centers[$0] })
        }
    }
}

struct Room3DView: UIViewRepresentable {
    var snapshot: RoomSnapshot
    var onSelect: (UUID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        context.coordinator.view = view
        context.coordinator.update(snapshot)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(snapshot)
    }

    final class Coordinator: NSObject {
        let scene = SCNScene()
        let camera = SCNNode()
        var content = SCNNode()
        weak var view: SCNView?
        var onSelect: (UUID?) -> Void
        var last: RoomSnapshot?
        var lastRoomSize: SIMD3<Float>?

        init(onSelect: @escaping (UUID?) -> Void) {
            self.onSelect = onSelect
            super.init()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 50
            camera.camera?.zNear = 0.05
            scene.rootNode.addChildNode(camera)
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 650
            scene.rootNode.addChildNode(ambient)
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 700
            sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
            scene.rootNode.addChildNode(sun)
            scene.rootNode.addChildNode(content)
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let hits = view.hitTest(g.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                if let name = hit.node.name, name.hasPrefix("item:"), let id = UUID(uuidString: String(name.dropFirst(5))) {
                    onSelect(id)
                    return
                }
            }
            onSelect(nil)
        }

        func update(_ s: RoomSnapshot) {
            guard s != last else { return }
            last = s
            content.removeFromParentNode()
            content = build(s)
            scene.rootNode.addChildNode(content)
            let size = SIMD3<Float>(s.width, s.depth, s.height)
            if lastRoomSize != size {
                lastRoomSize = size
                let span = max(s.width, s.depth)
                camera.position = SCNVector3(s.width * 0.85, span * 0.95 + s.height * 0.3, s.depth * 1.1)
                camera.look(at: SCNVector3(0, s.height * 0.25, 0))
                view?.pointOfView = camera
                view?.defaultCameraController.target = SCNVector3(0, s.height * 0.25, 0)
            }
        }

        private func build(_ s: RoomSnapshot) -> SCNNode {
            let root = SCNNode()
            let teal = Palette.tealUI
            let wallColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.32, alpha: 1) : UIColor(white: 0.97, alpha: 1) }
            let floorColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.16, green: 0.2, blue: 0.25, alpha: 1)
                                                                      : UIColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1) }

            let floor = SCNNode(geometry: SCNBox(width: CGFloat(s.width), height: 0.02, length: CGFloat(s.depth), chamferRadius: 0))
            floor.geometry?.firstMaterial?.diffuse.contents = floorColor
            floor.position = SCNVector3(0, -0.01, 0)
            root.addChildNode(floor)

            if s.walls.isEmpty {
                // Dollhouse: show the two back walls only, so the room stays visible.
                root.addChildNode(wall(width: s.width, height: s.height, at: SCNVector3(0, s.height / 2, -s.depth / 2), yaw: 0, color: wallColor))
                root.addChildNode(wall(width: s.depth, height: s.height, at: SCNVector3(-s.width / 2, s.height / 2, 0), yaw: .pi / 2, color: wallColor))
            } else {
                for w in s.walls {
                    root.addChildNode(wall(width: Float(w.width), height: Float(w.height),
                                           at: SCNVector3(Float(w.cx), Float(w.cy), Float(w.cz)), yaw: Float(w.yaw), color: wallColor))
                }
            }

            for z in s.zones {
                let box = SCNBox(width: CGFloat(z.size.x), height: CGFloat(z.size.y), length: CGFloat(z.size.z), chamferRadius: 0.02)
                let m = SCNMaterial()
                m.diffuse.contents = teal.withAlphaComponent(z.isIdea ? 0.14 : 0.32)
                m.isDoubleSided = true
                m.writesToDepthBuffer = false
                box.materials = [m]
                let node = SCNNode(geometry: box)
                node.position = SCNVector3(z.center.x, z.center.y, z.center.z)
                node.eulerAngles.y = z.yaw
                root.addChildNode(node)
                root.addChildNode(SceneShapes.label(z.name, at: SCNVector3(z.center.x, z.center.y + z.size.y / 2 + 0.12, z.center.z),
                                        color: z.isIdea ? teal.withAlphaComponent(0.7) : teal))
            }

            for it in s.items {
                let selected = it.id == s.selected
                let color: UIColor = it.state == .sorted ? .systemGreen : (it.state == .outOfPlace ? .systemOrange : teal)
                let sphere = SCNSphere(radius: selected ? 0.12 : 0.075)
                sphere.firstMaterial?.diffuse.contents = color
                sphere.firstMaterial?.emission.contents = color.withAlphaComponent(selected ? 0.5 : 0.15)
                let node = SCNNode(geometry: sphere)
                node.name = "item:\(it.id.uuidString)"
                node.position = SCNVector3(it.position.x, it.position.y, it.position.z)
                root.addChildNode(node)
                if selected {
                    root.addChildNode(SceneShapes.label(it.name, at: SCNVector3(it.position.x, it.position.y + 0.25, it.position.z), color: .label))
                }
                if let target = it.target, s.selected == nil || selected {
                    root.addChildNode(SceneShapes.arc(from: it.position, to: target, color: teal.withAlphaComponent(selected ? 1 : 0.6)))
                }
            }
            return root
        }

        private func wall(width: Float, height: Float, at p: SCNVector3, yaw: Float, color: UIColor) -> SCNNode {
            let plane = SCNPlane(width: CGFloat(max(width, 0.05)), height: CGFloat(max(height, 0.05)))
            plane.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.55)
            plane.firstMaterial?.isDoubleSided = true
            plane.firstMaterial?.writesToDepthBuffer = false
            let n = SCNNode(geometry: plane)
            n.position = p
            n.eulerAngles.y = yaw
            return n
        }
    }
}
