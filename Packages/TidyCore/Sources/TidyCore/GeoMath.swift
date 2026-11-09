import Foundation

/// A place on Earth (WGS84 degrees).
public struct GeoPoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Turns positions in a LiDAR scan (metres, ARKit world: y up, scan started at the origin) into GPS coordinates,
/// using the GPS fix and compass heading taken when the scan started. Rough by nature: indoor GPS is good to
/// about 5–30 m and the compass to about 10–20°, but enough to know which place and which side of it.
public enum GeoMath {
    static let metresPerDegreeLatitude = 111_320.0

    public static func normalize(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Compass bearing (degrees clockwise from true north) of the scan's −Z axis, from the compass heading the
    /// camera pointed at and the camera's forward direction in the scan at the same moment.
    public static func bearingOfMinusZ(headingDegrees: Double, forwardX: Double, forwardZ: Double) -> Double {
        // Angle of the camera's direction measured clockwise from −Z (towards +X).
        let phi = atan2(forwardX, -forwardZ) * 180 / .pi
        return normalize(headingDegrees - phi)
    }

    /// Metres east and north of the scan origin for a scan position.
    public static func eastNorth(x: Double, z: Double, bearingOfMinusZ: Double) -> (east: Double, north: Double) {
        let b = bearingOfMinusZ * .pi / 180
        return (x * cos(b) - z * sin(b), -x * sin(b) - z * cos(b))
    }

    /// The point `east` and `north` metres away from `p`.
    public static func offset(_ p: GeoPoint, east: Double, north: Double) -> GeoPoint {
        let lat = p.latitude + north / metresPerDegreeLatitude
        let lon = p.longitude + east / (metresPerDegreeLatitude * max(cos(p.latitude * .pi / 180), 1e-6))
        return GeoPoint(latitude: lat, longitude: lon)
    }

    /// GPS position of a scan position.
    public static func locate(x: Double, z: Double, origin: GeoPoint, bearingOfMinusZ: Double) -> GeoPoint {
        let en = eastNorth(x: x, z: z, bearingOfMinusZ: bearingOfMinusZ)
        return offset(origin, east: en.east, north: en.north)
    }

    /// Great-circle distance in metres.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    /// The closest of `places` within `radius` metres (indoor GPS drifts, so the radius should be generous).
    public static func nearest<ID>(_ places: [(ID, GeoPoint)], to here: GeoPoint, within radius: Double) -> ID? {
        places.map { ($0.0, distance($0.1, here)) }.filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
    }

    /// Compass name for a bearing, for labels like "north arrow" text.
    public static func compassName(_ bearing: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((normalize(bearing) + 22.5) / 45) % 8]
    }
}
