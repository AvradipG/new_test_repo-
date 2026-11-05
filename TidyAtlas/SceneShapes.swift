import SceneKit
import simd
import UIKit

/// Labels and "where it goes" arcs, shared by the 3D map and the AR view.
enum SceneShapes {
    static func label(_ text: String, at p: SCNVector3, color: UIColor, scale: Float = 0.012) -> SCNNode {
        let t = SCNText(string: text, extrusionDepth: 0.2)
        t.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        t.flatness = 0.3
        t.firstMaterial?.diffuse.contents = color
        t.firstMaterial?.readsFromDepthBuffer = false
        let n = SCNNode(geometry: t)
        let (minB, maxB) = n.boundingBox
        n.pivot = SCNMatrix4MakeTranslation((maxB.x - minB.x) / 2 + minB.x, minB.y, 0)
        n.scale = SCNVector3(scale, scale, scale)
        let holder = SCNNode()
        holder.position = p
        holder.addChildNode(n)
        holder.constraints = [SCNBillboardConstraint()]
        holder.renderingOrder = 10
        return holder
    }

    /// A raised curve from an item to where it belongs.
    static func arc(from a: SIMD3<Float>, to b: SIMD3<Float>, color: UIColor, lift: Float = 0.8, radius: CGFloat = 0.012) -> SCNNode {
        let mid = SIMD3<Float>((a.x + b.x) / 2, max(a.y, b.y) + lift, (a.z + b.z) / 2)
        let steps = 24
        var points: [SCNVector3] = []
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let u: Float = 1 - t
            let wa: Float = u * u, wm: Float = 2 * u * t, wb: Float = t * t
            let p: SIMD3<Float> = wa * a + wm * mid + wb * b
            points.append(SCNVector3(p.x, p.y, p.z))
        }
        let node = SCNNode()
        for i in 0..<steps where i % 2 == 0 {
            node.addChildNode(segment(points[i], points[i + 1], color: color, radius: radius))
        }
        let dot = SCNNode(geometry: SCNSphere(radius: radius * 3.3))
        dot.geometry?.firstMaterial?.diffuse.contents = color
        dot.position = points.last!
        node.addChildNode(dot)
        return node
    }

    static func segment(_ a: SCNVector3, _ b: SCNVector3, color: UIColor, radius: CGFloat = 0.012) -> SCNNode {
        let va = SIMD3<Float>(a.x, a.y, a.z), vb = SIMD3<Float>(b.x, b.y, b.z)
        let len = simd_length(vb - va)
        let cyl = SCNCylinder(radius: radius, height: CGFloat(len))
        cyl.firstMaterial?.diffuse.contents = color
        cyl.firstMaterial?.lightingModel = .constant
        let n = SCNNode(geometry: cyl)
        n.simdPosition = (va + vb) / 2
        let dir = simd_normalize(vb - va)
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
        return n
    }
}
