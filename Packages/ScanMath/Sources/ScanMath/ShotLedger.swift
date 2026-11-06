import Foundation

/// Counts the photos of a capture and decides where each new photo belongs on the coverage map (3.3).
///
/// Three things made gaps stay orange on a later pass:
/// - the capture session's own photo count can restart on a new pass, or lag behind the photos written to disk;
/// - a photo the app asked for arrives a moment later, when the phone may already have moved on;
/// - a request the camera ignored was asked again every second, using up the photo budget and never showing why.
/// The ledger keeps one running total (the larger of the session count, made cumulative, and the files on
/// disk), places a requested photo where it was asked for, and counts requests that produced nothing.
public struct ShotLedger: Equatable {
    public struct Pose: Equatable {
        public var degrees: Double
        public var band: Int
        public init(degrees: Double, band: Int) { self.degrees = degrees; self.band = band }
        public var key: Int { band * 100 + CoverageMap.sector(degrees) }
    }

    public private(set) var counted = 0
    public private(set) var requests = 0
    public private(set) var landed = 0
    public private(set) var failed = 0
    /// Requests per spot (band × sector) that produced no photo.
    public private(set) var failures: [Int: Int] = [:]
    /// The last request that produced no photo was the user's own tap.
    public private(set) var lastFailureWasManual = false
    /// How long a requested photo may take to show up.
    public var timeout: TimeInterval = 3.5

    private var sessionBase = 0
    private var lastSession = 0
    private var pending: Pose?
    private var pendingAt: TimeInterval = 0
    private var pendingManual = false

    public init() {}

    public var waiting: Bool { pending != nil }
    public func failures(at pose: Pose) -> Int { failures[pose.key] ?? 0 }

    /// The app asked the camera for a photo from `pose`.
    public mutating func requested(_ pose: Pose, manual: Bool, now: TimeInterval) {
        pending = pose
        pendingAt = now
        pendingManual = manual
        requests += 1
    }

    /// `session`: the capture session's photo count (it may restart at 0); `files`: photos on disk when known.
    /// Returns where each new photo goes, oldest first.
    public mutating func update(session: Int, files: Int?, pose: Pose, now: TimeInterval) -> [Pose] {
        if session < lastSession { sessionBase += lastSession }
        lastSession = session
        let total = max(sessionBase + session, files ?? 0)
        var out: [Pose] = []
        if total > counted {
            for i in 0..<(total - counted) {
                if i == 0, let p = pending, now - pendingAt <= timeout {
                    out.append(p)
                    landed += 1
                    pending = nil
                    lastFailureWasManual = false
                    failures[p.key] = nil
                } else {
                    out.append(pose)
                }
            }
            counted = total
        } else if let p = pending, now - pendingAt > timeout {
            failures[p.key, default: 0] += 1
            failed += 1
            lastFailureWasManual = pendingManual
            pending = nil
        }
        return out
    }
}

/// Plain directions for filling the gaps on the coverage map.
public enum GapGuide {
    /// Rings to fill, in order: rings the user walked (a quarter or more done, most complete first, so a ring is
    /// finished before the next height), then the untouched middle and high rings, then rings with only a few
    /// stray photos.
    public static func fillOrder(_ map: CoverageMap) -> [Int] {
        let share = map.bandShare
        let open = (0..<CoverageMap.bandCount).filter { share[$0] > 0 && share[$0] < 1 }.sorted { share[$0] > share[$1] }
        let walked = open.filter { share[$0] >= 0.25 }
        let stray = open.filter { share[$0] < 0.25 }
        let untouched = [1, 2].filter { share[$0] == 0 }
        return walked + untouched + stray
    }

    /// Where to go next, from the signed number of sectors to the nearest gap (positive = the way the user walked).
    /// `radius` is the distance from the rock in metres, for the length to walk round.
    public static func moveText(sectors d: Int, radius: Double = 0.33) -> String {
        if d == 0 { return "Gap here: hold the phone still for a second and the photo is taken for you" }
        let degrees = abs(d) * 360 / CoverageMap.sectorCount
        let cm = max(5, Int((Double(degrees) * .pi / 180 * radius * 100 / 5).rounded()) * 5)
        let way = d > 0 ? "on, the same way you were walking" : "back, the way you came"
        return "Next gap: go \(degrees)° \(way), about \(cm) cm round the rock, keeping the rock in the middle of the screen"
    }
}
