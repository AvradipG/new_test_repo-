import Foundation

/// Where photos were taken around the rock: 3 camera heights × 24 sectors of 15°, seen from above.
/// Pure value type so the capture guide's decisions can be unit-tested without a phone.
public struct CoverageMap: Equatable {
    public static let sectorCount = 24
    public static let bandCount = 3

    public private(set) var counts: [[Int]]

    public init() {
        counts = Array(repeating: Array(repeating: 0, count: Self.sectorCount), count: Self.bandCount)
    }

    public mutating func add(band: Int, degrees: Double) {
        counts[band][Self.sector(degrees)] += 1
    }

    public func count(band: Int, degrees: Double) -> Int { counts[band][Self.sector(degrees)] }

    /// Share of sectors with at least one photo, per band (0…1).
    public var bandShare: [Double] {
        counts.map { row in Double(row.filter { $0 > 0 }.count) / Double(Self.sectorCount) }
    }

    /// Runs of empty sectors at least `minLength` long in bands that have any photo: (band, first sector, length).
    public func gaps(minLength: Int = 2) -> [(band: Int, from: Int, length: Int)] {
        var out: [(band: Int, from: Int, length: Int)] = []
        for band in 0..<Self.bandCount {
            let row = counts[band]
            guard let firstFull = row.firstIndex(where: { $0 > 0 }) else { continue }
            var run = 0, runStart = 0
            for k in 1...Self.sectorCount {
                let s = (firstFull + k) % Self.sectorCount
                if row[s] == 0 {
                    if run == 0 { runStart = s }
                    run += 1
                } else {
                    if run >= minLength { out.append((band, runStart, run)) }
                    run = 0
                }
            }
        }
        return out.sorted { $0.length > $1.length }
    }

    /// Sectors to the nearest empty sector in a band: 0 here, positive ahead, negative behind.
    public func nearestGap(fromSector sector: Int, band: Int) -> Int? {
        let row = counts[band]
        let n = Self.sectorCount
        for d in 0...(n / 2) {
            if row[(sector + d) % n] == 0 { return d }
            if row[((sector - d) % n + n) % n] == 0 { return -d }
        }
        return nil
    }

    public static func wrap(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x <= -180 { x += 360 }
        return x
    }

    public static func positive(_ d: Double) -> Double {
        let x = d.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    public static func sector(_ degrees: Double) -> Int {
        min(sectorCount - 1, Int(positive(degrees) / (360 / Double(sectorCount))))
    }

    public static func band(lookDown: Double) -> Int { lookDown < 25 ? 0 : (lookDown < 50 ? 1 : 2) }
}

/// Decides when the app should ask the camera for a photo itself.
///
/// Object Capture takes photos on its own, but it skips viewpoints it thinks it already has, so a spot the
/// coverage map shows as empty (a missed or blurred photo, a slightly different height) could stay empty no
/// matter how often the user went back. When the phone is held fairly still on an empty sector, the app now
/// requests the photo directly.
public struct ShotPlanner {
    /// Faster than this (degrees per second round the rock) a requested photo would blur.
    public var maxSpeed = 12.0
    /// The phone must stay on the empty sector this long first, so Object Capture gets the first chance.
    public var dwell: TimeInterval = 0.7
    /// At most one request per this interval.
    public var minInterval: TimeInterval = 0.9

    private var emptySince: TimeInterval?
    private var emptyKey: Int?
    private var lastRequest: TimeInterval = -.infinity

    public init() {}

    /// Called on every update. Returns true when a photo should be requested now.
    public mutating func update(map: CoverageMap, degrees: Double, lookDown: Double, speed: Double,
                                tracking: Bool, now: TimeInterval) -> Bool {
        let band = CoverageMap.band(lookDown: lookDown)
        let key = band * 100 + CoverageMap.sector(degrees)
        guard tracking, lookDown < 85, map.count(band: band, degrees: degrees) == 0 else {
            emptySince = nil
            emptyKey = nil
            return false
        }
        if emptyKey != key {
            emptyKey = key
            emptySince = now
        }
        guard abs(speed) <= maxSpeed, now - (emptySince ?? now) >= dwell, now - lastRequest >= minInterval else { return false }
        lastRequest = now
        return true
    }
}
