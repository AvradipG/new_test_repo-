import CoreLocation
import Foundation
import TidyCore

/// GPS and compass for geotagging. Asks for permission only when a whole-place scan starts (or the user turns it on);
/// afterwards photos are geotagged and the app knows which place you're at.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    @Published var location: CLLocation?
    @Published var heading: CLHeading?
    @Published var authorization: CLAuthorizationStatus

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingOrientation = .portrait
    }

    var isAllowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Continuous GPS and compass, for the length of a whole-place scan.
    func startTracking() {
        requestPermission()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// One fresh fix (within `timeout` seconds), or nil when location isn't allowed. Never asks for permission.
    func current(timeout: Double = 6) async -> CLLocation? {
        guard isAllowed else { return nil }
        if let l = location, -l.timestamp.timeIntervalSinceNow < 60 { return l }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                self.resumeAll(self.location)
            }
        }
    }

    private func resumeAll(_ l: CLLocation?) {
        let w = waiters
        waiters = []
        w.forEach { $0.resume(returning: l) }
    }

    /// "12 Oak Street, Springfield" for a fix, or nil.
    static func address(for l: CLLocation) async -> String? {
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(l).first else { return nil }
        let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? p.name : street, p.locality, p.administrativeArea].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.authorization = s }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            self.location = l
            self.resumeAll(l)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in self.heading = newHeading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resumeAll(self.location) }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
}
