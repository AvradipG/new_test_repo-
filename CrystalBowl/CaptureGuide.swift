import Foundation
import CoreMotion
import UIKit
import simd

/// Hand-held capture guide. The motion sensors tell where the phone is around the rock (how far the
/// user has walked from the start and how steeply the camera looks down), every photo is placed on a
/// coverage map, and panorama-style haptics say when to slow down, keep going the same way or change height.
@MainActor
final class CaptureGuide: ObservableObject {
    nonisolated static let sectorCount = 24 // 15° each
    nonisolated static let hapticsKey = "capture.haptics"

    /// Camera heights, from the side to straight above. The bounds are how far the camera looks below the horizon.
    enum Band: Int, CaseIterable {
        case low, middle, high
        var name: String { ["Low", "Middle", "High"][rawValue] }
        var range: ClosedRange<Double> { [0...25, 25...50, 50...90][rawValue] }
        var advice: String {
            [
                "hold the phone low, nearly level with the rock, looking slightly down",
                "hold the phone about 30 cm away, looking down at the rock at about 35°",
                "hold the phone above the rock, looking down at about 60°",
            ][rawValue]
        }
        static func of(_ lookDown: Double) -> Band { lookDown < 25 ? .low : (lookDown < 50 ? .middle : .high) }
    }

    struct Gap: Identifiable {
        let band: Band
        let fromSector: Int
        let length: Int
        var id: String { "\(band.rawValue)-\(fromSector)" }
        var fromDegrees: Double { Double(fromSector) * 360 / Double(CaptureGuide.sectorCount) }
        var toDegrees: Double { Double(fromSector + length) * 360 / Double(CaptureGuide.sectorCount) }
        /// Clock positions with 12 o'clock where the pass started, counted the way the user walked.
        var clockText: String {
            let a = CaptureGuide.clock(fromDegrees), b = CaptureGuide.clock(toDegrees)
            return a == b ? "around \(a) o'clock" : "from \(a) to \(b) o'clock"
        }
    }

    private struct Shot { let heading: Double; let band: Band }

    /// Photos per band and sector, sectors counted from the start in the walking direction.
    @Published private(set) var coverage: [[Int]] = Array(repeating: Array(repeating: 0, count: CaptureGuide.sectorCount), count: 3)
    /// Degrees walked from the start, in the walking direction (0..<360).
    @Published private(set) var angle: Double = 0
    @Published private(set) var lookDown: Double = 35
    @Published private(set) var hint: String?
    @Published private(set) var targetBand: Band = .middle
    @Published private(set) var fillingGaps = false
    @Published private(set) var tracking = false

    private let motion = CMMotionManager()
    private var shots: [Shot] = []
    private var startHeading: Double?
    private var lastHeading: Double?
    private var lastTime: TimeInterval = 0
    private var rate: Double = 0 // smoothed, degrees per second, signed
    private var direction: Double = 0 // +1 or -1 once the user has walked far enough to tell
    private var lastShotCount = 0
    private var lastWarning = Date.distantPast
    private var backwardSince: TimeInterval?
    private var inTargetBand = true
    private var lastEmptySector: Int?
    private var lastFeedback: String?

    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let bump = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()
    private let select = UISelectionFeedbackGenerator()

    private var hapticsOn: Bool { UserDefaults.standard.object(forKey: Self.hapticsKey) as? Bool ?? true }

    // MARK: Lifecycle

    func start() {
        reset(keepCoverage: false)
        fillingGaps = false
        targetBand = .middle
        guard motion.isDeviceMotionAvailable else { tracking = false; return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        motion.startDeviceMotionUpdates(using: frames.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical)
        tracking = true
        let generators: [UIFeedbackGenerator] = [tick, bump, select, notify]
        generators.forEach { $0.prepare() }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        tracking = false
        hint = nil
    }

    /// A new pass. After a flip the rock shows a new face, so the map starts again; otherwise the pass fills gaps.
    func newPass(flipped: Bool) {
        reset(keepCoverage: !flipped)
        fillingGaps = !flipped
        targetBand = flipped ? .middle : (mostMissingBand() ?? .high)
        hint = nil
    }

    func passCompleted() {
        if hapticsOn { notify.notificationOccurred(.success) }
        hint = nil
    }

    private func reset(keepCoverage: Bool) {
        if !keepCoverage {
            shots = []
            direction = 0
            startHeading = nil
            recount()
        }
        lastHeading = nil
        rate = 0
        backwardSince = nil
        lastEmptySector = nil
    }

    // MARK: Updates (called by AppModel about ten times a second)

    func update(shotCount: Int, capturing: Bool, feedback: String?) {
        defer { lastShotCount = shotCount }
        guard tracking, let m = motion.deviceMotion else { return }
        let pose = Self.pose(m)
        lookDown = pose.lookDown
        let now = m.timestamp

        // Heading is meaningless when the camera looks straight down.
        if pose.lookDown < 80 {
            if startHeading == nil { startHeading = pose.heading }
            if let last = lastHeading, now > lastTime {
                let step = Self.wrap(pose.heading - last) / (now - lastTime)
                rate = 0.6 * rate + 0.4 * step
            }
            lastHeading = pose.heading
            lastTime = now
            let rel = Self.wrap(pose.heading - (startHeading ?? pose.heading))
            if direction == 0 && abs(rel) > 20 {
                direction = rel > 0 ? 1 : -1
                recount()
            }
            angle = Self.positive(rel * (direction == 0 ? 1 : direction))
        }

        if shotCount > lastShotCount, capturing, let heading = lastHeading, let start = startHeading {
            shots.append(Shot(heading: Self.wrap(heading - start), band: Band.of(pose.lookDown)))
            recount()
            if hapticsOn { tick.impactOccurred(intensity: 0.55) }
        }

        guard capturing else { hint = nil; return }
        guide(now: now, feedback: feedback)
    }

    private func guide(now: TimeInterval, feedback: String?) {
        var text: String?
        var warn = false

        // Object Capture's own warnings (too close, too fast, rock out of view…) get a buzz when they appear.
        if let feedback, feedback != lastFeedback { warn = true }
        lastFeedback = feedback

        let speed = abs(rate)
        if speed > 30 {
            text = "Slow down: walk around the rock more slowly"
            warn = true
        } else if direction != 0 && !fillingGaps && rate * direction < -6 {
            if backwardSince == nil { backwardSince = now }
            if now - (backwardSince ?? now) > 0.6 {
                text = "You're going back. Keep walking the same way round"
                warn = true
            }
        } else {
            backwardSince = nil
        }

        let band = Band.of(lookDown)
        let inBand = band == targetBand
        if !inBand && text == nil {
            text = band.rawValue < targetBand.rawValue
                ? "Raise the phone: \(targetBand.advice)"
                : "Lower the phone: \(targetBand.advice)"
        }
        if inBand && !inTargetBand && hapticsOn { select.selectionChanged() }
        inTargetBand = inBand

        if fillingGaps && text == nil {
            let sector = Self.sector(angle)
            let empty = coverage[targetBand.rawValue][sector] == 0
            if empty && lastEmptySector != sector && hapticsOn { bump.impactOccurred(intensity: 0.8) }
            lastEmptySector = empty ? sector : nil
            if let next = nearestGap(from: sector, band: targetBand) {
                text = next == 0 ? "Gap here: hold still while photos are taken" : "Next gap: \(abs(next) * 15)° \(next > 0 ? "ahead" : "back")"
            } else {
                text = "\(targetBand.name) ring complete"
            }
        }

        if warn && hapticsOn && Date().timeIntervalSince(lastWarning) > 1.2 {
            notify.notificationOccurred(.warning)
            lastWarning = Date()
        }
        hint = text
    }

    // MARK: Coverage

    private func recount() {
        var c = Array(repeating: Array(repeating: 0, count: Self.sectorCount), count: 3)
        let dir = direction == 0 ? 1 : direction
        for s in shots { c[s.band.rawValue][Self.sector(Self.positive(s.heading * dir))] += 1 }
        coverage = c
    }

    /// Share of sectors with at least one photo, per band (0…1).
    var bandCoverage: [Double] {
        coverage.map { row in Double(row.filter { $0 > 0 }.count) / Double(Self.sectorCount) }
    }

    /// Runs of empty sectors at least two sectors (30°) wide, biggest first.
    func gaps() -> [Gap] {
        var out: [Gap] = []
        for band in Band.allCases {
            let row = coverage[band.rawValue]
            guard row.contains(where: { $0 > 0 }) else { continue } // a band never visited is reported separately
            guard let firstFull = row.firstIndex(where: { $0 > 0 }) else { continue }
            var run = 0, runStart = 0
            for k in 1...Self.sectorCount {
                let s = (firstFull + k) % Self.sectorCount
                if row[s] == 0 {
                    if run == 0 { runStart = s }
                    run += 1
                } else {
                    if run >= 2 { out.append(Gap(band: band, fromSector: runStart, length: run)) }
                    run = 0
                }
            }
        }
        return out.sorted { $0.length > $1.length }
    }

    /// Plain-language advice for the next pass.
    func advice() -> [String] {
        var lines: [String] = []
        let cov = bandCoverage
        for band in [Band.middle, .high] where cov[band.rawValue] == 0 {
            lines.append("No photos from the \(band.name.lowercased()) height yet: \(band.advice), and walk all the way round.")
        }
        for gap in gaps().prefix(4) {
            lines.append("\(gap.band.name) height, \(gap.clockText): \(gap.band.advice).")
        }
        if lines.isEmpty {
            lines.append("Coverage looks complete for this side. Flip the rock to capture the underside.")
        } else {
            lines.append("12 o'clock is where you started this side, counting the way you walked. Tap \"Fill the gaps\" and the phone will buzz when you reach an orange sector.")
        }
        return lines
    }

    private func mostMissingBand() -> Band? {
        let cov = bandCoverage
        let candidates = [Band.middle, .high, .low].filter { cov[$0.rawValue] < 0.9 }
        return candidates.min { cov[$0.rawValue] < cov[$1.rawValue] }
    }

    /// Sectors to the nearest empty sector in a band: 0 here, positive ahead, negative behind.
    private func nearestGap(from sector: Int, band: Band) -> Int? {
        let row = coverage[band.rawValue]
        for d in 0...(Self.sectorCount / 2) {
            if row[(sector + d) % Self.sectorCount] == 0 { return d }
            if row[(sector - d + Self.sectorCount) % Self.sectorCount] == 0 { return -d }
        }
        return nil
    }

    // MARK: Geometry

    /// Camera heading (degrees, arbitrary zero) and how far the camera looks below the horizon.
    nonisolated static func pose(_ m: CMDeviceMotion) -> (heading: Double, lookDown: Double) {
        let g = SIMD3<Double>(m.gravity.x, m.gravity.y, m.gravity.z)
        let gl = max(simd_length(g), 1e-6)
        // The rear camera looks along the device's −Z axis.
        let lookDown = asin(max(-1, min(1, -g.z / gl))) * 180 / .pi
        let q = m.attitude.quaternion
        let att = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
        // Pick whichever direction of the attitude rotation sends gravity straight down in the reference frame,
        // so the result doesn't depend on the quaternion convention.
        let r = att.act(g / gl).z < att.inverse.act(g / gl).z ? att : att.inverse
        let cam = r.act(SIMD3<Double>(0, 0, -1))
        return (atan2(cam.y, cam.x) * 180 / .pi, lookDown)
    }

    nonisolated static func wrap(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x <= -180 { x += 360 }
        return x
    }

    nonisolated static func positive(_ d: Double) -> Double {
        let x = d.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    nonisolated static func sector(_ degrees: Double) -> Int {
        min(sectorCount - 1, Int(positive(degrees) / (360 / Double(sectorCount))))
    }

    nonisolated static func clock(_ degrees: Double) -> Int {
        let h = Int((positive(degrees) / 30).rounded()) % 12
        return h == 0 ? 12 : h
    }
}
